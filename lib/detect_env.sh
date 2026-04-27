#!/usr/bin/env bash
set -Eeuo pipefail

detect_rook() {
  have kubectl || return 1
  kubectl get ns rook-ceph >/dev/null 2>&1 && return 0
  kubectl get pods -A 2>/dev/null | grep -qi rook-ceph && return 0
  return 1
}

detect_ceph_cluster() {
  have ceph || return 1
  ceph -s >/dev/null 2>&1
}

detect_ceph_node() {
  [[ -d /var/log/ceph ]] && return 0
  have cephadm && return 0
  pgrep -fa 'ceph-(osd|mon|mgr|mds|rgw)' >/dev/null 2>&1 && return 0
  return 1
}
