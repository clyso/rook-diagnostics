#!/usr/bin/env bash
set -Eeuo pipefail

finalize_bundle() {
  local root_dir="$1"
  local run_dir="$2"
  local final_bundle="$3"
  (cd "$root_dir/output" && tar -czf "$final_bundle" "$(basename "$run_dir")")
}
