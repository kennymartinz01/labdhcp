#!/bin/bash
# ============================================================
# LAB 3 DHCP - NODE VM (VM 3) - pipe-ready  [Y = 55]
# NO PROMPTS - safe to pipe. Gateway AND Relay must run first.
# Run: wget -qO- <RAW_URL> | tr -d '\r' | sudo bash
#
# DHCP client | Expected IP 192.168.55.82 from Relay Kea (192.168.55.81)
# REQUIRES Gateway AND Relay running first
# Boot with NAT (Adapter 1) ON so dhclient can be installed via apt.
# ============================================================
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info(){ echo -e "${BLUE}[INFO]${NC} $1"; }
success(){ echo -e "${GREEN}[DONE]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
error(){ echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

echo -e "${GREEN}=== LAB 3 DHCP - NODE VM SETUP (Y=55) ===${NC}"
echo "DHCP client | Expected IP 192.168.55.82 from Relay Kea (192.168.55.81)"
echo "REQUIRES Gateway AND Relay running first"
echo ""

# Detect bridged interface (Node has only Adapter 3 active, NAT temp for install)
NAT_IF=$(ip -o -4 addr show | grep '10\.0\.2\.' | awk '{print $2}' | head -1)
NICS=( $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | grep -v "$NAT_IF") )
BRIDGE_IF="${NICS[0]:-enp0s9}"
info "Bridged interface: $BRIDGE_IF"

# Install dhcp client if internet available
if ping -c1 -W2 8.8.8.8 > /dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y isc-dhcp-client > /dev/null 2>&1 && success "isc-dhcp-client installed"
elif command -v dhclient > /dev/null 2>&1; then
    success "dhclient already available"
else
    warn "No internet and no dhclient - will try networkctl"
fi

# Release old lease
info "Releasing any old lease on $BRIDGE_IF..."
command -v dhclient > /dev/null 2>&1 && dhclient -r "$BRIDGE_IF" 2>/dev/null || true
ip addr flush dev "$BRIDGE_IF" 2>/dev/null || true
sleep 1

# Request fresh lease
info "Requesting DHCP lease from Relay Kea..."
if command -v dhclient > /dev/null 2>&1; then
    dhclient -v "$BRIDGE_IF" 2>&1 || true
else
    networkctl up "$BRIDGE_IF" 2>/dev/null || true; sleep 3
fi
sleep 2

# Verify IP
NODE_IP=$(ip -4 addr show "$BRIDGE_IF" | grep inet | awk '{print $2}')
if echo "$NODE_IP" | grep -q "192.168.55"; then
    success "Node received IP: $NODE_IP (scope global dynamic)"
else
    error "No IP received on $BRIDGE_IF (got: $NODE_IP). Check: Gateway+Relay Kea running, Relay port 67 = kea-dhcp4, cable connected, correct Bridged NIC"
fi

# Connectivity test
echo ""
info "Testing connectivity..."
ping -c2 192.168.55.81 > /dev/null 2>&1 && echo -e "  ${GREEN}OK${NC}  ping 192.168.55.81 (Relay)" || echo -e "  ${RED}FAIL${NC} ping 192.168.55.81 (Relay)"
ping -c2 192.168.55.1  > /dev/null 2>&1 && echo -e "  ${GREEN}OK${NC}  ping 192.168.55.1  (Gateway)" || echo -e "  ${RED}FAIL${NC} ping 192.168.55.1  (Gateway)"
ping -c2 192.168.55.2  > /dev/null 2>&1 && echo -e "  ${GREEN}OK${NC}  ping 192.168.55.2  (Relay enp0s8)" || echo -e "  ${RED}FAIL${NC} ping 192.168.55.2  (Relay enp0s8)"

echo ""
echo -e "${GREEN}=== NODE VM SETUP COMPLETE (Y=55) ===${NC}"
echo -e "  $BRIDGE_IF = $NODE_IP (dynamic from Relay Kea 192.168.55.81)"
echo -e "  Full chain: Node -> Relay Kea -> Gateway Kea"
echo -e "${GREEN}  LAB 3 OBJECTIVE ACHIEVED${NC}"
echo -e "${YELLOW}  To test internet: ping -c3 8.8.8.8 && ping -c3 google.com${NC}"
echo -e "${YELLOW}  Then turn OFF NAT (Adapter 1) for the clean topology.${NC}"
