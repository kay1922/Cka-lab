#!/usr/bin/env bash
set -euo pipefail

cat <<'TASK'
========================================
 TASK 04 — PersistentVolume + PVC + Pod
========================================
Create the following resources in namespace 'storage-lab':

1. Namespace: storage-lab

2. PersistentVolume named 'task-pv':
   - storageClassName: manual
   - capacity: 1Gi
   - accessModes: ReadWriteOnce
   - hostPath: /mnt/task-data

3. PersistentVolumeClaim named 'task-pvc':
   - namespace: storage-lab
   - storageClassName: manual
   - requests: 1Gi
   - accessModes: ReadWriteOnce

4. Pod named 'task-pod':
   - namespace: storage-lab
   - image: nginx:stable
   - mount task-pvc at /usr/share/nginx/html

The PVC must be Bound and the Pod must be Running.
========================================
TASK
