# Week 03 Exercises — Scheduling

Lab: 3-node kind cluster `cka` (`kubectl config use-context kind-cka`) — nodes `cka-control-plane` (tainted `node-role.kubernetes.io/control-plane:NoSchedule`), `cka-worker`, `cka-worker2`. Aliases assumed: `alias k=kubectl`, `export do="--dry-run=client -o yaml"`, `export now="--grace-period=0 --force"`. The kind nodes have **no** `topology.kubernetes.io/zone` labels by default — tasks that need zones create them in their setup fence. Each task states its namespace; setup fences create anything that must pre-exist. On the real exam every task opens with a printed `kubectl config use-context ...` line — run it first, always; that reflex is part of what you are drilling here. Cleanup at the end removes labels, taints, and namespaces.

---

## Tasks

### 1. Manual scheduling with `nodeName` (warmup, 3 min)

Context: namespace `sched`. The default scheduler is running normally.

Create namespace `sched`. In it, create a pod `pinned` using image `nginx:1.27` that runs on `cka-worker2` **without using the scheduler** and without any node labels. Then explain in one line why this pod would still land on a node even if that node were full or tainted.

---

### 2. `nodeSelector` placement (warmup, 4 min)

Context: namespace `sched`.

Label node `cka-worker` with `disktype=ssd`. Create a pod `ssd-only` (image `nginx:1.27`) in `sched` that the **scheduler** may only place on nodes carrying `disktype=ssd`. Verify it landed on `cka-worker`.

---

### 3. Taint a node, schedule a tolerating pod (exam, 5 min)

Context: namespace `sched`.

Taint `cka-worker2` with `dedicated=batch:NoSchedule`. Create a pod `batch-job` (image `busybox:1.36`, command `sleep infinity`) that is **allowed** to run on `cka-worker2`, and confirm it can. Then note in one line why adding only the toleration does not guarantee the pod actually lands on `cka-worker2`.

---

### 4. `NoExecute` evicts running pods (exam, 5 min)

Context: namespace `sched`. Two pods already run on `cka-worker`.

Setup:

```bash
k -n sched run stayer --image=nginx:1.27 --overrides='{"spec":{"nodeName":"cka-worker"}}'
k -n sched run leaver --image=nginx:1.27 --overrides='{"spec":{"nodeName":"cka-worker"}}'
k -n sched wait --for=condition=Ready pod/stayer pod/leaver --timeout=60s
```

Make `pod/stayer` survive a `NoExecute` taint on `cka-worker` while `pod/leaver` is evicted. Apply taint `drain-test=yes:NoExecute` to `cka-worker`, then show that `leaver` is gone and `stayer` still runs. Remove the taint afterwards.

---

### 5. Required node affinity with OR + AND (exam, 6 min)

Context: namespace `sched`. Nodes need zone/disk labels (created in setup).

Setup:

```bash
k label node cka-worker  topology.kubernetes.io/zone=zone-a disktype=ssd --overwrite
k label node cka-worker2 topology.kubernetes.io/zone=zone-b disktype=hdd --overwrite
```

Create a pod `affinity-pod` (image `nginx:1.27`) in `sched` with a **required** node affinity that admits nodes in zone `zone-a` **or** `zone-b` **and** having `disktype=ssd`. Given the labels above, which node must it land on, and why? Verify.

---

### 6. Preferred affinity as a tie-breaker (exam, 5 min)

Context: namespace `sched`, using the zone/disk labels from task 5.

Create a pod `pref-pod` (image `nginx:1.27`) that is allowed on any worker node but **prefers** nodes in `zone-b` with weight 100. Confirm which node the scheduler chose and explain in one line why the preference is not a guarantee.

---

### 7. Pod anti-affinity: one replica per node (exam, 6 min)

Context: namespace `sched`.

Create a deployment `spread-app` (image `nginx:1.27`, 2 replicas, label `app=spread-app`) whose pods must **never** share a node with another `spread-app` pod. Verify the two replicas land on two different worker nodes. Then scale to 3 replicas and explain what happens to the third pod (given the control-plane taint) and why.

---

### 8. Topology spread 2-2-2 across the three nodes (exam, 6 min)

Context: namespace `sched`. To use all three nodes, the deployment must tolerate the control-plane taint.

Create a deployment `even-app` (image `nginx:1.27`, 6 replicas, label `app=even-app`) that spreads its pods **evenly across all three nodes** (2 per node) using `topologySpreadConstraints` with `maxSkew: 1` and `whenUnsatisfiable: DoNotSchedule` on `kubernetes.io/hostname`. Because `cka-control-plane` is tainted, the pods must tolerate it. Verify the 2-2-2 distribution.

---

### 9. Cordon and drain with DaemonSet + emptyDir present (exam, 5 min)

Context: namespace `sched`. A DaemonSet and an `emptyDir`-using pod exist on the target node.

Setup:

```bash
k -n sched apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: agent
  namespace: sched
spec:
  selector:
    matchLabels:
      app: agent
  template:
    metadata:
      labels:
        app: agent
    spec:
      tolerations:
        - operator: Exists
      containers:
        - name: c
          image: busybox:1.36
          command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: scratch
  namespace: sched
spec:
  nodeName: cka-worker
  containers:
    - name: c
      image: busybox:1.36
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: tmp
          mountPath: /data
  volumes:
    - name: tmp
      emptyDir: {}
EOF
k -n sched wait --for=condition=Ready pod/scratch --timeout=60s
```

Drain `cka-worker` for maintenance. The DaemonSet pod must **not** block the drain and the `scratch` pod's ephemeral data may be discarded. Note that `scratch` is a **bare pod** (no controller). Then bring the node back into service. State which three flags you needed and why.

---

### 10. Static pod on a kind worker (exam, 6 min)

Context: no namespace needed (static pods default to `default`). You will act directly on the node `cka-worker`.

Create a **static pod** named `static-web` (image `nginx:1.27`) that runs on `cka-worker` via the kubelet's static-pod path. Verify it appears in the API as a mirror pod and prove it is static (not controller-managed). Then stop it cleanly.

Exam-flavor note: on the real exam you `ssh` to the node and `sudo` write into `/etc/kubernetes/manifests/`; on kind you reach the node with `docker exec`/`docker cp` instead.

---

### 11. PriorityClass and preemption (hard, 10 min)

Context: namespace `sched`. You will make a high-priority pod evict a low-priority one.

Setup:

```bash
k create priorityclass low-prio  --value=1000    --description="low"  2>/dev/null || true
k create priorityclass high-prio --value=1000000 --description="high" 2>/dev/null || true
k label node cka-worker preempt=demo --overwrite
k cordon cka-worker2
```

Create a low-priority pod `hog` (priorityClassName `low-prio`, image `nginx:1.27`) pinned to `cka-worker` (via `nodeSelector: preempt=demo`) that requests enough CPU to nearly fill the node. Then create a high-priority pod `vip` (priorityClassName `high-prio`, same nodeSelector, same large CPU request). Show that `vip` preempts `hog`: `hog` is evicted and `vip` runs. Read the event that proves preemption. Uncordon `cka-worker2` afterwards.

---

### 12. Drain blocked by a PodDisruptionBudget (hard, 8 min)

Context: namespace `pdb-lab`. A 2-replica app with a strict PDB pins availability so a drain cannot proceed.

Setup:

```bash
k create ns pdb-lab
k -n pdb-lab create deployment web --image=nginx:1.27 --replicas=2
k -n pdb-lab patch deployment web --type=merge -p '{"spec":{"template":{"spec":{"topologySpreadConstraints":[{"maxSkew":1,"topologyKey":"kubernetes.io/hostname","whenUnsatisfiable":"DoNotSchedule","labelSelector":{"matchLabels":{"app":"web"}}}]}}}}'
k -n pdb-lab rollout status deploy/web
k -n pdb-lab create pdb web-pdb --selector=app=web --min-available=2
```

A colleague started a maintenance window and ran `k drain cka-worker --ignore-daemonsets --delete-emptydir-data`, but it hangs. Determine why, prove it with the PDB's allowed-disruptions count, and adjust the PDB so the drain of `cka-worker` completes while still protecting the app as much as possible. Uncordon the node when done.

---

### 13. Diagnose a Pending pod: untolerated taint (exam, 4 min)

Context: namespace `diag`. One pod is stuck Pending.

Setup:

```bash
k create ns diag
k taint nodes cka-worker  reserved=true:NoSchedule --overwrite
k taint nodes cka-worker2 reserved=true:NoSchedule --overwrite
k -n diag run t1 --image=nginx:1.27
```

Pod `t1` in `diag` is Pending. Identify the exact root cause from the scheduler event, then make it run **without removing the taints from the nodes**. Clean up the taints afterwards.

---

### 14. Diagnose a Pending pod: unsatisfiable node affinity (exam, 4 min)

Context: namespace `diag`. One pod is stuck Pending.

Setup:

```bash
k -n diag apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: t2
  namespace: diag
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: gpu
                operator: In
                values: ["true"]
  containers:
    - name: c
      image: nginx:1.27
EOF
```

Pod `t2` is Pending. Name the root cause from the event, then make it schedule by satisfying the affinity (do **not** edit the pod). Verify it lands where you expect.

---

### 15. Diagnose a Pending pod: Insufficient cpu (exam, 5 min)

Context: namespace `diag`. One pod is stuck Pending because of its resource request.

Setup:

```bash
k -n diag apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: t3
  namespace: diag
spec:
  containers:
    - name: c
      image: nginx:1.27
      resources:
        requests:
          cpu: "9999"
EOF
```

Pod `t3` is Pending. Prove from the event that it is a resource problem (not a taint or affinity one), then make it run with the **smallest** change to the pod's spec. Verify.

---

### 16. Diagnose the silent Pending: wrong `schedulerName` (hard, 6 min)

Context: namespace `diag`. A pod is Pending but `kubectl describe` shows **no** scheduling events at all.

Setup:

```bash
k -n diag apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: t4
  namespace: diag
spec:
  schedulerName: ghost-scheduler
  containers:
    - name: c
      image: nginx:1.27
EOF
```

Pod `t4` is Pending with no `FailedScheduling` event. Explain why there is no event, identify the two fields that can produce this "silent Pending" signature, confirm which one applies here, and make `t4` run. (You may recreate the pod.)

---

### 17. Dedicated-node pattern: taint + toleration + affinity (hard, 8 min)

Context: namespace `sched`. You must reserve `cka-worker2` for a specific workload — nothing else may schedule there, and the workload must actually go there.

Reserve `cka-worker2` for `team=payments` workloads: no other pods may land on it, and pods of the payments deployment must run **only** on it. Create the deployment `payments` (image `nginx:1.27`, 2 replicas, label `app=payments`) so that both replicas run on `cka-worker2`. Then create a plain pod `intruder` (image `nginx:1.27`, no special config) in `sched` and confirm it does **not** land on `cka-worker2`. Explain in one line why the toleration alone was insufficient.

---

## Cleanup

```bash
k delete ns sched diag pdb-lab --ignore-not-found
k delete priorityclass low-prio high-prio --ignore-not-found
k taint nodes cka-worker  drain-test- reserved- dedicated- 2>/dev/null || true
k taint nodes cka-worker2 dedicated- reserved- team- 2>/dev/null || true
k label node cka-worker  disktype- topology.kubernetes.io/zone- preempt- 2>/dev/null || true
k label node cka-worker2 disktype- topology.kubernetes.io/zone- team- 2>/dev/null || true
k uncordon cka-worker cka-worker2 2>/dev/null || true
# static pod (task 10) — remove the manifest ON the node if still present:
docker exec cka-worker rm -f /etc/kubernetes/manifests/static-web.yaml 2>/dev/null || true
```

---

# SOLUTIONS

### 1. Manual scheduling with `nodeName`

```bash
k create ns sched
k -n sched run pinned --image=nginx:1.27 --overrides='{"spec":{"nodeName":"cka-worker2"}}'
k -n sched get pod pinned -o wide      # NODE = cka-worker2
```

Equivalent explicit YAML:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pinned
  namespace: sched
spec:
  nodeName: cka-worker2
  containers:
    - name: pinned
      image: nginx:1.27
```

Why: setting `.spec.nodeName` bypasses the scheduler completely — the kubelet on `cka-worker2` runs the pod directly, so the `NodeResourcesFit` and `TaintToleration` filters never run, and a full or tainted node would still accept it (only to possibly evict/OOM it later).

---

### 2. `nodeSelector` placement

```bash
k label node cka-worker disktype=ssd --overwrite
k -n sched run ssd-only --image=nginx:1.27 --overrides='{"spec":{"nodeSelector":{"disktype":"ssd"}}}'
k -n sched get pod ssd-only -o wide     # NODE = cka-worker
```

YAML form:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ssd-only
  namespace: sched
spec:
  nodeSelector:
    disktype: ssd
  containers:
    - name: ssd-only
      image: nginx:1.27
```

Why: `nodeSelector` is an ANDed exact-match against node labels enforced by the `NodeAffinity` filter; only `cka-worker` carries `disktype=ssd`, so it is the only feasible node.

---

### 3. Taint a node, schedule a tolerating pod

```bash
k taint nodes cka-worker2 dedicated=batch:NoSchedule
k -n sched apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: batch-job
  namespace: sched
spec:
  tolerations:
    - key: dedicated
      operator: Equal
      value: batch
      effect: NoSchedule
  containers:
    - name: c
      image: busybox:1.36
      command: ["sleep", "infinity"]
EOF
k -n sched get pod batch-job -o wide
```

Why the toleration alone does not guarantee `cka-worker2`: a toleration only *removes the barrier* on the tainted node; it does not attract the pod. `cka-worker` is untainted and equally (or more) feasible, so the scheduler may place `batch-job` there. To force `cka-worker2` you would add `nodeSelector`/affinity as well (see task 17).

---

### 4. `NoExecute` evicts running pods

Add a `NoExecute` toleration to `stayer` — but `stayer` already exists, so recreate it with the toleration (a running pod's tolerations are immutable for this purpose). Simplest: delete and recreate `stayer` with the toleration, leave `leaver` as-is, then taint.

```bash
k -n sched delete pod stayer --now
k -n sched apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: stayer
  namespace: sched
spec:
  nodeName: cka-worker
  tolerations:
    - key: drain-test
      operator: Equal
      value: "yes"
      effect: NoExecute
  containers:
    - name: c
      image: nginx:1.27
EOF
k -n sched wait --for=condition=Ready pod/stayer --timeout=60s

k taint nodes cka-worker drain-test=yes:NoExecute        # evicts non-tolerating pods

k -n sched get pods -o wide        # leaver: NotFound/Terminating; stayer: Running
k taint nodes cka-worker drain-test=yes:NoExecute-       # remove the taint
```

Why: `NoExecute` evicts already-running pods that do not tolerate it. `leaver` has no matching toleration → evicted (and, being a bare pod, not recreated). `stayer` tolerates `drain-test=yes:NoExecute` with no `tolerationSeconds`, so it stays indefinitely.

---

### 5. Required node affinity with OR + AND

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: affinity-pod
  namespace: sched
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: topology.kubernetes.io/zone
                operator: In
                values: ["zone-a", "zone-b"]
              - key: disktype
                operator: In
                values: ["ssd"]
  containers:
    - name: c
      image: nginx:1.27
```

```bash
k -n sched apply -f affinity-pod.yaml
k -n sched get pod affinity-pod -o wide     # NODE = cka-worker
```

Why `cka-worker`: the single term ANDs two expressions — zone in {zone-a, zone-b} AND disktype=ssd. `cka-worker` is zone-a + ssd (matches both); `cka-worker2` is zone-b + hdd (fails the disktype expression); `cka-control-plane` has neither label. The `In [zone-a, zone-b]` set is the "OR" between zones *inside one expression* — one term, so both expressions must hold.

---

### 6. Preferred affinity as a tie-breaker

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pref-pod
  namespace: sched
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: topology.kubernetes.io/zone
                operator: Exists
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          preference:
            matchExpressions:
              - key: topology.kubernetes.io/zone
                operator: In
                values: ["zone-b"]
  containers:
    - name: c
      image: nginx:1.27
```

```bash
k -n sched apply -f pref-pod.yaml
k -n sched get pod pref-pod -o wide     # NODE = cka-worker2 (zone-b) in the normal case
```

Why not a guarantee: `preferredDuringScheduling` only adds to a node's **score**; if `cka-worker2` were full, cordoned, or heavily loaded, the weighted score of `cka-worker` could win and the pod would land there instead. The required term here (`zone Exists`) limits candidates to the two labelled workers; the preference just biases toward zone-b.

---

### 7. Pod anti-affinity: one replica per node

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spread-app
  namespace: sched
spec:
  replicas: 2
  selector:
    matchLabels:
      app: spread-app
  template:
    metadata:
      labels:
        app: spread-app
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: spread-app
              topologyKey: kubernetes.io/hostname
      containers:
        - name: c
          image: nginx:1.27
```

```bash
k -n sched apply -f spread-app.yaml
k -n sched get pods -l app=spread-app -o wide    # two different worker nodes
k -n sched scale deploy/spread-app --replicas=3
k -n sched get pods -l app=spread-app -o wide    # third pod stays Pending
```

Why the third pod is Pending: the anti-affinity forbids two `spread-app` pods on the same `kubernetes.io/hostname`, so it needs a third distinct node. The only remaining node is `cka-control-plane`, which is tainted `NoSchedule` and the pod has no toleration — so no feasible node remains and the third replica is `Pending` (`didn't satisfy existing pods anti-affinity rules` plus the untolerated control-plane taint). This is correct behavior, not a bug.

---

### 8. Topology spread 2-2-2 across the three nodes

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: even-app
  namespace: sched
spec:
  replicas: 6
  selector:
    matchLabels:
      app: even-app
  template:
    metadata:
      labels:
        app: even-app
    spec:
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: even-app
      containers:
        - name: c
          image: nginx:1.27
```

```bash
k -n sched apply -f even-app.yaml
k -n sched rollout status deploy/even-app
k -n sched get pods -l app=even-app -o wide --sort-by=.spec.nodeName
# tally per node:
k -n sched get pods -l app=even-app -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c
```

Why: `maxSkew: 1` over three `kubernetes.io/hostname` domains with 6 pods forces the busiest and emptiest domains to differ by at most 1 → the only satisfying layout is 2-2-2. The control-plane toleration is what makes `cka-control-plane` a feasible third domain. Without it, only the two workers are eligible; 6 pods would land 3-3 (skew 0, still valid) — perfectly balanced but across two nodes, not the three the task requires. The toleration is therefore mandatory to hit 2-2-2.

---

### 9. Cordon and drain with DaemonSet + emptyDir present

```bash
k drain cka-worker --ignore-daemonsets --delete-emptydir-data --force
# ... maintenance ...
k uncordon cka-worker
```

Verify:

```bash
k get node cka-worker                              # SchedulingDisabled during drain
k -n sched get pods -o wide                        # scratch gone; agent-* still there (DS)
```

Which flags and why — **three** are required, because `scratch` trips two independent checks at once (local storage *and* unmanaged), plus the DaemonSet:

- `--ignore-daemonsets` because the `agent` DaemonSet pod cannot be evicted (it would be recreated immediately) — without it, drain refuses (`cannot delete DaemonSet-managed Pods`).
- `--delete-emptydir-data` because the `scratch` pod mounts an `emptyDir`; drain will not silently destroy that data without consent (`cannot delete Pods with local storage`).
- `--force` because `scratch` is a **bare pod** — `kind: Pod` with no owner reference, not managed by a ReplicaSet/Deployment/Job/StatefulSet/DaemonSet. drain's local-storage check and its unmanaged-pod check are *independent*: `--delete-emptydir-data` only satisfies the former. Without `--force` drain still refuses (`cannot delete Pods not managed by ReplicationController, ReplicaSet, Job, DaemonSet or StatefulSet (use --force to override): sched/scratch`).

Drop any one flag and the drain aborts naming the missing one. Note `--force` here does **not** delete-then-recreate; a bare pod, once evicted, is simply gone (see below).

> Note: `scratch` is a bare pod, so once evicted it is not recreated — that is expected. On the real exam, drained application pods are Deployment/StatefulSet-managed and reschedule onto other nodes.

---

### 10. Static pod on a kind worker

```bash
# 1. generate the manifest locally
k run static-web --image=nginx:1.27 $do > static-web.yaml

# 2. drop it into the kubelet's staticPodPath ON cka-worker
docker cp static-web.yaml cka-worker:/etc/kubernetes/manifests/static-web.yaml

# 3. the kubelet runs it; a mirror pod appears in the API within seconds
k get pods -A | grep static-web            # static-web-cka-worker   Running

# 4. prove it is static (owner is the Node, not a ReplicaSet/DaemonSet)
k get pod static-web-cka-worker -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'   # Node

# 5. stop it cleanly — remove the manifest from the node (deleting the mirror won't work)
docker exec cka-worker rm -f /etc/kubernetes/manifests/static-web.yaml
k get pods -A | grep static-web            # gone
```

The `static-web.yaml` written by `$do` is a valid standalone pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: static-web
spec:
  containers:
    - name: static-web
      image: nginx:1.27
```

Why: the kubelet watches `staticPodPath` (`/etc/kubernetes/manifests` — confirm with `docker exec cka-worker grep staticPodPath /var/lib/kubelet/config.yaml`) and runs any manifest there directly, creating a read-only **mirror pod** named `<name>-<node>` = `static-web-cka-worker` with owner kind `Node`. `kubectl delete pod static-web-cka-worker` would be undone by the kubelet in ~1s; only removing the file stops it.

Exam-flavor note: on kubeadm nodes you `ssh` to the node and `sudo vi /etc/kubernetes/manifests/static-web.yaml`; the mechanics (mirror name, delete-the-file-to-stop) are identical.

---

### 11. PriorityClass and preemption

```bash
# size the CPU request to nearly fill cka-worker's allocatable
k get node cka-worker -o jsonpath='{.status.allocatable.cpu}{"\n"}'   # e.g. 8  -> use ~7 below
```

Set `<BIG>` to roughly (allocatable CPU − 500m); on an 8-core kind node use `7`, on a 4-core node use `3`. Both pods request the same `<BIG>` so only one fits at a time.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hog
  namespace: sched
spec:
  priorityClassName: low-prio
  nodeSelector:
    preempt: demo
  containers:
    - name: c
      image: nginx:1.27
      resources:
        requests:
          cpu: "7"
```

```bash
k -n sched apply -f hog.yaml
k -n sched wait --for=condition=Ready pod/hog --timeout=60s
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: vip
  namespace: sched
spec:
  priorityClassName: high-prio
  nodeSelector:
    preempt: demo
  containers:
    - name: c
      image: nginx:1.27
      resources:
        requests:
          cpu: "7"
```

```bash
k -n sched apply -f vip.yaml

# vip cannot fit alongside hog -> scheduler preempts hog
k -n sched get pods -o wide                 # hog Terminating/gone, vip Running on cka-worker
k -n sched describe pod hog | grep -i preempt   # "Preempted by sched/vip on node cka-worker"
k -n sched get pod vip -o jsonpath='{.status.nominatedNodeName}{"\n"}'   # cka-worker (during preemption)

k uncordon cka-worker2
```

Why: `high-prio` (1000000) outranks `low-prio` (1000). With both pinned to `cka-worker` (via `nodeSelector`, other worker cordoned) and each requesting most of the node's CPU, `vip` has no feasible node until the scheduler's PostFilter preemption evicts the lower-priority `hog`. The victim's event `Preempted by ...` and the preemptor's `nominatedNodeName` are the proof.

> If `vip` schedules without evicting `hog`, your CPU request was too small for both to be mutually exclusive — raise `<BIG>` closer to allocatable and retry.

---

### 12. Drain blocked by a PodDisruptionBudget

Diagnose:

```bash
k -n pdb-lab get pdb web-pdb          # ALLOWED DISRUPTIONS: 0
k -n pdb-lab get pods -o wide         # one replica on cka-worker, one on cka-worker2
```

The drain hangs because `minAvailable: 2` with exactly 2 replicas means **zero** pods may be voluntarily evicted; the Eviction API returns 429 for the replica on `cka-worker` and drain retries forever. `--ignore-daemonsets`/`--delete-emptydir-data` do not help — the block is the PDB, and `--force` does **not** bypass a PDB.

Fix — loosen the budget to allow one disruption while still keeping one pod up:

```bash
k -n pdb-lab patch pdb web-pdb --type=merge -p '{"spec":{"minAvailable":1}}'
k -n pdb-lab get pdb web-pdb          # ALLOWED DISRUPTIONS: 1
k drain cka-worker --ignore-daemonsets --delete-emptydir-data
k uncordon cka-worker
```

Why `minAvailable: 1` (not deleting the PDB): it still guarantees at least one `web` pod stays up during the drain — the maximum protection compatible with evicting the one on `cka-worker`. Deleting the PDB would work but drops all protection.

> Where does the evicted replica go? Nowhere immediately: `cka-worker` is cordoned, placing a second pod on `cka-worker2` would push the hostname skew to 2 (blocked by `DoNotSchedule`), and `cka-control-plane` is tainted (untolerated). So it stays Pending until you `uncordon cka-worker`, then reschedules there. The grading point is that the **drain itself completes** once the PDB allows one disruption.

---

### 13. Diagnose a Pending pod: untolerated taint

```bash
k -n diag describe pod t1 | sed -n '/Events:/,$p'
# FailedScheduling: ... 1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: },
#                       2 node(s) had untolerated taint {reserved: true} ...
```

Root cause: both workers carry `reserved=true:NoSchedule` and the control plane its own taint — no feasible node. Fix without removing the taints: add a matching toleration to the pod (recreate it, since tolerations can't be added to a running pod cleanly):

```bash
k -n diag delete pod t1 --now
k -n diag apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: t1
  namespace: diag
spec:
  tolerations:
    - key: reserved
      operator: Equal
      value: "true"
      effect: NoSchedule
  containers:
    - name: c
      image: nginx:1.27
EOF
k -n diag get pod t1 -o wide     # now Running on a worker
# cleanup:
k taint nodes cka-worker reserved- ; k taint nodes cka-worker2 reserved-
```

Why: the toleration matches the workers' `reserved=true:NoSchedule` taint, making them feasible again; the control-plane node stays excluded (no toleration for it), which is fine — the pod only needs one feasible node.

---

### 14. Diagnose a Pending pod: unsatisfiable node affinity

```bash
k -n diag describe pod t2 | sed -n '/Events:/,$p'
# FailedScheduling: ... didn't match Pod's node affinity/selector.
```

Root cause: the required affinity demands label `gpu=true`, which no node has. Fix by satisfying the affinity (labeling a node), not by editing the pod:

```bash
k label node cka-worker gpu=true --overwrite
k -n diag get pod t2 -o wide     # Running on cka-worker
# cleanup:
k label node cka-worker gpu-
```

Why: `requiredDuringSchedulingIgnoredDuringExecution` is a hard filter; once `cka-worker` gets `gpu=true`, the node becomes feasible and the pod (already in `unschedulableQ`) is re-queued on the node-update event and binds. `IgnoredDuringExecution` means removing the label later won't evict it.

---

### 15. Diagnose a Pending pod: Insufficient cpu

```bash
k -n diag describe pod t3 | sed -n '/Events:/,$p'
# FailedScheduling: ... 0/3 nodes are available: 3 Insufficient cpu.
```

Root cause: the container requests `cpu: "9999"` (9999 cores), which exceeds every node's allocatable — so it is a **resource** problem, not a taint/affinity one (the event says `Insufficient cpu`, not `untolerated taint`). Smallest fix — lower the request to something that fits (recreate; requests are immutable in place):

```bash
k -n diag delete pod t3 --now
k -n diag apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: t3
  namespace: diag
spec:
  containers:
    - name: c
      image: nginx:1.27
      resources:
        requests:
          cpu: "100m"
EOF
k -n diag get pod t3 -o wide     # Running
```

Why: `NodeResourcesFit` sums container **requests** against allocatable; `100m` easily fits. Lowering the request (or removing it) is the minimal change — you do not need to touch limits, taints, or affinity.

---

### 16. Diagnose the silent Pending: wrong `schedulerName`

```bash
k -n diag describe pod t4 | sed -n '/Events:/,$p'    # <none> — no FailedScheduling
k -n diag get pod t4 -o yaml | grep -E 'schedulerName|nodeName'
# schedulerName: ghost-scheduler
```

Why there is no event: a pod is only considered by a scheduler whose profile `schedulerName` matches. `ghost-scheduler` is not running, so **no** scheduler owns `t4` and none emits `FailedScheduling` — the pod sits Pending in silence. The two fields that produce this silent-Pending signature are `.spec.schedulerName` (names a scheduler that isn't running) and `.spec.nodeName` (set directly to a missing/NotReady node, bypassing the scheduler). Here it is `schedulerName`.

Fix — recreate with the default scheduler:

```bash
k -n diag delete pod t4 --now
k -n diag run t4 --image=nginx:1.27           # schedulerName defaults to default-scheduler
k -n diag get pod t4 -o wide                  # Running
```

Why: `default-scheduler` is running and now owns the pod, so it is filtered, scored, and bound normally.

---

### 17. Dedicated-node pattern: taint + toleration + affinity

Taint the node (repel everyone), then give the payments pods both a matching **toleration** (permission to enter) and a **nodeSelector/affinity** (attraction to that node only):

```bash
k taint nodes cka-worker2 team=payments:NoSchedule
k label node cka-worker2 team=payments --overwrite
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
  namespace: sched
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payments
  template:
    metadata:
      labels:
        app: payments
    spec:
      tolerations:
        - key: team
          operator: Equal
          value: payments
          effect: NoSchedule
      nodeSelector:
        team: payments
      containers:
        - name: c
          image: nginx:1.27
```

```bash
k -n sched apply -f payments.yaml
k -n sched get pods -l app=payments -o wide      # both on cka-worker2
k -n sched run intruder --image=nginx:1.27       # no toleration
k -n sched get pod intruder -o wide              # lands on cka-worker, NOT cka-worker2
```

Why the toleration alone was insufficient: the taint keeps *other* pods off `cka-worker2`, and the toleration lets payments *in* — but toleration is only permission, not attraction, so payments pods could still schedule onto `cka-worker`. The `nodeSelector: team=payments` (only `cka-worker2` has that label) is what forces them onto the dedicated node. Taint + toleration + affinity is the complete "dedicated node" recipe: taint excludes others, toleration admits yours, affinity pins yours.
