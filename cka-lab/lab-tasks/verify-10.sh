#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH="ssh -i ${SCRIPT_DIR}/../cka-lab-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

result=$($SSH ubuntu@192.168.100.10 bash <<'REMOTE'
export KUBECONFIG=$HOME/.kube/config
kubectl get pod broken-pod -n troubleshoot-lab -o jsonpath='{.status.phase}' 2>/dev/null || echo "missing"
REMOTE
)

if [[ "$result" == "Running" ]]; then
  echo "[OK] broken-pod is Running"
  exit 0
else
  echo "[FAIL] broken-pod status: $result (expected Running)"
  exit 1
fi
