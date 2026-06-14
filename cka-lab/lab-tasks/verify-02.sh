#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH="ssh -i ${SCRIPT_DIR}/../cka-lab-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

if $SSH ubuntu@192.168.100.10 "test -s /opt/etcd-backup.db && \
  ETCDCTL_API=3 etcdctl snapshot status /opt/etcd-backup.db \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key" 2>/dev/null; then
  echo "[OK] etcd snapshot exists and is valid at /opt/etcd-backup.db"
  exit 0
else
  echo "[FAIL] /opt/etcd-backup.db missing or invalid"
  exit 1
fi
