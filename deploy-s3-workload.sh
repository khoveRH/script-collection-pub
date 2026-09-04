#!/usr/bin/env bash
#
# deploy-s3-workload.sh
#
# Deploys a continuous S3 write workload against ODF/OCS, backed by either
# NooBaa (MCG) or Ceph RGW. Provisioning goes through an ObjectBucketClaim
# (OBC) so the same script works against whichever backend's StorageClass
# you point it at -- no NooBaa/RGW-specific API calls are needed.
#
# Requires: oc or kubectl, logged in with rights to create namespaces,
# ObjectBucketClaims, ConfigMaps and Deployments.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
NAMESPACE="s3-workload"
BACKEND="noobaa"
STORAGE_CLASS=""
OBJECT_SIZE=1048576      # 1 MiB
INTERVAL=5               # seconds between writes
KEEP_COUNT=100           # objects to retain before pruning oldest
DURATION=0               # 0 = run forever
IMAGE="public.ecr.aws/aws-cli/aws-cli:latest"
VERIFY_SSL="false"
APP_NAME="s3-write-workload"
CLEANUP="false"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Deploys a workload that continuously writes (and periodically prunes)
objects in an S3 bucket backed by ODF NooBaa or Ceph RGW. Bucket
provisioning is done via an ObjectBucketClaim (OBC), so it is agnostic
to which backend actually services the StorageClass.

Options:
  -n, --namespace NAME       Namespace to deploy into (default: ${NAMESPACE})
  -b, --backend BACKEND      noobaa | rgw  (default: ${BACKEND})
                              Used only to auto-detect a StorageClass;
                              overridden by --storage-class if given.
      --storage-class NAME   Explicit StorageClass name to use for the OBC
                              (skips auto-detection).
  -s, --object-size BYTES    Size of each written object (default: ${OBJECT_SIZE})
  -i, --interval SECONDS     Sleep between writes (default: ${INTERVAL})
  -c, --keep-count N         Objects to retain before pruning oldest (default: ${KEEP_COUNT})
  -d, --duration SECONDS     Total run duration; 0 = run forever (default: ${DURATION})
      --image IMAGE          Container image with the aws CLI
                              (default: ${IMAGE})
      --verify-ssl           Enforce TLS verification against the S3 endpoint
                              (default: off, since internal ODF endpoints
                              commonly use a cluster-internal CA)
      --cleanup               Delete everything this script creates in
                              NAMESPACE and exit (does not delete the
                              namespace itself)
  -h, --help                  Show this help

Examples:
  # Write 1MiB objects every 5s against NooBaa
  $(basename "$0") --backend noobaa

  # Write 4MiB objects every 2s against Ceph RGW, keep 500 objects
  $(basename "$0") --backend rgw --object-size 4194304 --interval 2 --keep-count 500

  # Tear down
  $(basename "$0") --namespace s3-workload --cleanup
EOF
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -b|--backend) BACKEND="$2"; shift 2 ;;
    --storage-class) STORAGE_CLASS="$2"; shift 2 ;;
    -s|--object-size) OBJECT_SIZE="$2"; shift 2 ;;
    -i|--interval) INTERVAL="$2"; shift 2 ;;
    -c|--keep-count) KEEP_COUNT="$2"; shift 2 ;;
    -d|--duration) DURATION="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --verify-ssl) VERIFY_SSL="true"; shift ;;
    --cleanup) CLEANUP="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "${BACKEND}" != "noobaa" && "${BACKEND}" != "rgw" ]]; then
  echo "ERROR: --backend must be 'noobaa' or 'rgw'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# CLI detection
# ---------------------------------------------------------------------------
if command -v oc >/dev/null 2>&1; then
  KCTL="oc"
elif command -v kubectl >/dev/null 2>&1; then
  KCTL="kubectl"
else
  echo "ERROR: neither 'oc' nor 'kubectl' found in PATH" >&2
  exit 1
fi

OBC_NAME="${APP_NAME}-bucket"
SCRIPT_CM_NAME="${APP_NAME}-script"

# ---------------------------------------------------------------------------
# Cleanup path
# ---------------------------------------------------------------------------
if [[ "${CLEANUP}" == "true" ]]; then
  echo ">> Deleting resources in namespace '${NAMESPACE}'"
  "${KCTL}" -n "${NAMESPACE}" delete deployment "${APP_NAME}" --ignore-not-found
  "${KCTL}" -n "${NAMESPACE}" delete configmap "${SCRIPT_CM_NAME}" --ignore-not-found
  "${KCTL}" -n "${NAMESPACE}" delete objectbucketclaim "${OBC_NAME}" --ignore-not-found
  echo ">> Done. Namespace '${NAMESPACE}' left in place; delete it manually if no longer needed."
  exit 0
fi

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------
echo ">> Ensuring namespace '${NAMESPACE}' exists"
"${KCTL}" get namespace "${NAMESPACE}" >/dev/null 2>&1 || \
  "${KCTL}" create namespace "${NAMESPACE}"

# ---------------------------------------------------------------------------
# StorageClass auto-detection
# ---------------------------------------------------------------------------
if [[ -z "${STORAGE_CLASS}" ]]; then
  echo ">> Auto-detecting StorageClass for backend '${BACKEND}'"
  case "${BACKEND}" in
    noobaa)
      STORAGE_CLASS=$("${KCTL}" get storageclass -o name 2>/dev/null \
        | sed 's|storageclass.storage.k8s.io/||' \
        | grep -i 'noobaa' | head -n1 || true)
      ;;
    rgw)
      STORAGE_CLASS=$("${KCTL}" get storageclass -o name 2>/dev/null \
        | sed 's|storageclass.storage.k8s.io/||' \
        | grep -i 'ceph-rgw\|rgw' | head -n1 || true)
      ;;
  esac

  if [[ -z "${STORAGE_CLASS}" ]]; then
    echo "ERROR: could not auto-detect a StorageClass for backend '${BACKEND}'." >&2
    echo "       List available classes with: ${KCTL} get storageclass" >&2
    echo "       Then re-run with --storage-class <name>" >&2
    exit 1
  fi
fi
echo "   Using StorageClass: ${STORAGE_CLASS}"

# ---------------------------------------------------------------------------
# ObjectBucketClaim
# ---------------------------------------------------------------------------
echo ">> Applying ObjectBucketClaim '${OBC_NAME}'"
cat <<EOF | "${KCTL}" apply -f -
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: ${OBC_NAME}
  namespace: ${NAMESPACE}
spec:
  generateBucketName: ${APP_NAME}
  storageClassName: ${STORAGE_CLASS}
EOF

echo ">> Waiting for OBC to bind..."
for i in $(seq 1 60); do
  PHASE=$("${KCTL}" -n "${NAMESPACE}" get obc "${OBC_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [[ "${PHASE}" == "Bound" ]]; then
    echo "   OBC bound."
    break
  fi
  sleep 2
  if [[ "$i" -eq 60 ]]; then
    echo "ERROR: OBC did not reach Bound state within 120s (last phase: '${PHASE}')" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Workload script (mounted via ConfigMap)
# ---------------------------------------------------------------------------
echo ">> Applying workload script ConfigMap '${SCRIPT_CM_NAME}'"

if [[ "${VERIFY_SSL}" == "true" ]]; then
  SSL_FLAG=""
else
  SSL_FLAG="--no-verify-ssl"
fi

cat <<EOF | "${KCTL}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${SCRIPT_CM_NAME}
  namespace: ${NAMESPACE}
data:
  run.sh: |
    #!/bin/sh
    set -eu

    : "\${OBJECT_SIZE:=1048576}"
    : "\${INTERVAL:=5}"
    : "\${KEEP_COUNT:=100}"
    : "\${DURATION:=0}"
    : "\${BUCKET_NAME:?BUCKET_NAME not set}"
    : "\${BUCKET_HOST:?BUCKET_HOST not set}"
    : "\${BUCKET_PORT:=443}"

    if [ "\${BUCKET_PORT}" = "443" ]; then
      PROTO="https"
    else
      PROTO="http"
    fi
    ENDPOINT="\${PROTO}://\${BUCKET_HOST}:\${BUCKET_PORT}"

    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY
    export AWS_EC2_METADATA_DISABLED=true

    echo "Writing to bucket=\${BUCKET_NAME} endpoint=\${ENDPOINT}"

    start_ts=\$(date +%s)
    i=0
    while true; do
      now=\$(date +%s)
      if [ "\${DURATION}" != "0" ] && [ \$((now - start_ts)) -ge "\${DURATION}" ]; then
        echo "Duration reached, exiting."
        break
      fi

      key="workload/obj-\$(date +%s)-\$\$-\${i}.bin"
      head -c "\${OBJECT_SIZE}" /dev/urandom > /tmp/obj.bin

      if aws --endpoint-url "\${ENDPOINT}" ${SSL_FLAG} s3 cp /tmp/obj.bin "s3://\${BUCKET_NAME}/\${key}" >/tmp/last.log 2>&1; then
        echo "\$(date -Is) wrote \${key} (\${OBJECT_SIZE} bytes)"
      else
        echo "\$(date -Is) WRITE FAILED for \${key}"
        cat /tmp/last.log
      fi

      i=\$((i+1))

      count=\$(aws --endpoint-url "\${ENDPOINT}" ${SSL_FLAG} s3 ls "s3://\${BUCKET_NAME}/workload/" | wc -l)
      if [ "\${count}" -gt "\${KEEP_COUNT}" ]; then
        oldest=\$(aws --endpoint-url "\${ENDPOINT}" ${SSL_FLAG} s3 ls "s3://\${BUCKET_NAME}/workload/" | sort | head -n 1 | awk '{print \$4}')
        if [ -n "\${oldest}" ]; then
          aws --endpoint-url "\${ENDPOINT}" ${SSL_FLAG} s3 rm "s3://\${BUCKET_NAME}/workload/\${oldest}"
          echo "\$(date -Is) removed oldest object \${oldest}"
        fi
      fi

      rm -f /tmp/obj.bin
      sleep "\${INTERVAL}"
    done
EOF

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------
echo ">> Applying Deployment '${APP_NAME}'"
cat <<EOF | "${KCTL}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
      restartPolicy: Always
      containers:
        - name: workload
          image: ${IMAGE}
          command: ["/bin/sh", "-c"]
          args:
            - "cp /scripts/run.sh /tmp/run.sh && chmod +x /tmp/run.sh && /tmp/run.sh"
          envFrom:
            - secretRef:
                name: ${OBC_NAME}
            - configMapRef:
                name: ${OBC_NAME}
          env:
            - name: OBJECT_SIZE
              value: "${OBJECT_SIZE}"
            - name: INTERVAL
              value: "${INTERVAL}"
            - name: KEEP_COUNT
              value: "${KEEP_COUNT}"
            - name: DURATION
              value: "${DURATION}"
          volumeMounts:
            - name: script
              mountPath: /scripts
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 250m
              memory: 256Mi
      volumes:
        - name: script
          configMap:
            name: ${SCRIPT_CM_NAME}
            defaultMode: 0755
EOF

echo
echo ">> Deployed. Bucket backend: ${BACKEND} (StorageClass: ${STORAGE_CLASS})"
echo ">> Tail logs with:"
echo "     ${KCTL} -n ${NAMESPACE} logs -f deploy/${APP_NAME}"
echo ">> Tear down with:"
echo "     $(basename "$0") --namespace ${NAMESPACE} --cleanup"
