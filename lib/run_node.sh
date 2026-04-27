#!/usr/bin/env bash
set -Eeuo pipefail

run_ceph_node_diagnostics() {
  local root_dir="$1"
  local run_dir="$2"
  local out_dir="$run_dir/ceph-node-diagnostics"
  mkdir -p "$out_dir"
  log "Collecting ceph node diagnostics"

  safe_run "$out_dir/hostname.txt" hostnamectl
  safe_run "$out_dir/os-release.txt" cat /etc/os-release
  safe_run "$out_dir/uptime.txt" uptime
  safe_run "$out_dir/df-h.txt" df -h
  safe_run "$out_dir/lsblk.txt" lsblk
  safe_run "$out_dir/ip-a.txt" ip a
  safe_run "$out_dir/ip-r.txt" ip r
  safe_run "$out_dir/systemctl-ceph.txt" systemctl list-units 'ceph*' --no-pager
  safe_run "$out_dir/ps-ceph.txt" pgrep -fa ceph

  if [[ -d /var/log/ceph ]]; then
    mkdir -p "$out_dir/logs"
    find /var/log/ceph -maxdepth 1 -type f | while read -r f; do
      cp -a "$f" "$out_dir/logs/" 2>/dev/null || true
    done
  fi
}
