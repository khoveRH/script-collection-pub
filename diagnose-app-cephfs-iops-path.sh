#!/usr/bin/env bash
#
# diagnose-app-cephfs-iops-path.sh
#
# Same tooling/layering approach as diagnose-app-rbd-path.sh, adapted for
# an application pod using an ODF/Ceph CephFS-backed PVC instead of RBD.
# CephFS isn't a block device, so there's no /dev/rbdN and no per-device
# /sys/block/*/stat on the node -- layer C instead identifies the node-side
# mount (kernel cephfs vs ceph-fuse) and, for kernel mounts, does a
# best-effort dump of the kernel client's debugfs metrics. Layers B and E
# (pod cgroup I/O, bare-metal OSD disks) are unchanged from the RBD script.
#
# This script also checks for a well-known CephFS limitation: it does not
# support mount-time SELinux context, so on SELinux-enforcing nodes kubelet
# must recursively relabel every file in the volume on first mount into a
# pod's SELinux context (RBD/ext4 can skip this via the SELinux mount
# optimization, but that only applies to ReadWriteOncePod volumes, which
# CephFS's typical ReadWriteMany/ReadOnlyMany PVCs can't use). On a large
# CephFS volume this can make pod startup extremely slow. If this script
# finds that structural condition, it reports it with a link to Red Hat's
# KCS solution on the topic.
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
#   [C] worker node, CephFS mount
#       Identifies the kubelet mount point for the PV and its fstype
#       (kernel "ceph" vs "fuse.ceph-fuse"). For kernel mounts, samples
#       /sys/kernel/debug/ceph/*/metrics/latency twice across the window
#       (raw, best-effort -- kernel client debugfs formats vary more than
#       the stable /sys/block/*/stat layout, so this isn't reduced to a
#       single number the way the RBD script's layer C is).
#   [D] Ceph cluster (rook-ceph-operator pod, no toolbox needed)
#       `ceph -s`, `ceph health detail`, `ceph fs status` (MDS/session
#       state -- CephFS bottlenecks are often metadata-side, not OSD-side),
#       `ceph osd df`, `ceph osd perf` (commit/apply latency per OSD, still
#       relevant since the data pool is OSD-backed).
#   [E] bare-metal disks backing the busiest OSDs
#       Same as the RBD script: worst apply/commit latency OSDs from [D]
#       resolved to a hostname + block device via `ceph osd metadata`, and
#       (only for hyperconverged/internal-mode ODF) diffed the same way.
#   [selinux] SELinux relabeling risk
#       Flags SELinux-enforcing node + non-ReadWriteOncePod CephFS PVC as
#       a structural relabeling risk and links the Red Hat KCS solution.
#
# This script is read-only: it never modifies the pod, PVC, PV, or Ceph
# cluster state. It does create short-lived `oc debug node/<node>` pods
# (standard, self-cleaning) to read sysfs/debugfs on the nodes it inspects.
#
# Requires: oc, jq, awk (cluster-admin-ish access: node debug + rsh into the
# rook-ceph-operator pod)
#
# Usage:
#   diagnose-app-cephfs-iops-path.sh [options] <pod-name>
#   diagnose-app-cephfs-iops-path.sh [options] -l <selector>
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
#                            ./app-cephfs-diag-<pod>-<timestamp>)
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
#       --skip-node-mount    Skip layer C (node-level cephfs mount/client
#                            metrics)
#       --skip-osd-disks     Skip layer E (bare-metal OSD disk stats)
#       --skip-selinux-check Skip the SELinux relabeling risk check
#       --exec-cmd CMD       Also run CMD inside the app container via
#                            `oc exec` for a comparison point (e.g.
#                            --exec-cmd "iostat -xz 1 5", if present in
#                            the image)
#   -h, --help               Show this help
#
# Examples:
#   # by pod name, 15s samples per layer
#   diagnose-app-cephfs-iops-path.sh -n myapp -d 15 myapp-7c9f5d-xk2lm
#
#   # by label selector, skip the bare-metal OSD disk drill-down
#   diagnose-app-cephfs-iops-path.sh -n myapp -l app=myapp --skip-osd-disks
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
SKIP_NODE_MOUNT=0
SKIP_OSD_DISKS=0
SKIP_SELINUX_CHECK=0
EXEC_CMD=""
POD_NAME=""

SELINUX_KCS_TITLE="Workarounds to skip SELinux relabelling in OpenShift Data Foundation / OpenShift Container Storage"
SELINUX_KCS_URL="https://access.redhat.com/solutions/6906261"

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*" >&2; }
err()  { log "ERROR $*" >&2; }
die()  { err "$*"; exit 1; }

usage() { sed -n '2,105p' "$0" | sed 's/^# \{0,1\}//'; }

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
        --skip-node-mount) SKIP_NODE_MOUNT=1; shift ;;
        --skip-osd-disks) SKIP_OSD_DISKS=1; shift ;;
        --skip-selinux-check) SKIP_SELINUX_CHECK=1; shift ;;
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

metric() { # metric <key> <line-of-key=val-pairs>  -- pulls one value out
    grep -o "$1=[^ ]*" <<<"$2" | cut -d= -f2
}

# diskstat_delta <node> <blockdev-basename> <duration>  -- used by layer E
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

# ---- layer resolution: pod volumes -> PVC -> PV -> CephFS backing ---------

resolve_disks() {
    info "resolving pod PVCs and their ODF CephFS backing"
    local claim_names
    claim_names=$(oc get pod "$POD_NAME" -n "$NAMESPACE" -o json \
        | jq -r '.spec.volumes[] | .persistentVolumeClaim.claimName // empty' \
        | sort -u)

    DISK_PVC=(); DISK_PV=(); DISK_FS=(); DISK_SUBVOL=(); DISK_ACCESSMODES=()
    local pvc
    while IFS= read -r pvc; do
        [[ -z "$pvc" ]] && continue
        if ! oc get pvc "$pvc" -n "$NAMESPACE" >/dev/null 2>&1; then
            warn "PVC $pvc referenced by pod but not found -- skipping"
            continue
        fi
        local pv driver fsname subvol modes
        pv=$(oc get pvc "$pvc" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')
        driver=$(oc get pv "$pv" -o jsonpath='{.spec.csi.driver}' 2>/dev/null || true)
        if [[ "$driver" != *cephfs* ]]; then
            warn "PVC $pvc (PV $pv) is not CephFS-backed (driver='${driver:-none}') -- skipping storage layers for it"
            continue
        fi
        fsname=$(oc get pv "$pv" -o jsonpath='{.spec.csi.volumeAttributes.fsName}' 2>/dev/null || true)
        subvol=$(oc get pv "$pv" -o jsonpath='{.spec.csi.volumeAttributes.subvolumeName}' 2>/dev/null || true)
        [[ -n "$subvol" ]] || subvol=$(oc get pv "$pv" -o jsonpath='{.spec.csi.volumeAttributes.subvolumePath}' 2>/dev/null || true)
        modes=$(oc get pvc "$pvc" -n "$NAMESPACE" -o jsonpath='{.spec.accessModes[*]}' 2>/dev/null || true)
        DISK_PVC+=("$pvc"); DISK_PV+=("$pv"); DISK_FS+=("${fsname:-unknown}")
        DISK_SUBVOL+=("${subvol:-unknown}"); DISK_ACCESSMODES+=("$modes")
        info "  disk: pvc=$pvc pv=$pv fsName=${fsname:-unknown} subvolume=${subvol:-unknown} accessModes=$modes"
    done <<<"$claim_names"

    [[ ${#DISK_PVC[@]} -gt 0 ]] || die "no CephFS-backed PVCs found for pod $POD_NAME"
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

# ---- layer C: node-level CephFS mount --------------------------------------

find_cephfs_mount() {
    local node="$1" pv="$2"
    node_debug_exec "$node" sh -c "
        mp=\$(ls -d /var/lib/kubelet/pods/*/volumes/kubernetes.io~csi/$pv/mount 2>/dev/null | head -1)
        [ -n \"\$mp\" ] || exit 1
        echo \"MOUNTPOINT=\$mp\"
        findmnt -no FSTYPE,SOURCE \"\$mp\" 2>/dev/null
    "
}

capture_node_cephfs_layer() {
    local pv="$1"
    info "=== Layer C: node $NODE_NAME, CephFS mount for PV $pv ==="

    local out mountpoint fstype source
    out=$(find_cephfs_mount "$NODE_NAME" "$pv")
    if [[ -z "$out" ]]; then
        warn "  could not locate the kubelet mount point for PV $pv on $NODE_NAME"
        return 0
    fi
    echo "$out" > "$OUTPUT_DIR/node-cephfs-mount-${pv}.txt"

    mountpoint=$(grep -o 'MOUNTPOINT=.*' <<<"$out" | cut -d= -f2-)
    fstype=$(grep -v '^MOUNTPOINT=' <<<"$out" | awk 'NF{print $1; exit}')
    source=$(grep -v '^MOUNTPOINT=' <<<"$out" | awk 'NF{print $2; exit}')
    info "  mount: type=${fstype:-unknown} source=${source:-unknown} path=${mountpoint:-unknown}"
    NODE_CEPHFS_RESULT["$pv"]="mount_type=${fstype:-unknown} source=${source:-unknown}"

    if [[ "$fstype" != "ceph" ]]; then
        info "  not a kernel cephfs mount (fstype=${fstype:-unknown}) -- ceph-fuse doesn't expose comparable kernel client metrics here, skipping"
        return 0
    fi

    local dbgdir
    dbgdir=$(node_debug_exec "$NODE_NAME" sh -c 'ls -d /sys/kernel/debug/ceph/*/ 2>/dev/null' | head -1)
    if [[ -z "$dbgdir" ]]; then
        warn "  no /sys/kernel/debug/ceph/*/ client dir found on $NODE_NAME (debugfs not mounted, or no permission) -- skipping kernel client metrics"
        return 0
    fi

    info "  sampling kernel cephfs client metrics in $dbgdir over ${DURATION}s (raw, best-effort -- format varies by kernel)"
    local m0 m1
    m0=$(node_debug_exec "$NODE_NAME" cat "${dbgdir}metrics/latency" 2>/dev/null || true)
    sleep "$DURATION"
    m1=$(node_debug_exec "$NODE_NAME" cat "${dbgdir}metrics/latency" 2>/dev/null || true)
    {
        echo "--- $dbgdir metrics/latency snapshot 1 ---"; echo "$m0"
        echo "--- $dbgdir metrics/latency snapshot 2 ---"; echo "$m1"
    } > "$OUTPUT_DIR/node-cephfs-client-metrics.txt"

    if [[ -n "$m1" ]]; then
        info "  raw kernel client latency counters saved to $OUTPUT_DIR/node-cephfs-client-metrics.txt"
        sed 's/^/    /' <<<"$m1"
    else
        warn "  could not read metrics/latency under $dbgdir (older kernel? check $OUTPUT_DIR/node-cephfs-client-metrics.txt)"
    fi
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

    info "  ceph fs status (MDS/session state):"
    if ceph_exec fs status > "$OUTPUT_DIR/ceph-fs-status.txt"; then
        sed 's/^/    /' "$OUTPUT_DIR/ceph-fs-status.txt"
    else
        warn "  'ceph fs status' failed"
    fi

    ceph_exec osd df > "$OUTPUT_DIR/ceph-osd-df.txt" || warn "  'ceph osd df' failed"

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

# ---- SELinux relabeling risk check -----------------------------------------

check_selinux_relabel() {
    info "=== SELinux relabeling risk check ==="

    local enforce
    enforce=$(node_debug_exec "$NODE_NAME" cat /sys/fs/selinux/enforce 2>/dev/null || true)
    if [[ -z "$enforce" ]]; then
        warn "  could not read SELinux enforcement state on $NODE_NAME -- skipping this check"
        return 0
    fi
    if [[ "$enforce" != "1" ]]; then
        info "  SELinux is not enforcing on $NODE_NAME -- relabeling isn't a factor here"
        SELINUX_RISK=0
        return 0
    fi

    local risky_pvcs=() i
    for i in "${!DISK_PVC[@]}"; do
        if [[ "${DISK_ACCESSMODES[$i]}" == *ReadWriteMany* || "${DISK_ACCESSMODES[$i]}" == *ReadOnlyMany* ]]; then
            risky_pvcs+=("${DISK_PVC[$i]} (${DISK_ACCESSMODES[$i]})")
        fi
    done

    if [[ ${#risky_pvcs[@]} -eq 0 ]]; then
        info "  no ReadWriteMany/ReadOnlyMany CephFS PVCs on this pod -- lower relabeling risk"
        SELINUX_RISK=0
        return 0
    fi

    SELINUX_RISK=1
    warn "  SELinux is enforcing on $NODE_NAME and this pod uses CephFS PVC(s) with access mode(s) that cannot use"
    warn "  the SELinux mount optimization (that only applies to ReadWriteOncePod volumes):"
    local p
    for p in "${risky_pvcs[@]}"; do warn "    - $p"; done
    warn "  CephFS does not support mount-time SELinux context, so kubelet must recursively relabel every file in"
    warn "  the volume on first mount into this pod's SELinux context. On a large volume this can make pod startup"
    warn "  extremely slow, and can look like an I/O bottleneck when it's actually a one-time relabel walk."

    local events
    events=$(oc get events -n "$NAMESPACE" --field-selector "involvedObject.name=$POD_NAME" -o json 2>/dev/null \
        | jq -r '.items[] | select((.reason=="FailedMount") or (.message // "" | test("relabel"; "i"))) | "\(.lastTimestamp)  \(.reason): \(.message)"' 2>/dev/null || true)
    if [[ -n "$events" ]]; then
        echo "$events" > "$OUTPUT_DIR/pod-events-selinux.txt"
        warn "  corroborating pod events (see $OUTPUT_DIR/pod-events-selinux.txt):"
        sed 's/^/    /' <<<"$events" | while IFS= read -r line; do warn "$line"; done
    fi

    warn "  Red Hat KCS: $SELINUX_KCS_TITLE"
    warn "    $SELINUX_KCS_URL"
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
    echo "-- Layer C: node CephFS mount --"
    if [[ -z "${NODE_CEPHFS_RESULT[*]+set}" ]]; then
        echo "  no data"
    else
        for k in "${!NODE_CEPHFS_RESULT[@]}"; do echo "  $k: ${NODE_CEPHFS_RESULT[$k]}"; done
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
    echo "-- SELinux relabeling risk --"
    if [[ "${SELINUX_RISK:-}" == "1" ]]; then
        echo "  [WARN] structural risk present (SELinux enforcing + non-ReadWriteOncePod CephFS PVC)"
        echo "         $SELINUX_KCS_TITLE"
        echo "         $SELINUX_KCS_URL"
    elif [[ "${SELINUX_RISK:-}" == "0" ]]; then
        echo "  no risk indicators found"
    else
        echo "  not checked"
    fi

    echo
    echo "-- Heuristic --"
    local osd_daemon_flag=0 osd_disk_flag=0
    local v
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

    if [[ "${SELINUX_RISK:-}" == "1" ]]; then
        echo "  -> If the slowness is at pod startup specifically (not steady-state read/write), check the SELinux relabeling risk above first --"
        echo "     it's a one-time recursive relabel, not an ongoing storage bottleneck, and won't show up as OSD or disk latency."
    fi
    if [[ $osd_daemon_flag -eq 1 && $osd_disk_flag -eq 0 ]]; then
        echo "  -> Ceph OSD daemons show latency but their disks are healthy: look at OSD host CPU/network, not the drives."
    fi
    if [[ $osd_daemon_flag -eq 0 && $osd_disk_flag -eq 0 && "${SELINUX_RISK:-}" != "1" ]]; then
        echo "  -> No layer crossed its warning threshold during this sample. If the app is still slow, re-run during the actual slow window,"
        echo "     increase --duration to catch bursts, or check the app's own request queueing with --exec-cmd."
    fi

    echo
    echo "Raw captures saved under: $OUTPUT_DIR"
}

# ---- main --------------------------------------------------------------------

resolve_pod

[[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="./app-cephfs-diag-${POD_NAME}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTPUT_DIR"
info "raw captures will be saved under $OUTPUT_DIR"

resolve_disks

declare -A APP_CGROUP_RESULT
declare -A NODE_CEPHFS_RESULT
declare -A OSD_DISK_RESULT
TOP_OSD_LIST=""
SELINUX_RISK=""

capture_pod_cgroup_layer || warn "layer B (pod cgroup) failed"

if [[ $SKIP_NODE_MOUNT -eq 0 ]]; then
    for i in "${!DISK_PV[@]}"; do
        capture_node_cephfs_layer "${DISK_PV[$i]}" || warn "layer C failed for PV ${DISK_PV[$i]}"
    done
else
    info "skipping layer C (--skip-node-mount)"
fi

capture_ceph_layer || warn "layer D (Ceph cluster) failed"

if [[ $SKIP_OSD_DISKS -eq 0 ]]; then
    capture_osd_disk_layer || warn "layer E (bare-metal OSD disks) failed"
else
    info "skipping layer E (--skip-osd-disks)"
fi

if [[ $SKIP_SELINUX_CHECK -eq 0 ]]; then
    check_selinux_relabel || warn "SELinux relabeling check failed"
else
    info "skipping SELinux relabeling check (--skip-selinux-check)"
fi

capture_app_exec_layer || warn "extra exec-cmd layer failed"

print_summary
