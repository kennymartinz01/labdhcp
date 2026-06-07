#!/bin/bash
# ============================================================
# LAB 3 DHCP - GATEWAY VM (VM 1) - pipe-ready
# Run: wget -qO- <RAW_URL> | tr -d '\r' | sudo bash
#
# This VM = 192.168.55.1 | Relay gets 192.168.55.2
# Provides: Kea DHCP on 192.168.55.0/29, routing to the
# 192.168.55.80/28 (node) network, and NAT masquerade so the
# inner network reaches the internet. All reboot-persistent.
# NAT interface is hardcoded to enp0s3.
# ============================================================
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info(){ echo -e "${BLUE}[INFO]${NC} $1"; }
success(){ echo -e "${GREEN}[DONE]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
error(){ echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

# NAT interface is hardcoded per setup
NAT_IF="enp0s3"

echo -e "${BLUE}=== LAB 3 DHCP - GATEWAY VM SETUP ===${NC}"
echo "Subnet 192.168.55.0/29 | This VM 192.168.55.1 | Relay gets 192.168.55.2"
echo "NAT interface: $NAT_IF (hardcoded) | masquerade + persistent internet"
echo ""

# Detect the internal (intnet) interface = the non-lo, non-NAT NIC
INTNET_IF=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | grep -v "$NAT_IF" | head -1)
[ -z "$INTNET_IF" ] && INTNET_IF="enp0s8"
info "intnet interface: $INTNET_IF | NAT interface: $NAT_IF"

# ------------------------------------------------------------
# Netplan: NAT dynamic, intnet static .1/29 + route to node net
# ------------------------------------------------------------
info "Writing netplan..."
cat > /etc/netplan/99_config.yaml << EOF
network:
  version: 2
  ethernets:
    ${NAT_IF}:
      dhcp4: yes
    ${INTNET_IF}:
      dhcp4: no
      addresses: [192.168.55.1/29]
      routes:
        - to: 192.168.55.80/28
          via: 192.168.55.2
EOF
chmod 600 /etc/netplan/99_config.yaml
netplan apply; sleep 2
success "Netplan applied - $INTNET_IF = 192.168.55.1/29"

# ------------------------------------------------------------
# IP forwarding - PERSISTENT via /etc/sysctl.d (survives reboot)
# ------------------------------------------------------------
info "Enabling IP forwarding (persistent)..."
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-ipforward.conf
sysctl --system > /dev/null 2>&1
FWD=$(sysctl -n net.ipv4.ip_forward)
[ "$FWD" = "1" ] && success "IP forwarding enabled and persistent (=1)" || error "IP forwarding not active"

# ------------------------------------------------------------
# Install Kea
# ------------------------------------------------------------
info "Installing Kea..."
export DEBIAN_FRONTEND=noninteractive
apt-get update > /dev/null 2>&1 || true
apt-get install -y kea > /dev/null 2>&1
success "Kea installed"

# Mask conflicting services
systemctl stop kea-ctrl-agent isc-dhcp-relay 2>/dev/null || true
systemctl disable kea-ctrl-agent isc-dhcp-relay 2>/dev/null || true
systemctl mask kea-ctrl-agent isc-dhcp-relay 2>/dev/null || true
success "kea-ctrl-agent and isc-dhcp-relay masked permanently"

# ------------------------------------------------------------
# Kea config
# ------------------------------------------------------------
info "Writing Kea config..."
mkdir -p /etc/kea
cat > /etc/kea/kea-dhcp4.conf << EOF
{
  "Dhcp4": {
    "interfaces-config": { "interfaces": ["${INTNET_IF}"] },
    "lease-database": {
      "type": "memfile",
      "persist": true,
      "name": "/var/lib/kea/kea-leases4.csv"
    },
    "subnet4": [{
      "id": 1,
      "subnet": "192.168.55.0/29",
      "pools": [{"pool": "192.168.55.2 - 192.168.55.6"}],
      "option-data": [
        {"name": "routers", "data": "192.168.55.1"},
        {"name": "domain-name-servers", "data": "8.8.8.8"}
      ]
    }]
  }
}
EOF

# Permissions
mkdir -p /run/kea /var/lib/kea
chown -R _kea:_kea /etc/kea /run/kea /var/lib/kea
chmod 640 /etc/kea/kea-dhcp4.conf

# Test and start Kea
info "Testing Kea config..."
sudo -u _kea kea-dhcp4 -t /etc/kea/kea-dhcp4.conf || error "Kea config test failed"
success "Kea config syntax OK"
systemctl restart kea-dhcp4-server; sleep 2
systemctl is-active kea-dhcp4-server > /dev/null || error "Kea failed to start"
success "Kea DHCP server is running"

# Verify port 67
PORT67=$(ss -ulnp | grep ':67' | awk '{print $NF}')
echo "$PORT67" | grep -q "kea" && success "Port 67 owned by kea-dhcp4" || warn "Port 67: $PORT67"

# ------------------------------------------------------------
# NAT MASQUERADE via nftables (so inner net reaches internet)
# ------------------------------------------------------------
info "Configuring nft masquerade on $NAT_IF..."
# Clear any iptables-translated leftovers to avoid duplicate NAT
iptables -t nat -F 2>/dev/null || true
iptables -F 2>/dev/null || true

# Build the nft ruleset: nat table + postrouting masquerade (with counter),
# and a filter forward chain that accepts (forwarding already enabled above).
nft flush ruleset
nft add table ip nat
nft add chain ip nat POSTROUTING '{ type nat hook postrouting priority 100 ; policy accept ; }'
nft add rule ip nat POSTROUTING oifname "${NAT_IF}" counter masquerade
nft add table ip filter
nft add chain ip filter FORWARD '{ type filter hook forward priority 0 ; policy accept ; }'
success "nft masquerade rule added (with counter) on $NAT_IF"

# ------------------------------------------------------------
# PERSIST nft ruleset + apply AFTER interface is routable
# (networkd-dispatcher hook fixes the boot-timing problem so the
#  masquerade rule binds to $NAT_IF only once it is up)
# ------------------------------------------------------------
info "Saving nft ruleset and installing boot hook..."
# Save current ruleset (root-correct redirect)
nft list ruleset > /etc/nftables.ruleset

# networkd-dispatcher hook: runs when an interface becomes routable
mkdir -p /etc/networkd-dispatcher/routable.d
cat > /etc/networkd-dispatcher/routable.d/50-ifup.hooks << 'HOOK'
#!/bin/sh
/usr/sbin/nft --file /etc/nftables.ruleset
exit 0
HOOK
chmod +x /etc/networkd-dispatcher/routable.d/50-ifup.hooks
systemctl enable networkd-dispatcher > /dev/null 2>&1 || true
systemctl restart networkd-dispatcher > /dev/null 2>&1 || true
success "nft ruleset saved to /etc/nftables.ruleset + routable.d hook installed"

# ------------------------------------------------------------
# SSH
# ------------------------------------------------------------
apt-get install -y openssh-server > /dev/null 2>&1
systemctl start ssh; systemctl enable ssh > /dev/null 2>&1
success "SSH installed and running"

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------
echo ""
echo -e "${GREEN}=== GATEWAY VM SETUP COMPLETE ===${NC}"
echo -e "  $INTNET_IF = 192.168.55.1/29 | Kea serving 192.168.55.0/29"
echo -e "  Route to node net: 192.168.55.80/28 via 192.168.55.2"
echo -e "  IP forwarding: persistent (=1) | NAT masquerade: $NAT_IF (nft, with counter)"
echo -e "  Persistence: /etc/sysctl.d/99-ipforward.conf + /etc/nftables.ruleset + routable.d hook"
echo -e "  Port 67: $(ss -ulnp | grep ':67' | awk '{print $NF}')"
echo -e "${YELLOW}  KEEP NAT ON. Leave this VM running. NEXT: Relay script.${NC}"
echo -e "${YELLOW}  Verify masquerade counter later: sudo nft list chain ip nat POSTROUTING${NC}"
