#!/usr/bin/env bash
set -euo pipefail

cat <<'TASK'
========================================
 TASK 05 — RBAC
========================================
Create the following in namespace 'rbac-lab':

1. Namespace: rbac-lab

2. ServiceAccount named 'pod-reader-sa' in namespace rbac-lab

3. ClusterRole named 'pod-reader':
   - apiGroups: [""]
   - resources: ["pods"]
   - verbs: ["get", "list", "watch"]

4. ClusterRoleBinding named 'pod-reader-binding':
   - Binds ClusterRole 'pod-reader' to ServiceAccount 'pod-reader-sa'
     in namespace 'rbac-lab'

Verify:
  kubectl auth can-i list pods \
    --as=system:serviceaccount:rbac-lab:pod-reader-sa
  # expected: yes
========================================
TASK
