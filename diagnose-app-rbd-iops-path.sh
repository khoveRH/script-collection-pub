#!/usr/bin/env bash
#
# diagnose-app-rbd-path.sh
#
# Same layered I/O diagnostic as diagnose-vm-iops-path-v2.sh, but for a
# regular application pod using an ODF/Ceph RBD-backed PVC instead of a
# KubeVirt VM. There's no QEMU/virsh domain to sample here, so the
# pod-facing layer instead diffs the container's own cgroup io.stat --
# everything below that (node kernel RBD device, Ceph cluster, bare-metal
# OSD disks) uses the exact same mechanics as the VM script.
#
# Ceph commands run inside the rook-ceph-operator pod (always present,
# unlike the optional rook-ceph-tools toolbox):
#
#   oc rsh -n openshift-storage $(oc get pods -n openshift-storage -o name -l app=rook-ceph-operator)
#   export CEPH_ARGS='-c /var/lib/rook/openshift-storage/openshift-storage.config'
#
# The path this walks, and where each layer's numbers come from:
#
#   [B] application pod, cgroup io.stat
#       /sys/fs/cgroup/io.stat inside the target container, sampled twice
#       across the window and diffed per backing device (rios/wios/
#       rbytes/wbytes -> IOPS and MB/s). Falls back to a single blkio
#       throttle snapshot on cgroup v1 nodes (no delta, best-effort).
#   [C] worker node, kernel RBD device (/dev/rbdN)
#       The PV's pool+image is matched against /sys/bus/rbd/devices/*/ on
#       the node running the pod (no `rbd` CLI needed on the host), then
#       /sys/block/rbdN/stat is diffed across the window the same way
#       `iostat -x` computes await and %util, without depending on
#       sysstat being installed on RHCOS.
#   [D] Ceph cluster (rook-ceph-operator pod, no toolbox needed)
#       `ceph osd perf` (commit/apply latency per OSD), `ceph -s`,
#       `ceph health detail`, `ceph osd df`, `ceph osd pool stats`.
#   [E] bare-metal disks backing the busiest OSDs
#       The OSDs with the worst apply/commit latency from [D] are resolved
#       to a hostname + block device via `ceph osd metadata`, and (only if
#       that hostname is actually an OpenShift node -- i.e. hyperconverged/
#       internal-mode ODF) the same /sys/block/<dev>/stat diff from [C] is
#       run there.
#
# Comparing [C] against [E] is the useful part: high latency at the rbdN
# device with a healthy, low-utilization physical disk underneath means the
# bottleneck is upstream of the media -- OSD daemon CPU, replication, or the
# Ceph network -- not the drives themselves.
#
# This script is read-only: it never modifies the pod, PVC, PV, or Ceph
# cluster state. It does create short-lived `oc debug node/<node>` pods
# (standard, self-cleaning) to read sysfs on the nodes it inspects.
#
# Requires: oc, jq, awk (cluster-admin-ish access: node debug + rsh into the
# rook-ceph-operator pod)
#
# Usage:
#   diagnose-app-rbd-path.sh [options] <pod-name>
#   diagnose-app-rbd-path.sh [options] -l <selector>
#
# Options:
#   -n, --namespace NS       Namespace the pod lives in (default: current
#                            oc project)
#   -l, --selector SEL       Label selector to find the target pod (first
#                            match is used) -- alternative to a positional
#                            pod name, e.g. -l app=myapp
#   -c, --container NAME     Container to run cgroup/exec sampling in
#                            (default: pod's first container)
#   -d, --duration SEC       Sampling window per layer, in seconds
#                            (default: 10)
#   -o, --output-dir DIR     Where to save raw captures (default:
#                            ./app-rbd-diag-<pod>-<timestamp>)
#       --ceph-namespace NS  Namespace running Rook/ODF (default:
#                            openshift-storage)
#       --ceph-pod-selector SEL
#                            Label selector for the pod `ceph` commands run
#                            in (default: app=rook-ceph-operator)
#       --ceph-args ARGS     Value for CEPH_ARGS inside that pod (default:
#                            "-c /var/lib/rook/<ceph-namespace>/<ceph-namespace>.config",
#                            matching where Rook mounts the cluster config)
#       --top-osds N         How many worst-latency OSDs to drill into on
#                            bare metal (default: 3)
#       --skip-node-rbd      Skip layer C (node-level rbd device stats)
#       --skip-osd-disks     Skip layer E (bare-metal OSD disk stats)
#       --exec-cmd CMD       Also run CMD inside the app container via
#                            `oc exec` for a comparison point (e.g.
#                            --exec-cmd "iostat -xz 1 5", if present in
#                            the image)
#   -h, --help               Show this help
#
# Examples:
#   # by pod name, 15s samples per layer
#   diagnose-app-rbd-path.sh -n myapp -d 15 myapp-7c9f5d-xk2lm
#
#   # by label selector, skip the bare-metal OSD disk drill-down
#   diagnose-app-rbd-path.sh -n myapp -l app=myapp --skip-osd-disks
#
set -euo pipefail

NAMESPACE=""
SELECTOR=""
CONTAINER=""
DURATION=10
OUTPUT_DIR=""
CEPH_NAMESPACE="openshift-storage"
CEPH_POD_SELECTOR="app=rook-ceph-operator"
CEPH_POD=""
CEPH_ARGS=""
TOP_OSDS=3
SKIP_NODE_RBD=0
SKIP_OSD_DISKS=0
EXEC_CMD=""
POD_NAME=""

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*" >&2; }
err()  { log "ERROR $*" >&2; }
die()  { err "$*"; exit 1; }

usage() { sed -n '2,92p' "$0" | sed 's/^# \{0,1\}//'; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# ---- argument parsing ------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace) NAMESPACE="$2"; shift 2 ;;
        -l|--selector) SELECTOR="$2"; shift 2 ;;
        -c|--container) CONTAINER="$2"; shift 2 ;;
        -d|--duration) DURATION="$2"; shift 2 ;;
        -o|--output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --ceph-namespace) CEPH_NAMESPACE="$2"; shift 2 ;;
        --ceph-pod-selector) CEPH_POD_SELECTOR="$2"; shift 2 ;;
        --ceph-args) CEPH_ARGS="$2"; shift 2 ;;
        --top-osds) TOP_OSDS="$2"; shift 2 ;;
        --skip-node-rbd) SKIP_NODE_RBD=1; shift ;;
        --skip-osd-disks) SKIP_OSD_DISKS=1; shift ;;
        --exec-cmd) EXEC_CMD="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) [[ -z "$POD_NAME" ]] || die "unexpected extra argument: $1"; POD_NAME="$1"; shift ;;
    esac
done

[[ -n "$POD_NAME" || -n "$SELECTOR" ]] || { usage; die "either a pod-name or -l/--selector is required"; }

require_cmd oc
require_cmd jq
require_cmd awk

[[ -n "$NAMESPACE" ]] || NAMESPACE=$(oc project -q 2>/dev/null) || die "no namespace given and no current oc project"
[[ -n "$CEPH_ARGS" ]] || CEPH_ARGS="-c /var/lib/rook/${CEPH_NAMESPACE}/${CEPH_NAMESPACE}.config"

# ---- generic helpers --------------------------------------------------------

node_debug_exec() {
    # node_debug_exec <node> <command...>  -- runs chrooted into the host
    local node="$1"; shift
    oc debug node/"$node" --quiet=true -- chroot /host "$@" 2>/dev/null
}

# diskstat_delta <node> <blockdev-basename> <duration>
# Diffs /sys/block/<dev>/stat across <duration> seconds and prints the same
# metrics `iostat -x` reports (read/write IOPS, MB/s, average latency,
# %util), computed straight from the kernel counters -- no sysstat needed.
diskstat_delta() {
    local node="$1" dev="$2" duration="$3"
    local t0 t1 s0 s1

    s0=$(node_debug_exec "$node" cat "/sys/block/$dev/stat")
    t0=$(date +%s.%N)
    if [[ -z "$s0" ]]; then
        warn "could not read /sys/block/$dev/stat on $node"
        return 1
    fi

    sleep "$duration"

    s1=$(node_debug_exec "$node" cat "/sys/block/$dev/stat")
    t1=$(date +%s.%N)
    if [[ -z "$s1" ]]; then
        warn "could not read /sys/block/$dev/stat on $node (second sample)"
        return 1
    fi

    awk -v s0="$s0" -v s1="$s1" -v t0="$t0" -v t1="$t1" '
        BEGIN {
            split(s0, a); split(s1, b)
            elapsed = t1 - t0
            if (elapsed <= 0) elapsed = 0.001
            rd_ios = b[1]-a[1]; rd_sect = b[3]-a[3]; rd_ticks = b[4]-a[4]
            wr_ios = b[5]-a[5]; wr_sect = b[7]-a[7]; wr_ticks = b[8]-a[8]
            io_ticks = b[10]-a[10]
            tot_ios = rd_ios + wr_ios
            avg_lat = (tot_ios > 0) ? (rd_ticks + wr_ticks) / tot_ios : 0
            util = (io_ticks / 1000.0) / elapsed * 100.0
            printf "iops_r=%.1f iops_w=%.1f mb_r_s=%.2f mb_w_s=%.2f avg_lat_ms=%.2f util_pct=%.1f\n",
                rd_ios/elapsed, wr_ios/elapsed, (rd_sect*512/1048576)/elapsed,
                (wr_sect*512/1048576)/elapsed, avg_lat, util
        }'
}

metric() { # metric <key> <line-of-key=val-pairs>  -- pulls one value out
    grep -o "$1=[^ ]*" <<<"$2" | cut -d= -f2
}

# ---- layer resolution: pod -> node -----------------------------------------

resolve_pod() {
    if [[ -n "$POD_NAME" ]]; then
        info "resolving pod $POD_NAME in namespace $NAMESPACE"
        oc get pod "$POD_NAME" -n "$NAMESPACE" >/dev/null 2>&1 \
            || die "pod $POD_NAME not found in $NAMESPACE"
    else
        info "resolving pod via selector '$SELECTOR' in namespace $NAMESPACE"
        POD_NAME=$(oc get pods -n "$NAMESPACE" -l "$SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        [[ -n "$POD_NAME" ]] || die "no pod matching selector '$SELECTOR' found in $NAMESPACE"
    fi

    NODE_NAME=$(oc get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')
    [[ -n "$NODE_NAME" ]] || die "pod $POD_NAME has no assigned node (not scheduled/running?)"

    [[ -n "$CONTAINER" ]] || CONTAINER=$(oc get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].name}')
    [[ -n "$CONTAINER" ]] || die "could not determine a container name in pod $POD_NAME"

    info "pod $POD_NAME (container $CONTAINER) -> node $NODE_NAME"
}

# ---- layer resolution: pod volumes -> PVC -> PV -> RBD pool/image ---------

resolve_disks() {
    info "resolving pod PVCs and their ODF RBD backing"
    local claim_names
    claim_names=$(oc get pod "$POD_NAME" -n "$NAMESPACE" -o json \
        | jq -r '.spec.volumes[] | .persistentVolumeClaim.claimName // empty' \
        | sort -u)

    DISK_PVC=(); DISK_PV=(); DISK_POOL=(); DISK_IMAGE=(); DISK_VOLMODE=()
    local pvc
    while IFS= read -r pvc; do
        [[ -z "$pvc" ]] && continue
        if ! oc get pvc "$pvc" -n "$NAMESPACE" >/dev/null 2>&1; then
            warn "PVC $pvc referenced by pod but not found -- skipping"
            continue
        fi
        local pv driver pool image volmode
        pv=$(oc get pvc "$pvc" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')
        driver=$(oc get pv "$pv" -o jsonpath='{.spec.csi.driver}' 2>/dev/null || true)
        if [[ "$driver" != *rbd* ]]; then
            warn "PVC $pvc (PV $pv) is not RBD-backed (driver='${driver:-none}') -- skipping storage layers for it"
            continue
        fi
        pool=$(oc get pv "$pv" -o jsonpath='{.spec.csi.volumeAttributes.pool}' 2>/dev/null || true)
        image=$(oc get pv "$pv" -o jsonpath='{.spec.csi.volumeAttributes.imageName}' 2>/dev/null || true)
        volmode=$(oc get pvc "$pvc" -n "$NAMESPACE" -o jsonpath='{.spec.volumeMode}' 2>/dev/null || true)
        if [[ -z "$pool" || -z "$image" ]]; then
            warn "PVC $pvc (PV $pv) has no pool/imageName in volumeAttributes -- skipping"
            continue
        fi
        DISK_PVC+=("$pvc"); DISK_PV+=("$pv"); DISK_POOL+=("$pool")
        DISK_IMAGE+=("$image"); DISK_VOLMODE+=("$volmode")
        info "  disk: pvc=$pvc pv=$pv pool=$pool image=$image volumeMode=$volmode"
    done <<<"$claim_names"

    [[ ${#DISK_PVC[@]} -gt 0 ]] || die "no RBD-backed PVCs found for pod $POD_NAME"
}

# ---- layer B: application pod cgroup I/O -----------------------------------

capture_pod_cgroup_layer() {
    info "=== Layer B: application pod cgroup I/O (pod $POD_NAME, container $CONTAINER) ==="
    local s0 s1 t0 t1

    s0=$(oc exec -n "$NAMESPACE" "$POD_NAME" -c "$CONTAINER" -- cat /sys/fs/cgroup/io.stat 2>/dev/null || true)
    t0=$(date +%s.%N)
    if [[ -z "$s0" ]]; then
        warn "  could not read cgroup io.stat in $POD_NAME/$CONTAINER (cgroup v1 node? falling back to a single blkio throttle snapshot, no delta)"
        oc exec -n "$NAMESPACE" "$POD_NAME" -c "$CONTAINER" -- sh -c 'cat /sys/fs/cgroup/blkio/blkio.throttle.io_service_bytes 2>/dev/null' \
            | tee "$OUTPUT_DIR/app-pod-cgroup-blkio.txt" | sed 's/^/    /' || warn "  no cgroup io stats available in this container"
        return 0
    fi

    sleep "$DURATION"

    s1=$(oc exec -n "$NAMESPACE" "$POD_NAME" -c "$CONTAINER" -- cat /sys/fs/cgroup/io.stat 2>/dev/null || true)
    t1=$(date +%s.%N)

    {
        echo "--- io.stat snapshot 1 ---"; echo "$s0"
        echo "--- io.stat snapshot 2 ---"; echo "$s1"
    } > "$OUTPUT_DIR/app-pod-cgroup-io.txt"

    local devline
    while IFS= read -r devline; do
        [[ -z "$devline" ]] && continue
        local dev="${devline%% *}"
        APP_CGROUP_RESULT["$dev"]="${devline#* }"
        info "    $devline"
    done < <(awk -v s0="$s0" -v s1="$s1" -v t0="$t0" -v t1="$t1" '
        BEGIN {
            elapsed = t1 - t0
            if (elapsed <= 0) elapsed = 0.001
            n0 = split(s0, l0, "\n")
            for (i = 1; i <= n0; i++) {
                m = split(l0[i], f, " ")
                if (m < 2) continue
                dev = f[1]
                for (j = 2; j <= m; j++) { split(f[j], kv, "="); a[dev, kv[1]] = kv[2] }
                seen[dev] = 1
            }
            n1 = split(s1, l1, "\n")
            for (i = 1; i <= n1; i++) {
                m = split(l1[i], f, " ")
                if (m < 2) continue
                dev = f[1]
                for (j = 2; j <= m; j++) { split(f[j], kv, "="); b[dev, kv[1]] = kv[2] }
            }
            for (dev in seen) {
                rios = b[dev,"rios"] - a[dev,"rios"]
                wios = b[dev,"wios"] - a[dev,"wios"]
                rbytes = b[dev,"rbytes"] - a[dev,"rbytes"]
                wbytes = b[dev,"wbytes"] - a[dev,"wbytes"]
                printf "%s iops_r=%.1f iops_w=%.1f mb_r_s=%.2f mb_w_s=%.2f\n",
                    dev, rios/elapsed, wios/elapsed, rbytes/1048576/elapsed, wbytes/1048576/elapsed
            }
        }')
}

# ---- layer C: node-level kernel RBD device --------------------------------

find_rbd_device() {
    local node="$1" pool="$2" image="$3"
    node_debug_exec "$node" sh -c '
        for d in /sys/bus/rbd/devices/*/; do
            [ -d "$d" ] || continue
            id=$(basename "$d")
            p=$(cat "$d/pool" 2>/dev/null)
            n=$(cat "$d/name" 2>/dev/null)
            echo "$id $p $n"
        done' 2>/dev/null \
        | awk -v pool="$pool" -v image="$image" '$2==pool && $3==image {print "rbd"$1; exit}'
}

capture_node_rbd_layer() {
    local pool="$1" image="$2"
    info "=== Layer C: node $NODE_NAME, kernel RBD device for $pool/$image ==="

    local dev
    dev=$(find_rbd_device "$NODE_NAME" "$pool" "$image")
    if [[ -z "$dev" ]]; then
        warn "  no mapped /sys/bus/rbd/devices entry found on $NODE_NAME for $pool/$image (non-krbd mounter? already unmapped?)"
        return 0
    fi
    info "  found /dev/$dev on $NODE_NAME, sampling ${DURATION}s"

    local result
    result=$(diskstat_delta "$NODE_NAME" "$dev" "$DURATION") || return 0
    echo "$result" | tee "$OUTPUT_DIR/node-rbd-${dev}.txt" | sed 's/^/    /'
    NODE_RBD_RESULT["$pool/$image"]="$result (device=/dev/$dev node=$NODE_NAME)"
}

# ---- layer D: Ceph cluster --------------------------------------------------

find_ceph_pod() {
    oc get pods -n "$CEPH_NAMESPACE" -o name -l "$CEPH_POD_SELECTOR" 2>/dev/null | head -1
}

ceph_exec() {
    oc rsh -n "$CEPH_NAMESPACE" "$CEPH_POD" env CEPH_ARGS="$CEPH_ARGS" ceph "$@" 2>/dev/null
}

capture_ceph_layer() {
    info "=== Layer D: Ceph cluster (namespace=$CEPH_NAMESPACE) ==="
    [[ -n "${CEPH_POD:-}" ]] || CEPH_POD=$(find_ceph_pod)
    if [[ -z "$CEPH_POD" ]]; then
        warn "  could not find a pod matching selector '$CEPH_POD_SELECTOR' in $CEPH_NAMESPACE -- skipping cluster layer"
        warn "  (pass --ceph-pod-selector <selector> / --ceph-namespace <ns>)"
        return 0
    fi
    info "  running ceph commands in $CEPH_POD via 'oc rsh', CEPH_ARGS='$CEPH_ARGS'"

    ceph_exec -s > "$OUTPUT_DIR/ceph-status.txt" || warn "  'ceph -s' failed"
    sed 's/^/    /' "$OUTPUT_DIR/ceph-status.txt" 2>/dev/null || true

    ceph_exec health detail > "$OUTPUT_DIR/ceph-health-detail.txt" || warn "  'ceph health detail' failed"
    ceph_exec osd df > "$OUTPUT_DIR/ceph-osd-df.txt" || warn "  'ceph osd df' failed"

    for i in "${!DISK_POOL[@]}"; do
        ceph_exec osd pool stats "${DISK_POOL[$i]}" >> "$OUTPUT_DIR/ceph-pool-stats.txt" 2>/dev/null || true
    done

    if ! ceph_exec osd perf -f json > "$OUTPUT_DIR/ceph-osd-perf.json"; then
        warn "  'ceph osd perf' failed"
        return 0
    fi

    info "  worst OSD apply/commit latency (top $TOP_OSDS):"
    TOP_OSD_LIST=$(jq -r --argjson n "$TOP_OSDS" '
        (.osd_perf_infos // .osdstats.osd_perf_infos // [])
        | map({id: .id, lat: ([.perf_stats.commit_latency_ms, .perf_stats.apply_latency_ms] | max)})
        | sort_by(-.lat) | .[0:$n] | .[] | "\(.id) \(.lat)"
    ' "$OUTPUT_DIR/ceph-osd-perf.json" 2>/dev/null || true)

    if [[ -z "$TOP_OSD_LIST" ]]; then
        warn "  could not parse osd perf output"
    else
        echo "$TOP_OSD_LIST" | while read -r id lat; do
            info "    osd.$id  worst_latency_ms=$lat"
        done
    fi
}

# ---- layer E: bare-metal disks behind the busiest OSDs ---------------------

capture_osd_disk_layer() {
    info "=== Layer E: bare-metal disks behind the busiest OSDs ==="
    if [[ -z "${TOP_OSD_LIST:-}" ]]; then
        warn "  no OSD latency data from layer D -- skipping"
        return 0
    fi

    local id lat meta host devnode devbase result
    while read -r id lat; do
        [[ -z "$id" ]] && continue
        meta=$(ceph_exec osd metadata "$id")
        if [[ -z "$meta" ]]; then
            warn "  osd.$id: 'ceph osd metadata' failed, skipping"
            continue
        fi
        host=$(jq -r '.hostname // empty' <<<"$meta")
        devnode=$(jq -r '.bluestore_bdev_dev_node // empty' <<<"$meta")
        if [[ -z "$host" || -z "$devnode" || "$devnode" == "unknown" ]]; then
            warn "  osd.$id: no host/device metadata (not bluestore-on-block, or filestore) -- skipping"
            continue
        fi
        devbase=$(basename "$devnode")

        if ! oc get node "$host" >/dev/null 2>&1; then
            warn "  osd.$id lives on host '$host', which is not an OpenShift node (external/standalone Ceph) -- run iostat/smartctl on $devnode there manually"
            continue
        fi

        info "  osd.$id (worst_latency_ms=$lat) -> host=$host device=$devnode, sampling ${DURATION}s"
        result=$(diskstat_delta "$host" "$devbase" "$DURATION") || continue
        echo "$result" | tee "$OUTPUT_DIR/osd-${id}-disk-${devbase}.txt" | sed 's/^/    /'
        OSD_DISK_RESULT["osd.$id"]="$result (device=$devnode host=$host, reported_ceph_latency_ms=$lat)"
    done <<<"$TOP_OSD_LIST"
}

# ---- optional: extra command inside the app container ----------------------

capture_app_exec_layer() {
    [[ -n "$EXEC_CMD" ]] || return 0
    info "=== extra: command inside app container ($POD_NAME/$CONTAINER) ==="
    if ! oc exec -n "$NAMESPACE" "$POD_NAME" -c "$CONTAINER" -- sh -c "$EXEC_CMD" > "$OUTPUT_DIR/app-exec-output.txt" 2>&1; then
        warn "  exec command failed -- see $OUTPUT_DIR/app-exec-output.txt"
        return 0
    fi
    sed 's/^/    /' "$OUTPUT_DIR/app-exec-output.txt"
}

# ---- summary -----------------------------------------------------------------

print_summary() {
    echo
    echo "================================================================"
    echo " I/O PATH SUMMARY: pod $POD_NAME (namespace $NAMESPACE)"
    echo "================================================================"

    echo
    echo "-- Layer B: application pod cgroup I/O --"
    if [[ -z "${APP_CGROUP_RESULT[*]+set}" ]]; then
        echo "  no data"
    else
        for k in "${!APP_CGROUP_RESULT[@]}"; do echo "  $k: ${APP_CGROUP_RESULT[$k]}"; done
    fi

    echo
    echo "-- Layer C: node kernel RBD device --"
    if [[ -z "${NODE_RBD_RESULT[*]+set}" ]]; then
        echo "  no data"
    else
        for k in "${!NODE_RBD_RESULT[@]}"; do echo "  $k: ${NODE_RBD_RESULT[$k]}"; done
    fi

    echo
    echo "-- Layer D: Ceph OSD apply/commit latency (worst $TOP_OSDS) --"
    if [[ -z "${TOP_OSD_LIST:-}" ]]; then
        echo "  no data"
    else
        echo "$TOP_OSD_LIST" | while read -r id lat; do [[ -n "$id" ]] && echo "  osd.$id: worst_latency_ms=$lat"; done
    fi

    echo
    echo "-- Layer E: bare-metal disk behind those OSDs --"
    if [[ -z "${OSD_DISK_RESULT[*]+set}" ]]; then
        echo "  no data"
    else
        for k in "${!OSD_DISK_RESULT[@]}"; do echo "  $k: ${OSD_DISK_RESULT[$k]}"; done
    fi

    echo
    echo "-- Heuristic --"
    local node_lat_flag=0 osd_daemon_flag=0 osd_disk_flag=0
    local v
    for v in "${NODE_RBD_RESULT[@]:-}"; do
        [[ -z "$v" ]] && continue
        local lat util
        lat=$(metric avg_lat_ms "$v"); util=$(metric util_pct "$v")
        if awk -v l="$lat" 'BEGIN{exit !(l+0 > 15)}' || awk -v u="$util" 'BEGIN{exit !(u+0 > 85)}'; then
            echo "  [WARN] node RBD device shows avg_lat_ms=$lat util_pct=$util% -- congestion between the node and the Ceph cluster"
            node_lat_flag=1
        fi
    done
    if [[ -n "${TOP_OSD_LIST:-}" ]]; then
        local worst
        worst=$(echo "$TOP_OSD_LIST" | head -1 | awk '{print $2}')
        if awk -v l="${worst:-0}" 'BEGIN{exit !(l+0 > 15)}'; then
            echo "  [WARN] worst OSD apply/commit latency = ${worst}ms -- an OSD daemon (CPU, network, or its own disk) is the hot spot"
            osd_daemon_flag=1
        fi
    fi
    for v in "${OSD_DISK_RESULT[@]:-}"; do
        [[ -z "$v" ]] && continue
        local lat util
        lat=$(metric avg_lat_ms "$v"); util=$(metric util_pct "$v")
        if awk -v l="$lat" 'BEGIN{exit !(l+0 > 8)}' || awk -v u="$util" 'BEGIN{exit !(u+0 > 85)}'; then
            echo "  [WARN] physical disk behind a busy OSD shows avg_lat_ms=$lat util_pct=$util% -- the media itself is saturated"
            osd_disk_flag=1
        fi
    done

    if [[ $osd_daemon_flag -eq 1 && $osd_disk_flag -eq 0 ]]; then
        echo "  -> Ceph OSD daemons show latency but their disks are healthy: look at OSD host CPU/network, not the drives."
    fi
    if [[ $node_lat_flag -eq 1 && $osd_daemon_flag -eq 0 && $osd_disk_flag -eq 0 ]]; then
        echo "  -> The node-to-Ceph device is slow but OSDs look healthy: check the Ceph public network path from this node (MTU, bonding, congestion)."
    fi
    if [[ $node_lat_flag -eq 0 && $osd_daemon_flag -eq 0 && $osd_disk_flag -eq 0 ]]; then
        echo "  -> No layer crossed its warning threshold during this sample. If the app is still slow, re-run during the actual slow window,"
        echo "     increase --duration to catch bursts, or check the app's own request queueing with --exec-cmd."
    fi

    echo
    echo "Raw captures saved under: $OUTPUT_DIR"
}

# ---- main --------------------------------------------------------------------

resolve_pod

[[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="./app-rbd-diag-${POD_NAME}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTPUT_DIR"
info "raw captures will be saved under $OUTPUT_DIR"

resolve_disks

declare -A APP_CGROUP_RESULT
declare -A NODE_RBD_RESULT
declare -A OSD_DISK_RESULT
TOP_OSD_LIST=""

capture_pod_cgroup_layer || warn "layer B (pod cgroup) failed"

if [[ $SKIP_NODE_RBD -eq 0 ]]; then
    for i in "${!DISK_POOL[@]}"; do
        capture_node_rbd_layer "${DISK_POOL[$i]}" "${DISK_IMAGE[$i]}" || warn "layer C failed for ${DISK_POOL[$i]}/${DISK_IMAGE[$i]}"
    done
else
    info "skipping layer C (--skip-node-rbd)"
fi

capture_ceph_layer || warn "layer D (Ceph cluster) failed"

if [[ $SKIP_OSD_DISKS -eq 0 ]]; then
    capture_osd_disk_layer || warn "layer E (bare-metal OSD disks) failed"
else
    info "skipping layer E (--skip-osd-disks)"
fi

capture_app_exec_layer || warn "extra exec-cmd layer failed"

print_summary
