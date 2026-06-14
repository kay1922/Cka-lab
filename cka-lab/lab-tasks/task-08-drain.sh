#!/usr/bin/env bash
set -euo pipefail

cat <<'TASK'
========================================
 TASK 08 — Drain and Uncordon
========================================
Your task:
  1. Safely drain cka-worker-02 (evict all workloads, ignore DaemonSets):

     kubectl drain cka-worker-02 \
       --ignore-daemonsets \
       --delete-emptydir-data \
       --force

  2. Verify the node is SchedulingDisabled:

     kubectl get nodes

  3. Perform any simulated maintenance (e.g., echo "maintenance done")

  4. Uncordon the node to return it to service:

     kubectl uncordon cka-worker-02

  5. Verify the node returns to Ready:

     kubectl get nodes
========================================
TASK
