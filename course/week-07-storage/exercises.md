# Week 07 — Storage Exercises

Lab: the 3-node kind cluster `cka` (context `kind-cka`). Aliases assumed: `alias k=kubectl`, `export do="--dry-run=client -o yaml"`, `export now="--grace-period=0 --force"`. Run every task from the host terminal. The default StorageClass is `standard` (`rancher.io/local-path`, `Delete`, `WaitForFirstConsumer`, `allowVolumeExpansion: false`, RWO-only) — several tasks depend on that. Where a task needs pre-existing (or pre-broken) resources, run the **setup** fence first. A cleanup fence for the whole set is at the bottom.

Exam-flavor note (applies to all tasks): on the real exam the backing storage is a real CSI driver (EBS, PD, Ceph…) so capacity, access modes, and expansion are physically enforced; on kind, `rancher.io/local-path` is node-local hostPath, so some limits are matching-only. Where behavior differs, each solution says so in one line.

There are **15 tasks** (4 hard-mode). Do them in order — later tasks assume you can write the shapes from the earlier ones without docs.

---

## Task 1 — configMap as a read-only volume (warmup, 4 min)

Setup:

```bash
k create ns storage-lab
k -n storage-lab create configmap app-cfg \
  --from-literal=color=blue \
  --from-literal=application.properties='mode=prod'
```

Context: namespace `storage-lab`, configMap `app-cfg` exists. Create a pod `cfg-reader` (image `busybox:1.36`, command `sleep 3600`) that mounts `app-cfg` at `/etc/app` **read-only**. Verify the file `application.properties` is visible inside the container and that the mount is read-only (a write attempt fails).

## Task 2 — emptyDir RAM cache with a size limit (warmup, 4 min)

Context: namespace `storage-lab`. Create a pod `ram-cache` (image `busybox:1.36`, `sleep 3600`) with a **memory-backed** emptyDir mounted at `/cache`, `sizeLimit` 64Mi, and a container memory limit of 128Mi. Confirm from inside the pod that `/cache` is a tmpfs. State (to yourself) which limit the tmpfs bytes count against.

## Task 3 — hostPath mounted read-only (warmup, 3 min)

Context: namespace `storage-lab`. Create a pod `host-reader` (image `busybox:1.36`, `sleep 3600`) that mounts the node directory `/var/log` at `/host-logs` **read-only**, using a `hostPath` `type` that fails fast if the directory does not already exist. Verify you can read but not write.

## Task 4 — static PV + PVC + pod binding chain (exam, 7 min)

Context: namespace `storage-lab`. A default StorageClass exists, so you must bind statically on purpose. Create:

1. A PersistentVolume `pv-manual-2g`, 2Gi, `ReadWriteOnce`, reclaim `Retain`, `storageClassName: manual`, hostPath `/mnt/data/pv-manual-2g` (`DirectoryOrCreate`).
2. A PersistentVolumeClaim `claim-1g` in `storage-lab` requesting 1Gi RWO from `storageClassName: manual`.
3. A pod `pv-user` (image `nginx:1.27`) mounting the PVC at `/usr/share/nginx/html`.

Verify the PV shows `Bound` to `claim-1g` and the pod runs.

## Task 5 — diagnose and fix a Pending PVC (exam, 6 min)

Setup:

```bash
k -n storage-lab apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-fix-1g
spec:
  capacity:
    storage: 1Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  hostPath:
    path: /mnt/data/pv-fix-1g
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: broken-claim
  namespace: storage-lab
spec:
  accessModes: [ReadWriteMany]
  storageClassName: slow
  resources:
    requests:
      storage: 5Gi
EOF
```

Context: PV `pv-fix-1g` is `Available`; PVC `broken-claim` is `Pending`. Without changing the PV, make `broken-claim` bind to `pv-fix-1g`. Name every reason it was Pending. (Hint: think about which PVC fields you can and cannot edit in place.)

## Task 6 — create a StorageClass (exam, 4 min)

Context: nothing pre-exists. Create a StorageClass `fast` with provisioner `rancher.io/local-path`, reclaim policy `Delete`, `allowVolumeExpansion: true`, and binding mode `WaitForFirstConsumer`. Do **not** make it the default. Verify it appears in `k get sc` without a `(default)` marker.

## Task 7 — switch the default StorageClass (exam, 4 min)

Context: `standard` is currently the default; `fast` exists from Task 6. Make `fast` the default and ensure `standard` is no longer default. Prove that exactly one class shows `(default)`. Then create a PVC `default-test` in `storage-lab` with **no** `storageClassName` and confirm it picked up `fast`.

## Task 8 — WaitForFirstConsumer observation drill (exam, 5 min)

Context: namespace `storage-lab`, default class is WFFC. Create a PVC `wffc` (1Gi RWO, `storageClassName: standard`). Observe it stay `Pending` and read the exact event reason. Then create a pod `wffc-pod` (`busybox:1.36`, `sleep 3600`) mounting it at `/data`, and observe the PVC flip to `Bound`. Report which node the volume landed on and why the pod is pinned there.

## Task 9 — expand a PVC (exam, 5 min)

Setup:

```bash
k apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: expandable
provisioner: rancher.io/local-path
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
EOF
```

Context: namespace `storage-lab`, StorageClass `expandable` allows expansion. Create a PVC `grow-me` (1Gi RWO, `storageClassName: expandable`) and a pod `grow-pod` (`busybox:1.36`, `sleep 3600`) that mounts it (needed for WFFC to bind). Once bound, grow the PVC to 3Gi. Show the updated `spec.resources.requests.storage`. Explain what you would check if the pod still reported the old size.

## Task 10 — projected volume: configMap + downwardAPI (exam, 6 min)

Context: namespace `storage-lab`, configMap `app-cfg` exists (Task 1). Create a pod `projected-pod` (`busybox:1.36`, `sleep 3600`) with a single **projected** volume mounted read-only at `/etc/combined` that surfaces: (a) all keys of configMap `app-cfg`, and (b) the pod's own name from the downward API as a file `pod-name`. Verify all three files are present with the right contents.

## Task 11 — pod stuck ContainerCreating: missing configMap (exam, 4 min)

Setup:

```bash
k -n storage-lab apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: stuck-pod
  namespace: storage-lab
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sleep", "3600"]
    volumeMounts:
    - name: cfg
      mountPath: /etc/cfg
  volumes:
  - name: cfg
    configMap:
      name: missing-cfg
EOF
```

Context: `stuck-pod` is stuck in `ContainerCreating`. Diagnose from events, then make it run **without** editing the pod (it is immutable-ish for volumes). Verify it reaches `Running`.

## Task 12 — Retain reclaim: release and rebind by clearing claimRef (hard, 8 min)

Setup:

```bash
k -n storage-lab apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-retain
spec:
  capacity:
    storage: 1Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  hostPath:
    path: /mnt/data/pv-retain
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: retain-claim-old
  namespace: storage-lab
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: manual
  resources:
    requests:
      storage: 1Gi
EOF
```

Context: PV `pv-retain` (Retain) is `Bound` to `retain-claim-old`. Delete `retain-claim-old`. Observe the PV go to `Released` and confirm it will **not** bind a new claim in that state. Then make it `Available` again and bind a fresh PVC `retain-claim-new` (same specs) to it — **without deleting and recreating the PV**.

## Task 13 — StatefulSet with volumeClaimTemplates and scale-down retention (hard, 8 min)

Context: namespace `storage-lab`, default class `standard`. Create a headless Service `web` and a StatefulSet `web` (3 replicas, image `nginx:1.27`) whose `volumeClaimTemplates` gives each pod a 1Gi RWO PVC named `data`, mounted at `/usr/share/nginx/html`. Wait for all 3 pods `Running` and all 3 PVCs `Bound`. Then scale to 1 replica and report exactly which PVCs remain and why. State the two-step cleanup you'd run to remove all storage.

## Task 14 — triage three Pending PVCs, each a different cause (hard, 9 min)

Setup:

```bash
k -n storage-lab apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-a
  namespace: storage-lab
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: does-not-exist
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-b
  namespace: storage-lab
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ""
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-small
spec:
  capacity:
    storage: 500Mi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  hostPath:
    path: /mnt/data/pv-small
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-c
  namespace: storage-lab
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: manual
  resources:
    requests:
      storage: 2Gi
EOF
```

Context: three PVCs (`pvc-a`, `pvc-b`, `pvc-c`) are all `Pending` for **different** reasons. For each: state the exact cause from `describe`, then fix it so all three become `Bound` (create supporting objects as needed). Do not weaken the `pv-small` capacity.

## Task 15 — local PV with nodeAffinity vs hostPath (hard, 8 min)

Context: namespace `storage-lab`. Create a StorageClass `local-storage` (`kubernetes.io/no-provisioner`, `WaitForFirstConsumer`). Create a `local` PersistentVolume `pv-local-w2`, 2Gi RWO, `storageClassName: local-storage`, `local.path: /mnt/disks/ssd1`, with **required nodeAffinity** pinning it to node `cka-worker2`. Create a PVC `local-claim` and a pod `local-pod` (`busybox:1.36`, `sleep 3600`) that mounts it. Confirm the pod is scheduled specifically on `cka-worker2` and explain why `hostPath` could not have guaranteed that.

---

# SOLUTIONS

## Solution 1 — configMap as a read-only volume

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cfg-reader
  namespace: storage-lab
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sleep", "3600"]
    volumeMounts:
    - name: cfg
      mountPath: /etc/app
      readOnly: true
  volumes:
  - name: cfg
    configMap:
      name: app-cfg
```

```bash
k apply -f cfg-reader.yaml
k -n storage-lab exec cfg-reader -- cat /etc/app/application.properties   # mode=prod
k -n storage-lab exec cfg-reader -- sh -c 'echo x > /etc/app/color' 2>&1   # Read-only file system
```

Why: configMap volumes surface each key as a file; `readOnly: true` on the **mount** (configMap volumes are read-only anyway, but stating it satisfies the "read-only" ask and blocks writes).

## Solution 2 — emptyDir RAM cache with a size limit

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ram-cache
  namespace: storage-lab
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sleep", "3600"]
    resources:
      limits:
        memory: 128Mi
    volumeMounts:
    - name: cache
      mountPath: /cache
  volumes:
  - name: cache
    emptyDir:
      medium: Memory
      sizeLimit: 64Mi
```

```bash
k apply -f ram-cache.yaml
k -n storage-lab exec ram-cache -- mount | grep /cache    # tmpfs ... on /cache
```

Why: `medium: Memory` makes the emptyDir a tmpfs; its bytes count **against the container's 128Mi memory limit** (not disk), so oversizing the cache can OOM-kill the container.

## Solution 3 — hostPath mounted read-only

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: host-reader
  namespace: storage-lab
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sleep", "3600"]
    volumeMounts:
    - name: logs
      mountPath: /host-logs
      readOnly: true
  volumes:
  - name: logs
    hostPath:
      path: /var/log
      type: Directory
```

```bash
k apply -f host-reader.yaml
k -n storage-lab exec host-reader -- ls /host-logs
k -n storage-lab exec host-reader -- sh -c 'touch /host-logs/x' 2>&1   # Read-only file system
```

Why: `type: Directory` fails the mount if `/var/log` is absent (fail-fast); `readOnly: true` on the mount enforces read-only.

## Solution 4 — static PV + PVC + pod binding chain

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-manual-2g
spec:
  capacity:
    storage: 2Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  hostPath:
    path: /mnt/data/pv-manual-2g
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: claim-1g
  namespace: storage-lab
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: manual
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: pv-user
  namespace: storage-lab
spec:
  containers:
  - name: web
    image: nginx:1.27
    volumeMounts:
    - name: data
      mountPath: /usr/share/nginx/html
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: claim-1g
```

```bash
k apply -f task4.yaml
k get pv pv-manual-2g            # STATUS Bound, CLAIM storage-lab/claim-1g
k -n storage-lab get pvc,pod
```

Why: `storageClassName: manual` names a class with **no** dynamic provisioner object, so no dynamic provisioning happens; the PVC waits for and binds the static PV of the same class name. 1Gi ≤ 2Gi and RWO ⊆ RWO satisfy the binding rules. (Equivalent alternative: `storageClassName: ""` on both — empty string also blocks the default class from being injected.)

## Solution 5 — diagnose and fix a Pending PVC

```bash
k -n storage-lab describe pvc broken-claim
# no volume matches: wants RWX (PV offers RWO), class 'slow' (PV is 'manual'), 5Gi (PV is 1Gi)
```

Three mismatches: **access mode** (RWX ⊄ RWO), **storageClassName** (`slow` ≠ `manual`), **capacity** (5Gi > 1Gi). All three are **immutable** on a PVC (accessModes and storageClassName can't be edited; storage can only grow), so you cannot `k edit` your way out — delete and recreate:

```bash
k -n storage-lab delete pvc broken-claim
k -n storage-lab apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: broken-claim
  namespace: storage-lab
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: manual
  resources:
    requests:
      storage: 1Gi
EOF
k get pv pv-fix-1g              # Bound to storage-lab/broken-claim
```

Why: PVC spec fields (except growing `requests.storage`) are immutable after creation, so a mismatched Pending PVC is fixed by recreating it to match the PV — not by editing it.

## Solution 6 — create a StorageClass

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast
provisioner: rancher.io/local-path
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

```bash
k apply -f fast-sc.yaml
k get sc      # 'fast' present, no (default) next to it
```

Why: omitting the `is-default-class` annotation keeps it non-default; the four fields (provisioner, reclaimPolicy, allowVolumeExpansion, volumeBindingMode) are the exam-relevant knobs.

## Solution 7 — switch the default StorageClass

```bash
k patch storageclass standard -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
k patch storageclass fast     -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
k get sc      # only 'fast (default)'

k -n storage-lab create -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: default-test
  namespace: storage-lab
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
EOF
k -n storage-lab get pvc default-test -o jsonpath='{.spec.storageClassName}'   # fast
```

Why: the default is decided solely by the annotation; a PVC with the field **omitted** gets the current default's name stamped in by the DefaultStorageClass admission controller at creation time. Reset `standard` to default afterward if later tasks assume it (`k patch storageclass standard ...=true` and `fast ...=false`).

## Solution 8 — WaitForFirstConsumer observation drill

```bash
k -n storage-lab apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: wffc
  namespace: storage-lab
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: standard
  resources:
    requests:
      storage: 1Gi
EOF
k -n storage-lab describe pvc wffc | grep -A2 Events
# "waiting for first consumer to be created before binding"

k -n storage-lab apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: wffc-pod
  namespace: storage-lab
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
      claimName: wffc
EOF
k -n storage-lab get pvc wffc     # now Bound
k -n storage-lab get pod wffc-pod -o wide          # NODE = where the volume was provisioned
k get pv -o custom-columns=NAME:.metadata.name,NODE:'.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]'
```

Why: WFFC defers provisioning until the scheduler picks a node; the `local-path` PV is then created on that node with matching nodeAffinity, which **pins** the pod there. Before the pod existed, the PVC had nothing to bind to — hence Pending, by design.

## Solution 9 — expand a PVC

```bash
k -n storage-lab apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grow-me
  namespace: storage-lab
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: expandable
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: grow-pod
  namespace: storage-lab
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
      claimName: grow-me
EOF
k -n storage-lab get pvc grow-me                    # wait for Bound
k -n storage-lab patch pvc grow-me -p '{"spec":{"resources":{"requests":{"storage":"3Gi"}}}}'
k -n storage-lab get pvc grow-me -o jsonpath='{.spec.resources.requests.storage}'   # 3Gi
```

Why: expansion needs `allowVolumeExpansion: true` on the class and a grow-only edit to the PVC. If the pod still shows the old size, `k describe pvc grow-me` for a `FileSystemResizePending` condition and restart the pod so the filesystem is grown; watch `status.capacity`.
Exam-flavor note: kind's `local-path` does not physically resize node-local dirs, so `status.capacity` stays 1Gi on the lab — a real CSI driver moves it to 3Gi. The command sequence is identical.

## Solution 10 — projected volume: configMap + downwardAPI

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: projected-pod
  namespace: storage-lab
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
          name: app-cfg
      - downwardAPI:
          items:
          - path: pod-name
            fieldRef:
              fieldPath: metadata.name
```

```bash
k apply -f projected-pod.yaml
k -n storage-lab exec projected-pod -- ls /etc/combined      # application.properties  color  pod-name
k -n storage-lab exec projected-pod -- cat /etc/combined/pod-name   # projected-pod
```

Why: `projected` merges heterogeneous sources under one mount; `downwardAPI` with `fieldRef: metadata.name` writes the pod name to the file `pod-name`, alongside the configMap keys.

## Solution 11 — pod stuck ContainerCreating: missing configMap

```bash
k -n storage-lab describe pod stuck-pod | grep -A3 Events
# MountVolume.SetUp failed ... configmap "missing-cfg" not found

# fix: create the referenced configMap (the pod's volume names it)
k -n storage-lab create configmap missing-cfg --from-literal=key=value
k -n storage-lab get pod stuck-pod -w      # ContainerCreating -> Running
```

Why: a pod mounting a nonexistent configMap hangs in ContainerCreating until the object appears; the kubelet retries the mount, so creating `missing-cfg` unblocks it with no pod edit. (Alternative: delete the pod and recreate it referencing an existing configMap — but creating the missing object is faster and non-destructive.)

## Solution 12 — Retain reclaim: release and rebind by clearing claimRef

```bash
k -n storage-lab delete pvc retain-claim-old
k get pv pv-retain                       # STATUS: Released (NOT Available)

# prove it won't rebind while Released: a new matching PVC stays Pending
k -n storage-lab apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: retain-claim-new
  namespace: storage-lab
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: manual
  resources:
    requests:
      storage: 1Gi
EOF
k -n storage-lab get pvc retain-claim-new       # Pending (PV is Released, has stale claimRef)

# clear the stale binding so the PV returns to Available
k patch pv pv-retain -p '{"spec":{"claimRef":null}}'
k get pv pv-retain                       # Available
k -n storage-lab get pvc retain-claim-new       # now Bound
```

Why: with `Retain`, deleting the PVC leaves the PV `Released` with a `claimRef` still naming the old (deleted) claim UID — that stale ref blocks any new binding. Patching `claimRef` to `null` returns it to `Available` without touching the on-disk data.

## Solution 13 — StatefulSet with volumeClaimTemplates and scale-down retention

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: storage-lab
spec:
  clusterIP: None
  selector:
    app: web
  ports:
  - port: 80
    name: http
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: web
  namespace: storage-lab
spec:
  serviceName: web
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
        ports:
        - containerPort: 80
        volumeMounts:
        - name: data
          mountPath: /usr/share/nginx/html
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: standard
      resources:
        requests:
          storage: 1Gi
```

```bash
k apply -f web-sts.yaml
k -n storage-lab rollout status statefulset/web
k -n storage-lab get pvc     # data-web-0, data-web-1, data-web-2 all Bound

k -n storage-lab scale statefulset web --replicas=1
k -n storage-lab get pods    # only web-0
k -n storage-lab get pvc     # data-web-0, data-web-1, data-web-2 ALL still Bound
```

Why: `volumeClaimTemplates` creates one PVC per ordinal (`data-web-N`); the default `persistentVolumeClaimRetentionPolicy` is `Retain` for both `whenScaled` and `whenDeleted`, so scaling down keeps `data-web-1`/`data-web-2` intact for a scale-up. Full cleanup is two steps: `k -n storage-lab delete statefulset web` then `k -n storage-lab delete pvc -l app=web` (or the PVCs by name).

## Solution 14 — triage three Pending PVCs

```bash
k -n storage-lab describe pvc pvc-a pvc-b pvc-c | grep -E 'Name:|Events|not found|volume|waiting'
```

| PVC | Cause | Fix |
|---|---|---|
| `pvc-a` | `storageClassName: does-not-exist` → `storageclass ... not found`, no provisioning | recreate with `storageClassName: standard` (or create that class) |
| `pvc-b` | `storageClassName: ""` disables dynamic provisioning and there is no static PV with `""` to bind | create a matching static PV with `storageClassName: ""` |
| `pvc-c` | requests 2Gi but the only `manual` PV (`pv-small`) is 500Mi → capacity mismatch | recreate `pvc-c` requesting ≤ 500Mi |

```bash
# pvc-a
k -n storage-lab delete pvc pvc-a
k -n storage-lab apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-a
  namespace: storage-lab
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: standard
  resources:
    requests:
      storage: 1Gi
EOF
k -n storage-lab run pvc-a-user --image=busybox:1.36 \
  --overrides='{"spec":{"containers":[{"name":"c","image":"busybox:1.36","command":["sleep","3600"],"volumeMounts":[{"name":"d","mountPath":"/data"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"pvc-a"}}]}}' \
  --command -- sleep 3600      # WFFC needs a consumer to bind

# pvc-b: give it a static PV with empty-string class
k apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-empty-class
spec:
  capacity:
    storage: 1Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath:
    path: /mnt/data/pv-empty-class
    type: DirectoryOrCreate
EOF

# pvc-c: recreate within the 500Mi PV capacity
k -n storage-lab delete pvc pvc-c
k -n storage-lab apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-c
  namespace: storage-lab
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: manual
  resources:
    requests:
      storage: 500Mi
EOF
k -n storage-lab get pvc      # pvc-b and pvc-c Bound; pvc-a Bound after its consumer schedules
```

Why: three distinct Pending causes — a **named class that doesn't exist** (no provisioner, no static PV), an **empty-string class** (static-only, no matching PV), and a **capacity request exceeding** the only matching PV. Each needs a different remedy; `pvc-a` on the WFFC default also needs a consuming pod before it binds.

## Solution 15 — local PV with nodeAffinity vs hostPath

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-local-w2
spec:
  capacity:
    storage: 2Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /mnt/disks/ssd1
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - cka-worker2
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: local-claim
  namespace: storage-lab
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-storage
  resources:
    requests:
      storage: 2Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: local-pod
  namespace: storage-lab
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
      claimName: local-claim
```

```bash
# create the backing dir on the target node first (else mount fails)
docker exec cka-worker2 mkdir -p /mnt/disks/ssd1
k apply -f task15.yaml
k -n storage-lab get pvc local-claim         # Bound after the pod schedules (WFFC)
k -n storage-lab get pod local-pod -o wide   # NODE: cka-worker2
```

Why: a `local` PV **must** carry `nodeAffinity`; the scheduler reads it and places the consuming pod on `cka-worker2`, the only node that can reach the disk. `hostPath` has no such affinity — the pod could be scheduled on any node and would silently see a different (or empty) `/mnt/disks/ssd1`. WFFC ensures binding waits for that scheduling decision.
Exam-flavor note: on a kubeadm cluster you'd `ssh` to the node and `sudo mkdir` the path; on kind, `docker exec <node>` is the equivalent.

---

## Cleanup

```bash
k delete ns storage-lab --wait=false
k delete pv pv-manual-2g pv-fix-1g pv-retain pv-small pv-empty-class pv-local-w2 --ignore-not-found
k delete sc fast expandable local-storage --ignore-not-found
# restore 'standard' as the default if a task switched it away
k patch storageclass standard -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

Exam-flavor note: PVs are cluster-scoped, so deleting the namespace does **not** remove them — clean them up explicitly, exactly as above. On the real exam, leftover PVs/PVCs from one task can silently break a later one; always verify `k get pv,sc` is clean before moving on.
