#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH="ssh -i ${SCRIPT_DIR}/../cka-lab-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

$SSH ubuntu@192.168.100.10 bash <<'REMOTE'
set -euo pipefail
export KUBECONFIG=$HOME/.kube/config

kubectl create namespace netpol-lab --dry-run=client -o yaml | kubectl apply -f -

kubectl run frontend --image=nginx:stable -n netpol-lab \
  --labels=app=frontend --restart=Never --dry-run=client -o yaml | kubectl apply -f -

kubectl run backend --image=nginx:stable -n netpol-lab \
  --labels=app=backend --restart=Never --dry-run=client -o yaml | kubectl apply -f -

kubectl wait --for=condition=Ready pod/frontend pod/backend -n netpol-lab --timeout=120s
REMOTE

cat <<'TASK'
========================================
 TASK 03 — NetworkPolicy
========================================
Two pods are running in namespace 'netpol-lab':
  - frontend (label: app=frontend)
  - backend  (label: app=backend)

Your task:
  Create a NetworkPolicy named 'allow-frontend-to-backend' in namespace
  'netpol-lab' that:
    - Applies to the 'backend' pod
    - Allows ingress traffic only from pods with label app=frontend
    - Only on port 80
    - Denies all other ingress to backend

Verify manually:
  kubectl exec -n netpol-lab frontend -- curl -s backend:80   # should work (once backend svc exists)
  kubectl exec -n netpol-lab <other-pod> -- curl -s backend:80 # should fail
========================================
TASK
