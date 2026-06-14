#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "${SCRIPT_DIR}")/base-images"
BASE_IMAGE="${BASE_DIR}/ubuntu-22.04-cka-base.qcow2"
SOURCE_VM="cka-control"
SOURCE_DISK="/var/lib/libvirt/images/${SOURCE_VM}.qcow2"
KEY_FILE="${SCRIPT_DIR}/cka-lab-key"
SSH="ssh -i ${KEY_FILE} -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
CONTROL_IP="192.168.100.10"

check_prerequisites() {
  if [[ -f "$BASE_IMAGE" ]]; then
    warn "Base image already exists: ${BASE_IMAGE}"
    read -r -p "Overwrite? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
  fi

  if ! virsh domstate "$SOURCE_VM" 2>/dev/null | grep -q "running"; then
    error "VM '${SOURCE_VM}' is not running. Start it first."
    exit 1
  fi

  if ! $SSH "ubuntu@${CONTROL_IP}" true 2>/dev/null; then
    error "Cannot SSH into ${SOURCE_VM} (${CONTROL_IP}). Is it ready?"
    exit 1
  fi

  if [[ ! -f "$SOURCE_DISK" ]]; then
    error "Source disk not found: ${SOURCE_DISK}"
    exit 1
  fi
}

sysprep_vm() {
  info "Syspreping ${SOURCE_VM} (clearing cloud-init state, machine-id, SSH host keys)..."
  $SSH "ubuntu@${CONTROL_IP}" sudo bash <<'REMOTE'
set -euo pipefail
# Clear cloud-init so it re-runs on first boot of each clone
cloud-init clean --logs --seed 2>/dev/null || true
# Empty machine-id: systemd regenerates a unique one on first boot (required for k8s nodes)
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
# Remove SSH host keys: sshd regenerates them on first start
rm -f /etc/ssh/ssh_host_*
# Clear shell history
truncate -s 0 /home/ubuntu/.bash_history /root/.bash_history 2>/dev/null || true
sync
REMOTE
  ok "Sysprep complete"
}

shutdown_vm() {
  info "Shutting down ${SOURCE_VM}..."
  virsh shutdown "$SOURCE_VM"
  local elapsed=0
  while ! virsh domstate "$SOURCE_VM" 2>/dev/null | grep -q "shut off"; do
    if [[ $elapsed -ge 60 ]]; then
      warn "Graceful shutdown timed out — forcing off"
      virsh destroy "$SOURCE_VM" 2>/dev/null || true
      sleep 2
      break
    fi
    sleep 2
    elapsed=$((elapsed + 2))
    printf "."
  done
  echo ""
  ok "${SOURCE_VM} is off"
}

create_base_image() {
  info "Creating compressed base image (this may take a few minutes)..."
  mkdir -p "$BASE_DIR"
  # -c: compress  -O qcow2: output format  -p: show progress
  sudo qemu-img convert -c -O qcow2 -p "$SOURCE_DISK" "$BASE_IMAGE"
  sudo chown "$(id -un):$(id -gn)" "$BASE_IMAGE"
  local size
  size=$(du -sh "$BASE_IMAGE" | cut -f1)
  ok "Base image created: ${BASE_IMAGE} (${size})"
}

restart_vm() {
  info "Restarting ${SOURCE_VM} (will regenerate machine-id and SSH host keys)..."
  virsh start "$SOURCE_VM"

  # Wait for SSH — new host keys means we clear known_hosts for this IP first
  ssh-keygen -R "${CONTROL_IP}" 2>/dev/null || true

  local elapsed=0
  until $SSH "ubuntu@${CONTROL_IP}" true 2>/dev/null; do
    if [[ $elapsed -ge 120 ]]; then
      error "Timeout waiting for SSH after restart"
      exit 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    printf "."
  done
  echo ""
  ok "${SOURCE_VM} is back up"
}

main() {
  echo "========================================"
  echo " CKA Lab — Build base image"
  echo "========================================"
  check_prerequisites
  sysprep_vm
  shutdown_vm
  create_base_image
  restart_vm
  echo "========================================"
  ok "Base image ready: ${BASE_IMAGE}"
  info "Future runs of 03-vms.sh will clone this image (~30 sec per VM)."
  echo "========================================"
}

main
