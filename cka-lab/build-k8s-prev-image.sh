#!/usr/bin/env bash
# Builds ubuntu-22.04-cka-k8s-prev.qcow2 — identical to the k8s image but with
# one patch version older k8s binaries + container images pre-pulled.
# Use this image to practice cluster upgrades.
#
# Flow:
#   1. Detect current and prev k8s versions from the apt repo
#   2. Reset cluster on cka-control (removes cluster state, keeps binaries)
#   3. Downgrade k8s to PREV_VERSION on cka-control + pull prev images
#   4. Sysprep, shutdown, convert → ubuntu-22.04-cka-k8s-prev.qcow2
#   5. Reinstall CURRENT_VERSION on cka-control
#   6. Reset workers, restart cka-control, re-init full cluster
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "${SCRIPT_DIR}")/base-images"
PREV_IMAGE="${BASE_DIR}/ubuntu-22.04-cka-k8s-prev.qcow2"
SOURCE_VM="cka-control"
SOURCE_DISK="/var/lib/libvirt/images/${SOURCE_VM}.qcow2"
KEY_FILE="${SCRIPT_DIR}/cka-lab-key"
SSH="ssh -i ${KEY_FILE} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes"
CONTROL_IP="192.168.100.10"
WORKER_IPS=(192.168.100.11 192.168.100.12)
# Prev image is one MINOR behind current, for realistic exam upgrade practice (n-1 → n).
# Keep CURRENT_MINOR in sync with K8S_MINOR in 04-kubernetes.sh.
CURRENT_MINOR="1.34"
PREV_MINOR="1.33"

check_prerequisites() {
  if [[ -f "$PREV_IMAGE" ]]; then
    warn "Prev image already exists: ${PREV_IMAGE}"
    read -r -p "Overwrite? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
  fi

  if ! virsh --connect qemu:///system domstate "$SOURCE_VM" 2>/dev/null | grep -q "running"; then
    error "VM '${SOURCE_VM}' is not running. Start the cluster first."
    exit 1
  fi
  if ! $SSH "ubuntu@${CONTROL_IP}" true 2>/dev/null; then
    error "Cannot SSH into ${SOURCE_VM}. Is it ready?"
    exit 1
  fi
  if ! $SSH "ubuntu@${CONTROL_IP}" command -v kubeadm &>/dev/null; then
    error "kubeadm not found on ${SOURCE_VM}. Run 04-kubernetes.sh first."
    exit 1
  fi
  if [[ ! -f "$SOURCE_DISK" ]]; then
    error "Source disk not found: ${SOURCE_DISK}"
    exit 1
  fi
}

# Point cka-control's apt repo at a specific k8s minor (e.g. 1.33) and refresh.
# pkgs.k8s.io repos are per-minor, so a minor downgrade requires swapping the repo.
set_k8s_repo() {
  local minor="$1"
  info "Pointing cka-control apt repo at k8s v${minor}..."
  $SSH "ubuntu@${CONTROL_IP}" sudo bash -s -- "$minor" <<'REMOTE'
set -euo pipefail
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${1}/deb/Release.key" \
  | gpg --dearmor --batch --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${1}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
REMOTE
}

# Latest patch (e.g. 1.33.5) available for a minor in the currently-configured repo.
latest_patch() {
  local minor="$1"
  $SSH "ubuntu@${CONTROL_IP}" \
    "apt-cache madison kubeadm 2>/dev/null | grep -oP '${minor}\\.[0-9]+(?=-1\\.1)' | sort -t. -k3 -rn | head -1"
}

detect_current_version() {
  info "Detecting current k8s version (v${CURRENT_MINOR})..."
  CURRENT_VERSION=$(latest_patch "$CURRENT_MINOR")
  if [[ -z "$CURRENT_VERSION" ]]; then
    error "Could not detect a v${CURRENT_MINOR} version from the apt repo."
    exit 1
  fi
  ok "Current: v${CURRENT_VERSION}  →  building prev image at v${PREV_MINOR}.x"
}

reset_cluster() {
  info "Resetting k8s cluster on ${SOURCE_VM} (keeps binaries + cached images)..."
  $SSH "ubuntu@${CONTROL_IP}" sudo bash <<'REMOTE'
set -euo pipefail
kubeadm reset -f --cleanup-tmp-dir 2>/dev/null || true
rm -rf /home/ubuntu/.kube /root/.kube /etc/cni/net.d
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X 2>/dev/null || true
ip6tables -F && ip6tables -t nat -F && ip6tables -t mangle -F && ip6tables -X 2>/dev/null || true
REMOTE
  ok "Cluster reset complete"
}

install_prev_version() {
  set_k8s_repo "$PREV_MINOR"
  PREV_VERSION=$(latest_patch "$PREV_MINOR")
  if [[ -z "$PREV_VERSION" ]]; then
    error "Could not detect a v${PREV_MINOR} version from the apt repo."
    exit 1
  fi
  ok "Prev: v${PREV_VERSION}"

  info "Downgrading cka-control to k8s v${PREV_VERSION}..."
  $SSH "ubuntu@${CONTROL_IP}" sudo bash <<REMOTE
set -euo pipefail
apt-mark unhold kubelet kubeadm kubectl
apt-get install -y --allow-downgrades --allow-change-held-packages \
  kubeadm=${PREV_VERSION}-1.1 \
  kubelet=${PREV_VERSION}-1.1 \
  kubectl=${PREV_VERSION}-1.1
apt-mark hold kubelet kubeadm kubectl
kubeadm version
REMOTE
  ok "k8s binaries downgraded to v${PREV_VERSION}"

  info "Pulling control-plane images for v${PREV_VERSION}..."
  $SSH "ubuntu@${CONTROL_IP}" sudo bash <<REMOTE
set -euo pipefail
kubeadm config images pull --kubernetes-version=v${PREV_VERSION}
REMOTE
  ok "Images pulled for v${PREV_VERSION}"
}

sysprep_vm() {
  info "Syspreping ${SOURCE_VM}..."
  $SSH "ubuntu@${CONTROL_IP}" sudo bash <<'REMOTE'
set -euo pipefail
cloud-init clean --logs --seed 2>/dev/null || true
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_*
truncate -s 0 /home/ubuntu/.bash_history /root/.bash_history 2>/dev/null || true
sync
REMOTE
  ok "Sysprep complete"
}

shutdown_vm() {
  info "Shutting down ${SOURCE_VM}..."
  virsh --connect qemu:///system shutdown "$SOURCE_VM"
  local elapsed=0
  while ! virsh --connect qemu:///system domstate "$SOURCE_VM" 2>/dev/null | grep -q "shut off"; do
    if [[ $elapsed -ge 60 ]]; then
      warn "Graceful shutdown timed out — forcing off"
      virsh --connect qemu:///system destroy "$SOURCE_VM" 2>/dev/null || true
      sleep 2; break
    fi
    sleep 2; elapsed=$((elapsed + 2)); printf "."
  done
  echo ""; ok "${SOURCE_VM} is off"
}

create_prev_image() {
  info "Creating compressed prev image (this may take a few minutes)..."
  mkdir -p "$BASE_DIR"
  sudo qemu-img convert -c -O qcow2 -p "$SOURCE_DISK" "$PREV_IMAGE"
  sudo chown "$(id -un):$(id -gn)" "$PREV_IMAGE"
  local size
  size=$(du -sh "$PREV_IMAGE" | cut -f1)
  ok "Prev image created: ${PREV_IMAGE} (${size})"
}

reset_workers() {
  info "Resetting workers (removing stale kubelet.conf)..."
  for ip in "${WORKER_IPS[@]}"; do
    $SSH "ubuntu@${ip}" sudo bash <<'REMOTE'
set -euo pipefail
kubeadm reset -f --cleanup-tmp-dir 2>/dev/null || true
rm -rf /etc/cni/net.d
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X 2>/dev/null || true
REMOTE
    ok "Worker ${ip} reset"
  done
}

reinstate_current_version() {
  info "Reinstalling k8s v${CURRENT_VERSION} on ${SOURCE_VM}..."
  virsh --connect qemu:///system start "$SOURCE_VM"
  ssh-keygen -R "${CONTROL_IP}" 2>/dev/null || true

  local elapsed=0
  until $SSH "ubuntu@${CONTROL_IP}" true 2>/dev/null; do
    if [[ $elapsed -ge 120 ]]; then error "SSH timeout after restart"; exit 1; fi
    sleep 5; elapsed=$((elapsed + 5)); printf "."
  done
  echo ""; ok "${SOURCE_VM} is back up"

  set_k8s_repo "$CURRENT_MINOR"
  $SSH "ubuntu@${CONTROL_IP}" sudo bash <<REMOTE
set -euo pipefail
apt-mark unhold kubelet kubeadm kubectl
apt-get install -y --allow-downgrades --allow-change-held-packages \
  kubeadm=${CURRENT_VERSION}-1.1 \
  kubelet=${CURRENT_VERSION}-1.1 \
  kubectl=${CURRENT_VERSION}-1.1
apt-mark hold kubelet kubeadm kubectl
kubeadm version
REMOTE
  ok "k8s restored to v${CURRENT_VERSION} on ${SOURCE_VM}"
}

main() {
  echo "========================================"
  echo " CKA Lab — Build k8s prev image"
  echo "========================================"
  check_prerequisites
  detect_current_version
  reset_cluster
  install_prev_version
  sysprep_vm
  shutdown_vm
  create_prev_image
  reset_workers
  reinstate_current_version
  info "Re-initialising cluster with v${CURRENT_VERSION}..."
  bash "${SCRIPT_DIR}/04-kubernetes.sh"
  echo "========================================"
  ok "Prev image ready: ${PREV_IMAGE}  (k8s v${PREV_VERSION})"
  info "Provision with this image to practice upgrading v${PREV_VERSION} → v${CURRENT_VERSION}."
  echo "========================================"
}

main
