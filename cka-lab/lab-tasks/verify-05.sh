#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH="ssh -i ${SCRIPT_DIR}/../cka-lab-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

$SSH ubuntu@192.168.100.10 bash <<'REMOTE'
set -euo pipefail
export KUBECONFIG=$HOME/.kube/config
PASS=true

sa=$(kubectl get sa pod-reader-sa -n rbac-lab -o name 2>/dev/null || echo "")
[[ -n "$sa" ]] && echo "[OK] ServiceAccount pod-reader-sa exists" || { echo "[FAIL] ServiceAccount missing"; PASS=false; }

cr=$(kubectl get clusterrole pod-reader -o name 2>/dev/null || echo "")
[[ -n "$cr" ]] && echo "[OK] ClusterRole pod-reader exists" || { echo "[FAIL] ClusterRole missing"; PASS=false; }

crb=$(kubectl get clusterrolebinding pod-reader-binding -o name 2>/dev/null || echo "")
[[ -n "$crb" ]] && echo "[OK] ClusterRoleBinding pod-reader-binding exists" || { echo "[FAIL] ClusterRoleBinding missing"; PASS=false; }

can=$(kubectl auth can-i list pods --as=system:serviceaccount:rbac-lab:pod-reader-sa 2>/dev/null || echo "no")
[[ "$can" == "yes" ]] && echo "[OK] SA can list pods" || { echo "[FAIL] SA cannot list pods"; PASS=false; }

$PASS && echo "[OK] Task 05 passed" || { echo "[FAIL] Task 05 failed"; exit 1; }
REMOTE
