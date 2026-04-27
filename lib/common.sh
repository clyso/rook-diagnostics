#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

safe_run() {
  local outfile="$1"
  shift
  [[ "${VERBOSE:-0}" == "1" ]] && log "safe_run: $*  → $outfile"
  {
    echo "# CMD: $*"
    "$@"
  } >"$outfile" 2>&1 || true
}

write_manifest_header() {
  local run_dir="$1"
  mkdir -p "$run_dir/meta"
  {
    echo "timestamp=$(date --iso-8601=seconds 2>/dev/null || date)"
    echo "hostname=$(hostname 2>/dev/null || true)"
    echo "kernel=$(uname -a 2>/dev/null || true)"
    echo "user=$(id -un 2>/dev/null || true)"
  } > "$run_dir/meta/manifest.txt"
}
