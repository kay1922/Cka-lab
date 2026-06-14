#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH="ssh -i ${SCRIPT_DIR}/../cka-lab-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

current=$($SSH ubuntu@192.168.100.10 kubectl get node cka-control -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null || echo "v1.33.x")

cat <<TASK
========================================
 TASK 07 — Control-Plane Minor Upgrade
========================================
Current cluster version: ${current}

This cluster runs Kubernetes 1.33. Upgrade the control-plane node
(cka-control) one MINOR version, to 1.34 — the same kind of upgrade
you get on the CKA exam.

Steps to follow on cka-control (192.168.100.10):

1. The apt repo currently points at v1.33. A minor upgrade needs the
   v1.34 repo (pkgs.k8s.io is one repo per minor). Switch it:

     sudo sed -i 's#/v1.33/#/v1.34/#' /etc/apt/sources.list.d/kubernetes.list
     curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key \\
       | sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
     sudo apt-get update

2. Find the target patch version:
     apt-cache madison kubeadm | grep 1.34

3. Unhold and upgrade kubeadm:
     sudo apt-mark unhold kubeadm
     sudo apt-get install -y --allow-change-held-packages kubeadm=1.34.X-1.1
     sudo apt-mark hold kubeadm

4. Verify the upgrade plan:
     sudo kubeadm upgrade plan

5. Apply the upgrade:
     sudo kubeadm upgrade apply v1.34.X

6. Upgrade kubelet and kubectl:
     sudo apt-mark unhold kubelet kubectl
     sudo apt-get install -y --allow-change-held-packages kubelet=1.34.X-1.1 kubectl=1.34.X-1.1
     sudo apt-mark hold kubelet kubectl
     sudo systemctl daemon-reload
     sudo systemctl restart kubelet

7. Verify:
     kubectl get nodes
     kubectl version

Note: Worker node upgrades are separate (drain → switch repo → upgrade
kubelet → uncordon). The exam usually only asks for the control plane.
========================================
TASK
