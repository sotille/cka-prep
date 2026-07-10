# Week 07 — Storage Masterclass (Storage 10%, feeds Troubleshooting 30% and Workloads & Scheduling 15%)

Storage is the smallest scored domain (10%) but the highest points-per-minute if you have the small YAML shapes memorized, because unlike RBAC there is **no imperative generator for PVs, PVCs, or StorageClasses** — `kubectl create pv` does not exist. The exam pays you for knowing four tiny manifests cold and for reading three fields off `kubectl describe pvc`. The other half of the value is diagnostic: a "PVC stuck Pending" or "pod stuck ContainerCreating" scenario lands in the 30% Troubleshooting domain, and volume mounts (configMap/secret/emptyDir/projected) are half of the 15% Workloads domain. This module covers the ephemeral volume layer, the static PV/PVC binding algorithm, dynamic provisioning and StorageClass internals, access modes, reclaim policies, expansion, block vs filesystem, local vs hostPath, CSI, and StatefulSet claim templates — with the kind lab's `rancher.io/local-path` default class as the live demo rig.

Version caveat up front: everything targets the post-Feb-2025 curriculum on Kubernetes v1.33+ (the lab runs v1.36). Dynamic provisioning, expansion, and CSI awareness are curriculum additions. Confirm the live competency list on the CNCF curriculum page before exam day.

---

## What the exam actually asks

| Topic | Domain | Weight contribution | Typical task |
|---|---|---|---|
| Mount configMap/secret/emptyDir into a pod | Workloads & Scheduling | 15% domain | "Mount the configmap `app-cfg` at `/etc/app` read-only" |
| Static PV + PVC + pod binding chain | Storage | 10% domain core | "Create a PV of 2Gi hostPath, a PVC that binds it, mount it in a pod" |
| Create a StorageClass / set the default | Storage | 10% domain | "Make `fast` the default StorageClass" |
| Diagnose PVC Pending | Troubleshooting | 30% domain | "PVC `data` won't bind. Fix it." |
| Diagnose pod stuck ContainerCreating | Troubleshooting | 30% domain | "Pod references a volume that doesn't exist — fix so it runs" |
| Expand a PVC | Storage | 10% domain | "Grow PVC `logs` from 1Gi to 3Gi" |
| Reclaim policy / rebind a Retain PV | Storage | 10% domain | "Reuse the released PV for a new claim" |
| StatefulSet with volumeClaimTemplates | Workloads / Storage | crosses both | "Deploy a 3-replica StatefulSet each with its own 1Gi volume" |

Realistic expectation: 1–2 tasks (roughly 6–10% of total points) land squarely on this module, plus volume-mount subtasks embedded in Workloads questions and a likely PVC/mount diagnosis in Troubleshooting. Storage tasks are fast wins **if** you don't have to look up YAML shapes — that is the whole game here.

---

## The two-layer model: ephemeral volumes vs persistent volumes

Kubernetes storage splits cleanly into two layers with different lifecycles. Getting this distinction straight prevents most conceptual mistakes.

```text
Layer 1 — Volume (pod.spec.volumes[])            Layer 2 — PersistentVolume (cluster object)
 lifetime tied to the POD                          lifetime tied to the CLUSTER
 declared inline in the pod                        an admin/provisioner creates it
 emptyDir, hostPath, configMap, secret,            claimed via a PVC (namespaced request)
   downwardAPI, projected, and the                 survives pod deletion
   persistentVolumeClaim reference                 survives pod rescheduling
```

A `persistentVolumeClaim` is itself just one kind of entry in `pod.spec.volumes[]` — it is the bridge from layer 1 into layer 2. Everything else in `pod.spec.volumes[]` (emptyDir, configMap, secret…) is layer-1 ephemeral: it is born and dies with the pod. The exam tests both layers; do not conflate them.

### emptyDir — scratch space that dies with the pod

An `emptyDir` is created empty when the pod is assigned to a node and deleted permanently when the pod is removed from that node. It survives **container** restarts (a crashing container in the pod keeps the data) but not **pod** deletion or rescheduling. Two knobs matter on the exam:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cache-demo
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    resources:
      limits:
        memory: 256Mi          # memory-medium emptyDir counts against THIS limit
    volumeMounts:
    - name: scratch
      mountPath: /scratch
    - name: ramcache
      mountPath: /ramcache
  volumes:
  - name: scratch
    emptyDir:
      sizeLimit: 500Mi          # pod is evicted if it exceeds this on disk
  - name: ramcache
    emptyDir:
      medium: Memory            # tmpfs, RAM-backed
      sizeLimit: 128Mi
```

- **`medium: Memory`** backs the volume with a tmpfs (RAM). It is fast and always wiped on node reboot. Critically, on modern Kubernetes the memory a tmpfs emptyDir consumes **counts against the container's memory limit** — write 200Mi into a RAM emptyDir in a container limited to 256Mi and you risk an OOM kill, not a disk-full error. This is the trap the exam-style "memory cache" task is probing.
- **`sizeLimit`** caps the volume. Exceed it and the **pod is evicted** by the kubelet — eviction is the enforcement mechanism, not a write-time error for disk-backed dirs. For `medium: Memory`, `sizeLimit` also caps the tmpfs size.
- Without `medium: Memory`, an emptyDir lives on the node's kubelet directory (the node root disk by default), not in RAM.

### hostPath — a path on the node, and its `type` field

`hostPath` mounts a file or directory from the **node's** filesystem into the pod. It is powerful and dangerous: no scheduling awareness (the pod may land on a different node next time and see different or empty data), and Pod Security Admission `baseline`/`restricted` forbid it outright. The `type` field is a validation/creation directive that the exam likes to test because omitting it changes behavior:

| `type` value | Behavior |
|---|---|
| `""` (default, unset) | No checks performed. Mounts whatever is there; missing path is left to the runtime. |
| `DirectoryOrCreate` | If the path doesn't exist, create an empty directory (0755, owned by kubelet). |
| `Directory` | Path **must** already exist as a directory, else the pod fails to mount. |
| `FileOrCreate` | Create an empty file if absent (parent dir must exist). |
| `File` | Path must already exist as a file. |
| `Socket` | Path must be an existing UNIX socket. |
| `CharDevice` / `BlockDevice` | Path must be an existing char/block device node. |

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hostpath-demo
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: node-logs
      mountPath: /host-logs
      readOnly: true
  volumes:
  - name: node-logs
    hostPath:
      path: /var/log
      type: Directory          # fail fast if the dir isn't there
```

The `readOnly: true` on the **volumeMount** is how you satisfy "mount X read-only" — a frequent exam phrasing. `readOnly` belongs on the mount, not (for hostPath) on the volume source.

### configMap, secret, downwardAPI, projected — data as files

These four surface Kubernetes objects or pod metadata as files inside the container. All are mounted **read-only** and (except `subPath` mounts) are refreshed when the source changes.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: projected-demo
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: cfg
      mountPath: /etc/app
      readOnly: true
    - name: combined
      mountPath: /etc/combined
      readOnly: true
  volumes:
  - name: cfg
    configMap:
      name: app-cfg
      defaultMode: 0644           # octal; permission of projected files
      items:                      # optional: pick specific keys and rename
      - key: app.properties
        path: application.properties
  - name: combined
    projected:                    # merge multiple sources under one mountPath
      sources:
      - configMap:
          name: app-cfg
      - secret:
          name: app-secret
      - downwardAPI:
          items:
          - path: pod-name
            fieldRef:
              fieldPath: metadata.name
```

- **`defaultMode`** is an **octal** permission (`0644`, `0400`). Write it with the leading zero — `defaultMode: 644` is decimal 644 = octal 1204 = nonsense permissions. A classic silent points-loser.
- **`items`** projects only selected keys and can rename them (`key` → `path`). Without `items`, every key becomes a file named after the key.
- **`projected`** unifies configMap, secret, downwardAPI, and serviceAccountToken under a single mount — this is exactly how the default SA token is now mounted (`/var/run/secrets/kubernetes.io/serviceaccount`).
- **`downwardAPI`** as a **volume/projected file** exposes only `metadata.*` fields via `fieldRef` (`metadata.name`, `metadata.namespace`, `metadata.labels`, `metadata.annotations`, `metadata.uid`) plus container resource values via `resourceFieldRef`. Runtime fields like `status.podIP`, `status.hostIP`, and `spec.nodeName` are valid **only as environment variables** (`env[].valueFrom.fieldRef`), never as volume files — put `fieldPath: status.podIP` in a downwardAPI volume item and the API server rejects the manifest with `fieldPath status.podIP is not supported`.

There is no volume generator, but `kubectl create configmap`/`create secret` are imperative; you hand-edit the pod to add the mount. Fastest path: `k run app --image=busybox:1.36 $do -- sleep 3600 > pod.yaml`, then paste the volume block from memory.

### nfs — networked storage that survives the pod and does real RWX

An `nfs` volume mounts an export from an NFS server. Unlike `emptyDir`/`hostPath` it is **not** node-local: the same export can be mounted read-write by pods on **many** nodes at once, which is exactly why NFS (and CephFS) is the usual backing for genuine `ReadWriteMany`. There is no in-tree dynamic provisioner for it — you either reference it inline in a pod or wrap it in a static PV.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nfs-demo
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: share
      mountPath: /data
  volumes:
  - name: share
    nfs:
      server: 10.0.0.10        # NFS server IP or DNS name
      path: /exports/data      # exported path on that server
      readOnly: false
```

The same three fields (`server`, `path`, `readOnly`) live under `spec.nfs` of a PersistentVolume when you want it claimed via a PVC rather than mounted inline — that PV can advertise `ReadWriteMany`, and unlike a hostPath PV the mount actually works from any node. NFS is rarely tested directly on the CKA and is awkward to stand up on kind (there is no server in the lab), so know the shape and its RWX role rather than drilling it hands-on.

---

## The PV/PVC model — static provisioning

A **PersistentVolume (PV)** is a cluster-scoped (non-namespaced) piece of storage. A **PersistentVolumeClaim (PVC)** is a namespaced request for storage. In **static** provisioning an admin pre-creates PVs; users create PVCs; the control-plane's PV controller matches them. Binding is **one-to-one and exclusive**: once a PV is bound to a PVC, no other PVC can use it, even if the claim uses only part of the capacity.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-static-2g
spec:
  capacity:
    storage: 2Gi
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual        # must match the PVC exactly (or both omit/empty)
  hostPath:
    path: /mnt/data/pv-static-2g
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-static
  namespace: default
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi               # 1Gi <= 2Gi capacity -> can bind
  storageClassName: manual        # exact string match with the PV
```

### The binding algorithm — every condition must hold

The PV controller binds a PVC to an available PV only when **all** of these are true. Any single mismatch leaves the PVC `Pending`.

| Condition | Rule | Common failure |
|---|---|---|
| Capacity | `PV.capacity.storage >= PVC.requests.storage` | PVC asks 5Gi, PV is 2Gi → Pending |
| Access modes | PVC's requested modes are a **subset** of the PV's modes | PVC wants RWX, PV offers only RWO → Pending |
| StorageClass | `storageClassName` matches **exactly** (both named the same, or both empty) | PV `manual` vs PVC `standard` → Pending |
| Selector | If PVC has `spec.selector`, PV `labels` must match it | Label typo → Pending |
| volumeMode | `Filesystem` vs `Block` must match | Block PVC vs Filesystem PV → Pending |

When multiple PVs qualify, the controller prefers the **smallest** PV that still satisfies the request (least-waste), then binds. Capacity is a matching threshold, **not** an enforced quota — bind a 1Gi request to a 100Gi hostPath PV and the pod can write far more than 1Gi; nothing stops it. Capacity is only truly enforced by real CSI backends.

### PV phases

| Phase | Meaning |
|---|---|
| `Available` | Free, not yet bound to any claim. |
| `Bound` | Bound to a PVC (its `spec.claimRef` points at that PVC). |
| `Released` | The PVC was deleted, but the PV is not yet reclaimed. Data may still be present. **Not automatically reusable.** |
| `Failed` | Automatic reclamation failed. |

A PVC itself is either `Pending` (no PV yet) or `Bound`. The single most common exam diagnosis is a `Pending` PVC — jump straight to `kubectl describe pvc <name>` and read the events.

---

## Dynamic provisioning — StorageClass anatomy

Static provisioning does not scale; dynamic provisioning lets a **StorageClass** create a PV on demand when a PVC references it. This is the default path on any managed cluster and on the kind lab.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"   # makes this the cluster default
provisioner: rancher.io/local-path      # who creates the volume (CSI driver or in-tree)
parameters:                             # provisioner-specific tuning (opaque to k8s)
  archiveOnDelete: "false"
reclaimPolicy: Delete                   # applied to PVs this class creates
allowVolumeExpansion: true              # permits growing bound PVCs later
volumeBindingMode: WaitForFirstConsumer # delay PV creation until a pod schedules
```

Field by field:

- **`provisioner`** — the plugin that creates the backing volume. On the kind lab it is `rancher.io/local-path`. On cloud it is a CSI driver name like `ebs.csi.aws.com` or `pd.csi.storage.gke.io`. A StorageClass with provisioner `kubernetes.io/no-provisioner` does **no** dynamic provisioning — it exists only to group static/local PVs.
- **`parameters`** — free-form key/values passed straight to the provisioner (disk type, IOPS, filesystem). Kubernetes does not interpret them; wrong keys surface as provisioning errors on the PVC events.
- **`reclaimPolicy`** — `Delete` (default for dynamic) or `Retain`. Stamped onto every PV the class provisions. You cannot set `Recycle` here; it is deprecated and gone.
- **`allowVolumeExpansion`** — if `true`, bound PVCs of this class can be grown by editing the claim. If absent/false, expansion is rejected.
- **`volumeBindingMode`** — the field the exam most rewards understanding of.

### Immediate vs WaitForFirstConsumer — and why WFFC exists

| Mode | When the PV is provisioned/bound | Problem it solves / creates |
|---|---|---|
| `Immediate` | As soon as the PVC is created | The volume may be provisioned in a zone/node where the pod can never be scheduled — a **topology deadlock** |
| `WaitForFirstConsumer` (WFFC) | Only when a **pod** using the PVC is scheduled | The scheduler picks the node first, then the volume is provisioned **on/near that node**, respecting topology and pod constraints |

WFFC exists because in a multi-zone cluster (or with node-local storage like `local-path`), provisioning the volume before knowing where the pod runs can strand the pod: the volume is in zone A, but taints/affinity force the pod to zone B, and a zonal volume cannot cross zones. WFFC defers volume creation until the scheduler has committed to a node, so the volume is always reachable. The observable consequence — and a guaranteed exam surprise — is that **a PVC using a WFFC class sits in `Pending` until you create a pod that mounts it.** That is not a bug; describing the PVC shows `waiting for first consumer to be created before binding`. The kind lab's `standard` class is WFFC, so you will see this constantly.

### storageClassName: omitted vs empty-string vs named

This trips up seniors because the three cases are genuinely different:

| PVC `storageClassName` | Behavior |
|---|---|
| **Omitted** (field absent) | The `DefaultStorageClass` admission controller stamps the cluster's default class name into the PVC **at creation time**. Dynamic provisioning proceeds. If **no** default class exists at that moment, the field is treated as `""`. |
| **`""` (empty string)** | Explicitly **disables** dynamic provisioning. The PVC will only bind to a **pre-existing PV that also has `storageClassName: ""`**. Use this to force static binding. |
| **Named** (e.g. `fast`) | Uses that specific StorageClass (dynamic) or binds a static PV whose `storageClassName` is exactly `fast`. |

Two consequences worth memorizing: (1) once a PVC is created with the field omitted and a default existed, the default's name is **written into** the PVC object permanently — adding a different default later does not retroactively change it; (2) if you want a PVC to bind a hand-made static PV and there **is** a default class, you must set `storageClassName: ""` on both, otherwise the admission controller injects the default and the PVC tries to dynamically provision instead of binding your PV.

Exactly one StorageClass should carry the `is-default-class: "true"` annotation. If two do, the newest-created wins and Kubernetes logs a warning; if zero do, omitted-class PVCs get no dynamic provisioning.

---

## Access modes — node-level, not pod-level (except RWOP)

Access modes describe how many **nodes** (not pods) can mount the volume and in what mode. This is the single most misunderstood storage fact.

| Mode | Short | Semantics |
|---|---|---|
| `ReadWriteOnce` | RWO | Mounted read-write by a single **node**. Multiple pods **on that same node** can share it. |
| `ReadOnlyMany` | ROX | Mounted read-only by **many nodes** simultaneously. |
| `ReadWriteMany` | RWX | Mounted read-write by **many nodes** simultaneously (needs a networked filesystem like NFS/CephFS). |
| `ReadWriteOncePod` | RWOP | Mounted read-write by exactly **one pod** cluster-wide. The only **pod-level** mode. (Stable since v1.29.) |

The trap: RWO does **not** mean "one pod." Two pods scheduled on the same node can both mount a RWO volume read-write. If you genuinely need exclusive single-pod access, that is `ReadWriteOncePod`. A volume supporting multiple modes still mounts in exactly one mode per use — the modes list is capability, not simultaneity. The kind `local-path` provisioner backs every volume with **node-local** storage, so RWX is never truly usable across nodes — but note it does **not** validate access modes: it copies the PVC's requested modes verbatim onto the PV it creates and binds it (once a consumer pod schedules, since the class is WFFC), so an RWX PVC still binds and the pod runs — it simply never gets real cross-node RWX. Reserve "PVC Pending forever on access mode" for real CSI drivers that reject unsupported modes at provision time.

---

## Reclaim policies — and the Released-plus-Retain cleanup

The reclaim policy lives on the **PV** (`spec.persistentVolumeReclaimPolicy`), stamped from the StorageClass for dynamic PVs or set directly for static ones. It governs what happens to the PV **when its PVC is deleted**.

| Policy | On PVC deletion | Operational reality |
|---|---|---|
| `Delete` | PV object **and** backing storage are deleted | Default for dynamic. Data is gone. |
| `Retain` | PV kept, moves to `Released`, data preserved | Manual cleanup required before reuse. |
| `Recycle` | *Deprecated / removed* | Was a basic `rm -rf` scrub; do not use. |

**What `Released` + `Retain` means operationally** — a frequent exam drill. When you delete a PVC bound to a Retain PV, the PV does **not** return to `Available`. It goes to `Released` and stays there, because its `spec.claimRef` still names the now-deleted PVC (with the old UID). A `Released` PV **cannot be bound to a new claim**. To reuse it you must remove the stale binding:

```bash
# option A — clear the claimRef so the PV returns to Available
k patch pv pv-static-2g -p '{"spec":{"claimRef":null}}'
# PV -> Available, now a matching new PVC can bind it

# option B — recreate the PV entirely
k get pv pv-static-2g -o yaml > /tmp/pv.yaml   # edit out claimRef, resourceVersion, uid, status
k delete pv pv-static-2g && k apply -f /tmp/pv.yaml
```

Clearing `claimRef` returns the PV to `Available`; the data on disk is untouched (that is the point of Retain), so in production you would scrub it first. Note the asymmetry: `Delete` reclaim on a **statically** pre-created PV still deletes the PV object when the PVC goes away, but whether the backing storage is deleted depends on the volume plugin — for a hostPath static PV nothing on disk is removed.

---

## PVC expansion — flow and prerequisites

Growing a bound volume is edit-in-place, never recreate. Prerequisites, in order:

1. The PVC's StorageClass must have **`allowVolumeExpansion: true`**. If it doesn't, patch the class first (it is a mutable field).
2. The PVC must be **dynamically provisioned** by a CSI driver that supports resize. Statically hand-made hostPath/local PVs generally cannot be expanded.
3. You can only **grow**, never shrink. `resources.requests.storage` must increase.

```bash
# 1. allow expansion on the class (if not already)
k patch storageclass fast -p '{"allowVolumeExpansion": true}'

# 2. grow the claim
k patch pvc logs -p '{"spec":{"resources":{"requests":{"storage":"3Gi"}}}}'
# or: k edit pvc logs   -> bump spec.resources.requests.storage
```

For a **Filesystem** volume, the sequence has two stages the exam may probe: the block device is resized, then the filesystem is grown. Some drivers do both online; others set the PVC condition **`FileSystemResizePending`** and complete the filesystem grow only after the pod is **restarted** (which triggers a remount and `resize2fs`/`xfs_growfs`). So if `k get pvc` shows the requested size but the pod still reports the old size, check `k describe pvc` for `FileSystemResizePending` and restart the pod. `spec.resources.requests.storage` reflects your request; `status.capacity.storage` reflects what the volume actually delivers — watch the latter to confirm completion.

Kind's `local-path` class ships with `allowVolumeExpansion: false` and the provisioner does not truly resize the backing directory, so on the lab you demonstrate the **workflow** (patch the class, patch the PVC, read the events) rather than a physically enforced grow. On the exam the CSI driver enforces it for real; the commands are identical.

---

## volumeMode — Filesystem vs Block

`spec.volumeMode` on a PVC/PV chooses how the volume is presented:

- **`Filesystem`** (default) — the volume is formatted and mounted at a directory (`volumeMounts.mountPath`). This is what almost every workload uses.
- **`Block`** — the raw block device is handed to the container unformatted, exposed via `volumeDevices` with a `devicePath` (not `volumeMounts`). Used by databases that manage their own I/O. `volumeMode` must match between PV and PVC to bind.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: block-consumer
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeDevices:              # NOT volumeMounts — raw block
    - name: raw
      devicePath: /dev/xvda
  volumes:
  - name: raw
    persistentVolumeClaim:
      claimName: block-pvc      # a PVC created with volumeMode: Block
```

Exam relevance is mostly **awareness**: recognize that a Block PVC needs `volumeDevices`/`devicePath` while a Filesystem PVC uses `volumeMounts`/`mountPath`, and that the two modes cannot cross-bind.

---

## local volumes vs hostPath — and why local PVs require nodeAffinity

Both use node-local disk, but they are not interchangeable:

| | `hostPath` (layer-1 volume) | `local` PersistentVolume |
|---|---|---|
| Scheduling awareness | **None** — pod may land on any node and see different/empty data | **Required** `nodeAffinity` pins the PV (and thus the pod) to the node holding the disk |
| Object model | Inline in the pod spec | A real PV, claimed via a PVC |
| Dynamic provisioning | N/A | **None** — you pre-create local PVs by hand; use WFFC to bind |
| Use case | Node agents, reading `/var/log`, DaemonSets | Node-local performance storage with correct scheduling |

A `local` PV **must** declare `nodeAffinity`; the API rejects it otherwise. That affinity is what lets the scheduler place the consuming pod on the node that physically has the disk — the thing hostPath cannot do.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-local-worker
spec:
  capacity:
    storage: 5Gi
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /mnt/disks/ssd1
  nodeAffinity:                 # MANDATORY for local PVs
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - cka-worker
```

Pair a local PV with a `kubernetes.io/no-provisioner` StorageClass set to `WaitForFirstConsumer`, so the scheduler resolves node placement before binding.

---

## CSI in one paragraph

The Container Storage Interface (CSI) is how modern out-of-tree storage plugins integrate. Instead of in-tree code, a **CSI driver** runs as pods in the cluster (a controller Deployment plus a node DaemonSet) alongside sidecars — the **external-provisioner** watches for PVCs referencing a StorageClass whose `provisioner` equals the driver name and calls the driver to `CreateVolume`; **external-attacher**, **external-resizer**, and **node-driver-registrar** handle attach, expand, and kubelet registration. Kubernetes tracks drivers via `CSIDriver` objects and per-node capabilities via `CSINode` objects. For the CKA you are not installing a driver, but you must **recognize** that a StorageClass `provisioner: ebs.csi.aws.com` means "the AWS EBS CSI driver provisions this," that `kubectl get csidrivers` lists what's available, and that a PVC stuck Pending on `Immediate` with an external provisioner usually means the driver/sidecar isn't healthy — check the provisioner pods and the PVC events.

---

## StatefulSet volumeClaimTemplates — PVCs that outlive scale-down

A StatefulSet's `volumeClaimTemplates` gives **each replica its own PVC**, provisioned dynamically from the named (or default) StorageClass. The PVCs are named deterministically: `<template-name>-<statefulset-name>-<ordinal>`.

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: web
spec:
  serviceName: web              # required: the governing headless Service
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:1.27
        volumeMounts:
        - name: data
          mountPath: /usr/share/nginx/html
  volumeClaimTemplates:
  - metadata:
      name: data                # -> PVCs data-web-0, data-web-1, data-web-2
    spec:
      accessModes:
      - ReadWriteOnce
      storageClassName: standard
      resources:
        requests:
          storage: 1Gi
```

The behavior the exam probes: **scaling a StatefulSet down does NOT delete the PVCs.** Scale `web` from 3 to 1 and `data-web-1`/`data-web-2` remain `Bound` — deliberate, so scaling back up re-attaches the same data to the same ordinals. Deleting the StatefulSet also leaves the PVCs behind by default. Since v1.27 you can change this with `spec.persistentVolumeClaimRetentionPolicy` (`whenScaled` / `whenDeleted`, each `Retain` or `Delete`), but the default is `Retain` for both. Cleanup after a StatefulSet is therefore a **two-step** job: delete the StatefulSet, then explicitly delete the leftover PVCs.

---

## kind lab specifics

The lab's default class is `standard` (`rancher.io/local-path`), `Delete`, **`WaitForFirstConsumer`**, `allowVolumeExpansion: false`, RWO-only:

```bash
k get storageclass
# NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
# standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   false
```

Because it is WFFC, this is the canonical demo of "PVC Pending until a pod appears":

```bash
cat <<'EOF' | k apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: wffc-demo
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: standard
EOF
k get pvc wffc-demo            # STATUS: Pending
k describe pvc wffc-demo       # Events: "waiting for first consumer to be created before binding"

# create a consumer pod that mounts the PVC
cat <<'EOF' | k apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: consumer
spec:
  containers:
  - name: c
    image: busybox:1.36
    command: ["sleep", "3600"]
    volumeMounts:
    - name: d
      mountPath: /data
  volumes:
  - name: d
    persistentVolumeClaim:
      claimName: wffc-demo
EOF
k get pvc wffc-demo -w         # flips to Bound once the pod schedules and the PV is provisioned
```

The backing directories live under `/opt/local-path-provisioner/` inside each worker container (`docker exec cka-worker ls /opt/local-path-provisioner`). Because storage is node-local, a PVC bound to a volume on `cka-worker` pins its consuming pod to `cka-worker`.

---

## Troubleshooting — the three storage failure shapes

### 1. PVC stuck `Pending`

`k describe pvc <name>` and read events. Root causes and their tells:

| Cause | Tell in describe/events |
|---|---|
| No matching static PV | `no persistent volumes available for this claim` (and no dynamic class set) |
| No StorageClass and no default | storageClassName empty with no static PV to bind |
| WFFC waiting | `waiting for first consumer to be created before binding` — **create a pod**, not a bug |
| Access mode mismatch | PVC wants RWX but class/PV only offers RWO → provisioning fails or no PV matches |
| Capacity too large | Request exceeds every available PV's capacity |
| storageClassName typo | Named a class that doesn't exist → `storageclass.storage.k8s.io "X" not found` |
| Selector mismatch | PVC `spec.selector` matches no PV labels |
| Provisioner unhealthy | Dynamic + Immediate, events show `failed to provision volume` — check the provisioner/CSI pods |

### 2. Pod stuck `ContainerCreating` / `FailedMount`

The PVC is `Bound` but the pod won't start. `k describe pod <name>` → Events:

- **`MountVolume.SetUp failed ... configmap "X" not found`** or `secret "X" not found` — the pod mounts a configMap/secret volume that doesn't exist yet. The pod hangs in ContainerCreating indefinitely until you create the missing object (or fix the name). A top-3 exam diagnosis.
- **`FailedMount ... Unable to attach or mount volumes ... timed out waiting for the condition`** — the volume can't attach: wrong node for a node-local PV, CSI attach failure, or the backing path missing for a hostPath `type: Directory`.
- **`FailedAttachVolume`** — attach-level (CSI/attacher) problem, or the volume is RWO and already attached to another node.
- Wrong `subPath`, wrong key in `items`, or a `defaultMode` typo — files appear with wrong perms or missing.

### 3. Data "disappeared" after reschedule

Usually not a failure event at all — the workload used `emptyDir` (dies with the pod) or `hostPath` (data was on the old node) when it needed a PVC. The fix is architectural: use a PV/PVC. Recognize the symptom.

Fast triage sequence, memorize it:

```bash
k get pvc,pv                    # who is Pending, who is Bound/Released
k describe pvc <name>           # events explain the Pending
k describe pod <name>           # events explain the ContainerCreating
k get events --sort-by=.lastTimestamp -n <ns> | tail -20
```

---

## Traps

1. **Thinking RWO means one pod.** RWO is one **node**; two pods on the same node share it. Single-pod exclusivity is `ReadWriteOncePod`. Reaching for RWX when RWO would do is the more common exam version.
2. **Omitting `storageClassName: ""` when binding a hand-made PV in a cluster that has a default class.** The DefaultStorageClass admission controller injects the default name into your PVC, which then tries to dynamically provision instead of binding your static PV. Set `""` on both PV and PVC for static binding.
3. **Expecting a WFFC PVC to bind before a pod exists.** It stays Pending by design. Create the consumer. Do not "fix" it by switching to Immediate unless the task demands it.
4. **`defaultMode: 644` instead of `0644`.** Decimal vs octal — 644 decimal is octal 1204, garbage permissions. Always leading-zero the mode.
5. **Assuming a Retain PV auto-returns to Available.** Deleting the PVC leaves the PV `Released` with a stale `claimRef`; it will not rebind. Clear `claimRef` (patch to `null`) or recreate the PV.
6. **Treating capacity as an enforced quota.** It is a **matching threshold** only. A pod can write past the requested size on hostPath/local backends; real quota is a CSI-backend property.
7. **`medium: Memory` emptyDir is "free" RAM.** It counts against the container's memory limit and can OOM-kill the container. Size it against the limit.
8. **Editing a bound PVC to shrink it.** Only growth is allowed; shrink requests are rejected.
9. **Expecting expansion to reflect instantly in the pod.** For Filesystem volumes the PVC may sit at `FileSystemResizePending` until the pod restarts. Watch `status.capacity`, not `spec.requests`.
10. **Deleting a StatefulSet and assuming storage is gone.** `volumeClaimTemplates` PVCs are **retained** on scale-down and on delete by default. Clean them up explicitly, or you leave orphaned bound PVs.
11. **`hostPath` without a `type` in a "must-exist" task.** Default `type: ""` performs no checks; if the task needs the path to pre-exist or be created, use `Directory` / `DirectoryOrCreate` explicitly.
12. **Forgetting there is no imperative generator for PV/PVC/StorageClass.** You cannot `kubectl create pv`. Memorize the YAML shapes — that is the whole storage speed game.
13. **`readOnly` on the wrong object.** For read-only mounts, `readOnly: true` goes on the **volumeMount**, not the volume source (for most types).
14. **A `local` PV without `nodeAffinity`.** The API rejects it; and without it there is no way for the scheduler to place the pod on the node holding the disk.
15. **Two default StorageClasses.** Only one should have the `is-default-class` annotation. Two causes nondeterministic default selection and warnings; when switching defaults, unset the old one in the same change.

---

## Speed patterns

**There is no generator — so keep these four shapes in muscle memory.** PVC is the one you write most:

```bash
# PVC — the shape you'll type dozens of times
cat <<'EOF' | k apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: standard
  resources:
    requests:
      storage: 1Gi
EOF
```

**Mount a PVC into a pod** — remember the pairing of `volumes[].persistentVolumeClaim.claimName` with `volumeMounts[].name`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pvc-user
spec:
  containers:
  - name: app
    image: nginx:1.27
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: data
```

**Switch the default StorageClass** — two patches, JSON so they're `--overwrite`-safe:

```bash
# unset the current default
k patch storageclass standard -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
# set the new default
k patch storageclass fast -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
k get sc          # verify exactly one shows (default)
```

**Rebind a Retain PV:** `k patch pv <name> -p '{"spec":{"claimRef":null}}'` → back to Available.

**Expand a PVC:** `k patch pvc <name> -p '{"spec":{"resources":{"requests":{"storage":"3Gi"}}}}'` (patch the class to `allowVolumeExpansion:true` first if needed).

**Diagnose Pending in 20 seconds:** `k describe pvc <name>` → read the one Events line. It always names the cause (no class, WFFC, no match, not found).

**Recall field names offline:** `k explain pv.spec`, `k explain pvc.spec`, `k explain storageclass`, `k explain pod.spec.volumes.emptyDir`. Faster than the docs, always available.

**Generate a pod to hang for mounting demos:** `k run app --image=busybox:1.36 $do -- sleep 3600 > pod.yaml`, then paste the volume block.

**Cleanup order matters:** delete pods → delete PVCs → delete PVs (deleting a PVC while a pod uses it can hang on finalizers; the pod pins the PVC).

---

## Docs map

| Need | kubernetes.io path (exam Firefox: search the boldface term) |
|---|---|
| PV/PVC concepts, phases, reclaim, binding | `/docs/concepts/storage/persistent-volumes/` — search **persistent volumes** |
| StorageClass fields, provisioners, binding modes | `/docs/concepts/storage/storage-classes/` — search **storage classes** |
| Dynamic provisioning + default class annotation | `/docs/concepts/storage/dynamic-provisioning/` |
| Change the default StorageClass (copy-paste) | `/docs/tasks/administer-cluster/change-default-storage-class/` — search **change default storage class** |
| Expand a PersistentVolumeClaim | `/docs/concepts/storage/persistent-volumes/#expanding-persistent-volumes-claims` |
| Volume types (emptyDir, hostPath, configMap, projected…) | `/docs/concepts/storage/volumes/` — search **volumes** |
| Configure a pod to use a PVC (full walkthrough) | `/docs/tasks/configure-pod-container/configure-persistent-volume-storage/` |
| Projected volumes | `/docs/concepts/storage/projected-volumes/` |
| Access modes reference table | `/docs/concepts/storage/persistent-volumes/#access-modes` |
| StatefulSet storage / volumeClaimTemplates | `/docs/concepts/workloads/controllers/statefulset/` — search **statefulset** |
| CSI drivers / volume snapshots awareness | `/docs/concepts/storage/volumes/#csi` |

---

## Checkpoint

Time yourself. Every item is a realistic exam task and the target includes verification.

- Can you write a PVC manifest from memory (no docs, no generator) and apply it in **90 seconds**?
- Can you create a static hostPath PV, a matching PVC, and a pod that mounts it, and confirm `Bound` — with the `storageClassName: ""` trick if a default class exists — in **6 minutes**?
- Can you diagnose a `Pending` PVC to its exact cause from `describe` and fix it (mismatch: capacity, accessMode, class name, or WFFC) in **3 minutes**?
- Can you explain, in one sentence each, why WaitForFirstConsumer exists and what observable behavior it produces on the kind lab?
- Can you switch the cluster's default StorageClass from one class to another (unset old, set new) and prove exactly one default remains in **2 minutes**?
- Can you grow a bound PVC, and state where you'd look (`FileSystemResizePending`, `status.capacity`) if the pod still shows the old size, in **3 minutes**?
- Can you take a `Released` Retain PV and make it bindable again by clearing its `claimRef`, then bind a fresh PVC to it, in **4 minutes**?
- Can you state from memory what RWO/ROX/RWX/RWOP each mean at the node vs pod level, and which one the kind `local-path` class supports?
- Can you deploy a 3-replica StatefulSet with `volumeClaimTemplates`, scale it to 1, and predict which PVCs remain — in **5 minutes**?
- Can you fix a pod stuck in `ContainerCreating` because it mounts a configMap that doesn't exist, in **2 minutes**?
- Can you configure a `medium: Memory` emptyDir with a `sizeLimit` and explain what happens if the pod exceeds it (and against which limit RAM counts)?
