#!/usr/bin/env bash
set -Eeuo pipefail

# hostPath on the Kubernetes node where the ceph-diagnostics bundle is written.
# The directory is created by the Job if it does not exist.
CEPH_DIAG_HOST_PATH="${CEPH_DIAG_HOST_PATH:-/var/lib/ceph-diagnostics}"

rook_namespace() {
  if kubectl get ns rook-ceph >/dev/null 2>&1; then
    echo rook-ceph
    return 0
  fi
  kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -E '^rook-' | head -n1 || true
}

collect_rook_version() {
  local ns="$1"
  local out_dir="$2"
  {
    echo "# rook operator image"
    kubectl -n "$ns" get deployment rook-ceph-operator \
      -o jsonpath='{.spec.template.spec.containers[0].image}'
    echo
    echo "# rook operator yaml"
    kubectl -n "$ns" get deployment rook-ceph-operator -o yaml
  } > "$out_dir/rook-version.txt" 2>&1 || true
}

collect_cr_status_type() {
  local ns="$1" kind="$2" outfile="$3"
  {
    echo "kind=$kind namespace=$ns"
    kubectl -n "$ns" get "$kind" \
      -o jsonpath='{range .items[*]}NAME={.metadata.name}{"\n"}PHASE={.status.phase}{"\n"}CONDITIONS={range .status.conditions[*]}{.type}{":"}{.status}{" reason="}{.reason}{" message="}{.message}{" lastTransition="}{.lastTransitionTime}{"; "}{end}{"\n---\n"}{end}'
    echo
    echo "# wide"
    kubectl -n "$ns" get "$kind" -o wide
  } >"$outfile" 2>&1 || true
}

collect_rook_cr_status() {
  local ns="$1" out_dir="$2"
  local kinds=(
    cephcluster cephblockpool cephfilesystem cephobjectstore cephobjectstoreuser
    cephfilesystemsubvolumegroup cephnfs cephclient cephcosidriver cephrbdmirror
    cephbuckettopic cephbucketnotification cephbucketrealm
  )

  : > "$out_dir/status-all.txt"
  for kind in "${kinds[@]}"; do
    if kubectl api-resources --namespaced=true -o name 2>/dev/null | grep -qx "$kind"; then
      collect_cr_status_type "$ns" "$kind" "$out_dir/status-${kind}.txt"
      {
        echo "===== $kind ====="
        cat "$out_dir/status-${kind}.txt"
        echo
      } >> "$out_dir/status-all.txt"
    fi
  done
}

# Resolve the ceph container image to use for the diagnostics Job.
# Prefers the rook-ceph-tools image; falls back to the operator image.
resolve_ceph_image() {
  local ns="$1"
  local image
  image=$(kubectl -n "$ns" get deploy rook-ceph-tools \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null) || true
  if [[ -z "$image" ]]; then
    image=$(kubectl -n "$ns" get deploy rook-ceph-operator \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null) || true
  fi
  echo "$image"
}

# Run ceph_diagnostics_collect.sh inside a short-lived Kubernetes Job.
# Output is written to CEPH_DIAG_HOST_PATH on whichever node the Job runs on.
# The Job and its ConfigMap are deleted after completion.
run_diagnostics_job() {
  local ns="$1"
  local out_dir="$2"   # local dir for K8s metadata / job logs
  local ts="$3"
  local root_dir="$4"

  local image job_name cm_name script_src node

  image=$(resolve_ceph_image "$ns")
  if [[ -z "$image" ]]; then
    log "Cannot determine ceph container image; skipping ceph diagnostics Job"
    return 0
  fi

  job_name="ceph-diag-${ts}"
  cm_name="ceph-diag-script-${ts}"
  script_src="${root_dir}/vendor/ceph_diagnostics_collect.sh"

  log "Creating ConfigMap ${cm_name} with diagnostics script"
  kubectl -n "$ns" create configmap "$cm_name" \
    --from-file=ceph_diagnostics_collect.sh="$script_src" >/dev/null

  log "Launching diagnostics Job ${job_name} (image: ${image})"
  log "Output hostPath: ${CEPH_DIAG_HOST_PATH}"

  # Detect which config source is available (older Rook ships rook-ceph-config;
  # newer Rook removed it and stores monitor addresses in rook-ceph-mon-endpoints).
  local has_config_cm has_mon_endpoints has_keyring_secret
  has_config_cm=$(kubectl -n "$ns" get configmap rook-ceph-config \
    --ignore-not-found -o name 2>/dev/null || true)
  has_mon_endpoints=$(kubectl -n "$ns" get configmap rook-ceph-mon-endpoints \
    --ignore-not-found -o name 2>/dev/null || true)
  has_keyring_secret=$(kubectl -n "$ns" get secret rook-ceph-admin-keyring \
    --ignore-not-found -o name 2>/dev/null || true)

  # Build init-containers and extra volumes based on what exists.
  # Strategy A (old Rook): project rook-ceph-config + keyring directly into /etc/ceph.
  # Strategy B (new Rook): run an init container that builds ceph.conf from
  #   rook-ceph-mon-endpoints, then optionally copies the keyring.
  local init_containers="" ceph_etc_volume_spec keyring_volume_spec="" keyring_volume_mount=""

  if [[ -n "$has_keyring_secret" ]]; then
    keyring_volume_spec="
      - name: ceph-keyring
        secret:
          secretName: rook-ceph-admin-keyring"
    keyring_volume_mount="
          - name: ceph-keyring
            mountPath: /keyring
            readOnly: true"
  else
    log "WARNING: secret rook-ceph-admin-keyring not found; admin keyring will not be injected into the Job"
  fi

  if [[ -n "$has_config_cm" ]]; then
    # Old-style: project both resources directly — no init container needed.
    local projected_sources="
          - configMap:
              name: rook-ceph-config
              items:
              - key: config
                path: ceph.conf"
    if [[ -n "$has_keyring_secret" ]]; then
      projected_sources+="
          - secret:
              name: rook-ceph-admin-keyring
              items:
              - key: keyring
                path: keyring"
    fi
    ceph_etc_volume_spec="
      - name: ceph-etc
        projected:
          sources:${projected_sources}"
    keyring_volume_spec=""   # already projected into ceph-etc
    keyring_volume_mount=""
  elif [[ -n "$has_mon_endpoints" ]]; then
    # New-style: generate ceph.conf at Job start from the mon-endpoints ConfigMap.
    log "rook-ceph-config not found; will generate ceph.conf from rook-ceph-mon-endpoints"
    ceph_etc_volume_spec="
      - name: ceph-etc
        emptyDir: {}
      - name: mon-endpoints
        configMap:
          name: rook-ceph-mon-endpoints"
    # The init container parses the "data" key ("a=host:port,b=host:port,...") and
    # writes a minimal ceph.conf, then copies the keyring if available.
    init_containers="
      initContainers:
      - name: config-init
        image: ${image}
        command:
        - /bin/sh
        - -c
        - |
          set -e
          MON_DATA=\$(cat /mon-endpoints/data 2>/dev/null || true)
          if [ -z \"\$MON_DATA\" ]; then
            echo 'ERROR: rook-ceph-mon-endpoints data key is empty' >&2
            exit 1
          fi
          # Convert "a=host:port,b=host:port" -> "host:port,host:port"
          MON_HOSTS=\$(printf '%s' \"\$MON_DATA\" | tr ',' '\n' | sed 's/[^=]*=//' | tr '\n' ',' | sed 's/,\$//')
          mkdir -p /etc/ceph
          printf '[global]\nmon_host = %s\n' \"\$MON_HOSTS\" > /etc/ceph/ceph.conf
          if [ -f /keyring/keyring ]; then
            cp /keyring/keyring /etc/ceph/keyring
          fi
          echo 'config-init done:' && cat /etc/ceph/ceph.conf
        volumeMounts:
        - name: ceph-etc
          mountPath: /etc/ceph
        - name: mon-endpoints
          mountPath: /mon-endpoints
          readOnly: true${keyring_volume_mount}"
  else
    log "WARNING: neither rook-ceph-config nor rook-ceph-mon-endpoints found; /etc/ceph will not be populated"
    ceph_etc_volume_spec="
      - name: ceph-etc
        emptyDir: {}"
  fi

  kubectl -n "$ns" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${ns}
  labels:
    app: ceph-diagnostics
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      ${init_containers}
      containers:
      - name: collector
        image: ${image}
        command:
        - /bin/sh
        - /scripts/ceph_diagnostics_collect.sh
        - --archive-dir
        - /output
        volumeMounts:
        - name: ceph-etc
          mountPath: /etc/ceph
        - name: script
          mountPath: /scripts
        - name: output
          mountPath: /output
      volumes:${ceph_etc_volume_spec}${keyring_volume_spec}
      - name: script
        configMap:
          name: ${cm_name}
          defaultMode: 0755
      - name: output
        hostPath:
          path: ${CEPH_DIAG_HOST_PATH}
          type: DirectoryOrCreate
EOF

  log "Waiting for Job ${job_name} to complete (timeout 10 min)..."
  if kubectl -n "$ns" wait "job/${job_name}" \
      --for=condition=complete --timeout=600s >/dev/null 2>&1; then
    node=$(kubectl -n "$ns" get pod -l "job-name=${job_name}" \
      -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null) || node="unknown"
    log "ceph diagnostics bundle written to node=${node} at ${CEPH_DIAG_HOST_PATH}"
    printf 'node=%s\nhost_path=%s\n' "$node" "$CEPH_DIAG_HOST_PATH" \
      > "$out_dir/ceph-diag-job-location.txt"
  else
    log "WARNING: diagnostics Job ${job_name} did not complete successfully within timeout"
    kubectl -n "$ns" get pod -l "job-name=${job_name}" \
      > "$out_dir/ceph-diag-job-pods.txt" 2>&1 || true
  fi

  # Capture job container logs regardless of outcome
  kubectl -n "$ns" logs -l "job-name=${job_name}" --tail=-1 \
    > "$out_dir/ceph-diag-job.log" 2>&1 || true

  # Clean up ephemeral Job and ConfigMap
  kubectl -n "$ns" delete job "${job_name}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$ns" delete configmap "${cm_name}" --ignore-not-found >/dev/null 2>&1 || true
}

run_rook_diagnostics() {
  local root_dir="$1"
  local run_dir="$2"
  local out_dir="$run_dir/rook-diagnostics"
  mkdir -p "$out_dir"
  log "Collecting Rook/K8s diagnostics"

  local ns
  ns="$(rook_namespace)"
  if [[ -z "$ns" ]]; then
    log "No Rook namespace found"
    return 0
  fi

  echo "$ns" > "$out_dir/namespace.txt"
  collect_rook_version "$ns" "$out_dir"
  collect_rook_cr_status "$ns" "$out_dir"

  safe_run "$out_dir/k8s-namespaces.txt"   kubectl get ns
  safe_run "$out_dir/rook-pods.txt"         kubectl -n "$ns" get pods -o wide
  safe_run "$out_dir/rook-jobs.txt"         kubectl -n "$ns" get jobs -o wide
  safe_run "$out_dir/storageclasses.txt"    kubectl get storageclass
  safe_run "$out_dir/events.txt"            kubectl get events -A --sort-by=.lastTimestamp
  safe_run "$out_dir/operator-describe.txt" kubectl -n "$ns" describe deploy rook-ceph-operator

  kubectl get pods -n "$ns" -o name 2>/dev/null | while read -r pod; do
    name="${pod##*/}"
    safe_run "$out_dir/${name}.describe.txt" kubectl -n "$ns" describe "$pod"
    safe_run "$out_dir/${name}.logs.txt"     kubectl -n "$ns" logs "$pod" \
      --all-containers=true --tail=-1
  done

  kubectl get jobs -n "$ns" -o name 2>/dev/null | while read -r job; do
    name="${job##*/}"
    safe_run "$out_dir/${name}.describe.txt" kubectl -n "$ns" describe "$job"
  done

  # Derive a short timestamp for K8s object names (no colons, lowercase)
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"

  run_diagnostics_job "$ns" "$out_dir" "$ts" "$root_dir"
}
