#!/usr/bin/env bash
set -Eeuo pipefail

run_ceph_cluster_diagnostics() {
  local root_dir="$1"
  local run_dir="$2"
  local out_dir="$run_dir/ceph-cluster-diagnostics"
  mkdir -p "$out_dir"
  log "Collecting ceph cluster diagnostics"

  safe_run "$out_dir/ceph-status.txt" ceph -s
  safe_run "$out_dir/ceph-health-detail.txt" ceph health detail
  safe_run "$out_dir/ceph-versions.txt" ceph versions
  safe_run "$out_dir/ceph-fsid.txt" ceph fsid
  safe_run "$out_dir/ceph-osd-tree.txt" ceph osd tree
  safe_run "$out_dir/ceph-osd-df.txt" ceph osd df tree
  safe_run "$out_dir/ceph-df-detail.txt" ceph df detail
  safe_run "$out_dir/ceph-report.json" ceph report -f json
  safe_run "$out_dir/ceph-config-dump.txt" ceph config dump
  safe_run "$out_dir/ceph-orch-ps.txt" ceph orch ps
  safe_run "$out_dir/ceph-orch-host-ls.txt" ceph orch host ls
}
