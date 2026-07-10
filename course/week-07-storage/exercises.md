# Week 07 — Storage Exercises

Lab: 3-node kind cluster `cka` (nodes `cka-control-plane`, `cka-worker`, `cka-worker2`), context `kind-cka`. Default StorageClass is `standard` (`rancher.io/local-path`, WaitForFirstConsumer, reclaim Delete). Aliases assumed: `k`, `$do`, `$now`.

```bash
kubectl config use-context kind-cka
k get sc    # confirm: standard (default), rancher.io/local-path, WaitForFirstConsumer
```

Each task states its namespace. Cleanup after a task: `k delete ns <ns>` plus any cluster-scoped PVs/SCs the solution names. Exam-flavor notes mark where the real exam (kubeadm nodes, SSH, sudo) differs from kind (`docker exec`).

---

## Tasks

### Task 1 — Static binding chain (warmup, 6 min)

Context: namespace `t1-static` (create it). Nothing pre-exists.

Create a PersistentVolume `pv-app-logs`: 1Gi, `ReadWriteOnce`, `storageClassName: manual`, hostPath `/tmp/app-logs` (create the directory if absent), reclaim policy `Retain`. Create a PersistentVolumeClaim `app-logs` in `t1-static` that binds to it. Create a pod `writer` (image `busybox:1.36`, command `sleep 3600`) mounting the claim at `/logs`. Verify the PV and PVC are `Bound` and write a file into `/logs`.

### Task 2 — hostPath read-only (warmup, 4 min)

Context: namespace `default`. Nothing pre-exists.

Create a pod `log-reader` (image `busybox:1.36`, command `sleep 3600`) that mounts the node directory `/var/log` at `/host-logs`, read-only, with a hostPath type that fails fast if the directory does not exist. Verify you can list `/host-logs` but cannot create a file there.

### Task 3 — Fix the binding mismatch (exam, 8 min)

Context: namespace `t3-mismatch`. Run the setup first.

```bash
k create ns t3-mismatch
k apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-t3
spec:
  capacity:
    storage: 500Mi
  accessModes: [ReadOnlyMany]
  storageClassName: manual
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /tmp/t3-data
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
  namespace: t3-mismatch
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: manual
EOF
```

The PVC `data` is stuck `Pending`. Identify every reason it cannot bind to `pv-t3`, then make it bind **without deleting or recreating the PVC**. Verify both go `Bound`.

### Task 4 — In-memory cache volume (exam, 6 min)

Context: namespace `t4-cache` (create it).

Create a pod `cache-pod` with two containers, both `busybox:1.36` running `sleep 3600`, named `writer` and `reader`. They share a memory-backed emptyDir volume `cache` mounted at `/cache` in both, capped at 64Mi. Give each container a memory limit of 128Mi. Verify: a file written in `writer` is visible in `reader`, and `/cache` is a tmpfs mount.

### Task 5 — Projected volume (exam, 7 min)

Context: namespace `t5-projected` (create it).

Create a ConfigMap `app-config` with key `app.properties` = `mode=prod`, and a Secret `app-secret` with key `api-token` = `s3cr3t`. Create a pod `combined-pod` (image `busybox:1.36`, command `sleep 3600`, label `tier=backend`) that mounts a single projected volume at `/etc/combined` (read-only) exposing: all keys of `app-config`, all keys of `app-secret`, and the pod's labels via the downward API at file `pod-labels`. Verify all three files exist with expected content.

### Task 6 — StorageClass + default switch (exam, 6 min)

Context: cluster-scoped. `standard` is currently the default SC.

Create a StorageClass `fast-local`: provisioner `rancher.io/local-path`, `volumeBindingMode: WaitForFirstConsumer`, `reclaimPolicy: Delete`, expansion allowed. Make `fast-local` the cluster default and ensure `standard` is no longer default. Verify with `k get sc` (exactly one `(default)` marker).

### Task 7 — WFFC observation drill (exam, 5 min)

Context: namespace `t7-wffc` (create it). Uses SC `standard`.

Create a PVC `wffc-claim` (200Mi, RWO, class `standard`). Record its status and the exact event explaining it. Then create a pod `consumer` (image `busybox:1.36`, `sleep 3600`) mounting the claim at `/data`, and watch the PVC go `Bound`. Answer in one sentence: which StorageClass field caused the initial Pending, and why does that field exist?

### Task 8 — Expand a PVC (exam, 8 min)

Context: namespace `t8-expand` (create it). Uses SC `standard`.

Create PVC `data-grow` (1Gi, RWO, class `standard`) and a pod `grow-pod` mounting it at `/data` (so it provisions). Then expand the claim to 2Gi. Show where the new size is visible and where it is not, and explain the gap.

Exam-flavor note: kind's local-path provisioner cannot resize; the API accepts the request but `status.capacity` never converges. On the exam's CSI-backed clusters the same steps complete, possibly with a `FileSystemResizePending` condition until the pod remounts.

### Task 9 — Retain, release, rebind (hard, 12 min)

Context: namespace `t9-retain` (create it). Uses SC `standard`.

1. Create PVC `keep-data` (500Mi, RWO, class `standard`) and pod `producer` (busybox) mounting it at `/data`; write `important` into `/data/marker.txt`.
2. Protect the provisioned PV from deletion, then delete the pod AND the PVC.
3. Prove the PV survived and reached `Released`, and that the data is still on the node.
4. Make the PV bindable again, bind it to a NEW PVC `keep-data-2` in the same namespace, and mount it from pod `consumer2` to read `/data/marker.txt`. The file must still say `important`.

### Task 10 — local PV with node affinity (exam, 8 min)

Context: namespace `t10-local`. Run the setup first (pre-creates the disk directory on `cka-worker2`).

```bash
k create ns t10-local
docker exec cka-worker2 mkdir -p /mnt/disks/ssd1
```

Create a StorageClass `local-disks` (`kubernetes.io/no-provisioner`, WaitForFirstConsumer). Create a PV `pv-local-ssd`: 500Mi, RWO, class `local-disks`, reclaim `Retain`, **local** volume source at `/mnt/disks/ssd1`, required node affinity to `cka-worker2`. Create PVC `local-claim` (400Mi, RWO, class `local-disks`) and pod `pinned` (busybox, `sleep 3600`) mounting it at `/disk` — WITHOUT any nodeSelector/affinity on the pod. Verify the pod was scheduled on `cka-worker2` and explain in one sentence what put it there.

Exam-flavor note: on the exam you'd `ssh node01` and `sudo mkdir` instead of `docker exec`.

### Task 11 — StatefulSet with volumeClaimTemplates (exam, 8 min)

Context: namespace `t11-sts` (create it). Uses SC `standard`.

Create a headless Service `web` and a StatefulSet `web`: 3 replicas, image `nginx:1.27`, one volumeClaimTemplate `www` (100Mi, RWO, class `standard`) mounted at `/usr/share/nginx/html`. Once all replicas run: write a distinct marker file into replica 2's volume, scale the StatefulSet to 1, list the PVCs and state what happened to them, scale back to 3, and verify replica 2 still has its marker.

### Task 12 — PVC Pending: missing class (hard, 6 min)

Context: namespace `t12-diag`. Run the setup first, then treat it as a live incident.

```bash
k create ns t12-diag
k apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: web-data
  namespace: t12-diag
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 500Mi
  storageClassName: gold
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: t12-diag
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
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
          claimName: web-data
EOF
```

The `web` deployment in `t12-diag` has no running pods. Find the root cause and fix it **without deleting or modifying the PVC or the Deployment**. Everything must reach `Running`/`Bound`.

### Task 13 — PVC Pending: triple mismatch (hard, 10 min)

Context: namespace `t13-diag`. Run the setup first.

```bash
k create ns t13-diag
k apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-t13
spec:
  capacity:
    storage: 1Gi
  accessModes: [ReadWriteOnce]
  volumeMode: Block
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /tmp/t13-data
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared
  namespace: t13-diag
spec:
  accessModes: [ReadWriteMany]
  volumeMode: Filesystem
  resources:
    requests:
      storage: 2Gi
  storageClassName: ""
EOF
```

PVC `shared` is `Pending` and must bind to `pv-t13` (do not create other PVs; do not touch the PVC). List EVERY rule that currently blocks the binding, then fix the PV side. One of the mismatches cannot be patched in place — handle it correctly. Verify `Bound`.

### Task 14 — ContainerCreating: FailedMount (hard, 8 min)

Context: namespace `t14-diag`. Run the setup first, then diagnose.

```bash
k create ns t14-diag
k apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: site-data
  namespace: t14-diag
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 200Mi
  storageClassName: standard
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: site
  namespace: t14-diag
spec:
  replicas: 1
  selector:
    matchLabels:
      app: site
  template:
    metadata:
      labels:
        app: site
    spec:
      containers:
      - name: nginx
        image: nginx:1.27
        volumeMounts:
        - name: data
          mountPath: /usr/share/nginx/html
        - name: conf
          mountPath: /etc/nginx/conf.d
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: site-data
      - name: conf
        configMap:
          name: site-conf
EOF
```

The `site` pod in `t14-diag` never reaches `Running`. The team already "checked the PVC and it's fine". Find the actual root cause with evidence from events, fix it minimally, and get the pod `Running`.

---

## SOLUTIONS

### Solution 1 — Static binding chain

Fastest route: docs page "Configure a Pod to Use a PersistentVolume for Storage" has all three objects; adjust names. Full manifests:

```bash
k create ns t1-static
```

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-app-logs
spec:
  capacity:
    storage: 1Gi
  accessModes: [ReadWriteOnce]
  storageClassName: manual
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /tmp/app-logs
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: app-logs
  namespace: t1-static
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: manual
---
apiVersion: v1
kind: Pod
metadata:
  name: writer
  namespace: t1-static
spec:
  containers:
  - name: writer
    image: busybox:1.36
    command: ["sleep", "3600"]
    volumeMounts:
    - name: logs
      mountPath: /logs
  volumes:
  - name: logs
    persistentVolumeClaim:
      claimName: app-logs
```

```bash
k get pv pv-app-logs                      # Bound
k get pvc -n t1-static                    # Bound to pv-app-logs
k exec -n t1-static writer -- sh -c 'echo hi > /logs/test && cat /logs/test'
```

Why: class `manual` + capacity + RWO satisfy all five binding rules, so the PV controller binds them; no SC object named `manual` is needed for static matching.

### Solution 2 — hostPath read-only

"Fails fast if absent" = `type: Directory`. Read-only is a volumeMount property, not an accessMode.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: log-reader
  namespace: default
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

```bash
k exec log-reader -- ls /host-logs                       # works
k exec log-reader -- touch /host-logs/x                  # "Read-only file system"
```

Why: `readOnly: true` on the mount enforces read-only; `type: Directory` makes kubelet refuse the mount (loud FailedMount) instead of silently creating an empty dir.

### Solution 3 — Fix the binding mismatch

Diagnose:

```bash
k describe pvc data -n t3-mismatch | tail -5
k get pv pv-t3 -o custom-columns=CAP:.spec.capacity.storage,MODES:.spec.accessModes,CLASS:.spec.storageClassName
```

Two blockers: PV capacity 500Mi < requested 1Gi, and PV modes `[ReadOnlyMany]` do not include the requested `ReadWriteOnce`. Class matches. PVC is immutable in both fields, so patch the PV (both fields are mutable on an unbound PV):

```bash
k patch pv pv-t3 --type merge -p '{"spec":{"capacity":{"storage":"1Gi"},"accessModes":["ReadWriteOnce"]}}'
k get pvc -n t3-mismatch -w      # Bound within ~15s (binder retry loop)
```

Why: binding requires PV capacity >= request AND PV accessModes ⊇ PVC accessModes; fixing the PV side is the only option when the PVC must survive.

### Solution 4 — In-memory cache volume

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cache-pod
  namespace: t4-cache
spec:
  containers:
  - name: writer
    image: busybox:1.36
    command: ["sleep", "3600"]
    resources:
      limits:
        memory: 128Mi
    volumeMounts:
    - name: cache
      mountPath: /cache
  - name: reader
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
k create ns t4-cache && k apply -f cache-pod.yaml
k exec -n t4-cache cache-pod -c writer -- sh -c 'echo v1 > /cache/entry'
k exec -n t4-cache cache-pod -c reader -- cat /cache/entry        # v1
k exec -n t4-cache cache-pod -c reader -- sh -c 'mount | grep /cache'   # tmpfs
```

Why: `medium: Memory` = tmpfs shared across the pod's containers; the limit matters because tmpfs bytes are charged to container memory.

### Solution 5 — Projected volume

```bash
k create ns t5-projected
k create configmap app-config -n t5-projected --from-literal=app.properties=mode=prod
k create secret generic app-secret -n t5-projected --from-literal=api-token=s3cr3t
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: combined-pod
  namespace: t5-projected
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

```bash
k exec -n t5-projected combined-pod -- ls /etc/combined
# api-token  app.properties  pod-labels
k exec -n t5-projected combined-pod -- cat /etc/combined/pod-labels   # tier="backend"
```

Why: `projected` merges multiple sources under one mount point — the docs page "Projected Volumes" has this exact structure to copy.

### Solution 6 — StorageClass + default switch

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-local
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

```bash
k apply -f fast-local.yaml
k patch sc fast-local -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
k patch sc standard -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
k get sc      # only fast-local shows (default)
```

Why: default-ness is only the `storageclass.kubernetes.io/is-default-class` annotation; both patches are needed because Kubernetes will not un-default the old class for you. (Restore `standard` as default after the task if you want the lab pristine.)

### Solution 7 — WFFC observation drill

```bash
k create ns t7-wffc
k apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: wffc-claim
  namespace: t7-wffc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 200Mi
  storageClassName: standard
EOF
k get pvc -n t7-wffc                       # STATUS: Pending — expected
k describe pvc wffc-claim -n t7-wffc | tail -3
# Event: WaitForFirstConsumer  waiting for first consumer to be created before binding
k run consumer -n t7-wffc --image=busybox:1.36 $do -- sleep 3600 > /tmp/consumer.yaml
# add the volume stanza, then:
k apply -f /tmp/consumer.yaml
k get pvc -n t7-wffc -w                    # Pending -> Bound once the pod schedules
```

Consumer pod volume stanza (complete pod for reference):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: consumer
  namespace: t7-wffc
spec:
  containers:
  - name: consumer
    image: busybox:1.36
    command: ["sleep", "3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: wffc-claim
```

Answer: `volumeBindingMode: WaitForFirstConsumer` — provisioning is deferred until the scheduler places a consuming pod, so topology-constrained storage (node-local, zonal) is created where the pod actually runs.

### Solution 8 — Expand a PVC

```bash
k create ns t8-expand
k apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-grow
  namespace: t8-expand
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: standard
---
apiVersion: v1
kind: Pod
metadata:
  name: grow-pod
  namespace: t8-expand
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
      claimName: data-grow
EOF
k get pvc -n t8-expand -w                 # wait for Bound
# Prerequisite: standard has allowVolumeExpansion=false -> the resize would be rejected
k patch sc standard -p '{"allowVolumeExpansion":true}'
k patch pvc data-grow -n t8-expand -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
k get pvc data-grow -n t8-expand -o jsonpath='{.spec.resources.requests.storage} vs {.status.capacity.storage}{"\n"}'
# 2Gi vs 1Gi
k describe pvc data-grow -n t8-expand | tail -5     # waiting-for-external-resize style events
```

Where visible: `spec.resources.requests.storage` = 2Gi (accepted). Where not: `status.capacity` stays 1Gi — local-path has no resizer, so nothing ever performs the resize. Why: expansion needs BOTH the SC flag (API gate) and a driver capable of resizing (execution); on a CSI cluster status converges. Cleanup: `k patch sc standard -p '{"allowVolumeExpansion":false}'` if you want the lab default back.

### Solution 9 — Retain, release, rebind

```bash
k create ns t9-retain
k apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: keep-data
  namespace: t9-retain
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 500Mi
  storageClassName: standard
---
apiVersion: v1
kind: Pod
metadata:
  name: producer
  namespace: t9-retain
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
      claimName: keep-data
EOF
k wait -n t9-retain --for=condition=Ready pod/producer --timeout=120s
k exec -n t9-retain producer -- sh -c 'echo important > /data/marker.txt'

# 2. protect, then delete consumer and claim
PV=$(k get pvc keep-data -n t9-retain -o jsonpath='{.spec.volumeName}')
k patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
k delete pod producer -n t9-retain $now
k delete pvc keep-data -n t9-retain

# 3. survived + data intact
k get pv "$PV"                                    # STATUS: Released (Delete would have destroyed it)
NODE=$(k get pv "$PV" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}')
docker exec "$NODE" sh -c 'cat /var/local-path-provisioner/*/marker.txt'   # important

# 4. free the claimRef, rebind explicitly
k patch pv "$PV" --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'
k get pv "$PV"                                    # STATUS: Available
k apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: keep-data-2
  namespace: t9-retain
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 500Mi
  storageClassName: standard
  volumeName: $PV
EOF
k get pvc keep-data-2 -n t9-retain                # Bound to the same PV
```

Consumer pod to verify:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: consumer2
  namespace: t9-retain
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
      claimName: keep-data-2
```

```bash
k exec -n t9-retain consumer2 -- cat /data/marker.txt    # important
```

Why: Retain keeps PV + data after PVC deletion, but the stale `claimRef` (dead PVC's UID) blocks rebinding until removed; `volumeName` pre-binds the new claim so the provisioner doesn't create a fresh volume instead. Cleanup is manual by design: `k delete pv "$PV"` plus the data dir on the node. Exam-flavor: node inspection is `ssh <node>` + `sudo ls /var/...`, not `docker exec`.

### Solution 10 — local PV with node affinity

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-disks
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-local-ssd
spec:
  capacity:
    storage: 500Mi
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
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: local-claim
  namespace: t10-local
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 400Mi
  storageClassName: local-disks
---
apiVersion: v1
kind: Pod
metadata:
  name: pinned
  namespace: t10-local
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sleep", "3600"]
    volumeMounts:
    - name: disk
      mountPath: /disk
  volumes:
  - name: disk
    persistentVolumeClaim:
      claimName: local-claim
```

```bash
k get pod pinned -n t10-local -o wide      # NODE: cka-worker2
```

Why: with WFFC the scheduler resolves pod placement and volume binding together, and the PV's mandatory `nodeAffinity` leaves `cka-worker2` as the only node where the claim is satisfiable — no pod-level selector needed. (`nodeAffinity` is required on `local:` PVs; the API rejects one without it.)

### Solution 11 — StatefulSet with volumeClaimTemplates

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: t11-sts
spec:
  clusterIP: None
  selector:
    app: web
  ports:
  - port: 80
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: web
  namespace: t11-sts
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
        volumeMounts:
        - name: www
          mountPath: /usr/share/nginx/html
  volumeClaimTemplates:
  - metadata:
      name: www
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: standard
      resources:
        requests:
          storage: 100Mi
```

```bash
k create ns t11-sts && k apply -f web-sts.yaml
k rollout status sts/web -n t11-sts
k get pvc -n t11-sts                       # www-web-0, www-web-1, www-web-2 — all Bound
k exec -n t11-sts web-2 -- sh -c 'echo replica2 > /usr/share/nginx/html/marker'
k scale sts web -n t11-sts --replicas=1
k get pvc -n t11-sts                       # still all 3, still Bound — scale-down retains PVCs
k scale sts web -n t11-sts --replicas=3
k rollout status sts/web -n t11-sts
k exec -n t11-sts web-2 -- cat /usr/share/nginx/html/marker   # replica2
```

Why: PVCs from volumeClaimTemplates are named `<template>-<sts>-<ordinal>` and deliberately survive scale-down so returning ordinals re-attach to their data; deletion is opt-in via `persistentVolumeClaimRetentionPolicy` (GA on recent versions).

### Solution 12 — PVC Pending: missing class

```bash
k get pods -n t12-diag                      # Pending
k describe pod -n t12-diag -l app=web | tail -5
# ...pod has unbound immediate PersistentVolumeClaims
k describe pvc web-data -n t12-diag | tail -3
# ProvisioningFailed: storageclass.storage.k8s.io "gold" not found
k get sc                                    # no gold
```

Root cause: the PVC references StorageClass `gold`, which does not exist. `storageClassName` is immutable and the PVC must not be touched — so create the class:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gold
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
```

```bash
k apply -f gold-sc.yaml
k get pvc,pods -n t12-diag -w      # PVC Bound (the pending pod is the "first consumer"), pod Running
```

Why: creating the missing class un-blocks dynamic provisioning; the already-Pending pod acts as the WFFC consumer, so everything converges without recreating anything.

### Solution 13 — PVC Pending: triple mismatch

```bash
k describe pvc shared -n t13-diag | tail -3
k get pv pv-t13 -o yaml | grep -E 'storage:|accessModes|volumeMode' -A1
```

Blocking rules (all must hold, three fail):

1. Capacity: PV 1Gi < requested 2Gi.
2. Access modes: PV `[ReadWriteOnce]` does not include requested `ReadWriteMany`.
3. volumeMode: PV `Block` vs PVC `Filesystem`.

(Class matches: PV has no class, PVC has `""` — that pair is compatible.)

Capacity and accessModes are patchable on an unbound PV; **volumeMode is immutable** — the patch is rejected with "field is immutable", so the PV must be recreated:

```bash
k patch pv pv-t13 --type merge -p '{"spec":{"volumeMode":"Filesystem"}}'   # fails — proves immutability
k delete pv pv-t13
k apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-t13
spec:
  capacity:
    storage: 2Gi
  accessModes: [ReadWriteMany]
  volumeMode: Filesystem
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /tmp/t13-data
    type: DirectoryOrCreate
EOF
k get pvc shared -n t13-diag -w      # Bound
```

Why: binding needs all five rules simultaneously; deleting an `Available` PV is safe (no data/claim), and recreating is the only route past an immutable field.

### Solution 14 — ContainerCreating: FailedMount

```bash
k get pods -n t14-diag                          # ContainerCreating (NOT Pending — it scheduled)
POD=$(k get pod -n t14-diag -l app=site -o name)
k describe -n t14-diag "$POD" | tail -8
# Warning  FailedMount  MountVolume.SetUp failed for volume "conf" :
#   configmap "site-conf" not found
k get pvc -n t14-diag                           # site-data Bound — the team was right, red herring
```

Root cause: the pod mounts configMap `site-conf`, which doesn't exist. The PVC is healthy — `ContainerCreating` + `FailedMount` points at mount-time volume setup, and the event names the exact missing object. Minimal fix:

```bash
k create configmap site-conf -n t14-diag --from-literal=default.conf='server { listen 80; }'
k get pods -n t14-diag -w        # kubelet retries the mount automatically -> Running
```

Why: a missing configMap/secret blocks container start (ContainerCreating, not CrashLoop), and kubelet's periodic mount retry means creating the object is the entire fix — no pod restart needed.
