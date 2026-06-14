# CKA Lab — KVM/libvirt Kubernetes Cluster

3-node Kubernetes **1.34** lab on KVM: 1 control-plane + 2 workers, provisioned with
kubeadm and Calico CNI. Pure bash + kubectl + kubeadm — no Ansible/Terraform/Helm.
Includes a browser UI and 10 CKA-style practice tasks with verifiers.

## Prerequisites

- Ubuntu host with KVM/libvirt support (`/dev/kvm` present)
- Packages: `qemu-system-x86 libvirt-daemon-system virtinst libvirt-clients bridge-utils cloud-image-utils`
- User in `kvm` and `libvirt` groups
- ~55 GB free disk, ~8 GB RAM
- Ubuntu 22.04 LTS server ISO **(only for the first build — see image tiers below)**

Install missing packages:
```bash
sudo apt-get install -y qemu-system-x86 libvirt-daemon-system virtinst \
  libvirt-clients bridge-utils cloud-image-utils
```

> Note: on Ubuntu the package is `qemu-system-x86` (not `qemu-kvm`), and `virt-install`
> is provided by `virtinst`.

## VM Specifications

| Name          | Role          | vCPU | RAM  | Disk | IP             |
|---------------|---------------|------|------|------|----------------|
| cka-control   | control-plane | 2    | 4GB  | 20G  | 192.168.100.10 |
| cka-worker-01 | worker        | 2    | 2GB  | 15G  | 192.168.100.11 |
| cka-worker-02 | worker        | 2    | 2GB  | 15G  | 192.168.100.12 |

All VMs share the NAT network `cka-lab` (bridge `virbr-cka`, 192.168.100.0/24) with
static MAC→IP DHCP reservations.

## Base Image Tiers

The lab supports a slow first build (from ISO) and fast rebuilds (clone a prebuilt
qcow2). Images live in `../base-images/` and are **not** committed to git.

| Image | Contents | Built by |
|-------|----------|----------|
| `ubuntu-22.04-cka-base.qcow2` | Clean Ubuntu + k8s prereqs (kernel modules, sysctl, sudo) | `build-base-image.sh` |
| `ubuntu-22.04-cka-k8s.qcow2` | Above + containerd + kubeadm/kubelet/kubectl **1.34** + images pulled | `build-k8s-image.sh` |
| `ubuntu-22.04-cka-k8s-prev.qcow2` | Same but k8s **1.33** (one minor behind) — for upgrade practice | `build-k8s-prev-image.sh` |

`03-vms.sh` picks an image via env vars (highest priority first):
1. `USE_K8S_PREV_IMAGE=1` → prev (1.33) clone
2. (default) → latest k8s (1.34) clone
3. `USE_BASE_IMAGE=1` → clean base clone (then run `04-kubernetes.sh`)
4. ISO install fallback (needs `ISO_PATH`)

## Usage

### Web UI (easiest)

A Flask UI runs at **http://<host-ip>:1922** (systemd service `cka-lab-ui`). Pick an
image, click **Provision**, deploy tasks, and watch live logs. Restart with:
```bash
sudo systemctl restart cka-lab-ui
```

### CLI — fast rebuild (k8s image already exists)

```bash
YES=1 bash teardown.sh    # destroy VMs, network, seeds (no prompts)
bash 01-network.sh        # recreate cka-lab network
bash 02-cloud-init.sh     # regenerate clone seeds (fresh instance-ids)
bash 03-vms.sh            # clone the k8s image — all 3 VMs in parallel (~2 min)
bash 04-kubernetes.sh     # kubeadm init + join (~5 min)
bash 05-verify.sh         # validate cluster health
```

### CLI — first-time build (no images yet)

```bash
export ISO_PATH=/path/to/ubuntu-22.04.5-live-server-amd64.iso
bash 00-preflight.sh          # check host prerequisites
bash 01-network.sh
bash 02-cloud-init.sh
bash 03-vms.sh                # ISO install (~15 min/VM, sequential)
bash 04-kubernetes.sh
bash 05-verify.sh
bash build-base-image.sh      # snapshot the clean base
bash build-k8s-image.sh       # snapshot the 1.34 k8s image
bash build-k8s-prev-image.sh  # snapshot the 1.33 prev image
bash 02-cloud-init.sh         # regenerate clone seeds now that a base image exists
```

### SSH into nodes

```bash
ssh -i ./cka-lab-key ubuntu@192.168.100.10   # cka-control
ssh -i ./cka-lab-key ubuntu@192.168.100.11   # cka-worker-01
ssh -i ./cka-lab-key ubuntu@192.168.100.12   # cka-worker-02
```

Console fallback (password `ubuntu`):
```bash
virsh --connect qemu:///system console cka-control
```

Remote access from another LAN machine is port-forwarded (see `forward-ports.sh`):
ports 2210/2211/2212 → control/worker-01/worker-02:22 on the host IP.

### Copy kubeconfig locally (optional)

```bash
scp -i ./cka-lab-key ubuntu@192.168.100.10:.kube/config ./kubeconfig
export KUBECONFIG=./kubeconfig
kubectl get nodes
```

`k` is aliased to `kubectl` with tab-completion on every node.

## Lab Tasks

Each task deploys a scenario, prints instructions, and ships a verifier.

```bash
bash lab-tasks/task-01-broken-node.sh   # set up scenario + instructions
bash lab-tasks/verify-01.sh             # check your solution
```

| Task | Namespace | Topic |
|------|-----------|-------|
| task-01 | (kube-system) | Fix worker-01 kubelet pointing at the wrong API server |
| task-02 | (control plane) | etcd snapshot backup to `/opt/etcd-backup.db` |
| task-03 | `netpol-lab` | NetworkPolicy — frontend→backend, port 80 only |
| task-04 | `storage-lab` | PersistentVolume + PVC + Pod (hostPath, storageClass `manual`) |
| task-05 | `rbac-lab` | RBAC — ServiceAccount, ClusterRole, ClusterRoleBinding |
| task-06 | `ingress-lab` | Ingress routing `/app1` and `/app2` (object-only; no controller) |
| task-07 | (prev image) | **Minor** upgrade 1.33 → 1.34 of the control plane |
| task-08 | (node) | Drain and uncordon cka-worker-02 |
| task-09 | `workload-lab` | Deployment + ClusterIP service, scale to 5 |
| task-10 | `troubleshoot-lab` | Troubleshoot a pod with a bad image tag |

> task-07 is an exam-style **minor** upgrade and is meant to be run on the **prev**
> image (provision with `USE_K8S_PREV_IMAGE=1` or pick "k8s-prev" in the web UI).

## Components

- Kubernetes **1.34.x** (prev image: 1.33.x), containerd, Calico **v3.32.0** CNI
- Pod CIDR `10.244.0.0/16`, control-plane API on `192.168.100.10:6443`
- k8s packages from `pkgs.k8s.io` (per-minor repos), held via `apt-mark hold`

## Teardown

```bash
bash teardown.sh          # interactive (prompts before removing the SSH keypair)
YES=1 bash teardown.sh    # non-interactive (used by the web UI); keeps the keypair
```

Destroys all VMs, the `cka-lab` network, and generated cloud-init seed ISOs.
Base images in `../base-images/` are left intact.
