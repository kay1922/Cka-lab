# CKA Lab — KVM/libvirt Kubernetes Cluster

3-node Kubernetes 1.34 lab on KVM: 1 control-plane + 2 workers, provisioned with kubeadm and Calico CNI.

## Prerequisites

- Ubuntu host with KVM/libvirt support
- Packages: `qemu-system-x86 libvirt-daemon-system virtinst libvirt-clients bridge-utils cloud-image-utils`
- User in `kvm` and `libvirt` groups
- Ubuntu 22.04 LTS server ISO
- ~55 GB free disk, ~8 GB RAM

Install missing packages:
```bash
sudo apt-get install -y qemu-system-x86 libvirt-daemon-system virtinst \
  libvirt-clients bridge-utils cloud-image-utils
```

## VM Specifications

| Name          | Role          | vCPU | RAM  | Disk | IP             |
|---------------|---------------|------|------|------|----------------|
| cka-control   | control-plane | 2    | 4GB  | 20G  | 192.168.100.10 |
| cka-worker-01 | worker        | 2    | 2GB  | 15G  | 192.168.100.11 |
| cka-worker-02 | worker        | 2    | 2GB  | 15G  | 192.168.100.12 |

## Usage

### 1. Export the ISO path

```bash
export ISO_PATH=/home/akirillov/projects/cka/ubuntu-22.04.5-live-server-amd64.iso
```

### 2. Run scripts in order

```bash
bash 00-preflight.sh      # Check host prerequisites
bash 01-network.sh        # Create cka-lab libvirt network
bash 02-cloud-init.sh     # Generate SSH key + cloud-init seed ISOs
bash 03-vms.sh            # Create and boot VMs, wait for SSH
bash 04-kubernetes.sh     # Install containerd + k8s, init cluster, join workers
bash 05-verify.sh         # Validate cluster health
```

### 3. SSH into nodes

```bash
ssh -i ./cka-lab-key ubuntu@192.168.100.10   # cka-control
ssh -i ./cka-lab-key ubuntu@192.168.100.11   # cka-worker-01
ssh -i ./cka-lab-key ubuntu@192.168.100.12   # cka-worker-02
```

### 4. Copy kubeconfig locally (optional)

```bash
scp -i ./cka-lab-key ubuntu@192.168.100.10:.kube/config ./kubeconfig
export KUBECONFIG=./kubeconfig
kubectl get nodes
```

## Lab Tasks

Each task deploys a scenario to practice CKA exam skills.

```bash
# Run a task (sets up the scenario and prints instructions)
bash lab-tasks/task-01-broken-node.sh

# Verify your solution
bash lab-tasks/verify-01.sh
```

| Task | Topic |
|------|-------|
| task-01 | Fix broken kubelet config on worker-01 |
| task-02 | etcd snapshot backup |
| task-03 | NetworkPolicy — restrict ingress to port 80 |
| task-04 | PersistentVolume + PVC + Pod (hostPath) |
| task-05 | RBAC — ServiceAccount, ClusterRole, ClusterRoleBinding |
| task-06 | Ingress routing /app1 and /app2 |
| task-07 | Upgrade control-plane to next patch version |
| task-08 | Drain and uncordon worker-02 |
| task-09 | Deployment, ClusterIP service, scale to 5 |
| task-10 | Troubleshoot pod with wrong image |

## Teardown

```bash
bash teardown.sh
```

Destroys all VMs, the cka-lab network, and generated cloud-init ISOs.
Prompts before removing the SSH keypair.
