#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH="ssh -i ${SCRIPT_DIR}/../cka-lab-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

$SSH ubuntu@192.168.100.11 bash <<'REMOTE'
set -euo pipefail
# Point kubelet at a non-existent API server so it loses connectivity and the node goes NotReady
sudo sed -i 's|server: https://.*|server: https://192.168.100.99:6443|' /etc/kubernetes/kubelet.conf
sudo systemctl restart kubelet
REMOTE

echo "Waiting for cka-worker-01 to go NotReady..."
elapsed=0
until $SSH ubuntu@192.168.100.10 kubectl get node cka-worker-01 --no-headers 2>/dev/null | grep -v ' Ready' | grep -q 'NotReady'; do
  if [[ $elapsed -ge 120 ]]; then
    echo "[WARN] Node did not go NotReady within 120s — check manually"
    break
  fi
  sleep 5; elapsed=$((elapsed + 5)); printf "."
done
echo ""

cat <<'TASK'
========================================
 TASK 01 — Broken Node
========================================
The kubelet on cka-worker-01 (192.168.100.11) has been misconfigured and
the node is now NotReady.

Your task:
  1. SSH to cka-worker-01 and diagnose why the kubelet cannot reach the API server.
  2. Fix the configuration so the node returns to Ready.

Hints:
  - Check kubelet logs:  journalctl -u kubelet -n 50
  - The kubelet uses a kubeconfig to authenticate to the API server.
  - The control-plane address is 192.168.100.10:6443.

Relevant files on cka-worker-01:
  /etc/kubernetes/kubelet.conf

Verify with: kubectl get nodes   (run from cka-control)
========================================
TASK
