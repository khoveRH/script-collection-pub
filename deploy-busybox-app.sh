#!/usr/bin/env bash
#
# deploy-busybox-app.sh
#
# Deploys a minimal busybox test application (Deployment + PVC, optionally
# creating its namespace) for exercising storage-related scripts against --
# e.g. the SELinux-context migration/revert, PVC-terminating recovery, or
# Retain-policy audit scripts in this same directory.
#
# Creates, in order:
#   1. The namespace, if it doesn't exist: auto-created when -n/--namespace
#      is used to pick a namespace other than the default, or when
#      --create-namespace is given. Left at the default (busybox-test)
#      without --create-namespace, it errors out instead of assuming it's
#      safe to create a namespace you didn't explicitly ask for.
#   2. A PVC on the requested StorageClass and size.
#   3. A single-replica Deployment mounting that PVC at /data, running
#      busybox in a loop that, every --interval seconds:
#        - appends one timestamped line to /data/heartbeat.log, and
#        - writes --write-mb MiB of random (incompressible) data to
#          /data/blob-<n>.bin with fsync, so it really reaches the backend
#          (Ceph OSDs on ODF) rather than sitting in page cache.
#      Blob files are reused as a ring buffer, so on-disk usage stays capped
#      at roughly --max-mb while the backend keeps seeing steady write I/O.
#      Any failed write makes the container exit, so a broken/unwritable
#      mount shows up as CrashLoopBackOff instead of a silently "Running" pod.
# Then waits for the Deployment to become Available and verifies that data
# is actually being written to the volume.
#
# The app is labeled app=<name> and app.kubernetes.io/name=<name> only --
# deliberately NOT app.kubernetes.io/managed-by or /instance, so it doesn't
# get flagged as "ownership-protected" by audit-pv-retain-policy.sh and
# stays a usable test case for it.
#
# Requires: oc
#
# Usage:
#   deploy-busybox-app.sh [options]
#
# Options:
#   -n, --namespace NS       Namespace to deploy into (default: busybox-test).
#                             If this differs from the default, it's created
#                             automatically when missing.
#       --create-namespace   Create the namespace if it doesn't already exist
#                             (needed only to auto-create the default
#                             namespace busybox-test; a custom -n is always
#                             auto-created)
#   -s, --storage-class SC   StorageClass for the PVC
#                             (default: ocs-storagecluster-cephfs)
#       --size SIZE           PVC size (default: 1Gi)
#       --name NAME           Name for the PVC, Deployment, and its labels
#                             (default: busybox-test)
#       --write-mb N          MiB of random data written per interval
#                             (default: 4; 0 = heartbeat line only)
#       --max-mb N            Cap on total blob data kept on the volume, in
#                             MiB (default: 256; must be <= 80% of --size)
#       --interval SECONDS    Seconds between write rounds (default: 5)
#       --dry-run             Print manifests without applying them
#   -t, --timeout SECONDS    Timeout waiting for the Deployment to become
#                             Available (default: 120)
#   -h, --help                Show this help
#
# Examples:
#   # defaults: namespace busybox-test (must already exist), 1Gi on
#   # ocs-storagecluster-cephfs, 4 MiB every 5s, capped at 256 MiB on disk
#   deploy-busybox-app.sh --create-namespace
#
#   # heavier: 5Gi PVC, 32 MiB every 2s (~16 MiB/s), keep up to 4 GiB
#   deploy-busybox-app.sh -n storage-test --size 5Gi --write-mb 32 \
#       --interval 2 --max-mb 4096
#
#   # original lightweight behavior (heartbeat line only)
#   deploy-busybox-app.sh --create-namespace --write-mb 0
#
set -euo pipefail

NAMESPACE="busybox-test"
NAMESPACE_EXPLICIT=0
CREATE_NAMESPACE=0
STORAGE_CLASS="ocs-storagecluster-cephfs"
SIZE="1Gi"
NAME="busybox-test"
WRITE_MB=4
MAX_MB=256
INTERVAL=5
DRY_RUN=0
TIMEOUT=120

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*" >&2; }
err()  { log "ERROR $*" >&2; }
die()  { err "$*"; exit 1; }

# print the leading comment block (minus the shebang) as help text
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# to_mib <k8s quantity>: echoes size in MiB for Mi/Gi/Ti quantities, else empty
to_mib() {
    if [[ "$1" =~ ^([0-9]+)(Mi|Gi|Ti)$ ]]; then
        local n="${BASH_REMATCH[1]}"
        case "${BASH_REMATCH[2]}" in
            Mi) echo "$n" ;;
            Gi) echo $(( n * 1024 )) ;;
            Ti) echo $(( n * 1024 * 1024 )) ;;
        esac
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace) NAMESPACE="$2"; NAMESPACE_EXPLICIT=1; shift 2 ;;
        --create-namespace) CREATE_NAMESPACE=1; shift ;;
        -s|--storage-class) STORAGE_CLASS="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        --write-mb) WRITE_MB="$2"; shift 2 ;;
        --max-mb) MAX_MB="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -t|--timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) die "unexpected argument: $1" ;;
    esac
done

# ---- validate write settings ------------------------------------------------

is_uint "$WRITE_MB" || die "--write-mb must be a non-negative integer (got: $WRITE_MB)"
is_uint "$MAX_MB"   || die "--max-mb must be a non-negative integer (got: $MAX_MB)"
is_uint "$INTERVAL" && [[ "$INTERVAL" -ge 1 ]] || die "--interval must be an integer >= 1 (got: $INTERVAL)"

SLOTS=0
if [[ "$WRITE_MB" -gt 0 ]]; then
    [[ "$MAX_MB" -ge "$WRITE_MB" ]] \
        || die "--max-mb ($MAX_MB) must be >= --write-mb ($WRITE_MB)"
    SLOTS=$(( MAX_MB / WRITE_MB ))
    SIZE_MIB=$(to_mib "$SIZE")
    if [[ -n "$SIZE_MIB" ]]; then
        LIMIT_MIB=$(( SIZE_MIB * 80 / 100 ))
        [[ $(( SLOTS * WRITE_MB )) -le "$LIMIT_MIB" ]] \
            || die "--max-mb $MAX_MB would exceed 80% of PVC size $SIZE (${LIMIT_MIB} MiB); lower --max-mb or raise --size"
    else
        warn "can't parse PVC size '$SIZE' (expected NNMi/NNGi/NNTi); skipping --max-mb vs --size check"
    fi
    info "write load: ${WRITE_MB} MiB every ${INTERVAL}s (~$(( WRITE_MB * 60 / INTERVAL )) MiB/min), ${SLOTS} blob slots = $(( SLOTS * WRITE_MB )) MiB max on disk"
else
    info "write load: heartbeat line only (--write-mb 0)"
fi

require_cmd oc

apply() {
    # apply <manifest-on-stdin>
    local manifest
    manifest=$(cat)
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '%s\n' "$manifest"
        printf '%s\n' "$manifest" | oc apply --dry-run=client -f - >/dev/null
    else
        printf '%s\n' "$manifest" | oc apply -f -
    fi
}

namespace_exists() { oc get namespace "$1" >/dev/null 2>&1; }

# ---- namespace --------------------------------------------------------------

if namespace_exists "$NAMESPACE"; then
    info "namespace $NAMESPACE already exists"
elif [[ "$CREATE_NAMESPACE" -eq 1 || "$NAMESPACE_EXPLICIT" -eq 1 ]]; then
    info "creating namespace $NAMESPACE"
    cat <<EOF | apply
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
EOF
else
    die "namespace $NAMESPACE does not exist (pass --create-namespace, or -n a different namespace, to create it)"
fi

# ---- PVC ----------------------------------------------------------------

info "deploying PVC $NAME (${SIZE}, storageClass ${STORAGE_CLASS}) in $NAMESPACE"
cat <<EOF | apply
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${NAME}
    app.kubernetes.io/name: ${NAME}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: ${SIZE}
EOF

# ---- Deployment ---------------------------------------------------------

# Container loop (\$ is escaped so the pod's shell, not this script, expands it).
# Every write is checked; any failure exits the container so it's visible.
info "deploying busybox Deployment $NAME in $NAMESPACE"
cat <<EOF | apply
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${NAME}
    app.kubernetes.io/name: ${NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${NAME}
  template:
    metadata:
      labels:
        app: ${NAME}
        app.kubernetes.io/name: ${NAME}
    spec:
      containers:
        - name: busybox
          image: busybox:1.36
          env:
            - name: WRITE_MB
              value: "${WRITE_MB}"
            - name: SLOTS
              value: "${SLOTS}"
            - name: INTERVAL
              value: "${INTERVAL}"
          command: ["sh", "-c"]
          args:
            - |
              i=0
              while :; do
                date >> /data/heartbeat.log || { echo "FATAL: heartbeat write to /data failed" >&2; exit 1; }
                if [ "\$WRITE_MB" -gt 0 ]; then
                  f=/data/blob-\$((i % SLOTS)).bin
                  if ! dd if=/dev/urandom of="\$f" bs=1M count="\$WRITE_MB" conv=fsync 2>/tmp/dd.err; then
                    echo "FATAL: writing \$WRITE_MB MiB to \$f failed:" >&2; cat /tmp/dd.err >&2; exit 1
                  fi
                  i=\$((i + 1))
                fi
                sleep "\$INTERVAL"
              done
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: ${NAME}
EOF

if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would wait for deployment/$NAME to become Available and verify writes"
    exit 0
fi

# dump everything useful for diagnosing a failed deploy/write, then exit 1
fail_with_diagnostics() {
    err "$1"
    err "--- pods ---"
    oc get pods -n "$NAMESPACE" -l "app=$NAME" -o wide >&2 || true
    err "--- pvc ---"
    oc get pvc -n "$NAMESPACE" "$NAME" >&2 || true
    oc describe pvc -n "$NAMESPACE" "$NAME" | sed -n '/^Events:/,$p' >&2 || true
    err "--- container logs (current, then previous) ---"
    oc logs -n "$NAMESPACE" "deploy/$NAME" --tail=20 >&2 || true
    oc logs -n "$NAMESPACE" "deploy/$NAME" --previous --tail=20 >&2 2>/dev/null || true
    err "--- /data inside pod ---"
    oc exec -n "$NAMESPACE" "deploy/$NAME" -- sh -c 'id; mount | grep " /data "; ls -laZ /data 2>/dev/null || ls -la /data; df -h /data' >&2 || true
    exit 1
}

info "waiting up to ${TIMEOUT}s for deployment/$NAME to become Available"
oc wait --for=condition=Available "deployment/${NAME}" -n "$NAMESPACE" --timeout="${TIMEOUT}s" \
    || fail_with_diagnostics "deployment/$NAME did not become Available within ${TIMEOUT}s"
info "deployment/$NAME is Available"

# ---- verify data is actually landing on the volume -----------------------

data_stats() {
    # echoes "<heartbeat lines> <KiB used under /data>"
    oc exec -n "$NAMESPACE" "deploy/$NAME" -- sh -c \
        'echo "$(wc -l < /data/heartbeat.log 2>/dev/null || echo 0) $(du -sk /data | cut -f1)"' 2>/dev/null
}

info "verifying writes (sampling /data twice, $(( INTERVAL * 2 + 2 ))s apart)"
read -r LINES1 KIB1 <<<"$(data_stats || echo "x x")"
sleep $(( INTERVAL * 2 + 2 ))
read -r LINES2 KIB2 <<<"$(data_stats || echo "x x")"

is_uint "$LINES1" && is_uint "$LINES2" \
    || fail_with_diagnostics "could not read /data stats from the pod"
[[ "$LINES2" -gt "$LINES1" ]] \
    || fail_with_diagnostics "heartbeat.log not growing ($LINES1 -> $LINES2 lines); writes to /data are failing"
if [[ "$WRITE_MB" -gt 0 && "$KIB2" -lt $(( WRITE_MB * 1024 )) ]]; then
    fail_with_diagnostics "only ${KIB2} KiB under /data, expected at least ${WRITE_MB} MiB of blob data"
fi

info "writes verified: heartbeat $LINES1 -> $LINES2 lines, /data usage $(( KIB1 / 1024 )) -> $(( KIB2 / 1024 )) MiB"
info "done: PVC and Deployment '$NAME' running in namespace '$NAMESPACE'"
info "shell in with: oc exec -n $NAMESPACE deploy/$NAME -- sh"
