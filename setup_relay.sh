#!/bin/bash
# ============================================================
# LAB 3 DHCP - RELAY VM (VM 2) - Pastebin pipe-ready
# NO PROMPTS - safe to pipe. Gateway MUST be running first.
# Run: wget -qO- https://pastebin.com/raw/LINK | tr -d '\r' | sudo bash
# ============================================================
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info(){ echo -e "${BLUE}[INFO]${NC} $1"; }
success(){ echo -e "${GREEN}[DONE]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
error(){ echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

echo -e "${YELLOW}=== LAB 3 DHCP - RELAY VM SETUP ===${NC}"
echo "enp0s8 dynamic (192.168.99.2) from Gateway | enp0s9 static 192.168.99.81"
echo "Kea serving 192.168.99.80/28 | REQUIRES Gateway running first"
echo ""

# Detect interfaces (Adapter 1 empty -> only 2 NICs, but NAT may be on for install)
NAT_IF=$(ip -o -4 addr show | grep '10\.0\.2\.' | awk '{print $2}' | head -1)
NICS=( $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | grep -v "$NAT_IF") )
INTNET_IF="${NICS[0]:-enp0s8}"
BRIDGE_IF="${NICS[1]:-enp0s9}"
info "intnet (->Gateway): $INTNET_IF | Bridged (->Node): $BRIDGE_IF"

# DNS fix
cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
success "DNS set to 8.8.8.8"

# Netplan - enp0s8 dynamic, enp0s9 static
info "Writing netplan..."
cat > /etc/netplan/99_config.yaml << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${INTNET_IF}:
      dhcp4: yes
    ${BRIDGE_IF}:
      dhcp4: no
      addresses: [192.168.99.81/28]
EOF
chmod 600 /etc/netplan/99_config.yaml
netplan apply; sleep 3

RELAY_IP=$(ip -4 addr show "$INTNET_IF" | grep inet | awk '{print $2}')
echo "$RELAY_IP" | grep -q "192.168.99" && success "$INTNET_IF = $RELAY_IP (dynamic from Gateway)" || warn "$INTNET_IF = $RELAY_IP (expected 192.168.99.2 - is Gateway Kea running?)"

# Remove conflicting default route
if ip route show | grep -q "default via 192.168.99"; then
    ip route del default via $(ip route show | grep "default via 192.168.99" | awk '{print $3}') 2>/dev/null || true
    success "Removed conflicting default route"
fi

# IP forwarding
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p > /dev/null
success "IP forwarding enabled"

# Install Kea
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

# Kea config
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
      "subnet": "192.168.99.80/28",
      "pools": [{"pool": "192.168.99.82 - 192.168.99.94"}],
      "option-data": [
        {"name": "routers", "data": "192.168.99.81"},
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
echo -e "${GREEN}=== RELAY VM SETUP COMPLETE ===${NC}"
echo -e "  $INTNET_IF = $(ip -4 addr show $INTNET_IF | grep inet | awk '{print $2}') (dynamic)"
echo -e "  $BRIDGE_IF = 192.168.99.81/28 (static) | Kea serving 192.168.99.80/28"
echo -e "  Port 67: $(ss -ulnp | grep ':67' | awk '{print $NF}')"
echo -e "${YELLOW}  NEXT: Run the Node script on the Node VM (PC2)${NC}"
