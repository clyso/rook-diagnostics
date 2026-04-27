# ceph-oneclick-diagnostics

A starter one-click support bundle project that combines:
- **Rook Diagnostics** for Kubernetes/Rook collection
- **Ceph Diagnostics** concepts inspired by `clyso/ceph_diagnostics` for cluster and node collection

## Goals
- Single command execution
- Unified output bundle
- Separate sections for rook, cluster, and node diagnostics
- Easy to extend with upstream scripts later

## Run
```bash
chmod +x collect-all.sh
./collect-all.sh
```

## Output
The script creates:
- `output/run-<timestamp>/`
- `output/ceph-support-bundle-<timestamp>.tar.gz`

## Notes
This starter implementation uses native `kubectl`, `ceph`, and host commands to provide a merged workflow. You can later replace each module with vendored upstream scripts from:
- `clyso/ceph_diagnostics`
