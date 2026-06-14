#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIRSH="virsh --connect qemu:///system"
SEEDS_DIR="${SCRIPT_DIR}/seeds"
BASE_DIR="$(dirname "${SCRIPT_DIR}")/base-images"
# K8s image: Ubuntu + k8s binaries + images pulled, no cluster (fastest rebuild ~5 min)
K8S_IMAGE="${BASE_DIR}/ubuntu-22.04-cka-k8s.qcow2"
# K8s prev image: same but one patch version older — use to practice cluster upgrades
K8S_PREV_IMAGE="${BASE_DIR}/ubuntu-22.04-cka-k8s-prev.qcow2"
# Base image: clean Ubuntu install (used when k8s image unavailable)
BASE_IMAGE="${BASE_DIR}/ubuntu-22.04-cka-base.qcow2"
KEY_FILE="${SCRIPT_DIR}/cka-lab-key"
NETWORK="cka-lab"
OS_VARIANT="ubuntu22.04"
SSH_OPTS="-i ${KEY_FILE} -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
# Clone boot timeouts — k8s image needs more time (kubelet starts on boot)
SSH_TIMEOUT_CLONE=300
SSH_TIMEOUT_K8S_CLONE=420
SSH_TIMEOUT_INSTALL=1800

declare -A VM_RAM=(  [cka-control]=4096 [cka-worker-01]=2048 [cka-worker-02]=2048 )
declare -A VM_DISK=( [cka-control]=20   [cka-worker-01]=15   [cka-worker-02]=15   )
declare -A VM_MAC=(
  [cka-control]="52:54:00:aa:bb:01"
  [cka-worker-01]="52:54:00:aa:bb:02"
  [cka-worker-02]="52:54:00:aa:bb:03"
)
declare -A VM_IP=(
  [cka-control]="192.168.100.10"
  [cka-worker-01]="192.168.100.11"
  [cka-worker-02]="192.168.100.12"
)
VMS=(cka-control cka-worker-01 cka-worker-02)

check_iso() {
  if [[ -z "${ISO_PATH:-}" ]]; then
    error "ISO_PATH is not set. Export it first: export ISO_PATH=/path/to/ubuntu.iso"
    exit 1
  fi
  if [[ ! -f "$ISO_PATH" ]]; then
    error "ISO not found: $ISO_PATH"
    exit 1
  fi
}

# Fast path: clone a base image, boot with --import
# $1 = vm name, $2 = source image path
clone_vm() {
  local vm="$1"
  local src_image="$2"
  local ram="${VM_RAM[$vm]}"
  local disk="${VM_DISK[$vm]}"
  local mac="${VM_MAC[$vm]}"
  local seed="${SEEDS_DIR}/${vm}-clone-seed.iso"
  local disk_path="/var/lib/libvirt/images/${vm}.qcow2"

  if [[ ! -f "$seed" ]]; then
    error "Clone seed not found: ${seed}. Run 02-cloud-init.sh first."
    exit 1
  fi

  if sudo test -f "$disk_path"; then
    warn "Removing stale disk: ${disk_path}"
    sudo rm -f "$disk_path"
  fi

  info "Cloning $(basename "${src_image}") for '${vm}'..."
  # CoW clone inherits backing file's virtual size — do NOT specify a smaller size here.
  # Workers are 15G in the spec but k8s base images are 20G; truncating the virtual disk
  # makes the ext4 root filesystem unreadable (block group metadata beyond the cutoff).
  sudo qemu-img create -f qcow2 -F qcow2 -b "$src_image" "$disk_path"

  info "Starting VM '${vm}'..."
  virt-install \
    --connect qemu:///system \
    --name "$vm" \
    --ram "$ram" \
    --vcpus 2 \
    --os-variant "$OS_VARIANT" \
    --disk "path=${disk_path},bus=virtio,format=qcow2" \
    --disk "${seed},device=cdrom,bus=sata" \
    --network "network=${NETWORK},model=virtio,mac=${mac}" \
    --graphics none \
    --noautoconsole \
    --import

  ok "VM '${vm}' started"
}

# Slow path: full install from ISO (~15 min install + ~3 min first boot)
install_vm() {
  local vm="$1"
  local ram="${VM_RAM[$vm]}"
  local disk="${VM_DISK[$vm]}"
  local mac="${VM_MAC[$vm]}"
  local seed="${SEEDS_DIR}/${vm}-seed.iso"
  local disk_path="/var/lib/libvirt/images/${vm}.qcow2"

  if [[ ! -f "$seed" ]]; then
    error "Autoinstall seed not found: ${seed}. Run 02-cloud-init.sh first."
    exit 1
  fi

  if sudo test -f "$disk_path"; then
    warn "Removing stale disk: ${disk_path}"
    sudo rm -f "$disk_path"
  fi

  info "Installing VM '${vm}' from ISO (RAM: ${ram}MB, Disk: ${disk}GB) — ~15 min..."
  # --location extracts kernel/initrd; attaches ISO as CDROM for installer.
  # --wait -1: block until installer exits (on_reboot=destroy), then starts installed system.
  virt-install \
    --connect qemu:///system \
    --name "$vm" \
    --ram "$ram" \
    --vcpus 2 \
    --os-variant "$OS_VARIANT" \
    --disk "path=${disk_path},size=${disk},bus=virtio,format=qcow2" \
    --location "${ISO_PATH},kernel=casper/vmlinuz,initrd=casper/initrd" \
    --extra-args "autoinstall ds=nocloud console=ttyS0,115200n8 quiet" \
    --disk "${seed},device=cdrom,bus=sata" \
    --network "network=${NETWORK},model=virtio,mac=${mac}" \
    --graphics none \
    --noautoconsole \
    --wait -1

  ok "VM '${vm}' installation complete — installed system is starting"
}

ensure_running() {
  local vm="$1"
  local state
  state=$($VIRSH domstate "$vm" 2>/dev/null || echo "undefined")
  case "$state" in
    running)   ok "VM '${vm}' already running" ;;
    "shut off") info "Starting '${vm}'..."; $VIRSH start "$vm"; ok "Started" ;;
    *)          error "VM '${vm}' in unexpected state: ${state}"; exit 1 ;;
  esac
}

wait_for_ssh() {
  local vm="$1"
  local ip="${VM_IP[$vm]}"
  local timeout="$2"
  local elapsed=0

  # Clear stale known_hosts entry — host keys regenerate after sysprep/clone
  ssh-keygen -R "$ip" 2>/dev/null || true

  info "Waiting for SSH on ${vm} (${ip}) — timeout ${timeout}s..."
  until ssh $SSH_OPTS "ubuntu@${ip}" "hostname" &>/dev/null; do
    if [[ $elapsed -ge $timeout ]]; then
      error "Timeout waiting for SSH on ${vm} (${ip})"
      exit 1
    fi
    sleep 10
    elapsed=$((elapsed + 10))
    printf "."
  done
  echo ""
  ok "${vm} reachable via SSH ($(( elapsed / 60 ))m $(( elapsed % 60 ))s)"
}

provision_vm() {
  local vm="$1"

  if $VIRSH dominfo "$vm" &>/dev/null; then
    warn "Domain '${vm}' already exists — skipping creation"
    ensure_running "$vm"
    wait_for_ssh "$vm" "$SSH_TIMEOUT_K8S_CLONE"
    return
  fi

  # Image priority controlled by env vars (set by web UI):
  #   USE_K8S_PREV_IMAGE=1  → prev k8s version (for upgrade practice)
  #   USE_BASE_IMAGE=1      → clean Ubuntu (for full k8s install practice)
  #   (default)             → latest k8s image
  if [[ -f "$K8S_PREV_IMAGE" && "${USE_K8S_PREV_IMAGE:-}" == "1" ]]; then
    clone_vm "$vm" "$K8S_PREV_IMAGE"
    wait_for_ssh "$vm" "$SSH_TIMEOUT_K8S_CLONE"
  elif [[ -f "$K8S_IMAGE" && "${USE_BASE_IMAGE:-}" != "1" ]]; then
    clone_vm "$vm" "$K8S_IMAGE"
    wait_for_ssh "$vm" "$SSH_TIMEOUT_K8S_CLONE"
  elif [[ -f "$BASE_IMAGE" ]]; then
    clone_vm "$vm" "$BASE_IMAGE"
    wait_for_ssh "$vm" "$SSH_TIMEOUT_CLONE"
  else
    check_iso
    install_vm "$vm"
    sleep 5
    wait_for_ssh "$vm" "$SSH_TIMEOUT_INSTALL"
  fi

  $VIRSH autostart "$vm" &>/dev/null
  ok "VM '${vm}' ready and autostart enabled"
}

# Determine if we're on the clone path (parallel-safe) or ISO path (sequential).
is_clone_path() {
  if [[ -f "$K8S_PREV_IMAGE" && "${USE_K8S_PREV_IMAGE:-}" == "1" ]]; then return 0; fi
  if [[ -f "$K8S_IMAGE" && "${USE_BASE_IMAGE:-}" != "1" ]];           then return 0; fi
  if [[ -f "$BASE_IMAGE" ]];                                           then return 0; fi
  return 1
}

# virt-install implicitly creates a transient libvirt storage pool named after the
# seed ISO's parent directory ('seeds'). When three virt-installs run in parallel
# they race to create that pool and the losers fail with "pool 'seeds' is already
# active". Pre-create it once so every virt-install finds an existing active pool.
ensure_seeds_pool() {
  $VIRSH pool-create-as seeds dir --target "$SEEDS_DIR" &>/dev/null \
    || $VIRSH pool-start seeds &>/dev/null || true
  $VIRSH pool-refresh seeds &>/dev/null || true
}

main() {
  echo "========================================"
  echo " CKA Lab — VM provisioning"
  if [[ "${USE_K8S_PREV_IMAGE:-}" == "1" && -f "$K8S_PREV_IMAGE" ]]; then
    ok "K8s prev image — cluster will need upgrade after init"
  elif [[ -f "$K8S_IMAGE" && "${USE_BASE_IMAGE:-}" != "1" ]]; then
    ok "K8s image found — clone path (~5 min to working cluster)"
  elif [[ -f "$BASE_IMAGE" ]]; then
    info "Base image found — clone path (~2 min boot, then run 04-kubernetes.sh)"
  else
    warn "No base image — installing from ISO (~15 min per VM)"
    warn "After first provision, run build-base-image.sh and build-k8s-image.sh"
  fi
  echo "========================================"

  if is_clone_path; then
    # Clone path: start all VMs in parallel, then wait for SSH on each
    ensure_seeds_pool
    info "Starting all VMs in parallel..."
    declare -A pids=()
    for vm in "${VMS[@]}"; do
      echo "----------------------------------------"
      provision_vm "$vm" &
      pids[$vm]=$!
    done
    local failed=0
    for vm in "${VMS[@]}"; do
      wait "${pids[$vm]}" || { error "VM '${vm}' failed to provision"; failed=1; }
    done
    [[ $failed -eq 0 ]] || exit 1
  else
    # ISO install: sequential (RAM constraint — can't run 3 installs at once)
    check_iso
    for vm in "${VMS[@]}"; do
      echo "----------------------------------------"
      provision_vm "$vm"
    done
  fi

  echo "========================================"
  ok "All VMs are up and reachable"

  # Re-establish SSH port forwarding. Recreating the cka-lab network makes libvirt
  # re-insert its LIBVIRT_FWI REJECT into FORWARD, which can land above our per-host
  # ACCEPT rules and break forwarding. Re-running puts the ACCEPT rules back on top.
  if [[ -f "${SCRIPT_DIR}/forward-ports.sh" ]]; then
    info "Re-applying SSH port forwarding rules..."
    sudo bash "${SCRIPT_DIR}/forward-ports.sh" || warn "Port forwarding setup failed (non-fatal)"
  fi

  echo ""
  info "SSH access:"
  for vm in "${VMS[@]}"; do
    echo "  ssh -i ./cka-lab-key ubuntu@${VM_IP[$vm]}   # ${vm}"
  done
  if [[ -f "$K8S_IMAGE" ]]; then
    echo ""
    info "Run 04-kubernetes.sh to initialise the cluster (binaries already present)"
  elif [[ ! -f "$BASE_IMAGE" ]]; then
    echo ""
    warn "Run ./build-base-image.sh then ./build-k8s-image.sh for fast future rebuilds"
  fi
  echo "========================================"
}

main
