#!/usr/bin/env bash
#
# deploy-s3-workload.sh
#
# Deploys a continuous, verifiable S3 write workload against ODF/OCS object
# storage, backed by either NooBaa (MCG) or Ceph RGW. Provisioning goes
# through an ObjectBucketClaim (OBC) so the same script works against
# whichever backend's StorageClass you point it at -- no NooBaa/RGW-specific
# API calls are needed.
#
# Creates, in order:
#   1. The namespace (if missing).
#   2. An ObjectBucketClaim <name>-bucket, and waits for it to bind.
#   3. A ConfigMap <name>-script holding the in-pod writer tool.
#   4. A headless Service + StatefulSet <name> (pods <name>-0..N-1). A
#      StatefulSet gives each pod a stable identity, so its objects live
#      under a stable prefix and survive pod restarts.
# Then waits for the rollout, verifies objects are really landing in the
# bucket, and checks every object written so far.
#
# How it writes:
#   Each pod runs --workers parallel writers. Every --interval seconds a
#   writer generates --batch objects of random (incompressible) data,
#   --object-size each, and uploads them in ONE `aws s3 cp --recursive`
#   call (concurrent uploads; objects > 8 MiB go multipart). Keys are
#     workload/<pod>/w<writer>/s<slot>-<sha256>.bin
#   Each writer keeps a ring of --keep-count slots: writing slot k uploads a
#   new object and deletes that slot's previous one (one delete-objects call
#   per round), so stored data stays capped at
#     replicas x workers x keep-count x object-size
#   while the backend sees continuous PUT + DELETE traffic. (Deleted space
#   is reclaimed asynchronously -- RGW garbage collection / NooBaa -- so
#   raw usage can run above the cap for a while.)
#
#   Upload failures are retried by the AWS CLI (standard retry mode); after
#   --max-failures consecutive failed rounds the container exits, so a
#   broken endpoint/bucket shows up as CrashLoopBackOff instead of a pod
#   that looks healthy while writing nothing.
#
# Integrity checking (always on):
#   The sha256 of every object is part of its key, so any object can be
#   checked against its own name. Run with --verify-only after a
#   migration, failover, upgrade or recovery to download every object and
#   get a PASS/FAIL. Each pod also writes a workload/<pod>/first-write
#   marker once; --verify-only reports it, which shows whether the bucket's
#   history survived or the bucket was replaced by an empty one.
#
# Requires: oc or kubectl, logged in with rights to create namespaces,
# ObjectBucketClaims, ConfigMaps, Services and StatefulSets.
#
# Usage:
#   deploy-s3-workload.sh [options]
#
# Options:
#   -n, --namespace NAME       Namespace to deploy into (default: s3-workload)
#   -b, --backend BACKEND      noobaa | rgw (default: noobaa). Used only to
#                              auto-detect a StorageClass; overridden by
#                              --storage-class.
#       --storage-class NAME   Explicit StorageClass for the OBC
#       --name NAME            Name for the StatefulSet/OBC/ConfigMap
#                              (default: s3-write-workload)
#   -r, --replicas N           Writer pods (default: 1)
#   -w, --workers N            Parallel writers per pod (default: 1)
#   -s, --object-size SIZE     Size of each object; bytes or K/M/G suffix
#                              (default: 4M)
#   -B, --batch N              Objects uploaded per writer per round
#                              (default: 4; max 1000)
#   -i, --interval SECONDS     Sleep between rounds; 0 = back-to-back
#                              (default: 5)
#   -c, --keep-count N         Objects kept per writer (ring size)
#                              (default: 64; must be >= --batch)
#   -d, --duration SECONDS     Stop writing after this long and idle; 0 = run
#                              forever (default: 0)
#       --max-failures N       Consecutive failed rounds before the pod exits
#                              (default: 3)
#       --cpu-limit CPU        Container CPU limit (default: 1)
#       --memory-limit MEM     Container memory limit (default: 256Mi +
#                              192Mi per writer; each writer runs its own
#                              aws CLI with multipart buffers)
#       --image IMAGE          Container image with the aws CLI (default:
#                              public.ecr.aws/aws-cli/aws-cli:latest)
#       --verify-ssl           Enforce TLS verification against the S3
#                              endpoint (default: off, since internal ODF
#                              endpoints commonly use a cluster-internal CA)
#       --verify-only          Don't deploy; download and check every
#                              object of an existing workload (same
#                              -n/--name) and report PASS/FAIL
#       --dry-run              Print manifests without applying them
#   -t, --timeout SECONDS      Timeout for the OBC to bind and for the
#                              rollout (default: 180)
#       --cleanup              Delete everything this script creates in
#                              NAMESPACE and exit (the bucket goes with the
#                              OBC; the namespace is left in place)
#   -h, --help                 Show this help
#
# Examples:
#   # defaults: NooBaa, 4 x 4 MiB objects every 5s (~192 MiB/min), 256 MiB kept
#   deploy-s3-workload.sh
#
#   # RGW, heavier: 2 pods x 4 writers x 8 x 16 MiB (multipart) back-to-back
#   deploy-s3-workload.sh --backend rgw -r 2 -w 4 -B 8 -s 16M -i 0 -c 32
#
#   # check every object after a migration / failover / upgrade
#   deploy-s3-workload.sh --backend rgw --verify-only
#
#   # tear down
#   deploy-s3-workload.sh --namespace s3-workload --cleanup
#
set -euo pipefail

NAMESPACE="s3-workload"
BACKEND="noobaa"
STORAGE_CLASS=""
APP_NAME="s3-write-workload"
REPLICAS=1
WORKERS=1
OBJECT_SIZE_IN="4M"
BATCH=4
INTERVAL=5
KEEP_COUNT=64
DURATION=0
MAX_FAILURES=3
CPU_LIMIT="1"
MEMORY_LIMIT=""
IMAGE="public.ecr.aws/aws-cli/aws-cli:latest"
VERIFY_SSL="false"
VERIFY_ONLY=0
DRY_RUN=0
TIMEOUT=180
CLEANUP=0

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*" >&2; }
err()  { log "ERROR $*" >&2; }
die()  { err "$*"; exit 1; }

# print the leading comment block (minus the shebang) as help text
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# parse_size <N|NK|NM|NG|NKi|NMi|NGi>: echoes bytes (K/M/G are 1024-based), else empty
parse_size() {
    if [[ "$1" =~ ^([0-9]+)([KMG]i?)?$ ]]; then
        local n="${BASH_REMATCH[1]}"
        case "${BASH_REMATCH[2]}" in
            "") echo "$n" ;;
            K|Ki) echo $(( n * 1024 )) ;;
            M|Mi) echo $(( n * 1024 * 1024 )) ;;
            G|Gi) echo $(( n * 1024 * 1024 * 1024 )) ;;
        esac
    fi
}

# human <bytes>
human() {
    local b=$1
    if (( b >= 1073741824 )); then echo "$(( b / 1073741824 )) GiB"
    elif (( b >= 1048576 )); then echo "$(( b / 1048576 )) MiB"
    elif (( b >= 1024 )); then echo "$(( b / 1024 )) KiB"
    else echo "$b B"; fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace) NAMESPACE="$2"; shift 2 ;;
        -b|--backend) BACKEND="$2"; shift 2 ;;
        --storage-class) STORAGE_CLASS="$2"; shift 2 ;;
        --name) APP_NAME="$2"; shift 2 ;;
        -r|--replicas) REPLICAS="$2"; shift 2 ;;
        -w|--workers) WORKERS="$2"; shift 2 ;;
        -s|--object-size) OBJECT_SIZE_IN="$2"; shift 2 ;;
        -B|--batch) BATCH="$2"; shift 2 ;;
        -i|--interval) INTERVAL="$2"; shift 2 ;;
        -c|--keep-count) KEEP_COUNT="$2"; shift 2 ;;
        -d|--duration) DURATION="$2"; shift 2 ;;
        --max-failures) MAX_FAILURES="$2"; shift 2 ;;
        --cpu-limit) CPU_LIMIT="$2"; shift 2 ;;
        --memory-limit) MEMORY_LIMIT="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        --verify-ssl) VERIFY_SSL="true"; shift ;;
        --verify-only) VERIFY_ONLY=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -t|--timeout) TIMEOUT="$2"; shift 2 ;;
        --cleanup) CLEANUP=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1 (see --help)" ;;
        *) die "unexpected argument: $1 (see --help)" ;;
    esac
done

# ---- validate settings ------------------------------------------------------

[[ "$BACKEND" == noobaa || "$BACKEND" == rgw ]] || die "--backend must be 'noobaa' or 'rgw' (got: $BACKEND)"
OBJECT_SIZE=$(parse_size "$OBJECT_SIZE_IN")
[[ -n "$OBJECT_SIZE" && "$OBJECT_SIZE" -ge 1 ]] || die "--object-size must be bytes or N[K|M|G] (got: $OBJECT_SIZE_IN)"
is_uint "$REPLICAS" && [[ "$REPLICAS" -ge 1 ]] || die "--replicas must be an integer >= 1 (got: $REPLICAS)"
is_uint "$WORKERS" && [[ "$WORKERS" -ge 1 ]] || die "--workers must be an integer >= 1 (got: $WORKERS)"
is_uint "$BATCH" && [[ "$BATCH" -ge 1 && "$BATCH" -le 1000 ]] || die "--batch must be an integer 1..1000 (got: $BATCH)"
is_uint "$KEEP_COUNT" && [[ "$KEEP_COUNT" -ge "$BATCH" ]] || die "--keep-count must be an integer >= --batch ($BATCH) (got: $KEEP_COUNT)"
is_uint "$INTERVAL" || die "--interval must be a non-negative integer (got: $INTERVAL)"
is_uint "$DURATION" || die "--duration must be a non-negative integer (got: $DURATION)"
is_uint "$MAX_FAILURES" && [[ "$MAX_FAILURES" -ge 1 ]] || die "--max-failures must be an integer >= 1 (got: $MAX_FAILURES)"
is_uint "$TIMEOUT" || die "--timeout must be a non-negative integer (got: $TIMEOUT)"
(( VERIFY_ONLY + DRY_RUN + CLEANUP <= 1 )) || die "--verify-only, --dry-run and --cleanup are mutually exclusive"

[[ -n "$MEMORY_LIMIT" ]] || MEMORY_LIMIT="$(( 256 + 192 * WORKERS ))Mi"
ROUND_BYTES=$(( WORKERS * BATCH * OBJECT_SIZE ))
STORED_BYTES=$(( REPLICAS * WORKERS * KEEP_COUNT * OBJECT_SIZE ))

if command -v oc >/dev/null 2>&1; then KCTL="oc"
elif command -v kubectl >/dev/null 2>&1; then KCTL="kubectl"
else die "neither 'oc' nor 'kubectl' found in PATH"; fi

OBC_NAME="${APP_NAME}-bucket"
SCRIPT_CM_NAME="${APP_NAME}-script"

# ---- pod-side writer tool ---------------------------------------------------
#
# Mounted from the ConfigMap at /scripts/run.sh and run as
# `sh /scripts/run.sh <cmd>`: "run" is the container's main process;
# "stats", "check", "probe" and "verify" are used via exec. Bucket name,
# endpoint and credentials come from the OBC's ConfigMap/Secret (envFrom);
# workload settings from the container env.
read -r -d '' POD_SCRIPT <<'POD_SCRIPT_EOF' || true
#!/bin/sh
# s3 workload writer tool: run | stats | check <key> | probe | verify
: "${BUCKET_NAME:?BUCKET_NAME not set (OBC ConfigMap not mounted?)}"
: "${BUCKET_HOST:?BUCKET_HOST not set (OBC ConfigMap not mounted?)}"
BUCKET_PORT=${BUCKET_PORT:-443}
OBJECT_SIZE=${OBJECT_SIZE:-4194304}
BATCH=${BATCH:-4}
WORKERS=${WORKERS:-1}
KEEP_COUNT=${KEEP_COUNT:-64}
INTERVAL=${INTERVAL:-5}
DURATION=${DURATION:-0}
MAX_FAILURES=${MAX_FAILURES:-3}
POD=${HOSTNAME:-$(hostname)}
B=$BUCKET_NAME
ROOT=workload
if [ "$BUCKET_PORT" = 443 ]; then PROTO=https; else PROTO=http; fi
ENDPOINT=${S3_ENDPOINT:-$PROTO://$BUCKET_HOST:$BUCKET_PORT}
SSL=--no-verify-ssl
[ "${VERIFY_SSL:-false}" = true ] && SSL=
export AWS_EC2_METADATA_DISABLED=true AWS_RETRY_MODE=standard PYTHONWARNINGS=ignore
export AWS_MAX_ATTEMPTS=${AWS_MAX_ATTEMPTS:-5}
# newer AWS CLIs add/validate CRC checksums on every request by default, which
# S3-compatible stores (older RGW/NooBaa) may not support; only checksum when the
# server requires it -- object integrity is checked by our own sha256 instead
export AWS_REQUEST_CHECKSUM_CALCULATION=${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}
export AWS_RESPONSE_CHECKSUM_VALIDATION=${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}
TAB=$(printf '\t')

log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }
s3() { aws --endpoint-url "$ENDPOINT" $SSL "$@"; }
# errtail <file> [n]: last n non-blank lines of an error file, on one line
errtail() { grep -v '^[[:space:]]*$' "$1" 2> /dev/null | tail -n "${2:-3}" | tr '\n' ' '; }

# list_prefix <prefix> <out>: "key<TAB>size<TAB>lastmodified" per object
list_prefix() {
  s3 s3api list-objects-v2 --bucket "$B" --prefix "$1" \
    --query 'Contents[].[Key,Size,LastModified]' --output text > "$2.raw" 2> "$2.err" || return 1
  awk -F'\t' 'NF == 3' "$2.raw" > "$2"
}

# delete_keys <keyfile> <tag>: delete listed keys, 1000 per delete-objects call
delete_keys() {
  [ -s "$1" ] || return 0
  rm -f /tmp/delj."$2".*
  awk -v pre="/tmp/delj.$2." '
    { if (n % 1000 == 0) { if (n) { print "]}" > f; close(f) }
        f = pre int(n / 1000); printf "{\"Quiet\":true,\"Objects\":[" > f; sep = "" }
      printf "%s{\"Key\":\"%s\"}", sep, $0 > f; sep = ","; n++ }
    END { if (n) { print "]}" > f; close(f) } }' "$1"
  drc=0
  for jf in /tmp/delj."$2".*; do
    [ -f "$jf" ] || continue
    if ! s3 s3api delete-objects --bucket "$B" --delete "file://$jf" > /dev/null 2> "/tmp/delerr.$2"; then
      drc=1; log "w$2: WARN delete-objects failed: $(errtail "/tmp/delerr.$2" 2)"
    fi
    rm -f "$jf"
  done
  return $drc
}

# rebuild <j>: rebuild writer j's slot map from the bucket; delete duplicates
# (left by a failed/interrupted round) and slots beyond --keep-count
rebuild() {
  P="$ROOT/$POD/w$1"
  list_prefix "$P/s" "/tmp/ls.$1" || return 1
  awk -F'\t' '{ k = $1; sub(/.*\/s/, "", k); sub(/-.*/, "", k); if (k ~ /^[0-9]+$/) print k "\t" $3 "\t" $1 }' "/tmp/ls.$1" \
    | sort -t "$TAB" -k1,1n -k2,2 > "/tmp/sorted.$1"
  : > "/tmp/map.$1"; : > "/tmp/dup.$1"
  awk -F'\t' -v keep="$KEEP_COUNT" -v map="/tmp/map.$1" -v dup="/tmp/dup.$1" '
    $1 + 0 >= keep + 0 { print $3 > dup; next }
    { if ($1 in m) print m[$1] > dup; m[$1] = $3 }
    END { for (s in m) print s, m[s] > map }' "/tmp/sorted.$1"
  delete_keys "/tmp/dup.$1" "$1" || true
}

worker() {
  j=$1; P="$ROOT/$POD/w$j"; D="/tmp/batch.$j"; ST="/tmp/stats.$j"
  rounds=0; bytes=0; fails=0; last=-; ctr=0; start=$(date +%s)
  echo "0 0 - 0" > "$ST"
  n=0
  until rebuild "$j"; do
    n=$(( n + 1 ))
    log "w$j: listing s3://$B/$P/ failed ($n/$MAX_FAILURES): $(errtail "/tmp/ls.$j.err")"
    [ "$n" -ge "$MAX_FAILURES" ] && { log "w$j: FATAL: cannot list bucket"; exit 1; }
    sleep 5
  done
  log "w$j: ring s3://$B/$P/ has $(wc -l < "/tmp/map.$j") existing objects"
  while :; do
    if [ "$DURATION" != 0 ] && [ $(( $(date +%s) - start )) -ge "$DURATION" ]; then
      log "w$j: duration ${DURATION}s reached after $rounds rounds"; exit 0
    fi
    rm -rf "$D"; mkdir -p "$D"; : > "/tmp/new.$j"; : > "/tmp/old.$j"
    b=0
    while [ "$b" -lt "$BATCH" ]; do
      k=$(( ctr % KEEP_COUNT )); ctr=$(( ctr + 1 ))
      head -c "$OBJECT_SIZE" /dev/urandom > "$D/.tmp" || { log "w$j: FATAL: cannot generate data in /tmp"; exit 1; }
      sum=$(sha256sum "$D/.tmp" | cut -d' ' -f1)
      mv "$D/.tmp" "$D/s$k-$sum.bin"
      echo "$k $P/s$k-$sum.bin" >> "/tmp/new.$j"
      awk -v k="$k" '$1 == k { print $2 }' "/tmp/map.$j" >> "/tmp/old.$j"
      b=$(( b + 1 ))
    done
    if s3 s3 cp "$D" "s3://$B/$P/" --recursive --only-show-errors > "/tmp/err.$j" 2>&1; then
      delete_keys "/tmp/old.$j" "$j" || true
      awk 'NR == FNR { n[$1] = $2; next } !($1 in n) { print } END { for (k in n) print k, n[k] }' \
        "/tmp/new.$j" "/tmp/map.$j" > "/tmp/map.$j.new" && mv "/tmp/map.$j.new" "/tmp/map.$j"
      rounds=$(( rounds + 1 )); bytes=$(( bytes + BATCH * OBJECT_SIZE )); fails=0
      last=$(tail -n 1 "/tmp/new.$j" | cut -d' ' -f2)
      echo "$rounds $bytes $last $fails" > "$ST"
      log "w$j: round $rounds: uploaded $BATCH x $OBJECT_SIZE bytes (total $(( bytes / 1048576 )) MiB)"
    else
      fails=$(( fails + 1 ))
      echo "$rounds $bytes $last $fails" > "$ST"
      log "w$j: WRITE FAILED ($fails/$MAX_FAILURES consecutive) uploading to s3://$B/$P/:"
      grep -v '^[[:space:]]*$' "/tmp/err.$j" | tail -n 20 | sed 's/^/    /'
      if [ "$fails" -ge "$MAX_FAILURES" ]; then
        log "w$j: FATAL: $MAX_FAILURES consecutive failed rounds"; exit 1
      fi
      rebuild "$j" || true
    fi
    rm -rf "$D"
    [ "$INTERVAL" -gt 0 ] && sleep "$INTERVAL"
  done
}

run() {
  log "start: pod=$POD bucket=$B endpoint=$ENDPOINT workers=$WORKERS batch=$BATCH object_size=$OBJECT_SIZE keep=$KEEP_COUNT interval=${INTERVAL}s duration=${DURATION}s"
  M="$ROOT/$POD/first-write"
  if s3 s3api head-object --bucket "$B" --key "$M" > /dev/null 2> /tmp/head.err; then
    log "history marker s3://$B/$M: first write $(s3 s3 cp "s3://$B/$M" - 2> /dev/null)"
  elif grep -q -e 404 -e 'Not Found' /tmp/head.err; then
    date -u '+%Y-%m-%dT%H:%M:%SZ' | s3 s3 cp - "s3://$B/$M" --only-show-errors \
      && log "history marker s3://$B/$M created" || log "WARN could not create history marker s3://$B/$M"
  else
    log "WARN cannot check history marker: $(errtail /tmp/head.err 2)"
  fi
  pids=""
  # sh is PID 1 in the container and would otherwise ignore SIGTERM: stop writers and exit promptly
  trap 'log "SIGTERM: stopping writers"; [ -n "$pids" ] && kill $pids 2> /dev/null; exit 0' TERM INT
  j=0
  while [ "$j" -lt "$WORKERS" ]; do worker "$j" & pids="$pids $!"; j=$(( j + 1 )); done
  while [ -n "$pids" ]; do
    sleep 2
    for p in $pids; do
      kill -0 "$p" 2> /dev/null && continue
      wait "$p"; rc=$?
      pids=$(for q in $pids; do [ "$q" = "$p" ] || printf '%s ' "$q"; done)
      if [ "$rc" -ne 0 ]; then
        log "FATAL: a writer failed (rc=$rc); exiting so the failure is visible as a pod restart"
        [ -n "$pids" ] && kill $pids 2> /dev/null
        exit 1
      fi
    done
  done
  log "all writers finished (--duration reached); idling so the pod doesn't restart and write again"
  while :; do sleep 3600 & wait $!; done
}

# stats: "<rounds> <bytes> <last key of writer 0> <max consecutive failures>" summed over writers
stats() {
  cat /tmp/stats.* 2> /dev/null | awk '
    { r += $1; b += $2; if ($4 > f) f = $4; if (NR == 1) l = $3 }
    END { if (NR == 0) print "x x - x"; else print r + 0, b + 0, l, f + 0 }'
}

probe() {
  echo "endpoint=$ENDPOINT bucket=$B tls_verify=${VERIFY_SSL:-false}"
  s3 s3api head-bucket --bucket "$B" 2>&1 && echo "head-bucket: OK"
}

# verify: download every workload object and check it against the sha256 in its key
verify() {
  ok=0; bad=0; miss=0; skip=0; hfail=0
  if ! list_prefix "$ROOT/" /tmp/vls; then
    echo "FAIL cannot list s3://$B/$ROOT/: $(errtail /tmp/vls.err)"
    echo "RESULT ok=0 mismatch=0 missing=1 skipped_in_flight=0 history_fail=0"; return 1
  fi
  legacy=$(awk -F'\t' '{ if (split($1, a, "/") < 3) c++ } END { print c + 0 }' /tmp/vls)
  [ "$legacy" -gt 0 ] && echo "INFO ignoring $legacy legacy object(s) directly under $ROOT/ (written by an older version of this script)"
  pods=$(awk -F'\t' '{ if (split($1, a, "/") >= 3) print a[2] }' /tmp/vls | sort -u)
  [ -n "$pods" ] || { echo "FAIL no workload objects found under s3://$B/$ROOT/"; miss=$(( miss + 1 )); }
  for p in $pods; do
    first=$(s3 s3 cp "s3://$B/$ROOT/$p/first-write" - 2> /dev/null)
    summary=$(awk -F'\t' -v pre="$ROOT/$p/w" 'index($1, pre) == 1 { c++; s += $2; if ($3 > m) m = $3 }
      END { printf "%d objects, %d MiB, newest %s", c, s / 1048576, (m == "" ? "-" : m) }' /tmp/vls)
    if [ -n "$first" ]; then echo "INFO $p: history since $first; $summary"
    else echo "FAIL $p: history marker $ROOT/$p/first-write missing (bucket emptied or recreated?); $summary"; hfail=$(( hfail + 1 )); fi
    for wp in $(awk -F'\t' -v pre="$ROOT/$p/w" 'index($1, pre) == 1 { k = $1; sub(/\/[^\/]*$/, "", k); print k }' /tmp/vls | sort -u); do
      rm -rf /tmp/v; mkdir -p /tmp/v
      # 404s here are expected for objects the writer replaced since the listing
      s3 s3 cp "s3://$B/$wp/" /tmp/v/ --recursive --only-show-errors > /tmp/v.err 2>&1
      awk -F'\t' -v pre="$wp/" 'index($1, pre) == 1 { print $1 }' /tmp/vls > /tmp/vkeys
      while read -r key; do
        name=${key##*/}
        case "$name" in s[0-9]*-*.bin) ;; *) continue ;; esac
        want=${name#*-}; want=${want%.bin}
        if [ ! -f "/tmp/v/$name" ]; then
          if s3 s3api head-object --bucket "$B" --key "$key" > /dev/null 2>&1; then
            echo "FAIL unreadable: s3://$B/$key (still listed, download failed: $(grep -F "$name" /tmp/v.err | tail -n 1))"; miss=$(( miss + 1 ))
          else skip=$(( skip + 1 )); fi
          continue
        fi
        got=$(sha256sum "/tmp/v/$name" | cut -d' ' -f1)
        if [ "$got" = "$want" ]; then ok=$(( ok + 1 ))
        else echo "FAIL checksum mismatch: s3://$B/$key got $got"; bad=$(( bad + 1 )); fi
      done < /tmp/vkeys
      rm -rf /tmp/v
    done
  done
  echo "RESULT ok=$ok mismatch=$bad missing=$miss skipped_in_flight=$skip history_fail=$hfail"
  [ $(( bad + miss + hfail )) -eq 0 ]
}

cmd=${1:-run}; [ $# -gt 0 ] && shift
case "$cmd" in
  run) run ;;
  stats) stats ;;
  check) s3 s3api head-object --bucket "$B" --key "$1" --query ContentLength --output text ;;
  probe) probe ;;
  verify) verify ;;
  *) echo "usage: run.sh run | stats | check <key> | probe | verify" >&2; exit 2 ;;
esac
POD_SCRIPT_EOF

SCRIPT_SUM=$(printf '%s' "$POD_SCRIPT" | sha256sum | cut -c1-16)

# ---- helpers ------------------------------------------------------------------

apply() {
    # apply <manifest-on-stdin>
    local manifest
    manifest=$(cat)
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '%s\n---\n' "$manifest"
        printf '%s\n' "$manifest" | "$KCTL" apply --dry-run=client -f - >/dev/null
    else
        printf '%s\n' "$manifest" | "$KCTL" apply -f -
    fi
}

# tool_exec <pod> <run.sh args...>
tool_exec() {
    local pod=$1; shift
    "$KCTL" exec -n "$NAMESPACE" "$pod" -c workload -- sh /scripts/run.sh "$@"
}

# running, non-terminating workload pods
list_pods() {
    "$KCTL" get pods -n "$NAMESPACE" -l "app=$APP_NAME" --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null \
        | awk 'NF == 1 { print $1 }' | sort -V
}

# dump everything useful for diagnosing a failed deploy/write, then exit 1
# (never prints the OBC Secret -- only its ConfigMap: bucket name/host/port)
fail_with_diagnostics() {
    local msg="$1"; shift
    local pods=("$@") p
    if [[ ${#pods[@]} -eq 0 ]]; then
        mapfile -t pods < <("$KCTL" get pods -n "$NAMESPACE" -l "app=$APP_NAME" -o name 2>/dev/null | sed 's#^pod/##')
    fi
    err "$msg"
    err "--- obc ---"
    "$KCTL" get obc -n "$NAMESPACE" "$OBC_NAME" -o wide >&2 || true
    "$KCTL" describe obc -n "$NAMESPACE" "$OBC_NAME" 2>/dev/null | sed -n '/^Events:/,$p' >&2 || true
    err "--- obc configmap (bucket/endpoint) ---"
    "$KCTL" get configmap -n "$NAMESPACE" "$OBC_NAME" \
        -o jsonpath='{"BUCKET_NAME="}{.data.BUCKET_NAME}{" BUCKET_HOST="}{.data.BUCKET_HOST}{" BUCKET_PORT="}{.data.BUCKET_PORT}{"\n"}' >&2 2>/dev/null \
        || err "(missing -- OBC not bound?)"
    "$KCTL" get secret -n "$NAMESPACE" "$OBC_NAME" >/dev/null 2>&1 || err "obc secret $OBC_NAME missing"
    err "--- statefulset / pods ---"
    "$KCTL" get statefulset -n "$NAMESPACE" "$APP_NAME" -o wide >&2 || true
    "$KCTL" get pods -n "$NAMESPACE" -l "app=$APP_NAME" -o wide >&2 || true
    for p in "${pods[@]}"; do
        err "=== ${p} ==="
        err "--- pod events ---"
        "$KCTL" describe pod -n "$NAMESPACE" "$p" 2>/dev/null | sed -n '/^Events:/,$p' >&2 || true
        err "--- logs (current, then previous) ---"
        "$KCTL" logs -n "$NAMESPACE" "$p" -c workload --tail=25 >&2 2>/dev/null || true
        "$KCTL" logs -n "$NAMESPACE" "$p" -c workload --previous --tail=25 >&2 2>/dev/null || true
        err "--- endpoint probe from pod ---"
        tool_exec "$p" probe >&2 2>&1 || true
    done
    exit 1
}

# run_pod_verify <pod>: relay run.sh verify output
run_pod_verify() {
    local pod=$1 out rc=0 line
    out=$(tool_exec "$pod" verify 2>&1) || rc=$?
    while IFS= read -r line; do
        case "$line" in
            FAIL\ *) err "${line#FAIL }" ;;
            INFO\ *) info "${line#INFO }" ;;
            "") ;;
            *) info "$line" ;;
        esac
    done <<<"$out"
    return "$rc"
}

# ---- cleanup ------------------------------------------------------------------

if [[ "$CLEANUP" -eq 1 ]]; then
    info "deleting $APP_NAME resources in namespace $NAMESPACE"
    "$KCTL" -n "$NAMESPACE" delete statefulset "$APP_NAME" --ignore-not-found
    "$KCTL" -n "$NAMESPACE" delete deployment "$APP_NAME" --ignore-not-found   # older versions of this script
    "$KCTL" -n "$NAMESPACE" delete service "$APP_NAME" --ignore-not-found
    "$KCTL" -n "$NAMESPACE" delete configmap "$SCRIPT_CM_NAME" --ignore-not-found
    "$KCTL" -n "$NAMESPACE" delete objectbucketclaim "$OBC_NAME" --ignore-not-found
    info "done; namespace $NAMESPACE left in place (delete it manually if no longer needed)"
    exit 0
fi

# ---- verify-only ----------------------------------------------------------------

if [[ "$VERIFY_ONLY" -eq 1 ]]; then
    "$KCTL" get statefulset -n "$NAMESPACE" "$APP_NAME" >/dev/null 2>&1 \
        || die "statefulset/$APP_NAME not found in namespace $NAMESPACE (pass the same -n/--name used to deploy)"
    mapfile -t PODS < <(list_pods)
    [[ ${#PODS[@]} -gt 0 ]] \
        || fail_with_diagnostics "no running pods for statefulset/$APP_NAME (scale it up: $KCTL scale -n $NAMESPACE statefulset/$APP_NAME --replicas=1)"
    info "verifying every object in the bucket from ${PODS[0]} (downloads all workload data)"
    if run_pod_verify "${PODS[0]}"; then
        info "VERIFY PASS: $APP_NAME in $NAMESPACE"
        exit 0
    fi
    err "VERIFY FAIL: $APP_NAME in $NAMESPACE (see errors above)"
    exit 1
fi

# ---- deploy ---------------------------------------------------------------------

info "write load: $REPLICAS pod(s) x $WORKERS writer(s) x $BATCH x $(human "$OBJECT_SIZE") objects per round = $(human $(( REPLICAS * ROUND_BYTES ))) per round"
if [[ "$INTERVAL" -gt 0 ]]; then
    info "  every ${INTERVAL}s: up to ~$(human $(( REPLICAS * ROUND_BYTES * 60 / INTERVAL )))/min (less if uploads take longer than the interval)"
else
    info "  back-to-back (--interval 0): limited only by upload speed and --cpu-limit $CPU_LIMIT"
fi
info "  stored data capped at $(human "$STORED_BYTES") ($REPLICAS x $WORKERS x $KEEP_COUNT x $(human "$OBJECT_SIZE"))"
(( OBJECT_SIZE > 8 * 1024 * 1024 )) && info "  objects > 8 MiB are uploaded as multipart"

if [[ "$DRY_RUN" -eq 0 ]]; then
    if "$KCTL" get namespace "$NAMESPACE" >/dev/null 2>&1; then
        info "namespace $NAMESPACE already exists"
    else
        info "creating namespace $NAMESPACE"
        "$KCTL" create namespace "$NAMESPACE" >/dev/null
    fi
fi

if [[ -z "$STORAGE_CLASS" ]]; then
    info "auto-detecting StorageClass for backend '$BACKEND'"
    case "$BACKEND" in
        noobaa) pattern='noobaa' ;;
        rgw) pattern='rgw' ;;
    esac
    STORAGE_CLASS=$("$KCTL" get storageclass -o name 2>/dev/null \
        | sed 's|storageclass.storage.k8s.io/||' | grep -i "$pattern" | head -n1 || true)
    if [[ -z "$STORAGE_CLASS" ]]; then
        [[ "$DRY_RUN" -eq 1 ]] || die "could not auto-detect a StorageClass for backend '$BACKEND'; list them with '$KCTL get storageclass' and re-run with --storage-class <name>"
        STORAGE_CLASS="<auto-detected-${BACKEND}-storageclass>"
        warn "can't look up StorageClasses; using placeholder $STORAGE_CLASS in the dry-run output"
    fi
fi
info "using StorageClass $STORAGE_CLASS"

info "applying ObjectBucketClaim $OBC_NAME"
cat <<EOF | apply
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: ${OBC_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
spec:
  generateBucketName: ${APP_NAME}
  storageClassName: ${STORAGE_CLASS}
EOF

if [[ "$DRY_RUN" -eq 0 ]]; then
    info "waiting up to ${TIMEOUT}s for OBC $OBC_NAME to bind"
    PHASE=""
    for (( waited = 0; ; waited += 2 )); do
        PHASE=$("$KCTL" -n "$NAMESPACE" get obc "$OBC_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)
        [[ "$PHASE" == Bound ]] && break
        (( waited >= TIMEOUT )) && fail_with_diagnostics "OBC $OBC_NAME did not bind within ${TIMEOUT}s (last phase: '${PHASE:-none}')"
        sleep 2
    done
    info "OBC bound: bucket $("$KCTL" -n "$NAMESPACE" get configmap "$OBC_NAME" -o jsonpath='{.data.BUCKET_NAME}' 2>/dev/null) at $("$KCTL" -n "$NAMESPACE" get configmap "$OBC_NAME" -o jsonpath='{.data.BUCKET_HOST}:{.data.BUCKET_PORT}' 2>/dev/null)"

    # older versions of this script used a Deployment with the same name
    if "$KCTL" -n "$NAMESPACE" get deployment "$APP_NAME" >/dev/null 2>&1; then
        info "removing deployment/$APP_NAME from an older version of this script (replaced by a StatefulSet)"
        "$KCTL" -n "$NAMESPACE" delete deployment "$APP_NAME" --wait=true >/dev/null
    fi
fi

info "applying writer script ConfigMap $SCRIPT_CM_NAME"
cat <<EOF | apply
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${SCRIPT_CM_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
data:
  run.sh: |
$(printf '%s\n' "$POD_SCRIPT" | sed 's/^/    /')
EOF

info "applying headless Service + StatefulSet $APP_NAME ($REPLICAS replica(s))"
cat <<EOF | apply
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
spec:
  clusterIP: None
  selector:
    app: ${APP_NAME}
EOF

cat <<EOF | apply
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
spec:
  serviceName: ${APP_NAME}
  replicas: ${REPLICAS}
  podManagementPolicy: Parallel
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
      annotations:
        s3-workload/script-sha256: "${SCRIPT_SUM}"
    spec:
      containers:
        - name: workload
          image: ${IMAGE}
          command: ["sh", "/scripts/run.sh", "run"]
          envFrom:
            - secretRef:
                name: ${OBC_NAME}
            - configMapRef:
                name: ${OBC_NAME}
          env:
            - { name: OBJECT_SIZE, value: "${OBJECT_SIZE}" }
            - { name: BATCH, value: "${BATCH}" }
            - { name: WORKERS, value: "${WORKERS}" }
            - { name: KEEP_COUNT, value: "${KEEP_COUNT}" }
            - { name: INTERVAL, value: "${INTERVAL}" }
            - { name: DURATION, value: "${DURATION}" }
            - { name: MAX_FAILURES, value: "${MAX_FAILURES}" }
            - { name: VERIFY_SSL, value: "${VERIFY_SSL}" }
          volumeMounts:
            - name: script
              mountPath: /scripts
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: "${CPU_LIMIT}"
              memory: ${MEMORY_LIMIT}
      volumes:
        - name: script
          configMap:
            name: ${SCRIPT_CM_NAME}
EOF

if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would wait for the OBC to bind, the StatefulSet rollout, and verify writes"
    exit 0
fi

info "waiting up to ${TIMEOUT}s for statefulset/$APP_NAME rollout"
"$KCTL" rollout status "statefulset/${APP_NAME}" -n "$NAMESPACE" --timeout="${TIMEOUT}s" \
    || fail_with_diagnostics "statefulset/$APP_NAME rollout did not complete within ${TIMEOUT}s"

# ---- verify objects are really landing in the bucket ----------------------------

PODS=()
for (( n = 0; n < REPLICAS; n++ )); do PODS+=("${APP_NAME}-${n}"); done

WINDOW=$(( INTERVAL * 2 + 10 )); (( WINDOW < 20 )) && WINDOW=20
declare -A R1=() B1=()
info "verifying uploads on ${#PODS[@]} pod(s) (sampling twice, ${WINDOW}s apart)"
for p in "${PODS[@]}"; do
    read -r r b _ _ <<<"$(tool_exec "$p" stats 2>/dev/null || echo "x x - x")"
    R1[$p]=$r; B1[$p]=$b
done
sleep "$WINDOW"
BAD_PODS=()
for p in "${PODS[@]}"; do
    read -r r2 b2 lastkey f2 <<<"$(tool_exec "$p" stats 2>/dev/null || echo "x x - x")"
    r1=${R1[$p]}; b1=${B1[$p]}
    if ! is_uint "$r1" || ! is_uint "$r2"; then
        err "$p: could not read writer stats from the pod"; BAD_PODS+=("$p"); continue
    fi
    if [[ "$r2" -le "$r1" ]]; then
        err "$p: no rounds completed in ${WINDOW}s ($r1 -> $r2, consecutive failures: $f2); uploads are failing or stalled"
        BAD_PODS+=("$p"); continue
    fi
    size=$(tool_exec "$p" check "$lastkey" 2>/dev/null || true)
    if [[ "$size" != "$OBJECT_SIZE" ]]; then
        err "$p: last uploaded object $lastkey not readable back from the bucket (size '${size:-none}', expected $OBJECT_SIZE)"
        BAD_PODS+=("$p"); continue
    fi
    info "$p: rounds $r1 -> $r2, uploaded $(human "${b1:-0}") -> $(human "$b2"); $lastkey confirmed in bucket ($size bytes)"
done
[[ ${#BAD_PODS[@]} -eq 0 ]] \
    || fail_with_diagnostics "upload verification failed on ${#BAD_PODS[@]}/${#PODS[@]} pod(s): ${BAD_PODS[*]}" "${BAD_PODS[@]}"

info "checking every object written so far (sha256 in each key)"
run_pod_verify "${PODS[0]}" \
    || fail_with_diagnostics "object verification failed (see errors above)" "${PODS[0]}"

info "done: $APP_NAME writing to bucket via OBC $OBC_NAME ($BACKEND, StorageClass $STORAGE_CLASS)"
info "re-check every object later with: $0 -n $NAMESPACE --name $APP_NAME --verify-only"
info "tail logs with: $KCTL -n $NAMESPACE logs -f ${APP_NAME}-0"
info "tear down with: $0 -n $NAMESPACE --name $APP_NAME --cleanup"
exit 0
