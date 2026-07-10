# Week 07 — Storage Masterclass (Storage: 10% of exam + heavy overlap with Troubleshooting: 30%)

Storage is the smallest domain by weight, but it is the cheapest 10% on the exam: the object model is tiny (PV, PVC, StorageClass, pod volume stanza), the failure modes are enumerable, and every task type is drillable to under 8 minutes. It also double-dips into Troubleshooting — "PVC stuck Pending" and "pod stuck ContainerCreating on a volume" are classic troubleshooting-domain tasks. Master this week and you bank points in two domains.

Version note: behavior described here matches current exam-era Kubernetes. Where something is version-dependent it is flagged inline. Check the live exam version on the CNCF curriculum page before exam day.

---

## What the exam actually asks

| Task shape you'll see | Domain | Weight context |
|---|---|---|
| Create a PV, a PVC that binds to it, and a pod that mounts the PVC | Storage | The canonical storage task; appears in nearly every exam form |
| Create a StorageClass with a given provisioner/binding mode; make it the default | Storage | Post-Feb-2025 curriculum explicitly names dynamic provisioning |
| Expand an existing PVC | Storage | New-curriculum favorite; 2-minute task if you know the prerequisite |
| Change a PV's reclaim policy; recover a Released volume | Storage | Tests understanding of the lifecycle, not YAML typing |
| Add an emptyDir / hostPath / configMap volume to an existing pod spec | Storage / Workloads | Usually embedded inside a bigger task |
| PVC Pending — find out why and fix | Troubleshooting | 30% domain; storage is a favorite failure injection |
| Pod stuck ContainerCreating with FailedMount | Troubleshooting | Missing secret/configMap or unbound claim |
| StatefulSet with volumeClaimTemplates | Workloads / Storage | Know the PVC naming and retention behavior |

What the exam does NOT ask: writing a CSI driver, NFS server setup, cloud-provider parameters from memory. You need to *recognize* CSI concepts, not operate them.

---

## Volume types you will actually meet

A pod's `spec.volumes` list declares sources; each container mounts by name via `volumeMounts`. Everything below is a source type.

### emptyDir

Scratch space created when the pod is assigned to a node, deleted when the pod is removed. Survives *container* restarts (it belongs to the pod sandbox), does not survive pod deletion or rescheduling. On disk it lives under `/var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~empty-dir/<name>`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cache-demo
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sleep", "3600"]
    volumeMounts:
    - name: cache
      mountPath: /cache
    resources:
      limits:
        memory: 256Mi
  volumes:
  - name: cache
    emptyDir:
      medium: Memory      # tmpfs — RAM, not disk
      sizeLimit: 64Mi
```

Two details that decide correctness:

- `medium: Memory` makes it a tmpfs. **The bytes written count against the container's memory limit.** A "harmless" cache can OOM-kill your app. Without a `sizeLimit`, tmpfs defaults to half the node's RAM; on current exam-era versions the kubelet sizes the tmpfs to the `sizeLimit` (this sizing was feature-gated in older releases — version-dependent).
- `sizeLimit` on a disk-backed emptyDir is enforced by **kubelet eviction**, not by the filesystem: exceed it and the pod gets Evicted (visible in `k describe pod` as "Usage of EmptyDir volume ... exceeds the limit"), it does not get an ENOSPC write error immediately.

### hostPath

Mounts a path from the node's filesystem. Data is per-node: reschedule the pod to another node and the "same" path is a different (probably empty) directory. The `type` field controls the pre-mount check:

| type | Behavior |
|---|---|
| `""` (empty, default) | No check at all. Mount whatever is (or isn't) there. |
| `DirectoryOrCreate` | Create dir 0755 if absent |
| `Directory` | Must already exist, else pod stuck ContainerCreating |
| `FileOrCreate` | Create empty file if absent — **does not create parent directories**; if the parent is missing, mount fails |
| `File` | Must exist |
| `Socket` | Must exist |
| `CharDevice` / `BlockDevice` | Must exist |

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: log-reader
spec:
  containers:
  - name: reader
    image: busybox:1.36
    command: ["sleep", "3600"]
    volumeMounts:
    - name: varlog
      mountPath: /host-logs
      readOnly: true
  volumes:
  - name: varlog
    hostPath:
      path: /var/log
      type: Directory
```

hostPath is a security hole by design (node filesystem access) and gives the scheduler zero information. If a task needs node-pinned storage done "properly", the answer is a `local` PV (below), not hostPath.

### configMap, secret, downwardAPI, projected

All four project API objects as files:

- **configMap / secret volumes**: each key becomes a file. Mounted secrets are tmpfs-backed. Updates propagate to mounted files (kubelet sync, typically under ~2 minutes) via an atomic symlink swap — **except when mounted with `subPath`, which never updates**. `items:` selects specific keys; `defaultMode:` sets permissions; `optional: true` stops a missing object from blocking pod start.
- **downwardAPI**: pod metadata (labels, annotations, resource limits) as files.
- **projected**: combines configMap + secret + downwardAPI + serviceAccountToken into one mount point — one volume, several `sources`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: projected-demo
  labels:
    tier: backend
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sleep", "3600"]
    volumeMounts:
    - name: combined
      mountPath: /etc/combined
      readOnly: true
  volumes:
  - name: combined
    projected:
      sources:
      - configMap:
          name: app-config
      - secret:
          name: app-secret
      - downwardAPI:
          items:
          - path: pod-labels
            fieldRef:
              fieldPath: metadata.labels
```

The pod-visible failure mode: a referenced configMap/secret that doesn't exist leaves the pod in **ContainerCreating** with `FailedMount` events — it does not CrashLoopBackOff, because no container ever started.

### persistentVolumeClaim

The pod-side handle for everything durable:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pvc-consumer
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sleep", "3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: app-data
```

PVC is namespaced; the claim must live in the **pod's namespace**. That's it for the pod side — all the interesting machinery is in the PV/PVC/SC triangle.

---

## The PV/PVC model

**PersistentVolume** = cluster-scoped representation of a piece of storage (admin/provisioner concern). **PersistentVolumeClaim** = namespaced request for storage (user concern). The PV controller in kube-controller-manager continuously tries to match unbound PVCs to PVs.

### Static provisioning flow

1. Admin creates a PV describing existing storage (hostPath, local, NFS, a pre-created cloud disk via `csi:`).
2. User creates a PVC.
3. The PV controller finds a compatible PV and binds them: it writes `pv.spec.claimRef` (pointing at the PVC, including its UID) and `pvc.spec.volumeName`. Both go `Bound`.
4. Pod references the PVC; kubelet mounts the underlying volume.

### Binding rules — memorize these five

A PV is a candidate for a PVC iff ALL hold:

| Rule | Detail |
|---|---|
| Capacity | `pv.spec.capacity.storage` **>=** `pvc.spec.resources.requests.storage` |
| Access modes | PV's `accessModes` list is a **superset** of the PVC's requested modes |
| StorageClass | `storageClassName` strings must match **exactly** (empty string matches only PVs with no class) |
| volumeMode | Must match (`Filesystem` vs `Block`); both default to `Filesystem` |
| Selector | If the PVC sets `spec.selector`, the PV's labels must match |

Among candidates, the controller prefers the smallest PV that satisfies the request. Nuance worth knowing: for **static** binding the StorageClass *object* does not have to exist — class matching is pure string equality. The SC object only matters for dynamic provisioning and for supplying `volumeBindingMode`.

### One-to-one binding

Binding is exclusive and whole-volume. A 100Gi PV bound to a 1Gi PVC is fully consumed — the remaining 99Gi is wasted, not shareable. There is no bin-packing of claims into volumes.

Pre-binding shortcuts (both exam-relevant):

- PVC side: set `spec.volumeName: pv-name` — skips matching, binds directly to that PV (still validated against the five rules).
- PV side: set `spec.claimRef` with the target PVC's name+namespace — reserves the PV for that claim so nothing else steals it.

### PV phases

```text
Available ──bind──> Bound ──PVC deleted──> Released ──(policy Delete)──> gone
                                              │
                                              └─(policy Retain)──> stuck Released until admin acts
Failed = automated reclamation errored
```

- **Available**: unbound, matchable.
- **Bound**: exclusively attached to one PVC.
- **Released**: the PVC was deleted, but the PV still carries `claimRef` (including the dead PVC's UID). **A Released PV never rebinds automatically.**
- **Failed**: reclaim attempted and failed.

PVC phases: `Pending` (no PV yet — could be an error, could be WaitForFirstConsumer working as intended), `Bound`, `Lost` (bound PV vanished).

### Reclaim policies

| Policy | On PVC delete | Operational reality |
|---|---|---|
| `Delete` | PV object AND backing storage destroyed | Default for dynamically provisioned PVs (inherited from the SC at creation time) |
| `Retain` | PV goes `Released`; data intact | Manual recovery workflow (below) |
| `Recycle` | Deprecated. Do not use, do not answer with it | Was an `rm -rf` + rebind; removed from the curriculum |

**Released + Retain recovery** — an exam classic:

```bash
# 1. Data is still on the backing store. PV shows Released.
k get pv pv-data                     # STATUS: Released

# 2. Remove the stale claimRef -> PV returns to Available
k patch pv pv-data --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'

# 3. Create a new PVC that matches (or pre-bind with spec.volumeName)
```

The reclaim policy of an existing PV is patched directly (SC changes never touch existing PVs):

```bash
k patch pv pv-data -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

---

## Dynamic provisioning (curriculum addition — know it cold)

User creates a PVC referencing a StorageClass → a provisioner creates the PV on demand. No admin pre-creation.

### StorageClass anatomy

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-local
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rancher.io/local-path   # who creates volumes
parameters: {}                        # provisioner-specific (fs type, disk tier...)
reclaimPolicy: Delete                 # stamped onto each provisioned PV (default Delete)
allowVolumeExpansion: true            # gate for PVC expansion
volumeBindingMode: WaitForFirstConsumer
```

- `provisioner`: the driver name. For CSI it equals the CSIDriver object name (e.g. `ebs.csi.aws.com`). `kubernetes.io/no-provisioner` = "no dynamic provisioning here" — used for static local PVs that still want an SC for binding-mode semantics.
- `parameters`: opaque to Kubernetes, interpreted by the provisioner. Never invent these on the exam; copy from docs if a task specifies them.
- `reclaimPolicy` and `volumeBindingMode` are **immutable on the SC** and only affect PVs provisioned *after* any SC recreation.
- `allowVolumeExpansion` IS mutable — flipping it to true is step one of any expansion task.

### volumeBindingMode: Immediate vs WaitForFirstConsumer

- `Immediate` (default): PVC binds/provisions the moment it's created. Problem: the volume gets a location (zone, node) **before any pod exists**, so the scheduler can later be cornered — pod must run in zone A because its data landed there, but its node affinity says zone B. Result: unschedulable pod.
- `WaitForFirstConsumer` (WFFC): binding and provisioning are delayed until a pod using the PVC is scheduled. The scheduler picks the node first, taking ALL pod constraints into account, and the volume is provisioned to match that placement. **WFFC exists because of topology**: zonal cloud disks and node-local storage must be co-located with the pod, and only the scheduler knows where the pod can go.

Observable consequence: a PVC on a WFFC class sits `Pending` with event `waiting for first consumer to be created before binding` — that is *correct behavior*, not a fault. This is a deliberate exam trap.

### Default StorageClass semantics

- The default SC carries the annotation `storageclass.kubernetes.io/is-default-class: "true"`. Only one should have it (with multiple, newest wins on current versions — a misconfiguration you may be asked to fix).
- PVC with `storageClassName` **omitted** → admission fills in the default SC → dynamic provisioning.
- PVC with `storageClassName: ""` (explicit empty string) → **opts out** of dynamic provisioning entirely; will only bind statically to PVs with no class.

Those two are NOT the same and this single distinction resolves a whole family of "why is my PVC Pending" scenarios. Version note: since v1.28 (stable), a PVC created with no class while no default exists gets retroactively assigned the default SC when one appears.

Switching the default is a two-patch operation:

```bash
k patch storageclass standard -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
k patch storageclass fast-local -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
k get sc    # default is marked "(default)" next to the name
```

---

## Access modes — node-level, not pod-level

| Mode | Abbrev | Meaning |
|---|---|---|
| ReadWriteOnce | RWO | Read-write by a single **node** |
| ReadOnlyMany | ROX | Read-only by many nodes |
| ReadWriteMany | RWX | Read-write by many nodes |
| ReadWriteOncePod | RWOP | Read-write by a single **pod** (CSI-only; GA in v1.29) |

The trap: **RWO limits nodes, not pods.** Two pods on the *same node* can both write to an RWO volume simultaneously. If a task demands single-pod exclusivity, RWOP is the only correct answer (and it requires a CSI driver — kind's `local-path` is not CSI, so RWOP won't provision on the lab).

Access modes describe *capability for attachment*, not enforcement of read-only mounts — `readOnly: true` on the volumeMount is what makes a mount read-only.

---

## PVC expansion

Grow-only, never shrink. Prerequisites and flow:

1. The PVC's StorageClass has `allowVolumeExpansion: true` (patch it if not).
2. The underlying driver supports resize (CSI with an external-resizer, or the few in-tree plugins that do).
3. Edit the PVC: raise `spec.resources.requests.storage`. That is the entire user action:

```bash
k patch pvc data -p '{"spec":{"resources":{"requests":{"storage":"5Gi"}}}}'
```

4. Watch `k describe pvc data`: the volume resizes, then the filesystem. Condition `FileSystemResizePending` means the FS grow happens when a pod (re)mounts it — some drivers do it online, some need the pod restarted.
5. `status.capacity` lags `spec.resources.requests` until complete. A permanent gap = the driver can't resize (exactly what you'll observe on kind — see lab section).

You cannot expand: PVCs on classes without the flag (API rejects the edit), or statically-bound PVs by editing PV capacity (editing `pv.spec.capacity` changes a number in etcd, not the filesystem). Version note: recovering from a failed expansion by re-shrinking the *request* is gated/newer-version behavior — out of exam scope beyond knowing you can't shrink below actual size.

---

## volumeMode: Filesystem vs Block

`Filesystem` (default): the volume arrives formatted and mounted at `mountPath`. `Block`: the raw device is handed to the container — the pod uses `volumeDevices.devicePath` instead of `volumeMounts.mountPath`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: raw-claim
spec:
  accessModes: [ReadWriteOnce]
  volumeMode: Block
  resources:
    requests:
      storage: 1Gi
```

Exam-level awareness: volumeMode participates in binding (mismatch = PVC stays Pending) and it is **immutable on both PV and PVC** — a mismatch is fixed by recreating one side, not patching.

---

## local volumes vs hostPath

`local` is "hostPath done right": a PV-only source (you can't use `local:` directly in a pod) that **requires** `nodeAffinity` on the PV, which the scheduler honors — pods using the claim are automatically placed on the right node.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-local
spec:
  capacity:
    storage: 2Gi
  accessModes: [ReadWriteOnce]
  storageClassName: local-disks
  persistentVolumeReclaimPolicy: Retain
  local:
    path: /mnt/disks/ssd1
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values: [cka-worker2]
```

Pair it with a `no-provisioner` SC using WFFC so binding waits for the scheduler:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-disks
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
```

| | hostPath | local PV |
|---|---|---|
| Scheduler aware | No — pod can land on a node without the data | Yes — PV nodeAffinity steers the pod |
| Usable directly in pod | Yes | No, PV only |
| Dynamic provisioning | No (except add-ons like local-path) | No (no-provisioner; external provisioners exist) |
| API requirement | none | `nodeAffinity` mandatory — API rejects a local PV without it |
| Node dies | data gone, pod reschedules blindly | pod unschedulable ("volume node affinity conflict") — loud failure, which is what you want |

---

## CSI in one paragraph

Container Storage Interface = the plugin API that moved storage drivers out of the Kubernetes core. A driver ships a controller part (runs as a deployment with sidecars: **external-provisioner** watches PVCs whose SC `provisioner` matches the driver name and calls CreateVolume; external-attacher; external-resizer for expansion) and a node part (DaemonSet that does the actual mount for kubelet). What the exam expects: recognize `csi:` as a PV source, know `k get csidrivers` lists installed drivers, understand that the SC `provisioner` string names the driver, and reason that "dynamic provisioning stopped working" usually means the provisioner pod is dead — which you locate with `k get pods -A | grep -i -e csi -e provisioner`.

---

## StatefulSet volumeClaimTemplates

`spec.volumeClaimTemplates` stamps out one PVC per replica, named `<template-name>-<sts-name>-<ordinal>` (e.g. `www-web-0`). The behavior that gets tested:

- **Scale down does NOT delete PVCs.** Scale 3→1 and `www-web-1`, `www-web-2` stay Bound. Scale back up and pods re-attach to their old data — that's the feature.
- Deleting the StatefulSet also leaves PVCs behind (by default).
- `spec.persistentVolumeClaimRetentionPolicy` (`whenDeleted`/`whenScaled`: `Retain` or `Delete`) can change this — GA in recent versions (v1.32+); one line of awareness is enough.
- Each replica gets its OWN volume. If the task wants shared storage across replicas, that's a single RWX PVC in `spec.template.spec.volumes`, not a claim template.

---

## The kind lab: what `standard` gives you

```bash
k get sc
# NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
# standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   false
```

- Provisioner: **rancher.io/local-path** (runs in namespace `local-path-storage`). It provisions hostPath-backed PVs under `/var/local-path-provisioner/` on whichever node the first consumer pod lands on, and stamps nodeAffinity onto the PV.
- **WaitForFirstConsumer**: every bare PVC you create sits `Pending` until a pod uses it. Perfect for drilling the WFFC mental model — do it once deliberately (exercise 7) so it never surprises you.
- **Static-PV drills need an explicit class.** Because `standard` is the default, a PVC that *omits* `storageClassName` gets `standard` injected at admission and dynamically provisions a fresh volume — it will never bind to your classless static PV. For static binding on kind, give PV and PVC a matching made-up class name (e.g. `manual`) or set `storageClassName: ""` on both sides.
- Limitations vs the exam's clusters: no expansion (not CSI, no resizer — a resize request is accepted by the API but never completes), no Block mode, no RWOP, capacity is not enforced (it's a directory, `df` shows the node disk). Where an exercise hits one of these walls, the exercise says so and states what a real CSI-backed cluster would do.
- Inspect provisioned data from the host: `docker exec cka-worker ls /var/local-path-provisioner/` (exam equivalent: `ssh node01` + `sudo ls ...`).

---

## Troubleshooting storage — the decision tree

### PVC stuck Pending

`k describe pvc <name>` — the Events section names the cause almost verbatim:

| Event text (paraphrased) | Cause | Fix |
|---|---|---|
| `waiting for first consumer to be created before binding` | WFFC class, no pod yet | Not a fault. Create the consumer pod |
| `storageclass "X" not found` | PVC names a nonexistent SC | Create the SC (PVC's `storageClassName` is immutable — creating the class is usually the cheapest fix) |
| `no persistent volumes available for this claim and no storage class is set` | Static-only PVC (`""` or no default SC), no matching PV | Create/fix a PV: check all five binding rules — capacity, accessModes, class string, volumeMode, selector |
| `waiting for a volume to be created either by the external provisioner...` (and nothing happens) | Provisioner is named but broken/dead | Find and fix the provisioner pod |
| Nothing at all, cluster has no default SC | PVC omitted class, no default exists | Set the default-class annotation on an SC |

Fast context for any of these: `k get pv` (is there a candidate? what class/size/modes/status?), `k get sc` (does the class exist? is anything `(default)`? binding mode?).

### Pod stuck because of storage

- **Pending** + `pod has unbound immediate PersistentVolumeClaims` → the PVC itself is Pending: go up one level to the PVC tree above.
- **Pending** + `volume node affinity conflict` → PV (local) is pinned to a node the pod can't use — node gone, cordoned, or pod has conflicting nodeSelector/affinity.
- **ContainerCreating** + `FailedMount` / `MountVolume.SetUp failed` → mount-time failure: referenced configMap/secret doesn't exist (message names it), hostPath type check failed, or NFS/CSI backend unreachable. Fix the referenced object; kubelet retries automatically.
- **ContainerCreating** + `FailedAttachVolume` / `Multi-Attach error` → RWO volume still attached to another node (previous pod not fully gone). Delete the old pod, wait for detach.
- `k get events -n <ns> --sort-by=.lastTimestamp | tail -20` is the panoramic view when describe output is noisy.

---

## Traps

1. **"RWO means one pod."** Wrong — RWO is one *node*. Two pods co-scheduled on that node both get write access. Pod-level exclusivity is `ReadWriteOncePod`.
2. **"`storageClassName: \"\"` and omitting it are the same."** Omitted = "use the default SC" (dynamic). Empty string = "no class, static binding only". A task saying "do not use dynamic provisioning" wants the explicit `""`.
3. **"A Pending PVC is broken."** On a WFFC class, Pending-until-pod is by design. Read the event before "fixing" anything.
4. **"The PVC gets its requested size."** It binds to any PV with capacity >= request and consumes the whole PV. Requesting 1Gi and getting Bound to 100Gi is normal static-binding behavior.
5. **"Change the SC's reclaimPolicy to protect existing volumes."** SC fields stamp PVs at provision time only. To protect an existing PV: `k patch pv ... persistentVolumeReclaimPolicy: Retain` directly.
6. **"A Released PV will rebind when I recreate the PVC."** Never. The stale `claimRef` (with the old PVC's UID) blocks it. Remove `claimRef` to return it to Available.
7. **"I'll fix the mismatch by editing the PVC."** Almost everything on a bound-or-not PVC is immutable: accessModes, storageClassName, volumeMode, selector. Only `resources.requests.storage` can change (grow, and only with allowVolumeExpansion). Usually you edit the PV or recreate the PVC.
8. **"volumeMode can be patched to fix a Block/Filesystem mismatch."** Immutable on both sides. Delete and recreate one side.
9. **"hostPath data follows the pod."** Per-node. After rescheduling, the pod sees the other node's path. Node-pinned data = local PV with nodeAffinity.
10. **"emptyDir medium: Memory is a free cache."** It's tmpfs: usage counts against the container memory limit, and blowing past `sizeLimit` gets the pod evicted.
11. **"PVs live in namespaces."** PV and StorageClass are cluster-scoped; PVC is namespaced and must be in the pod's namespace. `k get pv -n foo` silently ignores the `-n` — don't let it mislead you.
12. **"Missing volume source → CrashLoopBackOff."** No: the container never starts, so the pod hangs in ContainerCreating with FailedMount events. CrashLoop means the volume mounted fine and the app died.
13. **"Recycle is a valid reclaim policy answer."** Deprecated. Retain or Delete.
14. **"`k create pvc` will scaffold it for me."** No imperative command exists for PV, PVC, or SC. Your options are a memorized heredoc or the docs page. Decide *before* the exam which one you use.
15. **"FileOrCreate creates the whole path."** It creates the file only; missing parent directories fail the mount. Pre-create dirs with `DirectoryOrCreate` or an initContainer.

---

## Speed patterns

**The PVC heredoc — memorize this, it's the highest-frequency storage object:**

```bash
cat <<EOF | k apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: standard
EOF
```

Six spec lines. Drill until you type it in under 60 seconds. Drop `storageClassName` to take the default; set `""` to force static.

**PV and pod-with-PVC — don't memorize, copy.** The docs task page "Configure a Pod to Use a PersistentVolume for Storage" contains a hostPath PV, a matching PVC, and a consuming pod, in that order. One search, three copy-pastes, adjust names/sizes. This is the fastest exam-legal route for the full chain.

**Pod skeleton first, volumes second:**

```bash
k run cache --image=busybox:1.36 $do -- sleep 3600 > pod.yaml
# then add volumes: + volumeMounts: blocks in vim
```

**Field-name amnesia → `k explain`, not docs:**

```bash
k explain pv.spec --recursive | less        # /local, /nodeAffinity to search
k explain pvc.spec
k explain pod.spec.volumes --recursive | grep -A3 emptyDir
k explain sc                                # top-level: provisioner, reclaimPolicy...
```

**One-liner patches (exam gold — no YAML editing at all):**

```bash
# reclaim policy of a PV
k patch pv PVNAME -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
# free a Released PV
k patch pv PVNAME --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'
# switch default SC (two patches)
k patch sc standard -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
k patch sc fast -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
# allow expansion, then expand
k patch sc standard -p '{"allowVolumeExpansion":true}'
k patch pvc data -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
```

**Status sweep, always in this order:**

```bash
k get sc                                   # classes, default marker, binding mode
k get pv                                   # capacity/modes/reclaim/status/claim
k get pvc -A                               # who's Pending, where
k describe pvc NAME | tail -8              # the answer is in Events
k get events --sort-by=.lastTimestamp | tail -20
```

**Watch a binding happen** (WFFC drills, rebind drills): `k get pvc -w` in one tmux pane while you create the pod in the other.

---

## Docs map

| You need | kubernetes.io path |
|---|---|
| PV/PVC everything: phases, binding, reclaim, expansion, `""` semantics | /docs/concepts/storage/persistent-volumes/ |
| Complete PV + PVC + pod worked example (copy-paste source) | /docs/tasks/configure-pod-container/configure-persistent-volume-storage/ |
| StorageClass fields, default-class annotation, per-provisioner parameters | /docs/concepts/storage/storage-classes/ |
| Dynamic provisioning concepts | /docs/concepts/storage/dynamic-provisioning/ |
| emptyDir, hostPath (+types), local, csi volume sources | /docs/concepts/storage/volumes/ |
| Projected volumes | /docs/concepts/storage/projected-volumes/ |
| Expand a PVC | /docs/concepts/storage/persistent-volumes/#expanding-persistent-volumes-claims |
| Change the default StorageClass | /docs/tasks/administer-cluster/change-default-storage-class/ |
| Change a PV's reclaim policy | /docs/tasks/administer-cluster/change-pv-reclaim-policy/ |
| StatefulSet volumeClaimTemplates | /docs/concepts/workloads/controllers/statefulset/ |
| ConfigMap/Secret as volumes | /docs/concepts/configuration/configmap/ (and /secret/) |
| Storage capacity / WFFC and topology background | /docs/concepts/storage/storage-capacity/ |

Search terms that land on the right page first try: "persistent volumes", "storage classes", "configure persistent volume storage", "projected volumes", "change reclaim policy".

---

## Checkpoint

Self-test on the kind lab. Clock every item; exam pace is the *upper* bound.

- Can you write a PVC from memory (no docs) in **90 seconds**?
- Can you build the full static chain — PV, PVC, pod, verify Bound and a file written — in **6 minutes** using the docs task page?
- Can you diagnose an arbitrary PVC Pending to its root cause (WFFC vs missing SC vs no matching PV vs mismatch) in **3 minutes**, citing the event line as evidence?
- Can you create a StorageClass with a specified provisioner and WFFC, and make it the cluster default (verifying with `k get sc`), in **3 minutes**?
- Can you state the five binding rules from memory in **30 seconds**?
- Can you take a Bound dynamically-provisioned PV to Retain, delete the PVC, free the Released PV, and rebind it to a new claim — data intact — in **8 minutes**?
- Can you expand a PVC (including flipping allowVolumeExpansion first) in **2 minutes**?
- Can you explain in one sentence why WaitForFirstConsumer exists, and spot it as the reason a PVC is Pending in **under 1 minute**?
- Can you deploy a 3-replica StatefulSet with a volumeClaimTemplate, scale it down, and predict exactly which PVCs remain, in **8 minutes**?
- Can you fix a pod stuck ContainerCreating on a missing configMap volume in **4 minutes**?
