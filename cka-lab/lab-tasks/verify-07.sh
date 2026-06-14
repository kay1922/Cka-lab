#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH="ssh -i ${SCRIPT_DIR}/../cka-lab-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

$SSH ubuntu@192.168.100.10 bash <<'REMOTE'
set -euo pipefail
export KUBECONFIG=$HOME/.kube/config

server_ver=$(kubectl version -o json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['serverVersion']['gitVersion'])")
node_ver=$(kubectl get node cka-control -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null)

echo "Server version : $server_ver"
echo "Kubelet version: $node_ver"

node_status=$(kubectl get node cka-control --no-headers | awk '{print $2}')
if [[ "$node_status" != "Ready" ]]; then
  echo "[FAIL] cka-control is not Ready: $node_status"
  exit 1
fi

# Target of this task is the 1.34 minor upgrade
if [[ "$node_ver" == v1.34.* ]]; then
  echo "[OK] cka-control is Ready and upgraded to ${node_ver}"
else
  echo "[FAIL] cka-control kubelet is ${node_ver}, expected v1.34.x"
  exit 1
fi
REMOTE
