#!/usr/bin/env bash
set -euo pipefail

cat <<'TASK'
========================================
 TASK 02 — etcd Backup
========================================
Take a snapshot of the etcd database and save it to /opt/etcd-backup.db
on the control-plane node (192.168.100.10).

Requirements:
  - Snapshot file must exist at: /opt/etcd-backup.db
  - Use etcdctl with the correct TLS certificates from /etc/kubernetes/pki/etcd/

Useful paths on cka-control:
  --endpoints=https://127.0.0.1:2379
  --cacert=/etc/kubernetes/pki/etcd/ca.crt
  --cert=/etc/kubernetes/pki/etcd/server.crt
  --key=/etc/kubernetes/pki/etcd/server.key

Hint: Install etcdctl if not present:
  ETCD_VER=v3.5.12
  curl -L https://github.com/etcd-io/etcd/releases/download/\${ETCD_VER}/etcd-\${ETCD_VER}-linux-amd64.tar.gz | tar xz
  sudo mv etcd-\${ETCD_VER}-linux-amd64/etcdctl /usr/local/bin/
========================================
TASK
