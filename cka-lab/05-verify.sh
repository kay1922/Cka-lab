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
CONTROL_IP="192.168.100.10"

run() {
  $SSH "ubuntu@${CONTROL_IP}" "$@"
}

check_nodes() {
  info "Checking nodes..."
  local output
  output=$(run kubectl get nodes --no-headers 2>/dev/null)
  echo "$output"
  local not_ready
  not_ready=$(echo "$output" | grep -cv ' Ready' || true)
  if [[ $not_ready -gt 0 ]]; then
    error "${not_ready} node(s) not Ready"
    return 1
  fi
  ok "All nodes Ready"
}

check_pods() {
  info "Checking kube-system pods..."
  run kubectl get pods -A --no-headers | grep -v 'Running\|Completed' | tee /tmp/not_running.txt || true
  local count
  count=$(wc -l < /tmp/not_running.txt)
  if [[ $count -gt 0 ]]; then
    warn "${count} pod(s) not Running/Completed"
  else
    ok "All kube-system pods Running"
  fi
  run kubectl get pods -A
}

check_test_pod() {
  info "Deploying test nginx pod..."
  run bash <<'REMOTE'
set -euo pipefail
export KUBECONFIG=$HOME/.kube/config
kubectl run verify-nginx --image=nginx:stable --restart=Never --timeout=120s 2>/dev/null || true
for i in $(seq 1 30); do
  phase=$(kubectl get pod verify-nginx -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  if [[ "$phase" == "Running" ]]; then
    echo "Test pod is Running"
    break
  fi
  echo "Waiting for pod... (${phase})"
  sleep 5
done
kubectl delete pod verify-nginx --ignore-not-found=true
REMOTE
  ok "Test pod ran and deleted successfully"
}

print_summary() {
  echo ""
  echo "========================================"
  echo " CKA Lab — Cluster Summary"
  echo "========================================"
  run bash <<'REMOTE'
export KUBECONFIG=$HOME/.kube/config
echo "Cluster version:"
kubectl version
echo ""
echo "Node count: $(kubectl get nodes --no-headers | wc -l)"
echo ""
echo "CNI: Calico"
echo "kubeconfig: ~/.kube/config"
echo ""
echo "Nodes:"
kubectl get nodes -o wide
REMOTE
  echo "========================================"
}

main() {
  echo "========================================"
  echo " CKA Lab — Cluster Verification"
  echo "========================================"
  check_nodes
  check_pods
  check_test_pod
  print_summary
}

main
