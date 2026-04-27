#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$ROOT_DIR/lib"
TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$ROOT_DIR/output/run-$TS"
FINAL_BUNDLE="$ROOT_DIR/output/ceph-support-bundle-$TS.tar.gz"
mkdir -p "$RUN_DIR" "$ROOT_DIR/output"

source "$LIB_DIR/common.sh"
source "$LIB_DIR/detect_env.sh"
source "$LIB_DIR/run_rook.sh"
source "$LIB_DIR/run_cluster.sh"
source "$LIB_DIR/run_node.sh"
source "$LIB_DIR/package.sh"

[[ "${VERBOSE:-0}" == "1" ]] && set -x

log "Starting ceph-oneclick-diagnostics"
write_manifest_header "$RUN_DIR"

ROOK_ENABLED=0
CLUSTER_ENABLED=0
NODE_ENABLED=0

detect_rook && ROOK_ENABLED=1 || true
detect_ceph_cluster && CLUSTER_ENABLED=1 || true
detect_ceph_node && NODE_ENABLED=1 || true

printf 'rook=%s\ncluster=%s\nnode=%s\n' "$ROOK_ENABLED" "$CLUSTER_ENABLED" "$NODE_ENABLED" >> "$RUN_DIR/manifest.env"

if [[ "$ROOK_ENABLED" -eq 1 ]]; then
  run_rook_diagnostics "$ROOT_DIR" "$RUN_DIR"
else
  log "Rook environment not detected; skipping rook diagnostics"
fi

if [[ "$CLUSTER_ENABLED" -eq 1 ]]; then
  run_ceph_cluster_diagnostics "$ROOT_DIR" "$RUN_DIR"
else
  log "Ceph cluster CLI access not detected; skipping cluster diagnostics"
fi

if [[ "$NODE_ENABLED" -eq 1 ]]; then
  run_ceph_node_diagnostics "$ROOT_DIR" "$RUN_DIR"
else
  log "Ceph node environment not detected; skipping node diagnostics"
fi

finalize_bundle "$ROOT_DIR" "$RUN_DIR" "$FINAL_BUNDLE"
log "Bundle ready: $FINAL_BUNDLE"
