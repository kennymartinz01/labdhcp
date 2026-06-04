#!/bin/bash
# ============================================================
# LAB 3 DHCP - GATEWAY VM (VM 1) - Pastebin pipe-ready
# Run: wget -qO- https://pastebin.com/raw/LINK | tr -d '\r' | sudo bash
# ============================================================
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info(){ echo -e "${BLUE}[INFO]${NC} $1"; }
success(){ echo -e "${GREEN}[DONE]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
error(){ echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

echo -e "${BLUE}=== LAB 3 DHCP - GATEWAY VM SETUP ===${NC}"
echo "Subnet 192.168.99.0/29 | This VM 192.168.99.1 | Relay gets 192.168.99.2"
echo ""

# Detect interfaces
NAT_IF=$(ip -o -4 addr show | grep '10\.0\.2\.' | awk '{print $2}' | head -1)
INTNET_IF=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | grep -v "$NAT_IF" | head -1)
[ -z "$NAT_IF" ] && NAT_IF="enp0s3"
[ -z "$INTNET_IF" ] && INTNET_IF="enp0s8"
info "NAT interface: $NAT_IF | intnet interface: $INTNET_IF"

# Netplan
info "Writing netplan..."
cat > /etc/netplan/99_config.yaml << EOF
network:
  version: 2
  ethernets:
    ${NAT_IF}:
      dhcp4: yes
    ${INTNET_IF}:
      dhcp4: no
      addresses: [192.168.99.1/29]
      routes:
        - to: 192.168.99.80/28
          via: 192.168.99.2
EOF
chmod 600 /etc/netplan/99_config.yaml
netplan apply; sleep 2
success "Netplan applied - $INTNET_IF = 192.168.99.1/29"

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

# Mask conflicting services
systemctl stop kea-ctrl-agent isc-dhcp-relay 2>/dev/null || true
systemctl disable kea-ctrl-agent isc-dhcp-relay 2>/dev/null || true
systemctl mask kea-ctrl-agent isc-dhcp-relay 2>/dev/null || true
success "kea-ctrl-agent and isc-dhcp-relay masked permanently"

# Kea config
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
      "subnet": "192.168.99.0/29",
      "pools": [{"pool": "192.168.99.2 - 192.168.99.6"}],
      "option-data": [
        {"name": "routers", "data": "192.168.99.1"},
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

# Verify port 67
PORT67=$(ss -ulnp | grep ':67' | awk '{print $NF}')
echo "$PORT67" | grep -q "kea" && success "Port 67 owned by kea-dhcp4" || warn "Port 67: $PORT67"

# SSH
apt-get install -y openssh-server > /dev/null 2>&1
systemctl start ssh; systemctl enable ssh > /dev/null 2>&1
success "SSH installed and running"

echo ""
echo -e "${GREEN}=== GATEWAY VM SETUP COMPLETE ===${NC}"
echo -e "  $INTNET_IF = 192.168.99.1/29 | Kea serving 192.168.99.0/29"
echo -e "  SSH port forward: Host 2222 -> Guest 22"
echo -e "${YELLOW}  NEXT: Run the Relay script on the Relay VM${NC}"
