#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH="ssh -i ${SCRIPT_DIR}/../cka-lab-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

result=$($SSH ubuntu@192.168.100.10 kubectl get node cka-worker-02 --no-headers 2>/dev/null)
status=$(echo "$result" | awk '{print $2}')

if [[ "$status" == "Ready" ]]; then
  echo "[OK] cka-worker-02 is Ready and uncordoned"
  exit 0
else
  echo "[FAIL] cka-worker-02 status: $status (expected Ready)"
  exit 1
fi
