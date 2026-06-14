#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

VIRSH="virsh --connect qemu:///system"
NETWORK_NAME="cka-lab"
BRIDGE="virbr-cka"
SUBNET="192.168.100.0"
PREFIX="24"
GATEWAY="192.168.100.1"
DHCP_START="192.168.100.100"
DHCP_END="192.168.100.200"

NET_XML=$(cat <<EOF
<network>
  <name>${NETWORK_NAME}</name>
  <forward mode='nat'/>
  <bridge name='${BRIDGE}' stp='on' delay='0'/>
  <ip address='${GATEWAY}' prefix='${PREFIX}'>
    <dhcp>
      <range start='${DHCP_START}' end='${DHCP_END}'/>
      <host mac='52:54:00:aa:bb:01' name='cka-control'   ip='192.168.100.10'/>
      <host mac='52:54:00:aa:bb:02' name='cka-worker-01' ip='192.168.100.11'/>
      <host mac='52:54:00:aa:bb:03' name='cka-worker-02' ip='192.168.100.12'/>
    </dhcp>
  </ip>
</network>
EOF
)

create_network() {
  if $VIRSH net-info "$NETWORK_NAME" &>/dev/null; then
    ok "Network '${NETWORK_NAME}' already exists — skipping creation"
  else
    info "Creating network '${NETWORK_NAME}'..."
    echo "$NET_XML" | $VIRSH net-define /dev/stdin
    ok "Network defined"
  fi
}

start_network() {
  if $VIRSH net-info "$NETWORK_NAME" | grep -q 'Active:.*yes'; then
    ok "Network '${NETWORK_NAME}' already active"
  else
    info "Starting network '${NETWORK_NAME}'..."
    $VIRSH net-start "$NETWORK_NAME"
    ok "Network started"
  fi
}

autostart_network() {
  if $VIRSH net-info "$NETWORK_NAME" | grep -q 'Autostart:.*yes'; then
    ok "Autostart already enabled"
  else
    info "Enabling autostart..."
    $VIRSH net-autostart "$NETWORK_NAME"
    ok "Autostart enabled"
  fi
}

main() {
  echo "========================================"
  echo " CKA Lab — Network setup"
  echo "========================================"
  create_network
  start_network
  autostart_network
  echo ""
  info "Network details:"
  $VIRSH net-info "$NETWORK_NAME"
  echo "========================================"
  ok "Network '${NETWORK_NAME}' ready"
  echo "========================================"
}

main
