# script-collection-pub

Bash scripts for testing and troubleshooting **OpenShift Data Foundation (ODF) / Ceph** storage on OpenShift:

- **Workload generators** keep real, verifiable I/O running against CephFS, RBD, NooBaa, or RGW.
- **Diagnostics** walk the I/O path layer by layer to find where latency comes from, or why ODF disaster-recovery peering is failing.

They're written for short-lived lab and reproduction clusters, but the diagnostics are read-only and safe to run on production clusters.

| Script | Type | What it does |
|---|---|---|
| [`deploy-busybox-app.sh`](#deploy-busybox-appsh) | Workload | Deployment + PVC with a verified write loop. Supports RWO/RWX/RWOP, Filesystem/Block, and integrity checks. |
| [`deploy-busybox-statefulset-app.sh`](#deploy-busybox-statefulset-appsh) | Workload | StatefulSet with per-pod or shared volumes, including shared raw block (VM-disk style). |
| [`deploy-s3-workload.sh`](#deploy-s3-workloadsh) | Workload | Parallel, bounded and verified S3 object writes to NooBaa (MCG) or Ceph RGW through an ObjectBucketClaim, with integrity checks. |
| [`diagnose-app-rbd-iops-path.sh`](#diagnose-app-rbd-iops-pathsh) | Diagnostic | Layered I/O latency for an app pod on an RBD PVC: pod, node `/dev/rbdN`, Ceph, OSD disks. |
| [`diagnose-app-cephfs-iops-path.sh`](#diagnose-app-cephfs-iops-pathsh) | Diagnostic | The same for CephFS PVCs, plus a check for SELinux relabeling risk. |
| [`diagnose-vm-iops-path-v2.sh`](#diagnose-vm-iops-path-v2sh) | Diagnostic | Layered I/O latency for a KubeVirt VM on RBD: QEMU, node, Ceph, OSD disks. |
| [`mirrorpeer-storageclusterpeer-diag.sh`](#mirrorpeer-storageclusterpeer-diagsh) | Diagnostic | Why ODF Regional-DR / Metro-DR peering (MirrorPeer / StorageClusterPeer) is failing. |

## Requirements

- `bash` 4+ and `oc`, logged in to the target cluster.
- The diagnostics also need `jq` and `awk`. `mirrorpeer-storageclusterpeer-diag.sh` also needs `column`.
- The diagnostics need cluster-admin-level access: they run `oc debug node/...` and `oc rsh` into the `rook-ceph-operator` pod.
- ODF's default StorageClasses (`ocs-storagecluster-cephfs` and `ocs-storagecluster-ceph-rbd`) are assumed unless you pass `-s` / `--storage-class`.

Every script has built-in help:

```bash
./<script>.sh --help
```

Some scripts aren't executable in the repo. Either run them with `bash <script>.sh` or run `chmod +x *.sh` once after cloning.

---

## Workload generators

### `deploy-busybox-app.sh`

Deploys a busybox Deployment and PVC that writes **fsync'd random data** to the volume on a schedule, so the data reaches the Ceph OSDs instead of sitting in page cache and can't be compressed away. Blob files are reused in a ring, so disk usage stays capped (`--max-mb`) while the volume keeps getting steady write I/O.

After deploying, the script **checks that data is really landing on the volume** and fails if it isn't. On failure it prints pod, PVC and log diagnostics, along with the mount, permissions and SELinux labels from inside the pod. A failed write also makes the container exit, so a broken volume shows up as `CrashLoopBackOff` instead of a pod that looks healthy.

| Mode | Behavior |
|---|---|
| `--access-mode RWO` (default) | One pod. Filesystem is mounted at `/data`. |
| `--access-mode RWX` | `-r` pods (default 2) share one CephFS volume and prefer separate nodes. Each pod has its own blob ring, and the script checks that every pod sees every other pod's writes. |
| `--access-mode RWOP` | Like RWO, plus a negative test: a probe pod mounting the same PVC must be refused by the scheduler. |
| `--volume-mode Block` | The PVC is attached as the raw device `/dev/xvda` (RBD, no filesystem). A header records the pod, a write counter and timestamps. |

```bash
# defaults: 1Gi CephFS RWO, 4 MiB every 5s, 256 MiB on-disk cap
./deploy-busybox-app.sh --create-namespace

# 3 pods sharing one CephFS RWX volume
./deploy-busybox-app.sh -n rwx-test --access-mode RWX -r 3 --size 2Gi

# raw RBD block device
./deploy-busybox-app.sh -n blk-test --volume-mode Block

# heavier load: ~16 MiB/s, up to 4 GiB kept
./deploy-busybox-app.sh -n load-test --size 5Gi --write-mb 32 --interval 2 --max-mb 4096
```

#### Integrity checking: did the data survive?

Use `--verify-integrity` when deploying, then `--verify-only` after any disruptive operation, such as a migration, restore, failover, PVC recovery, node drain or upgrade:

```bash
./deploy-busybox-app.sh -n mig-test --verify-integrity
# ... perform the migration / recovery ...
./deploy-busybox-app.sh -n mig-test --verify-only     # PASS / FAIL, exit code 0 / 1
```

- Every blob's sha256 is stored **on the volume itself**. A blob's entry is removed before the blob is rewritten and added back afterwards, so a write in progress is never reported as corruption.
- `--verify-only` rereads every recorded blob with `O_DIRECT`, so the data comes from Ceph rather than page cache where that's supported. It reports checksum mismatches, missing blobs and whether pods can see each other's writes.
- It also prints the volume's **history** (first and last write). If the first write is more recent than your operation, the volume was silently replaced with an empty one.
- Settings are read from the running pods, so `--verify-only` only needs the same `-n` / `--name` you deployed with.

### `deploy-busybox-statefulset-app.sh`

The StatefulSet counterpart of the Deployment script, with the same options and the same verification. Pods are `<name>-0..N` (default 3) and start in order, and a headless Service gives each one a stable DNS name.

| Mode | Volumes |
|---|---|
| RWO / RWOP (default RWO) | A `volumeClaimTemplate` gives each pod its own PVC, `data-<name>-N`. |
| RWX, Filesystem | One shared CephFS PVC, `<name>-shared`. Each pod writes its own blob ring. |
| RWX, Block | One shared raw RBD device. Each pod writes only to a fixed region based on its ordinal, the way OpenShift Virtualization shares an RWX disk between VM pods. |

```bash
./deploy-busybox-statefulset-app.sh --create-namespace

# shared raw block device across 3 pods, integrity-tracked
./deploy-busybox-statefulset-app.sh -n blk-rwx --access-mode RWX --volume-mode Block --size 2Gi --verify-integrity
./deploy-busybox-statefulset-app.sh -n blk-rwx --verify-only
```

> **Cleanup:** deleting a StatefulSet does **not** delete its PVCs. The script prints the full cleanup command when it finishes:
> `oc delete statefulset,service -n <ns> <name> && oc delete pvc -n <ns> -l app=<name>`

Both busybox scripts label their resources only with `app=<name>` and `app.kubernetes.io/name=<name>`, with no `managed-by` or `instance` labels. Tools that skip operator-owned volumes will therefore treat them as ordinary user workloads.

### `deploy-s3-workload.sh`

Deploys a StatefulSet that continuously writes objects to an S3 bucket. The bucket is provisioned through an **ObjectBucketClaim**, so the same script works against **NooBaa (MCG)** or **Ceph RGW**. The backend is chosen by auto-detecting the StorageClass, or by passing one explicitly.

- **Write load.** Each pod runs `--workers` parallel writers. Every `--interval` seconds, each writer uploads `--batch` objects of random data in a single `aws s3 cp` call, so the uploads run concurrently. Objects larger than 8 MiB are uploaded as multipart.
- **Bounded storage.** Each writer keeps a ring of `--keep-count` objects. Every upload replaces an older object, so stored data stays capped while the backend gets steady PUT and DELETE traffic. Deleted space is reclaimed asynchronously by RGW garbage collection or NooBaa, so raw usage can run above the cap for a while.
- **Verified.** After deploying, the script checks that rounds are completing and reads the newest object back from the bucket. If a round keeps failing, the pod exits, so a broken endpoint or bucket shows up as `CrashLoopBackOff` instead of a pod that looks healthy.
- **Integrity always on.** Each object's sha256 is part of its key (`workload/<pod>/w<n>/s<slot>-<sha256>.bin`). `--verify-only` downloads every object, checks it against its key, and reports the bucket's history from a `first-write` marker per pod. A missing marker means the bucket was emptied or recreated.

```bash
# defaults: NooBaa, 4 x 4 MiB objects every 5s (~192 MiB/min), 256 MiB kept
./deploy-s3-workload.sh

# RGW, heavy: 2 pods x 4 writers x 8 x 16 MiB (multipart), back-to-back, 4 GiB kept
./deploy-s3-workload.sh --backend rgw -r 2 -w 4 -B 8 -s 16M -i 0 -c 32

# check every object after a migration / failover / upgrade (PASS/FAIL)
./deploy-s3-workload.sh --backend rgw --verify-only

# tear down (the bucket goes with the OBC; the namespace is kept)
./deploy-s3-workload.sh --cleanup
```

The memory limit scales with `--workers` (256Mi + 192Mi per writer), because each writer runs its own AWS CLI. The AWS CLI is set to add checksums only when the server requires them, because the per-request checksums that newer CLIs add by default aren't supported by every S3-compatible store.

---

## Diagnostics

The three IOPS-path scripts sample I/O at **each hop** between the workload and the physical disks, then print a table showing which hop adds the latency, so you don't have to guess.

| Layer | Source |
|---|---|
| **[B]** workload | Pod: container cgroup `io.stat`. VM: `virsh domblkstat` on the QEMU domain. |
| **[C]** worker node | RBD: `/sys/block/rbdN/stat`, computed the way `iostat -x` does but without needing sysstat on RHCOS. CephFS: kernel vs FUSE mount detection plus debugfs client metrics. |
| **[D]** Ceph cluster | `ceph -s`, `health detail`, `osd perf`, `osd df`, `osd pool stats` (and `fs status` for CephFS). |
| **[E]** OSD disks | The worst-latency OSDs mapped to host and device, and sampled when those hosts are OpenShift nodes (internal/hyperconverged ODF). |

**How to read it:** if latency is high at **[C]** but the physical disks at **[E]** are healthy and lightly used, the bottleneck is above the drives: OSD CPU, replication, or the Ceph network.

Shared behavior:

- **Read-only.** The scripts never modify the workload, PVC, PV or Ceph. Their only side effect is short-lived, self-cleaning `oc debug node/...` pods.
- **No toolbox needed.** `ceph` commands run inside the always-present `rook-ceph-operator` pod. Adjust with `--ceph-namespace`, `--ceph-pod-selector` and `--ceph-args`.
- Raw captures are saved to an output directory (`-o`). The sampling window is set with `-d` (default 10s).

### `diagnose-app-rbd-iops-path.sh`

For an application pod on an RBD-backed PVC.

```bash
./diagnose-app-rbd-iops-path.sh -n myapp -d 15 myapp-7c9f5d-xk2lm
./diagnose-app-rbd-iops-path.sh -n myapp -l app=myapp
```

### `diagnose-app-cephfs-iops-path.sh`

For an application pod on a CephFS-backed PVC. Layer C identifies the node-side mount instead of an RBD device, and layer D adds `ceph fs status`, because CephFS bottlenecks are often on the metadata (MDS) side.

It also flags a known **SELinux relabeling risk**. CephFS doesn't support mount-time SELinux context, so on SELinux-enforcing nodes kubelet recursively relabels every file in the volume on first mount, which can make pod startup very slow on large volumes. When the conditions are present, the script reports this with a link to the Red Hat KCS solution.

```bash
./diagnose-app-cephfs-iops-path.sh -n myapp -l app=myapp
```

### `diagnose-vm-iops-path-v2.sh`

For a **KubeVirt / OpenShift Virtualization VM** on RBD. Layer B reads the QEMU domain's block statistics.

```bash
./diagnose-vm-iops-path-v2.sh -n vms -d 15 my-vm
```

### `mirrorpeer-storageclusterpeer-diag.sh`

Diagnoses failing **ODF Regional-DR / Metro-DR** peering by checking:

- **MirrorPeer** (`multicluster.odf.openshift.io/v1alpha1`, cluster-scoped, on the **ACM hub**);
- **StorageClusterPeer** (`ocs.openshift.io/v1`, in the ODF namespace on each **managed cluster**).

Run the same script against the hub and against each managed cluster, logging in to the right context with `oc login` first. It detects which CRDs are present and runs only the sections that apply.

```bash
./mirrorpeer-storageclusterpeer-diag.sh                     # openshift-storage, logs since 4h
./mirrorpeer-storageclusterpeer-diag.sh openshift-storage 12h
```

---

## Example workflows

**Reproduce a latency problem and find the slow layer**

```bash
./deploy-busybox-app.sh -n perf --volume-mode Block --size 5Gi --write-mb 32 --interval 1 --max-mb 2048
./diagnose-app-rbd-iops-path.sh -n perf -l app=busybox-test

./deploy-busybox-app.sh -n perf-fs --access-mode RWX -r 3 --size 5Gi --write-mb 16 --interval 1 --max-mb 1024
./diagnose-app-cephfs-iops-path.sh -n perf-fs -l app=busybox-test
```

**Prove data survives a disruptive operation**

```bash
./deploy-busybox-statefulset-app.sh -n survive --verify-integrity
# ... migrate / restore / fail over / recover PVCs / upgrade ...
./deploy-busybox-statefulset-app.sh -n survive --verify-only

# object storage: same idea
./deploy-s3-workload.sh --backend rgw
# ... upgrade ODF / fail over / restore ...
./deploy-s3-workload.sh --backend rgw --verify-only
```

## Notes

- These are community scripts for lab, reproduction and troubleshooting work. They are **not** an officially supported Red Hat product.
- The workload generators create resources and write data. Point them at a namespace you own, and clean up afterwards.
- Workload pods use the public `busybox:1.36` image (or `aws-cli` for S3). Disconnected clusters need these images mirrored.
