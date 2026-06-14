#!/usr/bin/env bash
# Re-applies SSH port forwarding rules for CKA VMs.
# Run once after boot, or install as a systemd service (see below).
#
# From any machine on the LAN:
#   ssh -i ./cka-lab-key -p 2210 ubuntu@192.168.1.184   # cka-control
#   ssh -i ./cka-lab-key -p 2211 ubuntu@192.168.1.184   # cka-worker-01
#   ssh -i ./cka-lab-key -p 2212 ubuntu@192.168.1.184   # cka-worker-02
#
# To install as a systemd service so rules persist across reboots:
#   sudo cp /etc/systemd/system/cka-portforward.service (see EOF below)
#   sudo systemctl enable --now cka-portforward
set -euo pipefail

LAN_IF="wlp2s0"

declare -A PORTS=(
  [2210]="192.168.100.10"   # cka-control
  [2211]="192.168.100.11"   # cka-worker-01
  [2212]="192.168.100.12"   # cka-worker-02
)

for port in "${!PORTS[@]}"; do
  dest="${PORTS[$port]}"
  # Idempotent: remove existing rule first, then re-add
  iptables -t nat -D PREROUTING -i "$LAN_IF" -p tcp --dport "$port" \
    -j DNAT --to-destination "${dest}:22" 2>/dev/null || true
  iptables -D FORWARD -d "$dest" -p tcp --dport 22 -j ACCEPT 2>/dev/null || true

  iptables -t nat -I PREROUTING -i "$LAN_IF" -p tcp --dport "$port" \
    -j DNAT --to-destination "${dest}:22"
  iptables -I FORWARD -d "$dest" -p tcp --dport 22 -j ACCEPT
  echo "Forwarding :${port} -> ${dest}:22"
done

echo "Done."
