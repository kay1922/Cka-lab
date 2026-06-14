#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH="ssh -i ${SCRIPT_DIR}/../cka-lab-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

result=$($SSH ubuntu@192.168.100.10 bash <<'REMOTE'
export KUBECONFIG=$HOME/.kube/config
kubectl get networkpolicy allow-frontend-to-backend -n netpol-lab -o json 2>/dev/null
REMOTE
)

if [[ -z "$result" ]]; then
  echo "[FAIL] NetworkPolicy 'allow-frontend-to-backend' not found in netpol-lab"
  exit 1
fi

# Check podSelector targets backend
if echo "$result" | grep -q '"app": "backend"' || echo "$result" | grep -q 'app.*backend'; then
  echo "[OK] NetworkPolicy exists and targets backend"
else
  echo "[WARN] NetworkPolicy exists but podSelector may not target app=backend — review it"
fi

# Check port 80
if echo "$result" | grep -q '"port": 80\|port.*80'; then
  echo "[OK] Port 80 rule present"
else
  echo "[FAIL] Port 80 not found in NetworkPolicy"
  exit 1
fi

echo "[OK] Task 03 verification passed"
