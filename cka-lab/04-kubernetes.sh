#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY_FILE="${SCRIPT_DIR}/cka-lab-key"
SSH="ssh -i ${KEY_FILE} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
SCP="scp -i ${KEY_FILE} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

CONTROL_IP="192.168.100.10"
WORKER_IPS=("192.168.100.11" "192.168.100.12")
ALL_IPS=("192.168.100.10" "192.168.100.11" "192.168.100.12")
POD_CIDR="10.244.0.0/16"
# k8s minor version — drives the pkgs.k8s.io apt repo. Bump this for a new exam version.
K8S_MINOR="1.34"
# Calico v3.32 is tested against k8s 1.34-1.36 (v3.28 maxed out at 1.30).
# Keep this in sync with K8S_MINOR when bumping versions.
CALICO_MANIFEST="https://raw.githubusercontent.com/projectcalico/calico/v3.32.0/manifests/calico.yaml"

# All remote heredocs run as root via sudo bash to avoid permission errors.
run_root() {
  local ip="$1"; shift
  $SSH "ubuntu@${ip}" sudo bash "$@"
}

run_user() {
  local ip="$1"; shift
  $SSH "ubuntu@${ip}" bash "$@"
}

install_common() {
  local ip="$1"
  # Skip if kubeadm is already installed (k8s base image was used)
  if $SSH "ubuntu@${ip}" command -v kubeadm &>/dev/null 2>&1; then
    ok "k8s binaries already present on ${ip} — skipping package install"
    return
  fi
  info "Installing common k8s components on ${ip} (k8s v${K8S_MINOR})..."
  run_root "$ip" -s -- "$K8S_MINOR" <<'REMOTE'
set -euo pipefail

# containerd from Docker CE repo
apt-get update -qq
apt-get install -y ca-certificates curl gnupg lsb-release

install -m 0755 -d /etc/apt/keyrings

# --batch --yes so re-runs don't fail if the key file already exists
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor --batch --yes -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y containerd.io

# containerd: enable SystemdCgroup (required for kubeadm)
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# Kubernetes apt repo (minor version passed as $1 from the local script)
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${1}/deb/Release.key" \
  | gpg --dearmor --batch --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${1}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet
REMOTE
  ok "Common components installed on ${ip}"
}

pull_images() {
  local ip="$1"
  # Check if kube-apiserver image is already present (k8s base image pre-pulled)
  if $SSH "ubuntu@${ip}" "sudo ctr -n k8s.io images ls 2>/dev/null | grep -q kube-apiserver" 2>/dev/null; then
    ok "Control-plane images already present on ${ip} — skipping pull"
    return
  fi
  info "Pulling control-plane images on ${ip}..."
  run_root "$ip" <<'REMOTE'
kubeadm config images pull
REMOTE
  ok "Images pulled on ${ip}"
}

init_control_plane() {
  info "Initialising control plane on ${CONTROL_IP}..."
  run_root "$CONTROL_IP" <<REMOTE
set -euo pipefail
if [ -f /etc/kubernetes/admin.conf ]; then
  echo "Control plane already initialised — skipping"
  exit 0
fi
kubeadm init \
  --pod-network-cidr=${POD_CIDR} \
  --apiserver-advertise-address=${CONTROL_IP}
REMOTE

  # Set up kubeconfig for the ubuntu user
  run_user "$CONTROL_IP" <<'REMOTE'
set -euo pipefail
mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
REMOTE
  ok "Control plane initialised"
}

install_calico() {
  info "Installing Calico CNI (v3.32.0)..."
  run_user "$CONTROL_IP" <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config
if kubectl get daemonset calico-node -n kube-system &>/dev/null; then
  echo "Calico already installed — skipping"
  exit 0
fi
kubectl apply -f ${CALICO_MANIFEST}
REMOTE
  ok "Calico applied"
}

wait_control_plane_ready() {
  info "Waiting for control-plane pods to be Running..."
  run_user "$CONTROL_IP" <<'REMOTE'
set -euo pipefail
export KUBECONFIG=$HOME/.kube/config
for i in $(seq 1 60); do
  not_running=$(kubectl get pods -n kube-system --no-headers 2>/dev/null \
    | grep -vc 'Running\|Completed' || true)
  if [[ $not_running -eq 0 ]]; then
    echo "All control-plane pods Running"
    exit 0
  fi
  echo "Waiting... (${not_running} pods not yet Running)"
  sleep 10
done
echo "Timeout waiting for control-plane pods" >&2
exit 1
REMOTE
  ok "Control-plane pods are Running"
}

get_join_command() {
  info "Generating join command..."
  run_root "$CONTROL_IP" <<'REMOTE'
set -euo pipefail
kubeadm token create --print-join-command > /tmp/join-command.sh
chmod +x /tmp/join-command.sh
REMOTE
  ok "Join command saved at /tmp/join-command.sh on control plane"
}

join_workers() {
  info "Fetching join command from control plane..."
  local join_cmd
  join_cmd=$($SSH "ubuntu@${CONTROL_IP}" cat /tmp/join-command.sh)

  for ip in "${WORKER_IPS[@]}"; do
    info "Joining worker ${ip}..."
    run_root "$ip" <<REMOTE
set -euo pipefail
if [ -f /etc/kubernetes/kubelet.conf ]; then
  echo "Worker already joined — skipping"
  exit 0
fi
${join_cmd}
REMOTE
    ok "Worker ${ip} joined"
  done
}

verify_nodes() {
  info "Verifying all nodes appear in cluster..."
  run_user "$CONTROL_IP" <<'REMOTE'
set -euo pipefail
export KUBECONFIG=$HOME/.kube/config
for i in $(seq 1 30); do
  ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true)
  if [[ $ready -eq 3 ]]; then
    echo "All 3 nodes Ready"
    kubectl get nodes
    exit 0
  fi
  echo "Waiting for nodes... (${ready}/3 Ready)"
  sleep 10
done
echo "Timeout waiting for nodes" >&2
kubectl get nodes
exit 1
REMOTE
}

setup_kubectl_helpers() {
  local ip="$1"
  if $SSH "ubuntu@${ip}" "grep -q 'alias k=kubectl' ~/.bashrc" 2>/dev/null; then
    ok "kubectl helpers already configured on ${ip} — skipping"
    return
  fi
  info "Setting up kubectl alias and completion on ${ip}..."
  run_user "$ip" <<'REMOTE'
set -euo pipefail
sudo apt-get install -y bash-completion -qq 2>/dev/null
cat >> ~/.bashrc <<'EOF'

# kubectl aliases and tab completion
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
EOF
REMOTE
  ok "kubectl helpers set up on ${ip}"
}

main() {
  echo "========================================"
  echo " CKA Lab — Kubernetes installation"
  echo "========================================"

  for ip in "${ALL_IPS[@]}"; do
    install_common "$ip"
    setup_kubectl_helpers "$ip"
  done

  pull_images "$CONTROL_IP"
  init_control_plane
  install_calico
  wait_control_plane_ready
  get_join_command

  for ip in "${WORKER_IPS[@]}"; do
    pull_images "$ip"
  done

  join_workers
  verify_nodes

  echo "========================================"
  ok "Kubernetes cluster is up!"
  info "kubeconfig on control plane: ~/.kube/config"
  info "Copy locally: ${SCP} ubuntu@${CONTROL_IP}:.kube/config ./kubeconfig"
  echo "========================================"
}

main
