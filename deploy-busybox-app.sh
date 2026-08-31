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
#      busybox in a loop that appends one timestamped line to
#      /data/heartbeat.log every few seconds -- enough to keep the volume
#      genuinely in use (non-empty, actively written) for exercising
#      recovery/migration scripts against, without growing unbounded.
# Then waits for the Deployment to become Available.
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
#       --dry-run             Print manifests without applying them
#   -t, --timeout SECONDS    Timeout waiting for the Deployment to become
#                             Available (default: 120)
#   -h, --help                Show this help
#
# Examples:
#   # defaults: namespace busybox-test (must already exist), 1Gi on
#   # ocs-storagecluster-cephfs
#   deploy-busybox-app.sh --create-namespace
#
#   # custom namespace/storage class/size -- namespace auto-created, no
#   # --create-namespace needed since -n overrides the default
#   deploy-busybox-app.sh -n storage-test -s gp3-csi --size 5Gi
#
set -euo pipefail

NAMESPACE="busybox-test"
NAMESPACE_EXPLICIT=0
CREATE_NAMESPACE=0
STORAGE_CLASS="ocs-storagecluster-cephfs"
SIZE="1Gi"
NAME="busybox-test"
DRY_RUN=0
TIMEOUT=120

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*" >&2; }
err()  { log "ERROR $*" >&2; }
die()  { err "$*"; exit 1; }

usage() { sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace) NAMESPACE="$2"; NAMESPACE_EXPLICIT=1; shift 2 ;;
        --create-namespace) CREATE_NAMESPACE=1; shift ;;
        -s|--storage-class) STORAGE_CLASS="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -t|--timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) die "unexpected argument: $1" ;;
    esac
done

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
          command: ["sh", "-c", "while true; do date >> /data/heartbeat.log; sleep 5; done"]
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: ${NAME}
EOF

if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would wait for deployment/$NAME to become Available"
    exit 0
fi

info "waiting up to ${TIMEOUT}s for deployment/$NAME to become Available"
if oc wait --for=condition=Available "deployment/${NAME}" -n "$NAMESPACE" --timeout="${TIMEOUT}s"; then
    info "deployment/$NAME is Available"
else
    err "deployment/$NAME did not become Available within ${TIMEOUT}s; check: oc get pods -n $NAMESPACE -l app=$NAME, oc describe pvc -n $NAMESPACE $NAME"
    exit 1
fi

info "done: PVC and Deployment '$NAME' running in namespace '$NAMESPACE'"
info "shell in with: oc exec -n $NAMESPACE deploy/$NAME -- sh"
