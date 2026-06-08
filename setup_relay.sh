#!/bin/bash
# ============================================================
# LAB 3 DHCP - RELAY VM (VM 2) - pipe-ready  [Y = 55]
# INTERNET-VIA-GATEWAY EDITION
# NO PROMPTS - safe to pipe. Gateway MUST be running first.
# Run: wget -qO- <RAW_URL> | tr -d '\r' | sudo bash
#
# enp0s8 dynamic (192.168.55.2) from Gateway | enp0s9 static 192.168.55.81
# Kea serving 192.168.55.80/28 | REQUIRES Gateway running first
#
# KEY DIFFERENCE from the original:
#   * Does NOT delete the default route.
#   * Installs a PERSISTENT default route via the Gateway (192.168.55.1)
#     on enp0s8 with a high metric, so once NAT (enp0s3) is turned off the
#     Relay still reaches the internet through the Gateway's masquerade.
#   * NAT keeps a lower-metric default during install (so apt works via NAT),
#     then the Gateway route takes over when NAT is disabled.
#
# .2 NOTE: to guarantee enp0s8 = .2, boot this VM with the intnet (Adapter 2)
# cable DISCONNECTED, run this script, THEN reconnect the cable and:
#   sudo systemctl restart systemd-networkd
# ============================================================
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info(){ echo -e "${BLUE}[INFO]${NC} $1"; }
success(){ echo -e "${GREEN}[DONE]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
error(){ echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

echo -e "${YELLOW}=== LAB 3 DHCP - RELAY VM SETUP (Y=55, internet-via-gateway) ===${NC}"
echo "enp0s8 dynamic (192.168.55.2) from Gateway | enp0s9 static 192.168.55.81"
echo "Kea serving 192.168.55.80/28 | Relay reaches internet via Gateway after NAT off"
echo ""

# Detect interfaces (NAT may be on for install)
NAT_IF=$(ip -o -4 addr show | grep '10\.0\.2\.' | awk '{print $2}' | head -1)
NICS=( $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | grep -v "$NAT_IF") )
INTNET_IF="${NICS[0]:-enp0s8}"
BRIDGE_IF="${NICS[1]:-enp0s9}"
info "intnet (->Gateway): $INTNET_IF | Bridged (->Node): $BRIDGE_IF | NAT: ${NAT_IF:-none}"

# DNS fix (so name resolution works whether via NAT or via Gateway later)
cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
success "DNS set to 8.8.8.8 / 8.8.4.4"

# ------------------------------------------------------------
# Netplan:
#   enp0s8 (intnet)  = DHCP from Gateway, AND a persistent default route
#                      via 192.168.55.1 with HIGH metric (700).
#   enp0s9 (bridged) = static 192.168.55.81/28, no gateway.
# The NAT interface (enp0s3) keeps its own DHCP default at LOW metric (100),
# so during install internet goes out NAT. When NAT is disabled, the only
# remaining default is via the Gateway -> Relay still has internet.
# ------------------------------------------------------------
info "Writing netplan (persistent default via Gateway)..."
cat > /etc/netplan/99_config.yaml << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${INTNET_IF}:
      dhcp4: yes
      dhcp4-overrides:
        use-routes: false
      routes:
        - to: default
          via: 192.168.55.1
          metric: 700
    ${BRIDGE_IF}:
      dhcp4: no
      addresses: [192.168.55.81/28]
EOF
chmod 600 /etc/netplan/99_config.yaml
netplan apply; sleep 3

RELAY_IP=$(ip -4 addr show "$INTNET_IF" | grep inet | awk '{print $2}')
echo "$RELAY_IP" | grep -q "192.168.55" && success "$INTNET_IF = $RELAY_IP (dynamic from Gateway)" || warn "$INTNET_IF = $RELAY_IP (expected 192.168.55.2 - Gateway Kea running? intnet cable connected?)"

# IP forwarding - PERSISTENT via /etc/sysctl.d (reliable reboot-safe method)
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-ipforward.conf
sysctl --system > /dev/null 2>&1
FWD=$(sysctl -n net.ipv4.ip_forward)
[ "$FWD" = "1" ] && success "IP forwarding enabled and persistent (=1) via /etc/sysctl.d" || error "IP forwarding not active"

# Install Kea (uses NAT for internet during this step)
info "Installing Kea..."
export DEBIAN_FRONTEND=noninteractive
apt-get update > /dev/null 2>&1 || true
apt-get install -y kea > /dev/null 2>&1
success "Kea installed"

# CRITICAL: mask dhcrelay permanently (port 67 fix)
systemctl stop isc-dhcp-relay kea-ctrl-agent 2>/dev/null || true
systemctl disable isc-dhcp-relay kea-ctrl-agent 2>/dev/null || true
systemctl mask isc-dhcp-relay kea-ctrl-agent 2>/dev/null || true
success "isc-dhcp-relay and kea-ctrl-agent masked permanently"

# Kill any lingering dhcrelay on port 67
STRAY=$(ss -ulnp 2>/dev/null | grep ':67' | grep -oP 'pid=\K[0-9]+' | head -1 || true)
[ -n "$STRAY" ] && { kill "$STRAY" 2>/dev/null || true; sleep 1; success "Killed stray process on port 67"; }

# Kea config - serves the node subnet on the bridged interface
info "Writing Kea config..."
mkdir -p /etc/kea
cat > /etc/kea/kea-dhcp4.conf << EOF
{
  "Dhcp4": {
    "interfaces-config": { "interfaces": ["${BRIDGE_IF}"] },
    "lease-database": {
      "type": "memfile",
      "persist": true,
      "name": "/var/lib/kea/kea-leases4.csv"
    },
    "subnet4": [{
      "id": 1,
      "subnet": "192.168.55.80/28",
      "pools": [{"pool": "192.168.55.82 - 192.168.55.94"}],
      "option-data": [
        {"name": "routers", "data": "192.168.55.81"},
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

# Test and start
info "Testing config..."
sudo -u _kea kea-dhcp4 -t /etc/kea/kea-dhcp4.conf || error "Kea config test failed"
success "Kea config syntax OK"
systemctl restart kea-dhcp4-server; sleep 2
systemctl is-active kea-dhcp4-server > /dev/null || error "Kea failed to start"
success "Kea DHCP server is running"

# Verify port 67 - retry if dhcrelay sneaked in
sleep 1
PORT67=$(ss -ulnp | grep ':67' | awk '{print $NF}')
if echo "$PORT67" | grep -q "kea"; then
    success "Port 67 owned by kea-dhcp4"
else
    STRAY=$(ss -ulnp | grep ':67' | grep -oP 'pid=\K[0-9]+' | head -1 || true)
    [ -n "$STRAY" ] && { kill "$STRAY" 2>/dev/null || true; sleep 1; systemctl restart kea-dhcp4-server; sleep 1; success "Restarted Kea - port 67 now kea-dhcp4"; }
fi

# SSH
apt-get install -y openssh-server > /dev/null 2>&1
systemctl start ssh; systemctl enable ssh > /dev/null 2>&1
success "SSH installed and running"

echo ""
echo -e "${GREEN}=== RELAY VM SETUP COMPLETE (Y=55) ===${NC}"
echo -e "  $INTNET_IF = $(ip -4 addr show $INTNET_IF | grep inet | awk '{print $2}') (dynamic)"
echo -e "  $BRIDGE_IF = 192.168.55.81/28 (static) | Kea serving 192.168.55.80/28"
echo -e "  IP forwarding: persistent (=1) | Default route via Gateway (192.168.55.1, metric 700)"
echo -e "  Port 67: $(ss -ulnp | grep ':67' | awk '{print $NF}')"
echo ""
echo -e "${YELLOW}  IF enp0s8 is NOT .2: reconnect the intnet cable, then:${NC}"
echo -e "${YELLOW}    sudo systemctl restart systemd-networkd ; sleep 5 ; ip a show $INTNET_IF${NC}"
echo -e "${YELLOW}  THEN turn OFF NAT (Adapter 1). Relay keeps internet via the Gateway.${NC}"
echo -e "${YELLOW}  Verify after NAT off:  ping -c3 8.8.8.8  &&  ping -c3 google.com${NC}"
echo -e "${YELLOW}  NEXT: Run the Node script on the Node VM (student laptop)${NC}"
