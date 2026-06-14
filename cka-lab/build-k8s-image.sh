#!/usr/bin/env bash
# Builds ubuntu-22.04-cka-k8s.qcow2 from a running cka-control VM.
# Prerequisites: 04-kubernetes.sh must have been run (k8s binaries + cluster up).
# The script resets the cluster (kubeadm reset), sysprePs, shuts down, converts,
# then restarts cka-control and re-initialises the cluster.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "${SCRIPT_DIR}")/base-images"
K8S_IMAGE="${BASE_DIR}/ubuntu-22.04-cka-k8s.qcow2"
SOURCE_VM="cka-control"
SOURCE_DISK="/var/lib/libvirt/images/${SOURCE_VM}.qcow2"
KEY_FILE="${SCRIPT_DIR}/cka-lab-key"
SSH="ssh -i ${KEY_FILE} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes"
CONTROL_IP="192.168.100.10"
VIRSH="virsh --connect qemu:///system"

check_prerequisites() {
  if [[ -f "$K8S_IMAGE" ]]; then
    warn "K8s image already exists: ${K8S_IMAGE}"
    read -r -p "Overwrite? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
  fi

  if ! $VIRSH domstate "$SOURCE_VM" 2>/dev/null | grep -q "running"; then
    error "VM '${SOURCE_VM}' is not running. Start it first."
    exit 1
  fi

  if ! $SSH "ubuntu@${CONTROL_IP}" true 2>/dev/null; then
    error "Cannot SSH into ${SOURCE_VM} (${CONTROL_IP}). Is it ready?"
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

reset_cluster() {
  info "Resetting k8s cluster on ${SOURCE_VM} (keeps binaries + cached images)..."
  $SSH "ubuntu@${CONTROL_IP}" sudo bash <<'REMOTE'
set -euo pipefail
# Reset kubeadm — removes /etc/kubernetes, /var/lib/etcd, clears iptables
kubeadm reset -f --cleanup-tmp-dir 2>/dev/null || true
# Remove kubeconfig
rm -rf /home/ubuntu/.kube /root/.kube
# Remove CNI config (Calico leaves files here)
rm -rf /etc/cni/net.d
# Reset iptables to clean state
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X 2>/dev/null || true
ip6tables -F && ip6tables -t nat -F && ip6tables -t mangle -F && ip6tables -X 2>/dev/null || true
REMOTE
  ok "Cluster reset complete (binaries and container images retained)"
}

sysprep_vm() {
  info "Syspreping ${SOURCE_VM} (clearing cloud-init state, machine-id, SSH host keys)..."
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
  $VIRSH shutdown "$SOURCE_VM"
  local elapsed=0
  while ! $VIRSH domstate "$SOURCE_VM" 2>/dev/null | grep -q "shut off"; do
    if [[ $elapsed -ge 60 ]]; then
      warn "Graceful shutdown timed out — forcing off"
      $VIRSH destroy "$SOURCE_VM" 2>/dev/null || true
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

create_k8s_image() {
  info "Creating compressed k8s base image (this may take a few minutes)..."
  mkdir -p "$BASE_DIR"
  sudo qemu-img convert -c -O qcow2 -p "$SOURCE_DISK" "$K8S_IMAGE"
  sudo chown "$(id -un):$(id -gn)" "$K8S_IMAGE"
  local size
  size=$(du -sh "$K8S_IMAGE" | cut -f1)
  ok "K8s image created: ${K8S_IMAGE} (${size})"
}

reset_workers() {
  info "Resetting workers (removing stale kubelet.conf so they can join the new cluster)..."
  for ip in 192.168.100.11 192.168.100.12; do
    $SSH "ubuntu@${ip}" sudo bash <<'REMOTE'
set -euo pipefail
kubeadm reset -f --cleanup-tmp-dir 2>/dev/null || true
rm -rf /etc/cni/net.d
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X 2>/dev/null || true
ip6tables -F && ip6tables -t nat -F && ip6tables -t mangle -F && ip6tables -X 2>/dev/null || true
REMOTE
    ok "Worker ${ip} reset"
  done
}

restart_and_reinit() {
  # Workers must be reset BEFORE the new control-plane starts,
  # so their stale kubelet.conf doesn't fool the join check in 04-kubernetes.sh.
  reset_workers

  info "Restarting ${SOURCE_VM}..."
  $VIRSH start "$SOURCE_VM"
  ssh-keygen -R "${CONTROL_IP}" 2>/dev/null || true

  local elapsed=0
  until $SSH "ubuntu@${CONTROL_IP}" true 2>/dev/null; do
    if [[ $elapsed -ge 120 ]]; then
      error "Timeout waiting for SSH after restart"
      exit 1
    fi
    sleep 5; elapsed=$((elapsed + 5)); printf "."
  done
  echo ""
  ok "${SOURCE_VM} is back up"

  info "Re-initialising cluster on ${SOURCE_VM}..."
  bash "${SCRIPT_DIR}/04-kubernetes.sh"
}

main() {
  echo "========================================"
  echo " CKA Lab — Build k8s base image"
  echo "========================================"
  check_prerequisites
  reset_cluster
  sysprep_vm
  shutdown_vm
  create_k8s_image
  restart_and_reinit
  echo "========================================"
  ok "K8s base image ready: ${K8S_IMAGE}"
  info "Future runs of 03-vms.sh will clone this image (~5 min to a working cluster)."
  echo "========================================"
}

main
