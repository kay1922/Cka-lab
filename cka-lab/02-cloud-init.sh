#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "${SCRIPT_DIR}")/base-images"
BASE_IMAGE="${BASE_DIR}/ubuntu-22.04-cka-base.qcow2"
SEEDS_DIR="${SCRIPT_DIR}/seeds"
KEY_FILE="${SCRIPT_DIR}/cka-lab-key"
KEY_PUB="${KEY_FILE}.pub"
# Host user's personal key — injected alongside cka-lab-key so direct SSH works
HOST_KEY_PUB="${HOME}/.ssh/id_rsa.pub"

VMS=(cka-control cka-worker-01 cka-worker-02)

generate_keypair() {
  if [[ -f "$KEY_FILE" && -f "$KEY_PUB" ]]; then
    ok "SSH keypair already exists at ${KEY_FILE}"
    return
  fi
  info "Generating SSH keypair..."
  ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "cka-lab"
  ok "Keypair generated: ${KEY_FILE}"
}

# Returns all authorized keys as YAML list items (indented for autoinstall ssh block)
authorized_keys_yaml() {
  local indent="$1"
  echo "${indent}- $(cat "$KEY_PUB")"
  if [[ -f "$HOST_KEY_PUB" ]]; then
    echo "${indent}- $(cat "$HOST_KEY_PUB")"
  fi
}

# Seed for fresh ISO install (Ubuntu Subiquity autoinstall format)
make_autoinstall_seed() {
  local vm="$1"
  local out_dir="${SEEDS_DIR}/${vm}"
  local seed_iso="${SEEDS_DIR}/${vm}-seed.iso"

  mkdir -p "$out_dir"

  local hashed_pw
  hashed_pw=$(openssl passwd -6 'ubuntu')

  local auth_keys
  auth_keys=$(authorized_keys_yaml "      ")

  cat > "${out_dir}/user-data" <<EOF
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: ${vm}
    username: ubuntu
    password: "${hashed_pw}"
  ssh:
    install-server: true
    authorized-keys:
${auth_keys}
  storage:
    layout:
      name: direct
  packages:
    - qemu-guest-agent
    - curl
    - apt-transport-https
  late-commands:
    - echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/ubuntu
    - chmod 0440 /target/etc/sudoers.d/ubuntu
    - sed -i '/[[:space:]]swap[[:space:]]/s/^/#/' /target/etc/fstab
    - printf 'overlay\nbr_netfilter\n' > /target/etc/modules-load.d/k8s.conf
    - printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n' > /target/etc/sysctl.d/k8s.conf
    - printf '192.168.100.10 cka-control\n192.168.100.11 cka-worker-01\n192.168.100.12 cka-worker-02\n' >> /target/etc/hosts
EOF

  cat > "${out_dir}/meta-data" <<EOF
instance-id: ${vm}
local-hostname: ${vm}
EOF

  _write_iso "$seed_iso" "$out_dir"
  ok "Autoinstall seed: ${seed_iso}"
}

# Seed for clone boot (standard cloud-config, base image already installed)
make_cloudinit_seed() {
  local vm="$1"
  local out_dir="${SEEDS_DIR}/${vm}-clone"
  local seed_iso="${SEEDS_DIR}/${vm}-clone-seed.iso"

  mkdir -p "$out_dir"

  local auth_keys
  auth_keys=$(authorized_keys_yaml "  ")

  # Minimal config: set hostname and ensure SSH keys are present.
  # Kernel modules, sysctl, sudo, and /etc/hosts are already baked into the base image.
  cat > "${out_dir}/user-data" <<EOF
#cloud-config
hostname: ${vm}
manage_etc_hosts: true
ssh_authorized_keys:
${auth_keys}
EOF

  # New instance-id triggers cloud-init to run (not skip as "already run")
  cat > "${out_dir}/meta-data" <<EOF
instance-id: ${vm}-$(date +%s)
local-hostname: ${vm}
EOF

  _write_iso "$seed_iso" "$out_dir"
  ok "Clone seed: ${seed_iso}"
}

_write_iso() {
  local out="$1"
  local dir="$2"
  if command -v cloud-localds &>/dev/null; then
    cloud-localds "$out" "${dir}/user-data" "${dir}/meta-data"
  else
    genisoimage -output "$out" -volid cidata -joliet -rock \
      "${dir}/user-data" "${dir}/meta-data"
  fi
}

main() {
  echo "========================================"
  echo " CKA Lab — Cloud-init seed generation"
  echo "========================================"
  mkdir -p "$SEEDS_DIR"
  generate_keypair

  for vm in "${VMS[@]}"; do
    if [[ -f "${SEEDS_DIR}/${vm}-seed.iso" ]]; then
      ok "Autoinstall seed for ${vm} already exists — skipping"
    else
      make_autoinstall_seed "$vm"
    fi

    if [[ -f "$BASE_IMAGE" ]]; then
      if [[ -f "${SEEDS_DIR}/${vm}-clone-seed.iso" ]]; then
        ok "Clone seed for ${vm} already exists — skipping"
      else
        make_cloudinit_seed "$vm"
      fi
    fi
  done

  echo "========================================"
  ok "Seeds ready in ${SEEDS_DIR}"
  if [[ -f "$BASE_IMAGE" ]]; then
    info "Clone seeds generated (base image detected)"
  else
    info "Only autoinstall seeds generated (no base image yet — run build-base-image.sh after first provision)"
  fi
  echo "========================================"
}

main
