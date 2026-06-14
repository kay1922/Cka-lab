#!/usr/bin/env bash
set -euo pipefail

cat <<'TASK'
========================================
 TASK 09 — Deployment, Service, Scale
========================================
Your task (in namespace 'workload-lab'):

1. Create namespace 'workload-lab'

2. Create a Deployment named 'web':
   - image: nginx:1.25
   - replicas: 3
   - label: app=web

3. Expose the Deployment as a ClusterIP Service named 'web-svc':
   - port: 80
   - targetPort: 80

4. Scale the Deployment to 5 replicas

5. Verify all 5 pods are Running:
   kubectl get pods -n workload-lab

Example commands:
  kubectl create namespace workload-lab
  kubectl create deployment web --image=nginx:1.25 --replicas=3 -n workload-lab
  kubectl expose deployment web --name=web-svc --port=80 -n workload-lab
  kubectl scale deployment web --replicas=5 -n workload-lab
========================================
TASK
