#!/usr/bin/env bash
#
# deploy-busybox-app.sh
#
# Deploys a busybox test application (Deployment + PVC, optionally creating
# its namespace) that keeps real, verifiable write I/O on a volume, for
# exercising storage-related scripts against -- e.g. the SELinux-context
# migration/revert, PVC-terminating recovery, Retain-policy audit, or
# CephFS/RBD IOPS-path diagnostic scripts in this same directory.
#
# Creates, in order:
#   1. The namespace, if it doesn't exist: auto-created when -n/--namespace
#      is used to pick a namespace other than the default, or when
#      --create-namespace is given. Left at the default (busybox-test)
#      without --create-namespace, it errors out instead of assuming it's
#      safe to create a namespace you didn't explicitly ask for.
#   2. A PVC with the requested StorageClass, size, access mode and volume
#      mode.
#   3. A Deployment whose pods run a busybox write loop against the PVC.
# Then waits for the rollout, verifies data is really being written, and
# prints the volume's history (and integrity results, if enabled).
#
# Access / volume modes:
#   RWO  Filesystem (default)  1 pod, PVC mounted at /data. Every
#        --interval seconds: appends "<timestamp> <pod>" to
#        /data/heartbeat.log and writes --write-mb MiB of random data
#        (fsync'd) to /data/blob-<n>.bin, a ring of files capped at
#        --max-mb.
#   RWX  Filesystem (CephFS)   -r pods (default 2, spread across nodes)
#        share one PVC. Each pod writes its own blob ring and appends to
#        the shared heartbeat.log; verification checks every pod can see
#        every other pod's writes. A replacement pod adopts a departed
#        pod's blob ring (after ~2 min idle) instead of piling up new ones.
#   RWO  Block (RBD)           1 pod, PVC attached as raw device /dev/xvda
#        (no filesystem). The first MiB holds a header record (pod,
#        write counter, timestamps) plus checksum entries; blobs are
#        written straight to the device after it.
#   RWOP (either volume mode)  like RWO, plus a negative test: a probe pod
#        mounting the same PVC must be refused by the scheduler.
#   RWX + Block (shared raw device) needs stable pod identities -- use
#   deploy-busybox-statefulset-app.sh for that.
#
# Any failed write makes the container exit, so a broken/unwritable volume
# shows up as CrashLoopBackOff instead of a silently "Running" pod.
#
# Integrity checking (--verify-integrity):
#   Each blob's sha256 is recorded on the volume itself (a manifest file
#   per blob ring, or checksum sectors in the block header). The entry is
#   dropped before a blob is rewritten and re-added after, so in-flight
#   writes are never mistaken for corruption. Run with --verify-only after a
#   migration/recovery to re-read every recorded blob (O_DIRECT, so it
#   comes from the backend rather than page cache where supported) and get
#   a PASS/FAIL. --verify-only also reports the heartbeat history (first
#   and last write), which shows whether the volume's data survived or was
#   replaced by a fresh, empty volume.
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
#   -s, --storage-class SC   StorageClass for the PVC (default:
#                             ocs-storagecluster-cephfs, or
#                             ocs-storagecluster-ceph-rbd with Block)
#       --size SIZE           PVC size (default: 1Gi)
#       --name NAME           Name for the PVC, Deployment, and its labels
#                             (default: busybox-test)
#       --access-mode MODE    RWO | RWX | RWOP (default: RWO)
#       --volume-mode MODE    Filesystem | Block (default: Filesystem)
#   -r, --replicas N          Pods (default: 1; 2 for RWX; must be 1 unless
#                             RWX)
#       --write-mb N          MiB of random data written per interval, per
#                             pod (default: 4; 0 = heartbeat/header only)
#       --max-mb N            Cap on blob data kept per pod, in MiB
#                             (default: 256; total must be <= 80% of --size)
#       --interval SECONDS    Seconds between write rounds (default: 5)
#       --verify-integrity    Record a sha256 for every blob written
#       --verify-only         Don't deploy; check an existing deployment
#                             (-n/--name) and report PASS/FAIL. Mode
#                             settings are read from the running pods.
#       --dry-run             Print manifests without applying them
#   -t, --timeout SECONDS    Timeout waiting for the rollout (default: 180)
#   -h, --help                Show this help
#
# Examples:
#   # defaults: busybox-test (must already exist), 1Gi CephFS RWO,
#   # 4 MiB every 5s, 256 MiB cap
#   deploy-busybox-app.sh --create-namespace
#
#   # integrity-tracked app, then re-check after a migration/recovery
#   deploy-busybox-app.sh --create-namespace --verify-integrity
#   deploy-busybox-app.sh --verify-only
#
#   # 3 pods sharing one CephFS RWX volume
#   deploy-busybox-app.sh -n rwx-test --access-mode RWX -r 3 --size 2Gi
#
#   # raw RBD block device, integrity-tracked
#   deploy-busybox-app.sh -n blk-test --volume-mode Block --verify-integrity
#
#   # RWOP: deploy and check a second pod is refused
#   deploy-busybox-app.sh -n rwop-test --access-mode RWOP
#
set -euo pipefail

NAMESPACE="busybox-test"
NAMESPACE_EXPLICIT=0
CREATE_NAMESPACE=0
STORAGE_CLASS=""
SIZE="1Gi"
NAME="busybox-test"
ACCESS_MODE_IN="RWO"
VOLUME_MODE_IN="Filesystem"
REPLICAS=""
WRITE_MB=4
MAX_MB=256
INTERVAL=5
INTEGRITY=0
VERIFY_ONLY=0
DRY_RUN=0
TIMEOUT=180

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
        --access-mode) ACCESS_MODE_IN="$2"; shift 2 ;;
        --volume-mode) VOLUME_MODE_IN="$2"; shift 2 ;;
        -r|--replicas) REPLICAS="$2"; shift 2 ;;
        --write-mb) WRITE_MB="$2"; shift 2 ;;
        --max-mb) MAX_MB="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --verify-integrity) INTEGRITY=1; shift ;;
        --verify-only) VERIFY_ONLY=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -t|--timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) die "unexpected argument: $1" ;;
    esac
done

# ---- pod-side tool ----------------------------------------------------------
#
# Runs inside the busybox container: "run" is the container's main loop;
# "stats", "info" and "verify" are invoked via oc exec. Its settings come
# from the container env (VOLUME_MODE WRITE_MB SLOTS INTERVAL INTEGRITY
# SHARED ADOPT REGION_MB REPLICAS), so --verify-only always checks a volume
# with the parameters it was actually written with.
#
# Block layout (MiB offsets on /dev/xvda): region r = [r*REGION_MB,
# (r+1)*REGION_MB). First MiB of a region is its header: 512-byte sector 0
# = "BBX1 <pod> <counter> <last epoch> <first epoch>", sector 1+k =
# checksum entry for blob slot k ("S <sha256> <counter>", or "-" while
# being rewritten). Blob slot k lives at MiB 1 + k*WRITE_MB of the region.
# Header/blob reads use bs=1M iflag=direct (busybox dd only page-aligns
# buffers >= 4 KiB, which O_DIRECT needs).
#
# This block is kept identical in deploy-busybox-statefulset-app.sh.
#@@POD_TOOL_BEGIN@@
read -r -d '' POD_TOOL <<'POD_TOOL_EOF' || true
H=${HOSTNAME:-$(hostname)}
D=/data
DEV=/dev/xvda
STATE=/tmp/pod-tool.state

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') $*"; }
die() { echo "FATAL: $*" >&2; [ -s /tmp/err ] && cat /tmp/err >&2; exit 1; }
isnum() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
my_index() { if [ "$SHARED" = 1 ]; then echo "${H##*-}"; else echo 0; fi; }

# ---- block helpers
hdr_load() { dd status=none if="$DEV" bs=1M skip="$(( $1 * REGION_MB ))" count=1 iflag=direct 2>/tmp/err > "/tmp/hdr.$1"; }
hdr_sec() { dd status=none if="/tmp/hdr.$1" bs=512 skip="$2" count=1 2>/dev/null | tr -d '\000'; }
hdr_parse() { set -- $1; MAGIC=${1:-}; HHOST=${2:-}; HN=${3:-}; HLAST=${4:-}; HFIRST=${5:-}; }
sec_write() { printf '%s' "$2" | dd status=none of="$DEV" bs=512 seek="$1" count=1 conv=notrunc,sync,fsync 2>/tmp/err; }
blk_sum() { dd status=none if="$DEV" bs=1M skip="$1" count="$WRITE_MB" iflag=direct,fullblock 2>/dev/null | sha256sum | cut -d' ' -f1; }
fmt_epoch() { date -d "@$1" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo "epoch $1"; }

# ---- filesystem helpers
# man_set <manifest> <file> [sha]: drop <file>'s entry, then add it back if sha given
man_set() {
  { [ -f "$1" ] && awk -v f="$2" '$2 != f' "$1"; [ -n "${3:-}" ] && echo "$3  $2"; } \
    | dd status=none of="$1.tmp" conv=fsync 2>/tmp/err && mv -f "$1.tmp" "$1"
}
man_has() { awk -v s="$2" -v f="$3" '$1 == s && $2 == f { x = 1 } END { exit !x }' "$1" 2>/dev/null; }
# claim_prefix: adopt the blob ring of a departed pod (owner file idle > 2 min), else start a new one
claim_prefix() {
  for o in $(find "$D/owners" -type f -mmin +2 2>/dev/null); do
    case "$o" in *.claim.*) continue ;; esac
    if mv "$o" "$o.claim.$H" 2>/dev/null; then
      mv "$o.claim.$H" "$o" && echo "${o##*/}" && return 0
    fi
  done
  echo "blob-$H"
}

run_fs() {
  : > /tmp/err
  [ -d "$D" ] || die "$D is not mounted"
  if [ "$SHARED" = 1 ] && [ "$ADOPT" = 1 ]; then
    mkdir -p "$D/owners" 2>/tmp/err || die "creating $D/owners"
    P=$(claim_prefix)
  elif [ "$SHARED" = 1 ]; then
    P="blob-$H"
  else
    P=blob
  fi
  echo "$P" > "$STATE"
  MAN="$D/$P.sha256"
  log "filesystem mode: pod=$H ring=$P write=${WRITE_MB}MiB slots=$SLOTS interval=${INTERVAL}s integrity=$INTEGRITY"
  i=0
  while :; do
    : > /tmp/err
    echo "$(date '+%Y-%m-%dT%H:%M:%S%z') $H" >> "$D/heartbeat.log" 2>/tmp/err || die "heartbeat write to $D failed"
    if [ "$ADOPT" = 1 ]; then echo "$H" > "$D/owners/$P" 2>/tmp/err || die "updating owner file $D/owners/$P"; fi
    if [ "$WRITE_MB" -gt 0 ]; then
      f="$D/$P-$(( i % SLOTS )).bin"
      if [ "$INTEGRITY" = 1 ]; then man_set "$MAN" "$f" || die "updating $MAN"; fi
      dd status=none if=/dev/urandom of="$f" bs=1M count="$WRITE_MB" iflag=fullblock conv=fsync 2>/tmp/err \
        || die "writing $WRITE_MB MiB to $f"
      if [ "$INTEGRITY" = 1 ]; then
        s=$(sha256sum "$f" | cut -d' ' -f1)
        man_set "$MAN" "$f" "$s" || die "updating $MAN"
      fi
      i=$(( i + 1 ))
    fi
    sleep "$INTERVAL"
  done
}

run_block() {
  : > /tmp/err
  [ -b "$DEV" ] || die "$DEV is not a block device: $(ls -l "$DEV" 2>&1)"
  [ -w "$DEV" ] || die "$DEV is not writable by $(id): $(ls -l "$DEV")"
  IDX=$(my_index); isnum "$IDX" || die "cannot derive region index from pod name $H"
  DEVMB=$(( $(blockdev --getsize64 "$DEV") / 1048576 ))
  BASE=$(( IDX * REGION_MB )); SEC0=$(( BASE * 2048 ))
  [ $(( BASE + REGION_MB )) -le "$DEVMB" ] || die "region $IDX (${BASE}+${REGION_MB} MiB) exceeds device size ${DEVMB} MiB"
  echo "$IDX" > "$STATE"
  hdr_load "$IDX" || die "reading header of region $IDX"
  hdr_parse "$(hdr_sec "$IDX" 0)"
  if [ "$MAGIC" = BBX1 ] && isnum "$HN" && isnum "$HFIRST"; then n=$HN; first=$HFIRST; else n=0; first=$(date +%s); fi
  log "block mode: pod=$H dev=$DEV (${DEVMB} MiB) region=$IDX at ${BASE} MiB size ${REGION_MB} MiB resume_counter=$n integrity=$INTEGRITY"
  while :; do
    : > /tmp/err
    n=$(( n + 1 ))
    if [ "$WRITE_MB" -gt 0 ]; then
      k=$(( n % SLOTS )); off=$(( BASE + 1 + k * WRITE_MB ))
      if [ "$INTEGRITY" = 1 ]; then sec_write $(( SEC0 + 1 + k )) "-" || die "invalidating checksum entry $k"; fi
      dd status=none if=/dev/urandom of="$DEV" bs=1M seek="$off" count="$WRITE_MB" iflag=fullblock conv=notrunc,fsync 2>/tmp/err \
        || die "writing $WRITE_MB MiB at ${off} MiB of $DEV"
      if [ "$INTEGRITY" = 1 ]; then
        s=$(blk_sum "$off")
        sec_write $(( SEC0 + 1 + k )) "S $s $n" || die "writing checksum entry $k"
      fi
    fi
    sec_write "$SEC0" "BBX1 $H $n $(date +%s) $first" || die "writing header of region $IDX"
    sleep "$INTERVAL"
  done
}

# stats: "<progress counter> <KiB of blob data>" for this pod
stats() {
  if [ "$VOLUME_MODE" = Block ]; then
    IDX=$(cat "$STATE" 2>/dev/null); isnum "$IDX" || IDX=$(my_index)
    hdr_load "$IDX" || { echo "x x"; return; }
    hdr_parse "$(hdr_sec "$IDX" 0)"
    { [ "$MAGIC" = BBX1 ] && isnum "$HN"; } || { echo "0 0"; return; }
    w=$HN; [ "$w" -gt "$SLOTS" ] && w=$SLOTS
    echo "$HN $(( w * WRITE_MB * 1024 ))"
  else
    P=$(cat "$STATE" 2>/dev/null)
    l=$(grep -c " $H\$" "$D/heartbeat.log" 2>/dev/null); isnum "$l" || l=0
    k=$(du -ck "$D/$P"-*.bin 2>/dev/null | tail -n1 | cut -f1); isnum "$k" || k=0
    echo "$l $k"
  fi
}

verify_fs() {
  hb="$D/heartbeat.log"
  if [ -s "$hb" ]; then
    echo "INFO history: $(wc -l < "$hb") heartbeat lines; first: $(head -n1 "$hb"); last: $(tail -n1 "$hb")"
  else
    echo "FAIL $hb missing or empty"; vfail=$(( vfail + 1 ))
  fi
  for h in "$@"; do
    last=$(grep " $h\$" "$hb" 2>/dev/null | tail -n1)
    if [ -n "$last" ]; then echo "INFO sees $h: $last"
    else echo "FAIL no heartbeat lines from $h visible"; vfail=$(( vfail + 1 )); fi
  done
  [ "$scope" = full ] || return 0
  if [ "$INTEGRITY" != 1 ]; then echo "INFO integrity tracking not enabled (deployed without --verify-integrity)"; return 0; fi
  found=0
  for m in "$D"/blob*.sha256; do
    [ -f "$m" ] || continue
    found=1
    cp "$m" /tmp/snap 2>/dev/null || { echo "FAIL cannot read $m"; bad=$(( bad + 1 )); continue; }
    while read -r s f; do
      [ -n "$f" ] || continue
      if [ ! -f "$f" ]; then
        if man_has "$m" "$s" "$f"; then echo "FAIL missing: $f (listed in ${m##*/})"; miss=$(( miss + 1 ))
        else skip=$(( skip + 1 )); fi
        continue
      fi
      a=$(dd status=none if="$f" bs=1M iflag=direct,fullblock 2>/dev/null | sha256sum | cut -d' ' -f1)
      if [ "$a" = "$s" ]; then ok=$(( ok + 1 ))
      elif man_has "$m" "$s" "$f"; then echo "FAIL checksum mismatch: $f expected $s got $a"; bad=$(( bad + 1 ))
      else skip=$(( skip + 1 )); fi
    done < /tmp/snap
  done
  [ "$found" = 1 ] || { echo "FAIL no blob checksum manifests (blob*.sha256) under $D"; miss=$(( miss + 1 )); }
}

verify_block() {
  [ -b "$DEV" ] || { echo "FAIL $DEV is not a block device"; vfail=$(( vfail + 1 )); return; }
  now=$(date +%s)
  if [ "$SHARED" = 1 ]; then regions=$(seq 0 $(( REPLICAS - 1 ))); else regions=0; fi
  for h in "$@"; do
    r=${h##*-}; isnum "$r" || { echo "FAIL cannot map $h to a region"; vfail=$(( vfail + 1 )); continue; }
    hdr_load "$r" || { echo "FAIL reading header of region $r"; vfail=$(( vfail + 1 )); continue; }
    hdr_parse "$(hdr_sec "$r" 0)"
    if [ "$MAGIC" = BBX1 ] && [ "$HHOST" = "$h" ]; then
      echo "INFO sees $h (region $r): counter $HN, last write $(( now - HLAST ))s ago"
    else
      echo "FAIL region $r header not written by $h (found: '$MAGIC $HHOST')"; vfail=$(( vfail + 1 ))
    fi
  done
  [ "$scope" = full ] || return 0
  for r in $regions; do
    hdr_load "$r" || { echo "FAIL reading header of region $r"; miss=$(( miss + 1 )); continue; }
    hdr_parse "$(hdr_sec "$r" 0)"
    if [ "$MAGIC" != BBX1 ]; then echo "FAIL region $r has no header (never written, or data lost)"; miss=$(( miss + 1 )); continue; fi
    echo "INFO history region $r: $HN writes by $HHOST since $(fmt_epoch "$HFIRST"), last $(fmt_epoch "$HLAST")"
    [ "$INTEGRITY" = 1 ] || continue
    k=0
    while [ "$k" -lt "$SLOTS" ]; do
      e=$(hdr_sec "$r" $(( 1 + k )))
      set -- $e
      if [ "${1:-}" = S ]; then
        off=$(( r * REGION_MB + 1 + k * WRITE_MB ))
        a=$(blk_sum "$off")
        if [ "$a" = "$2" ]; then ok=$(( ok + 1 ))
        else
          hdr_load "$r" >/dev/null 2>&1
          if [ "$(hdr_sec "$r" $(( 1 + k )))" = "$e" ]; then
            echo "FAIL checksum mismatch: region $r slot $k (${off} MiB) expected $2 got $a"; bad=$(( bad + 1 ))
          else skip=$(( skip + 1 )); fi
        fi
      elif [ "${1:-}" = "-" ]; then skip=$(( skip + 1 ))
      fi
      k=$(( k + 1 ))
    done
  done
  [ "$INTEGRITY" = 1 ] || echo "INFO integrity tracking not enabled (deployed without --verify-integrity)"
}

# verify full|vis [peer pod...]: history + peer visibility (+ checksums if full)
verify() {
  scope=${1:-full}; [ $# -gt 0 ] && shift
  ok=0; bad=0; miss=0; skip=0; vfail=0
  if [ "$VOLUME_MODE" = Block ]; then verify_block "$@"; else verify_fs "$@"; fi
  echo "RESULT ok=$ok mismatch=$bad missing=$miss skipped_in_flight=$skip visibility_fail=$vfail"
  [ $(( bad + miss + vfail )) -eq 0 ]
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
  run) if [ "$VOLUME_MODE" = Block ]; then run_block; else run_fs; fi ;;
  stats) stats ;;
  info) echo "$VOLUME_MODE $SHARED $INTEGRITY $REPLICAS" ;;
  verify) verify "$@" ;;
  *) echo "usage: pod-tool run | stats | info | verify full|vis [peer...]" >&2; exit 2 ;;
esac
POD_TOOL_EOF
#@@POD_TOOL_END@@

# ---- validate settings ------------------------------------------------------

case "${ACCESS_MODE_IN^^}" in
    RWO|READWRITEONCE) ACCESS=RWO; ACCESS_K8S=ReadWriteOnce ;;
    RWX|READWRITEMANY) ACCESS=RWX; ACCESS_K8S=ReadWriteMany ;;
    RWOP|READWRITEONCEPOD) ACCESS=RWOP; ACCESS_K8S=ReadWriteOncePod ;;
    *) die "--access-mode must be RWO, RWX or RWOP (got: $ACCESS_MODE_IN)" ;;
esac
case "${VOLUME_MODE_IN,,}" in
    filesystem|fs) VOLUME_MODE=Filesystem ;;
    block) VOLUME_MODE=Block ;;
    *) die "--volume-mode must be Filesystem or Block (got: $VOLUME_MODE_IN)" ;;
esac
if [[ -z "$STORAGE_CLASS" ]]; then
    if [[ "$VOLUME_MODE" == Block ]]; then STORAGE_CLASS="ocs-storagecluster-ceph-rbd"
    else STORAGE_CLASS="ocs-storagecluster-cephfs"; fi
fi

[[ "$ACCESS" == RWX && "$VOLUME_MODE" == Block ]] \
    && die "RWX + Block (shared raw device) needs stable pod identities; use deploy-busybox-statefulset-app.sh --access-mode RWX --volume-mode Block"
if [[ -z "$REPLICAS" ]]; then
    if [[ "$ACCESS" == RWX ]]; then REPLICAS=2; else REPLICAS=1; fi
fi
is_uint "$REPLICAS" && [[ "$REPLICAS" -ge 1 ]] || die "--replicas must be an integer >= 1 (got: $REPLICAS)"
[[ "$ACCESS" == RWX || "$REPLICAS" -eq 1 ]] \
    || die "--replicas $REPLICAS needs --access-mode RWX (a $ACCESS volume can only be used by one pod)"
is_uint "$WRITE_MB" || die "--write-mb must be a non-negative integer (got: $WRITE_MB)"
is_uint "$MAX_MB"   || die "--max-mb must be a non-negative integer (got: $MAX_MB)"
is_uint "$INTERVAL" && [[ "$INTERVAL" -ge 1 ]] || die "--interval must be an integer >= 1 (got: $INTERVAL)"
is_uint "$TIMEOUT"  || die "--timeout must be a non-negative integer (got: $TIMEOUT)"
[[ "$VERIFY_ONLY" -eq 1 && "$DRY_RUN" -eq 1 ]] && die "--verify-only and --dry-run can't be combined"

SHARED=0; ADOPT=0
if [[ "$ACCESS" == RWX ]]; then SHARED=1; ADOPT=1; fi

SLOTS=0
if [[ "$WRITE_MB" -gt 0 ]]; then
    [[ "$MAX_MB" -ge "$WRITE_MB" ]] || die "--max-mb ($MAX_MB) must be >= --write-mb ($WRITE_MB)"
    SLOTS=$(( MAX_MB / WRITE_MB ))
fi
REGION_MB=0
if [[ "$VOLUME_MODE" == Block ]]; then
    [[ "$SLOTS" -le 2047 ]] || die "Block mode supports at most 2047 blob slots (--max-mb / --write-mb = $SLOTS); raise --write-mb or lower --max-mb"
    REGION_MB=$(( 1 + SLOTS * WRITE_MB ))
    NEED_MB=$(( (SHARED ? REPLICAS : 1) * REGION_MB ))
else
    NEED_MB=$(( (SHARED ? REPLICAS : 1) * SLOTS * WRITE_MB ))
fi

if [[ "$VERIFY_ONLY" -eq 0 ]]; then
    SIZE_MIB=$(to_mib "$SIZE")
    if [[ -n "$SIZE_MIB" ]]; then
        LIMIT_MIB=$(( SIZE_MIB * 80 / 100 ))
        [[ "$NEED_MB" -le "$LIMIT_MIB" ]] \
            || die "data needs ${NEED_MB} MiB ($( [[ $SHARED -eq 1 ]] && echo "$REPLICAS pods x ")$(( NEED_MB / (SHARED ? REPLICAS : 1) )) MiB), over 80% of PVC size $SIZE (${LIMIT_MIB} MiB); lower --max-mb or raise --size"
    else
        warn "can't parse PVC size '$SIZE' (expected NNMi/NNGi/NNTi); skipping capacity check"
    fi
    info "mode: $ACCESS $VOLUME_MODE, $REPLICAS pod(s), integrity=$([[ $INTEGRITY -eq 1 ]] && echo on || echo off)"
    if [[ "$WRITE_MB" -gt 0 ]]; then
        info "write load per pod: ${WRITE_MB} MiB every ${INTERVAL}s (~$(( WRITE_MB * 60 / INTERVAL )) MiB/min), ${SLOTS} slots = $(( SLOTS * WRITE_MB )) MiB max; volume needs ${NEED_MB} MiB"
    else
        info "write load: heartbeat/header only (--write-mb 0)"
    fi
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

# tool_exec <pod> <pod-tool args...>
tool_exec() {
    local pod=$1; shift
    oc exec -n "$NAMESPACE" "$pod" -c busybox -- sh -c "$POD_TOOL" pod-tool "$@"
}

# check the StorageClass's provisioner supports the requested access/volume mode
check_storage_class() {
    local prov=""
    prov=$(oc get storageclass "$STORAGE_CLASS" -o jsonpath='{.provisioner}' 2>/dev/null) || prov=""
    if [[ -z "$prov" ]]; then
        [[ "$DRY_RUN" -eq 1 ]] || die "StorageClass $STORAGE_CLASS not found (oc get storageclass)"
        warn "can't look up StorageClass $STORAGE_CLASS; skipping access/volume-mode compatibility check"
        return 0
    fi
    case "$prov" in
        *cephfs.csi.ceph.com)
            [[ "$VOLUME_MODE" == Block ]] \
                && die "StorageClass $STORAGE_CLASS is CephFS ($prov), which doesn't support volumeMode Block; use -s ocs-storagecluster-ceph-rbd" ;;
        *rbd.csi.ceph.com)
            [[ "$ACCESS" == RWX && "$VOLUME_MODE" == Filesystem ]] \
                && die "StorageClass $STORAGE_CLASS is RBD ($prov), which doesn't support RWX with volumeMode Filesystem; use CephFS (-s ocs-storagecluster-cephfs)" ;;
        *)
            warn "StorageClass provisioner $prov is neither CephFS nor RBD; skipping compatibility check" ;;
    esac
    info "StorageClass $STORAGE_CLASS (provisioner $prov)"
}

# volume_attach <indent>: container volumeMounts/volumeDevices stanza
volume_attach() {
    local pad="$1"
    if [[ "$VOLUME_MODE" == Block ]]; then
        printf '%svolumeDevices:\n%s  - name: data\n%s    devicePath: /dev/xvda\n' "$pad" "$pad" "$pad"
    else
        printf '%svolumeMounts:\n%s  - name: data\n%s    mountPath: /data\n' "$pad" "$pad" "$pad"
    fi
}

# running, non-terminating app pods (excludes the RWOP probe)
list_pods() {
    oc get pods -n "$NAMESPACE" -l "app=$NAME" --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null \
        | awk 'NF == 1 { print $1 }' | sort
}

# dump everything useful for diagnosing a failed deploy/write, then exit 1.
# fail_with_diagnostics <message> [pod...]  (pods default to all app pods)
fail_with_diagnostics() {
    local msg="$1"; shift
    local pods=("$@") p
    if [[ ${#pods[@]} -eq 0 ]]; then
        mapfile -t pods < <(oc get pods -n "$NAMESPACE" -l "app=$NAME" -o name 2>/dev/null | sed 's#^pod/##')
    fi
    err "$msg"
    err "--- deployment ---"
    oc get deployment -n "$NAMESPACE" "$NAME" -o wide >&2 || true
    err "--- pods ---"
    oc get pods -n "$NAMESPACE" -l "app=$NAME" -o wide >&2 || true
    err "--- pvc ---"
    oc get pvc -n "$NAMESPACE" "$NAME" >&2 || true
    oc describe pvc -n "$NAMESPACE" "$NAME" 2>/dev/null | sed -n '/^Events:/,$p' >&2 || true
    for p in "${pods[@]}"; do
        err "=== ${p} ==="
        err "--- pod events ---"
        oc describe pod -n "$NAMESPACE" "$p" 2>/dev/null | sed -n '/^Events:/,$p' >&2 || true
        err "--- logs (current, then previous) ---"
        oc logs -n "$NAMESPACE" "$p" --tail=20 >&2 2>/dev/null || true
        oc logs -n "$NAMESPACE" "$p" --previous --tail=20 >&2 2>/dev/null || true
        err "--- volume inside pod ---"
        oc exec -n "$NAMESPACE" "$p" -- sh -c 'id; ls -l /dev/xvda 2>/dev/null && blockdev --getsize64 /dev/xvda; mount | grep " /data "; ls -laZ /data 2>/dev/null || ls -la /data 2>/dev/null; df -h /data 2>/dev/null' >&2 2>/dev/null || true
    done
    exit 1
}

# run_pod_verify <pod> <full|vis> [peer...]: relay pod-tool verify output
run_pod_verify() {
    local pod=$1 scope=$2 out rc=0 line; shift 2
    out=$(tool_exec "$pod" verify "$scope" "$@" 2>&1) || rc=$?
    while IFS= read -r line; do
        case "$line" in
            FAIL\ *) err "$pod: ${line#FAIL }" ;;
            INFO\ *) info "$pod: ${line#INFO }" ;;
            "") ;;
            *) info "$pod: $line" ;;
        esac
    done <<<"$out"
    return "$rc"
}

# verify_data <pod...>: history, cross-pod visibility and checksums; returns 1 on any FAIL
verify_data() {
    local pods=("$@") vmode shared integ reps p rc=0
    read -r vmode shared integ reps <<<"$(tool_exec "${pods[0]}" info 2>/dev/null || echo "? ? ? ?")"
    [[ "$vmode" == "?" ]] && { err "${pods[0]}: could not read pod-tool settings"; return 1; }
    info "verifying data ($vmode, shared=$shared, integrity=$integ) on: ${pods[*]}"
    if [[ "$shared" == 1 ]]; then
        run_pod_verify "${pods[0]}" full "${pods[@]}" || rc=1
        for p in "${pods[@]:1}"; do run_pod_verify "$p" vis "${pods[@]}" || rc=1; done
    else
        for p in "${pods[@]}"; do run_pod_verify "$p" full || rc=1; done
    fi
    return "$rc"
}

# rwop_probe <pvc>: a second pod on an RWOP claim must be refused. 0=pass 1=fail 2=inconclusive
rwop_probe() {
    local pvc=$1 probe="${NAME}-rwop-probe" phase msgs i rc=2
    info "RWOP check: starting probe pod $probe on PVC $pvc (must NOT be scheduled)"
    oc delete pod -n "$NAMESPACE" "$probe" --ignore-not-found --wait=true >/dev/null 2>&1 || true
    cat <<EOF | apply >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${probe}
  namespace: ${NAMESPACE}
  labels:
    app: ${probe}
spec:
  restartPolicy: Never
  containers:
    - name: busybox
      image: busybox:1.36
      command: ["sleep", "3600"]
$(volume_attach "      ")
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${pvc}
EOF
    for (( i = 0; i < 20; i++ )); do
        sleep 3
        phase=$(oc get pod -n "$NAMESPACE" "$probe" -o jsonpath='{.status.phase}' 2>/dev/null || true)
        msgs=$(oc get pod -n "$NAMESPACE" "$probe" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}' 2>/dev/null || true)
        msgs+=$'\n'$(oc get events -n "$NAMESPACE" --field-selector "involvedObject.name=$probe" -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null || true)
        if [[ "$phase" == Running ]]; then
            err "RWOP check FAILED: probe pod $probe is Running on PVC $pvc alongside the app pod"
            rc=1; break
        fi
        if grep -qi 'ReadWriteOncePod' <<<"$msgs"; then
            info "RWOP check passed: probe refused -- $(grep -i -m1 'ReadWriteOncePod' <<<"$msgs")"
            rc=0; break
        fi
    done
    if [[ "$rc" -eq 2 ]]; then
        warn "RWOP check inconclusive after 60s: probe phase '${phase:-unknown}', no ReadWriteOncePod refusal seen. Messages:"
        printf '%s\n' "$msgs" | sed '/^$/d' >&2
    fi
    oc delete pod -n "$NAMESPACE" "$probe" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    return "$rc"
}

# ---- verify-only ------------------------------------------------------------

if [[ "$VERIFY_ONLY" -eq 1 ]]; then
    oc get deployment -n "$NAMESPACE" "$NAME" >/dev/null 2>&1 \
        || die "deployment/$NAME not found in namespace $NAMESPACE (pass the same -n/--name used to deploy)"
    mapfile -t PODS < <(list_pods)
    [[ ${#PODS[@]} -gt 0 ]] \
        || fail_with_diagnostics "no running pods for deployment/$NAME (scale it up, e.g. oc scale -n $NAMESPACE deployment/$NAME --replicas=1)"
    if verify_data "${PODS[@]}"; then
        info "VERIFY PASS: deployment/$NAME in $NAMESPACE"
        exit 0
    fi
    err "VERIFY FAIL: deployment/$NAME in $NAMESPACE (see errors above)"
    exit 1
fi

# ---- storage class + namespace ----------------------------------------------

check_storage_class

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

info "deploying PVC $NAME (${SIZE}, ${ACCESS_K8S}, ${VOLUME_MODE}, storageClass ${STORAGE_CLASS}) in $NAMESPACE"
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
    - ${ACCESS_K8S}
  volumeMode: ${VOLUME_MODE}
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: ${SIZE}
EOF

# ---- Deployment ---------------------------------------------------------

# single-attach volumes can't roll (new pod would wait on the old one's
# attachment), so replace pods instead; RWX pods prefer separate nodes
if [[ "$SHARED" -eq 1 ]]; then
    STRATEGY="RollingUpdate"
    AFFINITY="      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels:
                    app: ${NAME}"
else
    STRATEGY="Recreate"
    AFFINITY=""
fi

info "deploying busybox Deployment $NAME ($REPLICAS replica(s), strategy $STRATEGY) in $NAMESPACE"
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
  replicas: ${REPLICAS}
  strategy:
    type: ${STRATEGY}
  selector:
    matchLabels:
      app: ${NAME}
  template:
    metadata:
      labels:
        app: ${NAME}
        app.kubernetes.io/name: ${NAME}
    spec:
${AFFINITY}
      containers:
        - name: busybox
          image: busybox:1.36
          env:
            - { name: VOLUME_MODE, value: "${VOLUME_MODE}" }
            - { name: WRITE_MB, value: "${WRITE_MB}" }
            - { name: SLOTS, value: "${SLOTS}" }
            - { name: INTERVAL, value: "${INTERVAL}" }
            - { name: INTEGRITY, value: "${INTEGRITY}" }
            - { name: SHARED, value: "${SHARED}" }
            - { name: ADOPT, value: "${ADOPT}" }
            - { name: REGION_MB, value: "${REGION_MB}" }
            - { name: REPLICAS, value: "${REPLICAS}" }
          command: ["sh", "-c"]
          args:
            - |
$(printf '%s\n' "$POD_TOOL" | sed 's/^/              /')
            - pod-tool
            - run
$(volume_attach "          ")
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: ${NAME}
EOF

if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would wait for deployment/$NAME rollout and verify writes"
    exit 0
fi

info "waiting up to ${TIMEOUT}s for deployment/$NAME rollout"
oc rollout status "deployment/${NAME}" -n "$NAMESPACE" --timeout="${TIMEOUT}s" \
    || fail_with_diagnostics "deployment/$NAME rollout did not complete within ${TIMEOUT}s"
info "deployment/$NAME rollout complete"

# ---- verify data is actually landing on the volume -----------------------

mapfile -t PODS < <(list_pods)
[[ ${#PODS[@]} -eq "$REPLICAS" ]] \
    || fail_with_diagnostics "expected $REPLICAS running pod(s), found ${#PODS[@]}: ${PODS[*]:-none}"

if [[ "$VOLUME_MODE" == Block ]]; then UNIT="header write counter"; else UNIT="heartbeat lines"; fi
declare -A C1=() K1=()
info "verifying writes on ${#PODS[@]} pod(s) (sampling twice, $(( INTERVAL * 2 + 2 ))s apart)"
for p in "${PODS[@]}"; do
    read -r c k <<<"$(tool_exec "$p" stats 2>/dev/null || echo "x x")"
    C1[$p]=$c; K1[$p]=$k
done
sleep $(( INTERVAL * 2 + 2 ))
BAD_PODS=()
for p in "${PODS[@]}"; do
    read -r c2 k2 <<<"$(tool_exec "$p" stats 2>/dev/null || echo "x x")"
    c1=${C1[$p]}; k1=${K1[$p]}
    if ! is_uint "$c1" || ! is_uint "$c2"; then
        err "$p: could not read write stats from the pod"; BAD_PODS+=("$p"); continue
    fi
    if [[ "$c2" -le "$c1" ]]; then
        err "$p: $UNIT not increasing ($c1 -> $c2); writes are failing"; BAD_PODS+=("$p"); continue
    fi
    if [[ "$WRITE_MB" -gt 0 && "$k2" -lt $(( WRITE_MB * 1024 )) ]]; then
        err "$p: only ${k2} KiB of blob data, expected at least ${WRITE_MB} MiB"; BAD_PODS+=("$p"); continue
    fi
    info "$p: $UNIT $c1 -> $c2, blob data $(( k1 / 1024 )) -> $(( k2 / 1024 )) MiB"
done
[[ ${#BAD_PODS[@]} -eq 0 ]] \
    || fail_with_diagnostics "write verification failed on ${#BAD_PODS[@]}/${#PODS[@]} pod(s): ${BAD_PODS[*]}" "${BAD_PODS[@]}"

verify_data "${PODS[@]}" \
    || fail_with_diagnostics "data verification failed (history/visibility/checksums; see errors above)"

if [[ "$ACCESS" == RWOP ]]; then
    RWOP_RC=0; rwop_probe "$NAME" || RWOP_RC=$?
    [[ "$RWOP_RC" -ne 1 ]] || fail_with_diagnostics "RWOP not enforced for PVC $NAME"
fi

info "writes verified"
info "done: Deployment '$NAME' ($ACCESS $VOLUME_MODE, $REPLICAS pod(s)) running in namespace '$NAMESPACE'"
[[ "$INTEGRITY" -eq 1 ]] && info "re-check integrity later with: $0 -n $NAMESPACE --name $NAME --verify-only"
info "shell in with: oc exec -n $NAMESPACE deploy/$NAME -- sh"
exit 0
