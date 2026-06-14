#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "${SCRIPT_DIR}")/base-images"
REQUIRED_PKGS=(qemu-system-x86 libvirt-daemon-system virtinst libvirt-clients bridge-utils cloud-image-utils)
MIN_RAM_MB=7500
MIN_DISK_GB=55

check_kvm() {
  info "Checking KVM support..."
  if ! egrep -q 'vmx|svm' /proc/cpuinfo; then
    error "CPU does not support hardware virtualisation (no vmx/svm in /proc/cpuinfo)"
    exit 1
  fi
  ok "KVM CPU support present"
}

check_packages() {
  info "Checking required packages..."
  local missing=()
  for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
      missing+=("$pkg")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Missing packages: ${missing[*]} — installing..."
    sudo apt-get update -qq
    sudo apt-get install -y "${missing[@]}"
  fi
  ok "All required packages installed"
}

check_libvirtd() {
  info "Checking libvirtd..."
  if ! systemctl is-active --quiet libvirtd; then
    warn "libvirtd not running — starting..."
    sudo systemctl enable --now libvirtd
  fi
  ok "libvirtd is running"
}

check_ram() {
  info "Checking available RAM..."
  local total_mb
  total_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  if [[ $total_mb -lt $MIN_RAM_MB ]]; then
    error "Insufficient RAM: ${total_mb} MB available, need ${MIN_RAM_MB} MB"
    exit 1
  fi
  ok "RAM: ${total_mb} MB"
}

check_disk() {
  info "Checking free disk space..."
  local free_gb
  free_gb=$(df --output=avail -BG /var/lib/libvirt/images 2>/dev/null || df --output=avail -BG /home)
  free_gb=$(echo "$free_gb" | tail -1 | tr -d 'G ')
  if [[ $free_gb -lt $MIN_DISK_GB ]]; then
    error "Insufficient disk: ${free_gb} GB free, need ${MIN_DISK_GB} GB"
    exit 1
  fi
  ok "Disk: ${free_gb} GB free"
}

check_iso() {
  info "Checking ISO..."
  # ISO is only needed for the slow-path install; clone path uses base images
  if compgen -G "${BASE_DIR}/*.qcow2" > /dev/null; then
    ok "Base image(s) found in ${BASE_DIR} — ISO not required (clone path)"
    return
  fi
  if [[ -z "${ISO_PATH:-}" ]]; then
    error "No base images and ISO_PATH is not set. Export it: export ISO_PATH=/path/to/ubuntu.iso"
    exit 1
  fi
  if [[ ! -f "$ISO_PATH" ]]; then
    error "ISO not found at: $ISO_PATH"
    exit 1
  fi
  ok "ISO found: $ISO_PATH"
}

main() {
  echo "========================================"
  echo " CKA Lab — Preflight checks"
  echo "========================================"
  check_kvm
  check_packages
  check_libvirtd
  check_ram
  check_disk
  check_iso
  echo "========================================"
  ok "All preflight checks passed. Ready to provision."
  echo "========================================"
}

main
