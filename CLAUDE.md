# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Running the Tool

```bash
chmod +x collect-all.sh
./collect-all.sh
```

No arguments or flags. The script auto-detects the environment and runs all applicable diagnostic modes.

**Rook path output** — the full ceph diagnostics bundle is written to the Kubernetes **node's** filesystem at `/var/lib/ceph-diagnostics/` (hostPath). Override with `CEPH_DIAG_HOST_PATH=/path/to/dir ./collect-all.sh`.

**Bare-metal path output** — lands in `output/run-<timestamp>/` and is bundled into `output/ceph-support-bundle-<timestamp>.tar.gz`.

## Architecture

This is a pure Bash diagnostics collector for Ceph/Rook environments. The entrypoint `collect-all.sh` sources six library modules from `lib/`, then runs up to three independent diagnostic modes depending on what's detected in the environment.

### Vendored upstream scripts (`vendor/`)

Scripts vendored from [clyso/ceph_diagnostics](https://github.com/clyso/ceph_diagnostics). Do not edit manually; re-vendor by re-fetching from upstream.

- **`ceph_diagnostics_collect.sh`** — comprehensive `ceph` CLI collection: health, monitors, OSDs, PGs, MDS, RGW, orchestrator, Prometheus metrics, and per-daemon `ceph tell` stats
- **`ceph_diagnostics_node_collect.sh`** — node-level collection via `cephadm`: daemon admin-socket stats, crash info, journal logs, ceph-volume inventory

### Library modules (`lib/`)

- **`common.sh`** — Shared utilities:
  - `log()` — timestamped logging to stdout
  - `have()` — command existence check (`command -v`)
  - `safe_run <output-file> <cmd...>` — runs a command capturing stdout+stderr to a file, never propagates failure
  - `write_manifest_header()` — writes run metadata to `meta/manifest.txt`

- **`detect_env.sh`** — Three detection functions that set flags used by `collect-all.sh`:
  - `detect_rook` — checks for `kubectl` + `rook-ceph` namespace/pods
  - `detect_ceph_cluster` — checks for `ceph` binary + successful `ceph -s`
  - `detect_ceph_node` — checks for `/var/log/ceph`, `cephadm`, or running ceph daemon processes

- **`run_rook.sh`** — Rook/K8s collection in two parts:
  1. **K8s resource collection** (runs locally via `kubectl`): namespace, all Rook CRD statuses (13 kinds), pod describe+logs, storage classes, events
  2. **Ceph diagnostics Job**: creates a short-lived Kubernetes Job that mounts `vendor/ceph_diagnostics_collect.sh` via ConfigMap and a **hostPath** volume at `CEPH_DIAG_HOST_PATH` on the node, runs the full upstream script, then deletes the Job and ConfigMap. The Job uses the rook-ceph-tools image and mounts `rook-ceph-config` (ceph.conf) + `rook-ceph-admin-keyring` (keyring) so the ceph CLI works inside the container.

- **`run_cluster.sh`** — Native `ceph` CLI collection for directly accessible clusters (bare-metal/cephadm): health, status, OSD tree/df, versions, config dump, orch ps/host ls

- **`run_node.sh`** — Host-level collection: hostname/OS/disk/network info, systemd ceph units, running processes, Ceph log files from `/var/log/ceph`

- **`package.sh`** — `finalize_bundle()`: tars the run directory into the support bundle tarball

### Output structure

**Rook path** (Kubernetes Job writes to the node):
```
<node>:/var/lib/ceph-diagnostics/ceph-collect_<DATE>-XXX.tar.gz   ← full ceph diagnostics
output/run-<timestamp>/rook-diagnostics/                           ← K8s resource metadata
  namespace.txt, rook-version.txt, status-*.txt
  <pod-name>.describe.txt, <pod-name>.logs.txt
  ceph-diag-job-location.txt                                       ← node + path of bundle
  ceph-diag-job.log                                                ← Job container stdout
output/ceph-support-bundle-<timestamp>.tar.gz                      ← K8s metadata tarball
```

**Bare-metal path**:
```
output/run-<timestamp>/
  meta/manifest.txt
  ceph-cluster-diagnostics/
  ceph-node-diagnostics/
output/ceph-support-bundle-<timestamp>.tar.gz
```

### Key conventions

- Every file uses `set -Eeuo pipefail` for strict error handling.
- All external command invocations go through `safe_run` so a single failure never aborts collection.
- All three diagnostic modes are independent and can run simultaneously in one invocation.
- The Rook ceph diagnostics Job cleans up after itself (Job + ConfigMap deleted on exit).
