#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH="ssh -i ${SCRIPT_DIR}/../cka-lab-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

$SSH ubuntu@192.168.100.10 bash <<'REMOTE'
set -euo pipefail
export KUBECONFIG=$HOME/.kube/config
PASS=true

replicas=$(kubectl get deployment web -n workload-lab -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "$replicas" -eq 5 ]]; then
  echo "[OK] Deployment 'web' has 5 ready replicas"
else
  echo "[FAIL] Deployment 'web' ready replicas: $replicas (expected 5)"
  PASS=false
fi

image=$(kubectl get deployment web -n workload-lab -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
if echo "$image" | grep -q 'nginx:1.25'; then
  echo "[OK] Image is nginx:1.25"
else
  echo "[FAIL] Image is '$image' (expected nginx:1.25)"
  PASS=false
fi

svc=$(kubectl get svc web-svc -n workload-lab -o name 2>/dev/null || echo "")
[[ -n "$svc" ]] && echo "[OK] Service web-svc exists" || { echo "[FAIL] Service web-svc missing"; PASS=false; }

$PASS && echo "[OK] Task 09 passed" || { echo "[FAIL] Task 09 failed"; exit 1; }
REMOTE
