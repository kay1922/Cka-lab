#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH="ssh -i ${SCRIPT_DIR}/../cka-lab-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

$SSH ubuntu@192.168.100.10 bash <<'REMOTE'
set -euo pipefail
export KUBECONFIG=$HOME/.kube/config

kubectl create namespace ingress-lab --dry-run=client -o yaml | kubectl apply -f -

kubectl create deployment app1 --image=nginx:stable -n ingress-lab --dry-run=client -o yaml | kubectl apply -f -
kubectl create deployment app2 --image=nginx:stable -n ingress-lab --dry-run=client -o yaml | kubectl apply -f -

kubectl expose deployment app1 --port=80 --target-port=80 -n ingress-lab --dry-run=client -o yaml | kubectl apply -f -
kubectl expose deployment app2 --port=80 --target-port=80 -n ingress-lab --dry-run=client -o yaml | kubectl apply -f -
REMOTE

cat <<'TASK'
========================================
 TASK 06 — Ingress
========================================
Two services are deployed in namespace 'ingress-lab':
  - app1 (ClusterIP, port 80)
  - app2 (ClusterIP, port 80)

Your task:
  Create an Ingress resource named 'lab-ingress' in namespace 'ingress-lab'
  that routes:
    - /app1  →  service app1, port 80
    - /app2  →  service app2, port 80

  Use pathType: Prefix.
  No IngressClass is required (use default or omit).

Note: An ingress controller must be installed for full routing to work.
      The verify script checks only the Ingress object definition.
========================================
TASK
