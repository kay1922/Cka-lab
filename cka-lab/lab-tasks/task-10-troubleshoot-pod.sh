#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH="ssh -i ${SCRIPT_DIR}/../cka-lab-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

$SSH ubuntu@192.168.100.10 bash <<'REMOTE'
set -euo pipefail
export KUBECONFIG=$HOME/.kube/config

kubectl create namespace troubleshoot-lab --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: broken-pod
  namespace: troubleshoot-lab
spec:
  containers:
  - name: app
    image: nginx:DOESNOTEXIST
EOF
REMOTE

cat <<'TASK'
========================================
 TASK 10 — Troubleshoot a Broken Pod
========================================
A pod named 'broken-pod' in namespace 'troubleshoot-lab' is not starting.

Your task:
  1. Identify why the pod is not running.
  2. Fix the pod so it runs successfully.

Hints:
  kubectl describe pod broken-pod -n troubleshoot-lab
  kubectl get events -n troubleshoot-lab

The fix should result in 'broken-pod' reaching Running state.
You may edit the pod spec (delete and recreate, or kubectl edit).
Use image: nginx:stable as the corrected image.
========================================
TASK
