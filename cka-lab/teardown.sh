#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMS=(cka-control cka-worker-01 cka-worker-02)
NETWORK="cka-lab"
VIRSH="virsh --connect qemu:///system"

confirm() {
  local prompt="$1"
  read -r -p "${prompt} [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

destroy_vms() {
  for vm in "${VMS[@]}"; do
    if ! $VIRSH dominfo "$vm" &>/dev/null; then
      info "VM '${vm}' does not exist — skipping"
      continue
    fi
    info "Destroying VM '${vm}'..."
    $VIRSH destroy "$vm" 2>/dev/null || true
    $VIRSH undefine "$vm" --remove-all-storage
    ok "VM '${vm}' removed"
  done
}

destroy_network() {
  if ! $VIRSH net-info "$NETWORK" &>/dev/null; then
    info "Network '${NETWORK}' does not exist — skipping"
    return
  fi
  info "Destroying network '${NETWORK}'..."
  $VIRSH net-destroy "$NETWORK" 2>/dev/null || true
  $VIRSH net-undefine "$NETWORK"
  ok "Network '${NETWORK}' removed"
}

remove_seeds() {
  if [[ -d "${SCRIPT_DIR}/seeds" ]]; then
    info "Removing seed ISOs..."
    rm -rf "${SCRIPT_DIR}/seeds"
    ok "Seed ISOs removed"
  fi
}

remove_keypair() {
  if confirm "Remove SSH keypair (cka-lab-key)?"; then
    rm -f "${SCRIPT_DIR}/cka-lab-key" "${SCRIPT_DIR}/cka-lab-key.pub"
    ok "SSH keypair removed"
  else
    info "Keypair kept"
  fi
}

main() {
  echo "========================================"
  echo " CKA Lab — Teardown"
  echo "========================================"

  # YES=1 skips all prompts (used by web UI); never removes keypair in automated mode
  if [[ "${YES:-}" != "1" ]]; then
    warn "This will destroy all CKA lab VMs, the network, and generated files."
    if ! confirm "Proceed?"; then
      info "Teardown cancelled"
      exit 0
    fi
  fi

  destroy_vms
  destroy_network
  remove_seeds

  if [[ "${YES:-}" != "1" ]]; then
    remove_keypair
  else
    info "Keypair kept (automated mode)"
  fi

  echo "========================================"
  ok "Teardown complete"
  echo "========================================"
}

main
