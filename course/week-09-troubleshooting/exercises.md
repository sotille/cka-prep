# Week 09 — Troubleshooting Exercises

Lab: 3-node kind cluster `cka` (context `kind-cka`, nodes `cka-control-plane`, `cka-worker`, `cka-worker2`). Aliases assumed: `alias k=kubectl`, `export do="--dry-run=client -o yaml"`, `export now="--grace-period=0 --force"`. Each task has a **setup fence — run it first**, then diagnose and fix without peeking. Where the real exam differs (kubeadm nodes with SSH + sudo instead of `docker exec`), a one-line exam-flavor note says so. Every solution ends with a cleanup line. For deeper node/control-plane breakage drills, use `labs/breakfix/`.

15 tasks. Difficulty tags: **warmup** (know it cold), **exam** (representative of a real item), **hard** (multi-fault or control-plane, the ones that decide the domain). Hard: Tasks 10, 11, 12, 15.

---

### Task 1 — Pod stuck Pending (warmup, 3 min)

Context: namespace `ex01`. A Deployment `hog` was created but its only pod never leaves `Pending`.

```bash
k create ns ex01 2>/dev/null || true
k -n ex01 create deployment hog --image=nginx:1.27
k -n ex01 set resources deployment hog --requests=cpu=64,memory=256Mi
```

Diagnose why the pod is Pending and make it Running. Do not add nodes.

---

### Task 2 — Deployment never becomes available (warmup, 3 min)

Context: namespace `ex02`. Deployment `web` shows `0/1` ready and its pod is not Running.

```bash
k create ns ex02 2>/dev/null || true
k -n ex02 create deployment web --image=nginx:1.99.99-nope
```

Get the pod Running. The intended image is nginx 1.27.

---

### Task 3 — Pod will not start, no logs (exam, 4 min)

Context: namespace `ex03`. Pod `app` is stuck and has never produced a log line.

```bash
k create ns ex03 2>/dev/null || true
cat <<'EOF' | k -n ex03 apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  containers:
  - name: app
    image: nginx:1.27
    envFrom:
    - configMapRef:
        name: app-config
EOF
```

Make `app` reach Running without changing the pod spec's env wiring.

---

### Task 4 — Container keeps restarting (exam, 5 min)

Context: namespace `ex04`. Pod `leaky` restarts every few seconds.

```bash
k create ns ex04 2>/dev/null || true
cat <<'EOF' | k -n ex04 apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: leaky
spec:
  containers:
  - name: leaky
    image: busybox:1.36
    command: ["sh","-c","dd if=/dev/zero of=/dev/shm/fill bs=1M count=150 && sleep 3600"]
    resources:
      limits:
        memory: 64Mi
EOF
```

Identify why it restarts and make it run stably. Keep the container's command as-is.

---

### Task 5 — App Running but Service returns nothing (exam, 4 min)

Context: namespace `ex05`. Deployment `web` is healthy but `http://web.ex05` times out from other pods.

```bash
k create ns ex05 2>/dev/null || true
k -n ex05 create deployment web --image=nginx:1.27 --port=80
k -n ex05 expose deployment web --port=80
k -n ex05 patch service web -p '{"spec":{"selector":{"app":"frontend"}}}'
```

Make the Service serve the app. Verify with a test pod.

---

### Task 6 — Service connects but resets (exam, 4 min)

Context: namespace `ex06`. Service `web` has endpoints, but connecting to it is refused.

```bash
k create ns ex06 2>/dev/null || true
k -n ex06 create deployment web --image=nginx:1.27
k -n ex06 expose deployment web --port=80 --target-port=8080
```

Make `http://web.ex06` return nginx's page.

---

### Task 7 — Service has no endpoints, pods look up (exam, 5 min)

Context: namespace `ex07`. Deployment `api` is `Running` but its Service `api` has no endpoints and the pods sit at `0/1` ready.

```bash
k create ns ex07 2>/dev/null || true
cat <<'EOF' | k -n ex07 apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
      - name: api
        image: nginx:1.27
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /healthz
            port: 80
          initialDelaySeconds: 2
          periodSeconds: 3
EOF
k -n ex07 expose deployment api --port=80
```

Get the pods Ready and the Service populated with endpoints. The container is nginx and must stay nginx.

---

### Task 8 — Pod cannot be placed (exam, 5 min)

Context: namespace `ex08`. Pod `needy` is Pending; the cluster has capacity.

```bash
k create ns ex08 2>/dev/null || true
k taint nodes cka-worker gpu=true:NoSchedule
k taint nodes cka-worker2 gpu=true:NoSchedule
k -n ex08 run needy --image=nginx:1.27
```

Get `needy` Running on a worker node without removing the taints (they belong to another team).

---

### Task 9 — Cluster DNS is down (exam, 3 min)

Context: cluster-wide. Pods can reach Services by ClusterIP but name resolution fails everywhere.

```bash
k -n kube-system scale deployment coredns --replicas=0
```

Restore DNS. Verify `nslookup kubernetes.default` succeeds from a pod.

---

### Task 10 — DNS still broken after the obvious fix (hard, 7 min)

Context: cluster-wide. DNS is dead and there is more than one fault.

```bash
k -n kube-system get configmap coredns -o yaml > /tmp/ex10-coredns.bak.yaml
k -n kube-system get configmap coredns -o yaml \
  | sed 's#forward \. /etc/resolv.conf#forwrad . /etc/resolv.conf#' \
  | k apply -f -
k -n kube-system scale deployment coredns --replicas=0
```

Bring DNS fully back. Keep digging until `nslookup kubernetes.default.svc.cluster.local` resolves from a fresh pod.

---

### Task 11 — A worker went NotReady (hard, 6 min)

Context: node `cka-worker2` shows `NotReady`. Exam-flavor: on a real cluster you would `ssh cka-worker2 && sudo -i`; on kind use `docker exec`.

```bash
docker exec cka-worker2 systemctl stop kubelet
```

Return `cka-worker2` to `Ready`. The fix must survive a node reboot.

---

### Task 12 — Nothing new schedules anywhere (hard, 8 min)

Context: cluster-wide. Every newly created pod stays `Pending` with no events; existing pods are fine. Exam-flavor: control-plane edits happen on the control-plane node's disk.

```bash
docker exec cka-control-plane cp /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/ksched.bak
docker exec cka-control-plane sed -i '/- kube-scheduler$/a\    - --this-flag-does-not-exist=true' /etc/kubernetes/manifests/kube-scheduler.yaml
sleep 15
k run ex12-canary --image=nginx:1.27 --restart=Never
```

Get `ex12-canary` (and scheduling in general) working again.

---

### Task 13 — A user gets Forbidden (exam, 6 min)

Context: namespace `ex13`. ServiceAccount `dev` exists but cannot read pods.

```bash
k create ns ex13 2>/dev/null || true
k -n ex13 create serviceaccount dev
```

Grant `dev` the ability to `get`, `list`, and `watch` pods in `ex13` — and nothing more. Prove it works with `kubectl auth can-i`.

---

### Task 14 — PVC never binds (exam, 4 min)

Context: namespace `ex14`. PVC `data` is stuck `Pending`.

```bash
k create ns ex14 2>/dev/null || true
cat <<'EOF' | k -n ex14 apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: fast
  resources:
    requests:
      storage: 1Gi
EOF
```

Get the PVC `Bound` using the cluster's existing dynamic provisioner (do not hand-craft a PV).

---

### Task 15 — Back up and be ready to restore etcd (hard, 8 min)

Context: control-plane node `cka-control-plane`. No pre-break; this is the etcd snapshot drill. Exam-flavor: identical on kubeadm, run from the control-plane host with `sudo`.

```bash
# no break to run — this task is about producing and validating a snapshot
echo "etcd snapshot drill — take a verified snapshot to /var/lib/etcd-backup.db"
```

Take a snapshot of etcd to `/var/lib/etcd-backup.db` on the control-plane node, then verify the snapshot's integrity. In the solution, be able to state the exact restore procedure.

---
---

# SOLUTIONS

### Task 1 — Pending from insufficient CPU

Diagnosis: `k -n ex01 get pod -o wide` shows `Pending`, `NODE <none>`. `k -n ex01 describe pod -l app=hog | tail` shows `FailedScheduling ... 0/3 nodes are available: 3 Insufficient cpu`. The Deployment requests 64 CPU, more than any node's Allocatable.

```bash
k -n ex01 describe pod -l app=hog | tail -5           # FailedScheduling: Insufficient cpu
k -n ex01 set resources deployment hog --requests=cpu=100m,memory=128Mi
k -n ex01 get pods -w                                  # pod schedules and runs
```

Why: the scheduler cannot find a node with 64 free CPUs; a sane request fits and it binds. Cleanup: `k delete ns ex01`.

---

### Task 2 — ImagePullBackOff from a bad tag

Diagnosis: `k -n ex02 get pods` shows `ImagePullBackOff`. `k -n ex02 describe pod -l app=web | tail` shows `Failed to pull image "nginx:1.99.99-nope": ... not found`. The tag does not exist.

```bash
k -n ex02 describe pod -l app=web | grep -A2 Events    # "not found" pull error
k -n ex02 set image deployment/web '*=nginx:1.27'      # '*' targets every container, no name guessing
k -n ex02 rollout status deployment/web
```

Why: the tag `1.99.99-nope` does not exist, so the kubelet loops on the pull. `kubectl create deployment web` names the container `web`, but the `*=` wildcard sets the image on all containers regardless, so you never have to look the name up. A valid tag pulls cleanly and the rollout completes. Cleanup: `k delete ns ex02`.

---

### Task 3 — CreateContainerConfigError, missing ConfigMap

Diagnosis: `k -n ex03 get pod app` shows `CreateContainerConfigError`. `k -n ex03 describe pod app | tail` shows `Error: configmap "app-config" not found`. `envFrom` references a ConfigMap that does not exist, so the kubelet cannot build the container's environment and never starts it — hence no logs.

```bash
k -n ex03 describe pod app | grep -A3 Events           # "configmap app-config not found"
k -n ex03 create configmap app-config --from-literal=MODE=prod
# the kubelet retries CreateContainerConfigError on its own once the ConfigMap exists — no action needed.
# if you truly want to nudge it, re-apply the SAME Pod manifest; never `delete pod app` — it is a bare
# Pod (no controller), so a delete removes it permanently with nothing to recreate it.
```

Why: the task forbade changing the env wiring, so the fix is to *create the referenced ConfigMap*, not to remove the `envFrom`. Once the key source exists, the container starts. Cleanup: `k delete ns ex03`.

---

### Task 4 — /dev/shm is 64M, so `dd` hits ENOSPC (not a cgroup OOM)

Diagnosis: at `memory: 64Mi` the pod never runs — `k -n ex04 describe pod leaky` shows `State: Waiting, Reason: RunContainerError` with `Last State: Terminated, Reason: StartError, Exit Code: 128` and message `container init was OOM-killed`. The trap is thinking "raise the memory limit." A pod's `/dev/shm` is a **64M tmpfs regardless of the memory limit**, so writing 150 MiB into it fails on space, not on the cgroup. Bump only the limit and you swap one failure for another: `dd: error writing '/dev/shm/fill': No space left on device`, Exit 1, CrashLoopBackOff.

```bash
k -n ex04 describe pod leaky | grep -iA6 'state:'        # RunContainerError / StartError, exit 128
k -n ex04 delete pod leaky
cat <<'EOF' | k -n ex04 apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: leaky
spec:
  volumes:
  - name: shm
    emptyDir:
      medium: Memory
      sizeLimit: 200Mi
  containers:
  - name: leaky
    image: busybox:1.36
    command: ["sh","-c","dd if=/dev/zero of=/dev/shm/fill bs=1M count=150 && sleep 3600"]
    resources:
      limits:
        memory: 256Mi
    volumeMounts:
    - name: shm
      mountPath: /dev/shm
EOF
k -n ex04 get pod leaky -w                               # Running and stable
```

Why: the fix must enlarge `/dev/shm`, which the default 64M tmpfs cannot hold. Mounting an `emptyDir{medium: Memory, sizeLimit: 200Mi}` at `/dev/shm` gives the write room to land; because memory-backed tmpfs pages are charged to the pod's memory cgroup, you also need a `memory` limit above the working set (256Mi ≥ 150M written + overhead). The command is unchanged, as required. Note the exit codes: Exit 137 / `Reason: OOMKilled` would be a genuine working-set OOM — here you see `StartError`/128 (init OOM-killed at the tight limit) or `No space left on device`, both pointing at the tmpfs, not the limit. Cleanup: `k delete ns ex04`.

---

### Task 5 — Service selector mismatch

Diagnosis: pods are `Running`/`Ready` but `k -n ex05 describe svc web | grep -i endpoints` shows `Endpoints: <none>`. The Service selector is `app=frontend`; the pods carry `app=web`. No match → no endpoints → timeout.

```bash
k -n ex05 get pods --show-labels                        # app=web
k -n ex05 get svc web -o jsonpath='{.spec.selector}{"\n"}'   # {"app":"frontend"}
k -n ex05 patch service web -p '{"spec":{"selector":{"app":"web"}}}'
k -n ex05 describe svc web | grep -i endpoints          # now populated
k run tmp --rm -it --image=busybox:1.36 --restart=Never -- wget -qO- --timeout=2 http://web.ex05
```

Why: the EndpointSlice controller only lists pods whose labels match the Service selector; fixing the selector repopulates endpoints and kube-proxy programs the DNAT. Cleanup: `k delete ns ex05`.

---

### Task 6 — targetPort mismatch

Diagnosis: `k -n ex06 describe svc web` shows endpoints present (selector is fine) but `TargetPort: 8080`. nginx listens on 80, so the DNAT sends traffic to a closed port → connection refused.

```bash
k -n ex06 get endpointslices -l kubernetes.io/service-name=web   # endpoints exist -> not a selector bug
k -n ex06 get svc web -o jsonpath='{.spec.ports[0].targetPort}{"\n"}'   # 8080 (wrong)
k -n ex06 patch service web --type=json \
  -p='[{"op":"replace","path":"/spec/ports/0/targetPort","value":80}]'
k run tmp --rm -it --image=busybox:1.36 --restart=Never -- wget -qO- --timeout=2 http://web.ex06
```

Why: `port` is what clients hit on the ClusterIP; `targetPort` must equal the container's listening port. Correcting `targetPort` to 80 makes the DNAT land on nginx. Cleanup: `k delete ns ex06`.

---

### Task 7 — Readiness probe draining the Service

Diagnosis: pods are `Running` but `0/1 READY`; `k -n ex07 get endpoints api` is empty. `k -n ex07 describe pod -l app=api | grep -A2 Events` shows `Readiness probe failed: HTTP probe returned statusCode: 404`. nginx returns 404 for `/healthz`, so readiness never passes and the pods are held out of endpoints.

```bash
k -n ex07 get pods                                       # 0/1 READY, Running
k -n ex07 describe pod -l app=api | grep -i 'readiness'   # 404 on /healthz
k -n ex07 patch deployment api --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/"}]'
k -n ex07 rollout status deployment/api
k -n ex07 get endpoints api                               # now has the pod IPs
```

Why: readiness gates endpoint membership. nginx serves `/` with 200; pointing the probe at `/` makes it pass, the pods flip to Ready, and the Service fills. A "dead Service" was really a probe misconfiguration. Cleanup: `k delete ns ex07`.

---

### Task 8 — Taint without toleration

Diagnosis: `k -n ex08 describe pod needy | tail` shows `FailedScheduling ... node(s) had untolerated taint {gpu: true}` for the workers, plus the control-plane's own `node-role.kubernetes.io/control-plane` taint. The pod tolerates nothing, so no node accepts it.

```bash
k -n ex08 describe pod needy | tail -6                    # untolerated taint {gpu: true}
k -n ex08 delete pod needy
cat <<'EOF' | k -n ex08 apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: needy
spec:
  tolerations:
  - key: gpu
    operator: Equal
    value: "true"
    effect: NoSchedule
  containers:
  - name: needy
    image: nginx:1.27
EOF
k -n ex08 get pod needy -o wide                           # Running on a worker
```

Why: the taints stay (another team owns them); the pod must *tolerate* `gpu=true:NoSchedule` to be admitted onto a worker. Cleanup: `k -n ex08 delete pod needy; k taint nodes cka-worker gpu=true:NoSchedule-; k taint nodes cka-worker2 gpu=true:NoSchedule-; k delete ns ex08`.

---

### Task 9 — CoreDNS scaled to zero

Diagnosis: `k -n kube-system get deploy coredns` shows `0/0`. No CoreDNS pod = no DNS. `nslookup` from a pod times out.

```bash
k -n kube-system get deploy coredns                      # READY 0/0
k -n kube-system scale deployment coredns --replicas=2
k -n kube-system rollout status deployment coredns
k run dnstest --rm -it --image=busybox:1.36 --restart=Never -- nslookup kubernetes.default
```

Why: the `kube-dns` Service and its ClusterIP were intact; only the backing pods were gone. Scaling back to 2 restores resolution. Cleanup: none (this is the correct steady state).

---

### Task 10 — Two DNS faults: scaled to zero AND corrupt Corefile

Diagnosis: scaling CoreDNS back up is not enough — the pods then land in `CrashLoopBackOff`. `k -n kube-system logs -l k8s-app=kube-dns --previous` shows `Corefile:N - Error during parsing: Unknown directive 'forwrad'`. The ConfigMap has a typo (`forwrad` for `forward`), so CoreDNS refuses to start even once replicas exist.

```bash
k -n kube-system scale deployment coredns --replicas=2
k -n kube-system get pods -l k8s-app=kube-dns             # CrashLoopBackOff
k -n kube-system logs -l k8s-app=kube-dns --previous | grep -i error   # "Unknown directive 'forwrad'"
k -n kube-system edit configmap coredns                   # change forwrad -> forward
# or restore from the backup taken in setup:
# k apply -f /tmp/ex10-coredns.bak.yaml
k -n kube-system rollout restart deployment coredns
k run dnstest --rm -it --image=busybox:1.36 --restart=Never -- nslookup kubernetes.default.svc.cluster.local
```

Why: two independent faults — zero replicas *and* an unparseable Corefile. You must fix both; the `reload` plugin picks up the corrected ConfigMap, and the restart guarantees a clean parse. This is the "keep digging" lesson: the first fix revealing a second fault is common on the exam. Cleanup: `rm -f /tmp/ex10-coredns.bak.yaml` (state is now healthy).

---

### Task 11 — kubelet stopped on a worker

Diagnosis: `k get nodes` shows `cka-worker2 NotReady`. `k describe node cka-worker2 | grep -A6 Conditions` → `Ready False, kubelet stopped posting node status`. On the node, `systemctl status kubelet` shows it is `inactive (dead)`.

```bash
k get nodes                                               # cka-worker2 NotReady
docker exec cka-worker2 systemctl status kubelet          # inactive (dead)
docker exec cka-worker2 systemctl enable --now kubelet    # start AND enable (survives reboot)
k get nodes -w                                            # cka-worker2 -> Ready in ~30-60s
```

Why: the node was NotReady because its kubelet stopped posting status. `enable --now` both starts it now and marks it to start at boot, satisfying "survive a reboot." Exam-flavor: on kubeadm, `ssh cka-worker2` then `sudo systemctl enable --now kubelet`. Cleanup: none (node is correctly Ready and kubelet enabled).

---

### Task 12 — Bad flag in the kube-scheduler static pod

Diagnosis: `ex12-canary` is `Pending` with no events (`k describe pod ex12-canary | tail` shows an empty Events block). No scheduling events = the scheduler is not running. `k -n kube-system get pods | grep scheduler` shows `kube-scheduler-cka-control-plane` in `CrashLoopBackOff`; its log shows `unknown flag: --this-flag-does-not-exist`. The static pod manifest has a bogus flag.

```bash
k get pod ex12-canary -o wide                             # Pending, NODE <none>
k describe pod ex12-canary | tail -3                      # Events: <none>  -> scheduler down
k -n kube-system get pods | grep scheduler                # CrashLoopBackOff
k -n kube-system logs kube-scheduler-cka-control-plane | tail -3   # unknown flag
# fix the manifest on disk (kubelet reconciles automatically):
docker exec cka-control-plane sed -i '/--this-flag-does-not-exist=true/d' /etc/kubernetes/manifests/kube-scheduler.yaml
# or restore the backup taken in setup:
# docker exec cka-control-plane cp /tmp/ksched.bak /etc/kubernetes/manifests/kube-scheduler.yaml
sleep 20
k -n kube-system get pods | grep scheduler                # Running
k get pod ex12-canary -o wide                             # now Scheduled/Running
```

Why: the kubelet runs whatever `/etc/kubernetes/manifests/kube-scheduler.yaml` says; a flag the binary rejects makes it crash-loop, and with no scheduler, nothing binds — Pending with zero events is the fingerprint. Editing the file (not `kubectl edit`) and waiting for the kubelet to re-create the pod restores scheduling. Exam-flavor: edit the file directly on the control-plane host. Cleanup: `k delete pod ex12-canary; rm -f /tmp/ksched.bak` after confirming the scheduler is Running.

---

### Task 13 — RBAC: grant least-privilege pod read

Diagnosis: `k auth can-i list pods --as=system:serviceaccount:ex13:dev -n ex13` returns `no`. The ServiceAccount has no Role bound, so every request is 403 Forbidden (authenticated as the SA, but not authorized).

```bash
k auth can-i list pods --as=system:serviceaccount:ex13:dev -n ex13   # no
k -n ex13 create role pod-reader --verb=get,list,watch --resource=pods
k -n ex13 create rolebinding dev-pod-reader --role=pod-reader --serviceaccount=ex13:dev
k auth can-i list pods --as=system:serviceaccount:ex13:dev -n ex13   # yes
k auth can-i create pods --as=system:serviceaccount:ex13:dev -n ex13  # no (least privilege held)
```

Why: 403 means authorization, not authentication — the fix is RBAC, not credentials. A namespaced Role limited to `get,list,watch` on `pods` plus a RoleBinding to the SA grants exactly what was asked and nothing more. Cleanup: `k delete ns ex13`.

---

### Task 14 — PVC references a nonexistent StorageClass (and `standard` is WaitForFirstConsumer)

Diagnosis: `k -n ex14 describe pvc data | tail` shows `storageclass.storage.k8s.io "fast" not found`. The PVC names a StorageClass (`fast`) that does not exist, so no provisioner acts on it. The real default is `standard` (kind's local-path provisioner) — but its `VolumeBindingMode` is `WaitForFirstConsumer`, so pointing at it is necessary *and not sufficient*: the claim binds only once a Pod that mounts it is scheduled.

```bash
k -n ex14 describe pvc data | tail -4                     # "fast" not found
k get storageclass                                        # standard (default), WaitForFirstConsumer
k -n ex14 delete pvc data
cat <<'EOF' | k -n ex14 apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: standard
  resources:
    requests:
      storage: 1Gi
EOF
k -n ex14 get pvc data                                    # still Pending: "waiting for first consumer"
# WaitForFirstConsumer binds only after a Pod mounts the claim — create a consumer:
cat <<'EOF' | k -n ex14 apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: data-consumer
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
EOF
k -n ex14 get pvc data -w                                 # Bound once the pod schedules
```

Why: `spec.storageClassName` is immutable, so the PVC must be recreated pointing at a class that exists. But `standard` uses `WaitForFirstConsumer`, so the bare claim stays Pending with `waiting for first consumer to be created before binding` — it binds only after a Pod that references it is scheduled, letting the provisioner place the volume on that Pod's node. Omitting `storageClassName` would also fall through to the default class, but you still need the consumer Pod to trigger binding. Cleanup: `k delete ns ex14`.

---

### Task 15 — etcd snapshot (and the restore you must be ready to run)

Diagnosis / procedure: etcd runs as a **distroless** static pod. On this kind cluster `etcdctl` is *not* installed on the node host, so `docker exec cka-control-plane etcdctl ...` returns `etcdctl: not found` — the binary lives only inside the etcd container. Run it there with `kubectl exec` (no `sh -c`; the image has no shell), using the apiserver's etcd client certs from `/etc/kubernetes/pki/etcd/`.

```bash
# take the snapshot from INSIDE the etcd pod:
kubectl -n kube-system exec etcd-cka-control-plane -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd-backup.db

# verify integrity. On etcd >=3.6 (this cluster is 3.6.x) snapshot status/restore moved to etcdutl:
kubectl -n kube-system exec etcd-cka-control-plane -- etcdutl \
  --write-out=table snapshot status /var/lib/etcd-backup.db
```

Restore (state the exact steps; only run in a throwaway cluster — it rewrites cluster state):

```text
1. Restore the snapshot to a NEW data dir (etcd >=3.6: use etcdutl; etcd 3.5 still
   accepts `etcdctl snapshot restore` with a deprecation warning):
   etcdutl snapshot restore /var/lib/etcd-backup.db --data-dir /var/lib/etcd-restore
2. Point etcd at it: edit /etc/kubernetes/manifests/etcd.yaml, change the hostPath
   volume backing /var/lib/etcd (the "etcd-data" volume) to /var/lib/etcd-restore.
3. The kubelet restarts the etcd static pod from the new data dir; the apiserver reconnects.
4. Verify: k get nodes ; k get pods -A  reflect the snapshot's point-in-time state.
```

Why: `snapshot save` needs a *running* etcd and the mutual-TLS certs; `snapshot status` proves the file is a valid etcd snapshot (hash, revision, total keys) before you ever depend on it. On etcd 3.6 the `status` and `restore` subcommands were moved out of `etcdctl` into `etcdutl` (`snapshot save` stays in `etcdctl`). Restore is offline — it writes a new data dir and does nothing until etcd's manifest is repointed and the kubelet restarts the pod. Exam-flavor: on a kubeadm control-plane host `etcdctl`/`etcdutl` are on `PATH`, so you run the same commands directly under `sudo` (writing to the host's `/var/lib/etcd-backup.db`); the exam's older etcd (3.5.x) may still take `etcdctl snapshot restore/status` with a deprecation warning. Cleanup: the snapshot sits in the etcd pod's writable layer and is discarded when the static pod is recreated — nothing on the host to remove; do NOT run the restore on the shared lab cluster.
