#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH="ssh -i ${SCRIPT_DIR}/../cka-lab-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

$SSH ubuntu@192.168.100.10 bash <<'REMOTE'
set -euo pipefail
export KUBECONFIG=$HOME/.kube/config
PASS=true

ing=$(kubectl get ingress lab-ingress -n ingress-lab -o json 2>/dev/null || echo "")
if [[ -z "$ing" ]]; then
  echo "[FAIL] Ingress 'lab-ingress' not found in ingress-lab"
  exit 1
fi
echo "[OK] Ingress lab-ingress exists"

echo "$ing" | grep -q '/app1' && echo "[OK] /app1 path present" || { echo "[FAIL] /app1 path missing"; PASS=false; }
echo "$ing" | grep -q '/app2' && echo "[OK] /app2 path present" || { echo "[FAIL] /app2 path missing"; PASS=false; }
echo "$ing" | grep -q '"app1"' && echo "[OK] app1 backend present" || { echo "[FAIL] app1 backend missing"; PASS=false; }
echo "$ing" | grep -q '"app2"' && echo "[OK] app2 backend present" || { echo "[FAIL] app2 backend missing"; PASS=false; }

$PASS && echo "[OK] Task 06 passed" || { echo "[FAIL] Task 06 failed"; exit 1; }
REMOTE
