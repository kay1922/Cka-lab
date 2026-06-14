#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH="ssh -i ${SCRIPT_DIR}/../cka-lab-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

$SSH ubuntu@192.168.100.10 bash <<'REMOTE'
set -euo pipefail
export KUBECONFIG=$HOME/.kube/config
PASS=true

pvc_status=$(kubectl get pvc task-pvc -n storage-lab -o jsonpath='{.status.phase}' 2>/dev/null || echo "missing")
if [[ "$pvc_status" == "Bound" ]]; then
  echo "[OK] PVC task-pvc is Bound"
else
  echo "[FAIL] PVC task-pvc status: $pvc_status"
  PASS=false
fi

pod_status=$(kubectl get pod task-pod -n storage-lab -o jsonpath='{.status.phase}' 2>/dev/null || echo "missing")
if [[ "$pod_status" == "Running" ]]; then
  echo "[OK] Pod task-pod is Running"
else
  echo "[FAIL] Pod task-pod status: $pod_status"
  PASS=false
fi

mount=$(kubectl get pod task-pod -n storage-lab -o jsonpath='{.spec.volumes[*].persistentVolumeClaim.claimName}' 2>/dev/null || echo "")
if [[ "$mount" == "task-pvc" ]]; then
  echo "[OK] Pod mounts task-pvc"
else
  echo "[FAIL] Pod does not mount task-pvc"
  PASS=false
fi

$PASS && echo "[OK] Task 04 passed" || { echo "[FAIL] Task 04 failed"; exit 1; }
REMOTE
