# Week 03 Masterclass — Scheduling (Workloads & Scheduling 15% · a large slice of Troubleshooting 30% when the symptom is "Pending" · cordon/drain and static pods graded under Cluster Architecture 25%)

Scheduling is a small explicit slice of the blueprint (part of Workloads & Scheduling, 15%) but it is over-represented in what actually costs points, because a pod that will not leave `Pending` is a scheduling problem wearing a troubleshooting costume, and troubleshooting is 30%. `drain`/`cordon` and static pods are graded under Cluster Architecture (25%) as prerequisites for node maintenance and kubeadm upgrades. Master the pipeline once and both the "make this pod land on that node" build tasks and the "why won't this schedule" forensic tasks collapse into the same mental model: filter, score, bind — then read the events. This module covers the scheduler internals, every placement primitive (`nodeName`, `nodeSelector`, node/pod affinity, taints/tolerations, topology spread), disruption control (cordon/drain/PDB), static pods, PriorityClass/preemption, and multi-scheduler awareness. Behavior noted as version-dependent should be re-checked against the current exam Kubernetes version on the CNCF curriculum page.

---

## What the exam actually asks

| Topic | Domain | Weight | Typical task phrasing |
|---|---|---|---|
| Place a pod on a specific node | Workloads & Scheduling | 15% | "Schedule pod `X` only on nodes labelled `disk=ssd`" |
| Node affinity (required/preferred) | Workloads & Scheduling | 15% | "Pod must run on a node in zone `a`, prefer nodes with `gpu=true`" |
| Pod (anti-)affinity, topology spread | Workloads & Scheduling | 15% | "Spread the 6 replicas evenly across nodes; never two on one node" |
| Taints & tolerations | Workloads & Scheduling | 15% | "Taint the node so only workload `X` schedules there" |
| Cordon / drain a node | Cluster Architecture / Troubleshooting | 25% / 30% | "Drain `node2` for maintenance without deleting daemonset pods" |
| Static pods | Cluster Architecture | 25% | "Create a static pod `web` on `node2`" |
| PriorityClass & preemption | Workloads & Scheduling | 15% | "Create a high-priority class; ensure critical pods evict others" |
| Diagnose a `Pending` pod | Troubleshooting | 30% | "Pod `X` is Pending. Make it run." |

Expect at least one explicit affinity/taint build task, at least one drain task (often bundled with kubeadm upgrade in the 25% domain), and one or two `Pending`-forensics tasks where the fix is a one-line label, toleration, or request change. The build tasks reward YAML speed; the forensic tasks reward reading `kubectl describe` events fast and knowing which message means what.

Version note: everything below is stable behavior on any exam-current Kubernetes (v1.30+). Where a field is newer or renamed it is flagged inline. Confirm the live exam version at github.com/cncf/curriculum before exam day.

---

## The scheduler pipeline: what happens between Pending and Running

`kube-scheduler` is a control-loop that watches for pods with an empty `.spec.nodeName` **and** a `.spec.schedulerName` it owns (default `default-scheduler`). For each such pod it runs one **scheduling cycle** (synchronous, one pod at a time) followed by an asynchronous **binding cycle**. Everything you configure in this module is a knob on one of these extension points.

```
                    ┌─────────────── scheduling queue ───────────────┐
   new Pod ───────► │ activeQ (heap: priority, then arrival time)     │
   cluster event ─► │ backoffQ (failed recently, exp. backoff)        │
                    │ unschedulableQ (couldn't fit; waits for events) │
                    └───────────────────────┬────────────────────────┘
                                             │ pop head
                       SCHEDULING CYCLE (sync, per pod)
   PreFilter ─► Filter ─► PostFilter ─► PreScore ─► Score ─► Reserve ─► Permit
   (feasibility)  │        (preempt if     (rank feasible nodes)   (assume)
                  │         no node fit)
                  ▼
        feasible nodes = 0 ──► FailedScheduling event, pod → unschedulableQ
                       BINDING CYCLE (async)
                    PreBind ─► Bind ─► PostBind
                    (write .spec.nodeName via /binding subresource)
```

The scheduling **queue** has three parts and understanding them explains flaky-looking behavior. `activeQ` is a heap ordered by pod priority, then arrival time — this is why a `PriorityClass` changes *which pod is tried first*. A pod that fails scheduling drops to `backoffQ` and is retried with exponential backoff, then parks in `unschedulableQ`. Crucially, a pod in `unschedulableQ` is **not** retried on a timer — it is re-queued when a relevant **cluster event** fires (a node is added, a pod is deleted, a node label changes). So "I freed up CPU and the Pending pod scheduled instantly" is the queue reacting to the delete event, not a poll.

The two words the old docs used still appear in exam-legal docs and events:

- **Predicates → Filter plugins.** Boolean feasibility. A node either survives or is eliminated. Key filters: `NodeResourcesFit` (do the pod's **requests** fit in allocatable?), `NodeAffinity` (nodeSelector + required node affinity), `NodeName`, `TaintToleration`, `PodTopologySpread` (DoNotSchedule constraints), `InterPodAffinity`, `NodePorts`, `NodeUnschedulable` (cordon), `VolumeBinding` (PV zone/topology).
- **Priorities → Score plugins.** Each surviving node gets 0–100 per plugin; the weighted sum picks the winner (ties broken randomly). Key scorers: `NodeResourcesFit` (default `LeastAllocated` → spread load across nodes), `ImageLocality` (node already has the image), `InterPodAffinity`, `PodTopologySpread` (ScheduleAnyway), `TaintToleration`, `NodeAffinity` (preferred terms).

**Bind** writes `.spec.nodeName` through the pod's `/binding` subresource. Only then does the kubelet on that node see the pod (kubelets watch pods filtered by `nodeName`) and start pulling images. The scheduler sets the `PodScheduled` condition to `True` at bind time — so `PodScheduled=False` is the machine-readable "the scheduler could not place this".

### Pending forensics — read the condition, then the event

Two questions answer almost every "why is it Pending" task:

```bash
k describe pod <p> | sed -n '/Conditions:/,/Events:/p'   # is PodScheduled False?
k describe pod <p> | sed -n '/Events:/,$p'               # what did FailedScheduling say?
k get events --field-selector involvedObject.name=<p> --sort-by=.lastTimestamp
```

The `FailedScheduling` message is a compact tally: `0/3 nodes are available: 1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: }, 2 Insufficient cpu.` Learn to decode it:

| Event fragment | Root cause | One-line fix |
|---|---|---|
| `didn't match Pod's node affinity/selector` | `nodeSelector` / required node affinity matches no node | fix label on node or selector on pod |
| `had untolerated taint {k: v}` | node tainted, pod lacks toleration | add toleration (or remove taint) |
| `Insufficient cpu` / `Insufficient memory` | pod **requests** exceed free allocatable everywhere | lower requests or free/add capacity |
| `node(s) didn't match pod topology spread constraints` | `DoNotSchedule` spread can't be satisfied | relax `maxSkew`/`whenUnsatisfiable`, add a domain |
| `node(s) didn't satisfy existing pods anti-affinity rules` | pod anti-affinity of *already-running* pods excludes this node | scale domains or relax anti-affinity |
| `node(s) had volume node affinity conflict` | PV is pinned to a zone/node the pod can't use | match pod placement to PV, or use WaitForFirstConsumer SC |
| `pod has unbound immediate PersistentVolumeClaims` | PVC not bound yet | provision/bind the PVC |
| `too many pods` | node hit `maxPods` (kubelet, default 110) | different node / raise maxPods |
| **No `FailedScheduling` event at all, still Pending** | no scheduler owns it (wrong `schedulerName`) **or** `nodeName` set to a missing/NotReady node | fix `schedulerName`; check `nodeName` target |

That last row is the sharpest trap and the fastest tell: if a pod is Pending with **zero** scheduler events, no scheduler ever looked at it. Either `.spec.schedulerName` names a scheduler that isn't running, or `.spec.nodeName` was set directly (bypassing the scheduler) to a node that can't or won't run it. Check both fields: `k get pod <p> -o yaml | grep -E 'schedulerName|nodeName'`.

---

## Direct assignment vs selection: `nodeName`, `nodeSelector`

### `nodeName` — the scheduler bypass

Set `.spec.nodeName` and the scheduler is out of the loop entirely. No filtering, no scoring, no `TaintToleration`, no `NodeResourcesFit`. The kubelet on the named node simply notices the pod and runs it. Consequences you must internalize:

- **Taints are ignored.** A pod with `nodeName: cka-control-plane` lands on the control plane despite its `NoSchedule` taint, because the taint is enforced by a *filter plugin* and you skipped the filters.
- **The scheduler's resource filter is skipped — but the kubelet re-checks fit.** No `NodeResourcesFit` runs, so the scheduler never vets capacity. The kubelet's own admission on the target node, however, still evaluates requests: a `nodeName` pod whose requests exceed the node's allocatable is **rejected at admission** and goes `Failed` with reason `OutOfcpu`/`OutOfmemory` (it never runs). A pod with no/small requests (the common case, and all the exercise pods here) always lands; only then can it be OOM-killed or evicted later. Taints are truly ignored; resource fit is not — the kubelet re-checks it.
- **A wrong name = silent Pending.** `nodeName: doesnotexist` leaves the pod Pending forever with no event, because no kubelet is watching for that name and no scheduler is involved.

It is the single fastest way to force placement in the exam when you *know* the node name and don't care about safety — but reach for it knowing it silences every guardrail.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pin-by-name
spec:
  nodeName: cka-worker
  containers:
    - name: c
      image: nginx:1.27
```

### `nodeSelector` — the simplest selection

A flat map; **every** key/value must equal a node label (ANDed). Missing any → `didn't match Pod's node affinity/selector` and Pending. This is the fastest *scheduler-respecting* placement, and `kubectl label node` + `nodeSelector` is often the intended two-command answer.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pin-by-label
spec:
  nodeSelector:
    disktype: ssd
  containers:
    - name: c
      image: nginx:1.27
```

```bash
k label node cka-worker disktype=ssd          # make it match
k label node cka-worker disktype-             # remove the label (trailing dash)
```

`nodeSelector` has no operators, no OR, no soft mode. The moment the task says "prefer", "or", "not", or "greater than", you need node affinity.

---

## Node affinity: expressive placement

Node affinity lives under `.spec.affinity.nodeAffinity` and has two clauses whose long names encode a promise: the `IgnoredDuringExecution` suffix means once the pod is scheduled, later changes to node labels will **not** evict it. There is no `RequiredDuringExecution` today.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: affinity-demo
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
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 50
          preference:
            matchExpressions:
              - key: cpu-tier
                operator: In
                values: ["high"]
  containers:
    - name: c
      image: nginx:1.27
```

### The one semantic that trips everyone: AND vs OR

- `nodeSelectorTerms` is a **list**, and the terms are **ORed**. A node satisfies the required rule if it matches *any one* term.
- Inside a single term, `matchExpressions` (and `matchFields`) are **ANDed**. The node must match *every* expression in that term.

So "zone-a **and** ssd" is one term with two expressions (as above). "zone-a **or** ssd" is two terms each with one expression:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: affinity-or
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: topology.kubernetes.io/zone
                operator: In
                values: ["zone-a"]
          - matchExpressions:
              - key: disktype
                operator: In
                values: ["ssd"]
  containers:
    - name: c
      image: nginx:1.27
```

Getting this backwards is the classic "my affinity is too strict / too loose" bug. **Terms = OR, expressions = AND.**

### Operators

| Operator | Meaning | Notes |
|---|---|---|
| `In` | label value is in the set | the workhorse |
| `NotIn` | value not in the set (or key absent) | node *anti-affinity*; a node that **lacks the key entirely also matches** (a missing label satisfies `NotIn`) |
| `Exists` | label key present (any value) | `values` must be omitted/empty |
| `DoesNotExist` | label key absent | anti-affinity by absence; `values` empty |
| `Gt` / `Lt` | value greater/less than | single integer in `values`; label value compared numerically |

`Gt`/`Lt` take exactly one value and compare as integers — handy for "kernel version greater than N" style tasks. `preferredDuring...` entries each carry a `weight` (1–100) that adds to the node's score; they never make a node infeasible. `matchFields` (instead of `matchExpressions`) matches against pod-facing node *fields* rather than labels — rarely needed on the exam; `matchExpressions` is what you reach for.

---

## Pod affinity / anti-affinity: placement relative to other pods

Where node affinity talks about node labels, pod affinity talks about *other pods*, evaluated within a **topology domain** you name with `topologyKey`. The `topologyKey` is a node label; all nodes sharing the same value for that label form one domain.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cache
  labels:
    app: cache
spec:
  affinity:
    podAffinity:                 # schedule NEAR pods matching the selector...
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              app: web
          topologyKey: topology.kubernetes.io/zone   # ...in the same zone
    podAntiAffinity:             # ...but never TWO caches on the same node
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              app: cache
          topologyKey: kubernetes.io/hostname
  containers:
    - name: c
      image: redis:7
```

Read it as: "place me on a node whose **zone** already runs an `app=web` pod, and whose **host** does not already run an `app=cache` pod." `topologyKey: kubernetes.io/hostname` means "per node" (the classic one-per-node spread). `topologyKey: topology.kubernetes.io/zone` means "per zone".

- `requiredDuring...` is a list of terms, **ANDed** (all must hold). Each term has a `labelSelector` and a mandatory `topologyKey`.
- `preferredDuring...` entries carry `weight` and a nested `podAffinityTerm`.
- Scope defaults to the pod's own namespace; widen with `namespaces:` (explicit list) or `namespaceSelector:`.

**Cost warning — this is in the docs and worth an exam remark.** Inter-pod affinity/anti-affinity is evaluated against every candidate pod on every candidate node; the docs explicitly warn it "requires substantial amounts of processing which can slow down scheduling significantly in large clusters" and advise against it above a few hundred nodes. For pure even-spreading, `topologySpreadConstraints` (below) is cheaper and more precise — prefer it unless the task literally says "near pod X".

An anti-affinity gotcha: with `requiredDuringScheduling` anti-affinity on `kubernetes.io/hostname` and a selector matching the pod's own label, you get strict one-per-node. If replicas exceed nodes, the surplus pods stay **Pending** (`didn't satisfy existing pods anti-affinity rules`) — by design, not a bug.

---

## Taints and tolerations: the node's side of the contract

A **taint** repels pods; a **toleration** on a pod lets it ignore a matching taint. Taints are `key=value:effect` on the node; tolerations are per-pod.

```bash
k taint nodes cka-worker workload=batch:NoSchedule      # add
k taint nodes cka-worker workload=batch:NoSchedule-     # remove (trailing dash)
k taint nodes cka-worker workload-                        # remove ALL taints with this key
```

### Effects

| Effect | New pods without toleration | Already-running pods |
|---|---|---|
| `NoSchedule` | rejected by the filter | untouched |
| `PreferNoSchedule` | scheduled elsewhere if possible (soft) | untouched |
| `NoExecute` | rejected | **evicted** unless they tolerate it |

### Tolerations

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: batch-worker
spec:
  tolerations:
    - key: workload
      operator: Equal          # key AND value AND effect must match
      value: batch
      effect: NoSchedule
    - key: node.kubernetes.io/not-ready
      operator: Exists         # value ignored; matches any value for the key
      effect: NoExecute
      tolerationSeconds: 30     # stay 30s after taint appears, then evict
  containers:
    - name: c
      image: busybox:1.36
      command: ["sleep", "infinity"]
```

- `operator: Equal` (default) requires `key`, `value`, and `effect` to match the taint.
- `operator: Exists` ignores `value` — matches any value for that key. An **empty `key` with `Exists`** tolerates *every* taint (this is how a monitoring DaemonSet stays on every node).
- Omitting `effect` in a toleration tolerates **all effects** for that key.
- `tolerationSeconds` applies only to `NoExecute`: how long a tolerating pod stays before it is evicted anyway. `null`/absent = tolerate forever.

**A toleration is permission, not attraction.** Tolerating a taint does not *pull* a pod onto the tainted node; it only removes the barrier. To both repel others and attract yours, pair a taint (on the node) with a matching toleration **and** a `nodeSelector`/affinity (on the pod). This taint+affinity pairing is the standard "dedicated nodes" pattern and a common exam combination.

### Built-in taints and the 5-minute eviction

The node controller and kubelet apply taints automatically. The two that dominate troubleshooting:

- `node.kubernetes.io/not-ready:NoExecute` — kubelet stopped reporting Ready (`status=False`).
- `node.kubernetes.io/unreachable:NoExecute` — node controller lost contact (`status=Unknown`).

When a node goes down, the node controller taints it `unreachable:NoExecute`. Pods do **not** vanish immediately: an admission plugin (`DefaultTolerationSeconds`) has already injected default tolerations for `not-ready` and `unreachable` with `tolerationSeconds: 300` into every pod. So pods sit for **5 minutes** before eviction and rescheduling. This is why "node died but pods are still there" for a few minutes is *correct behavior*, not a stuck cluster. Other built-ins: `memory-pressure`, `disk-pressure`, `pid-pressure` (NoSchedule), `network-unavailable`, and `node.kubernetes.io/unschedulable:NoSchedule` (added by cordon).

---

## Cordon, drain, and PodDisruptionBudgets

### cordon

```bash
k cordon cka-worker      # .spec.unschedulable=true; adds node.kubernetes.io/unschedulable:NoSchedule
k uncordon cka-worker    # reverse
```

Cordon marks the node unschedulable and taints it — **new** pods won't land, **existing** pods keep running. It is the reversible "stop bleeding new work onto this node" switch.

### drain = cordon + evict

`kubectl drain` first cordons, then evicts every pod via the **Eviction API** (which honors PDBs). It refuses to proceed unless you acknowledge the categories of pods it can't cleanly move:

| Flag | When it is required | Why |
|---|---|---|
| `--ignore-daemonsets` | almost always | DaemonSet pods would be immediately recreated on the same node; drain refuses to evict them unless told to skip them. kube-proxy/CNI are DaemonSets, so real clusters *always* need this. |
| `--delete-emptydir-data` | any pod uses an `emptyDir` volume | that data is destroyed on eviction; drain won't silently lose it. |
| `--force` | any pod is **not** managed by a controller (bare pod, static pod) | such pods won't be recreated elsewhere; drain won't orphan them without consent. |

```bash
k drain cka-worker --ignore-daemonsets --delete-emptydir-data
# add --force only if bare/unmanaged pods exist:
k drain cka-worker --ignore-daemonsets --delete-emptydir-data --force
```

The message tells you which flag is missing (`cannot delete DaemonSet-managed Pods`, `cannot delete Pods with local storage`, `cannot delete Pods not managed by ...`). Add the named flag; don't guess the whole set up front.

### PDBs block drains — on purpose

A **PodDisruptionBudget** caps how many pods of a set may be *voluntarily* disrupted at once (`minAvailable` or `maxUnavailable`). The Eviction API consults it: if evicting the next pod would drop availability below the budget, the API returns **429 Too Many Requests** and `drain` retries, waiting. This is intended protection — but a misconfigured PDB blocks a drain **forever**:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb
spec:
  minAvailable: 3           # with only 3 replicas, ZERO may be evicted -> drain hangs
  selector:
    matchLabels:
      app: web
```

If `minAvailable` equals the replica count (or `maxUnavailable: 0`), no pod can ever be evicted and the drain hangs. Exam fix: identify the PDB (`k get pdb -A`, look at `ALLOWED DISRUPTIONS: 0`), then loosen it (`maxUnavailable: 1`), scale the app up so the budget allows a disruption, or — if the task permits force — delete the pods directly. Note `--force` does **not** bypass a PDB; only deleting pods directly (not via the Eviction API) or editing the PDB does.

---

## Static pods: kubelet-run, API-mirrored

A **static pod** is a pod the kubelet runs directly from a manifest file on the node's disk — no scheduler, no controller, no API server required to *start* it. The kubelet watches `staticPodPath` from its config:

```bash
grep staticPodPath /var/lib/kubelet/config.yaml     # -> staticPodPath: /etc/kubernetes/manifests
```

Drop a pod manifest into that directory and the kubelet runs it within seconds. This is how kubeadm runs the control plane (`etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` are all static pods in `/etc/kubernetes/manifests` on the control-plane node).

### Mirror pods and the name suffix

For visibility, the kubelet creates a read-only **mirror pod** object in the API server. Its name is `<manifest-pod-name>-<node-name>` — e.g. a manifest named `web` on `cka-worker` appears as `web-cka-worker`. **That node-name suffix is the tell**: a `-cka-worker` / `-cka-control-plane` suffix on a pod almost certainly means "static pod". Confirm with the owner reference:

```bash
k get pod web-cka-worker -o jsonpath='{.metadata.ownerReferences[0].kind}'   # -> Node
```

An owner reference of kind `Node` (not `ReplicaSet`/`DaemonSet`) is the definitive marker.

### You cannot manage it through the API

`kubectl delete pod web-cka-worker` removes the mirror, and the kubelet recreates it within a second because the manifest is still on disk. **To stop a static pod you must remove its manifest file from `staticPodPath` on the node**:

```bash
# on the node (kind: docker exec into it):
mv /etc/kubernetes/manifests/web.yaml /root/web.yaml     # kubelet stops the pod; mirror disappears
```

Static pods bypass scheduling entirely (like `nodeName`): they ignore taints, `schedulerName`, and requests-based feasibility. They also can't consume API objects the way normal pods do — no ServiceAccount token projection, and referencing ConfigMaps/Secrets is unsupported because they exist independent of the API. On the exam, "create a static pod on node X" means: write the manifest, get it into `/etc/kubernetes/manifests` **on that node**, and verify the `-X` mirror appears with `k get pods -A`.

---

## Topology spread constraints: even distribution, precisely

`topologySpreadConstraints` control how evenly pods matching a selector are distributed across topology domains. This is the modern, cheaper answer to "spread evenly" and the exam's preferred spread primitive.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spread-web
spec:
  replicas: 6
  selector:
    matchLabels:
      app: spread-web
  template:
    metadata:
      labels:
        app: spread-web
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: spread-web
      containers:
        - name: c
          image: nginx:1.27
```

- **`maxSkew`** — the maximum allowed difference between the domain with the most matching pods and the domain with the fewest eligible domain. `maxSkew: 1` across 3 hosts with 6 replicas → 2-2-2 (perfectly even); it will never let one host get 2 ahead of another.
- **`topologyKey`** — the node label defining a domain (`kubernetes.io/hostname` = per node, `topology.kubernetes.io/zone` = per zone).
- **`whenUnsatisfiable`** — `DoNotSchedule` (hard: if placing here would exceed `maxSkew`, keep the pod Pending) vs `ScheduleAnyway` (soft: prefer balanced, but schedule regardless).
- **`labelSelector`** — which existing pods count toward the skew. Usually the workload's own labels.
- **`minDomains`** (optional) — require at least N domains to be counted, forcing spread even when some domains are empty.

Difference from pod anti-affinity: anti-affinity is all-or-nothing per domain ("never two here"); topology spread is graduated ("keep them within `maxSkew` of each other"). Spread lets you say "at most one more on the busiest node than the emptiest" without forbidding co-location outright.

A subtle rollout trap: without `matchLabelKeys: [pod-template-hash]` (added in newer versions, GA'd more recently), old and new ReplicaSet pods both match the selector during a rolling update, and the constraint counts them together — which can wedge the rollout as `Pending`. Where available, add `pod-template-hash` to `matchLabelKeys` so each revision is spread independently. Verify availability in your exam cluster's version.

---

## Requests drive scheduling (limits do not)

The `NodeResourcesFit` filter compares the pod's total **requests** against each node's **allocatable minus already-requested**. Two facts that decide many tasks:

- **Limits are irrelevant to scheduling.** Only `requests` are summed for feasibility. A pod with `limits` but no `requests` inherits requests = limits; a pod with neither requests nothing and schedules anywhere (BestEffort QoS), which is why a "must land on the big node" task sometimes needs a *request* added, not a limit.
- **A pod's effective request per resource is `max(sum of app-container requests, max init-container request)`.** Init containers run sequentially, so their peak (not sum) counts alongside the app containers' sum.

`0/3 nodes are available: 3 Insufficient cpu` means the summed CPU request exceeds free allocatable on every node. Diagnose with:

```bash
k describe node cka-worker | sed -n '/Allocated resources/,/Events/p'   # Requests vs Allocatable
k get pod <p> -o jsonpath='{.spec.containers[*].resources.requests}'
```

Fix by lowering the request, freeing capacity (evict/scale down other pods), or moving to a node with headroom.

---

## PriorityClass and preemption

A **PriorityClass** maps a name to an integer priority. Higher values schedule first, and — if enabled — a high-priority pod that can't fit will **preempt** (evict) lower-priority pods to make room.

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority
value: 1000000
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: "Critical workloads that may evict lower-priority pods"
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: critical
spec:
  priorityClassName: high-priority
  containers:
    - name: c
      image: nginx:1.27
      resources:
        requests:
          cpu: "1"
```

Mechanics:

- Admission stamps `.spec.priority` from the class. The scheduling queue's `activeQ` sorts by priority first, so high-priority pods are scheduled ahead of low ones already waiting.
- If a high-priority pod fails all filters, the **PostFilter** (preemption) plugin looks for a node where evicting one or more lower-priority pods would let it fit. It picks the node causing the fewest/cheapest evictions, sets `.status.nominatedNodeName` on the preemptor, and deletes the victims **gracefully** (they get their termination grace period).
- **PDBs are respected on a best-effort basis** during preemption — the scheduler prefers victims that don't violate a PDB, but will violate one if that's the only way to schedule a higher-priority pod. Don't count on a PDB to stop preemption.
- `preemptionPolicy: Never` makes the pod jump the queue (scheduled before lower-priority pods) **without** evicting anyone. `PreemptLowerPriority` (default) allows eviction.
- `globalDefault: true` (only one class may set it) assigns this priority to pods that name no class. Existing pods are unaffected retroactively.
- Reserved system classes: `system-cluster-critical` (2000000000) and `system-node-critical` (2000001000) — do not exceed these with user classes.

To watch preemption on the exam, create a low-priority pod that fills a node's CPU requests, then a high-priority pod that needs the same CPU — describe the low pod's events for `Preempted by ...` and the high pod's for `nominatedNodeName`.

---

## Multiple schedulers and `schedulerName`

Every pod carries `.spec.schedulerName` (default `default-scheduler`). A pod is only ever considered by a scheduler whose configured `profiles[].schedulerName` matches. You can run a second scheduler (as a Deployment) or run one `kube-scheduler` binary with multiple **profiles**, each a distinct `schedulerName` with its own plugin config.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: custom-sched
spec:
  schedulerName: my-scheduler
  containers:
    - name: c
      image: nginx:1.27
```

The exam-relevant fact is the failure mode: **if `schedulerName` names a scheduler that is not running, the pod is Pending with no events at all** — no scheduler owns it, so nobody emits `FailedScheduling`. This is the same "silent Pending" signature as a direct `nodeName` to a bad node, and distinguishing the two (`k get pod -o yaml | grep -E 'schedulerName|nodeName'`) is a fast forensic win. Know the field exists, know how to set it, and recognize the silence it causes when misused.

---

## A note on DaemonSet scheduling

DaemonSet pods are scheduled by the **default scheduler** (not the DS controller directly, in current versions): the controller creates each pod with a `nodeAffinity` pinning it to one node's `kubernetes.io/hostname`, and the scheduler binds it. This matters for two reasons. First, DaemonSet pods carry **automatic tolerations** for the standard node conditions (`not-ready`, `unreachable`, `disk-pressure`, `memory-pressure`, `pid-pressure`, `unschedulable`) so they keep running on troubled nodes — but they do **not** automatically tolerate *your* custom taints or the control-plane taint. To run a DaemonSet on the control plane or a custom-tainted node, you add the toleration yourself. Second, because DS pods are recreated per node, `drain` refuses to evict them without `--ignore-daemonsets`.

---

## Traps

- **"Terms are ANDed."** Wrong. In node affinity, `nodeSelectorTerms` are **ORed**; only the `matchExpressions` *inside* one term are ANDed. Put AND conditions in one term, OR conditions in separate terms.
- **"A toleration schedules my pod onto the tainted node."** No — a toleration only removes the barrier. Without a matching `nodeSelector`/affinity, a tolerating pod may still land on any *other* untainted node. Pair taint + toleration + affinity for dedicated nodes.
- **"`nodeName` respects taints/resources."** It bypasses the scheduler entirely: no taint check, no resource check. A tainted or full node still accepts it; a nonexistent node leaves it Pending with no event.
- **"Deleting the mirror pod stops a static pod."** The kubelet recreates it from the on-disk manifest within a second. Remove the file from `staticPodPath` on the node instead.
- **"Static pod name is what I put in `metadata.name`."** The mirror in the API is `<name>-<nodename>`. Reference `web-cka-worker`, not `web`, in `kubectl`.
- **"Drain will just work."** It refuses on DaemonSet pods (needs `--ignore-daemonsets`), `emptyDir` pods (needs `--delete-emptydir-data`), and unmanaged pods (needs `--force`). It also hangs indefinitely on a PDB with zero allowed disruptions.
- **"`--force` bypasses the PDB."** It does not. `--force` only lets drain delete *unmanaged* pods. A blocking PDB must be edited, or the app scaled up, to allow the eviction.
- **"Limits control scheduling."** Only **requests** are used by `NodeResourcesFit`. A pod with high limits but no requests schedules onto a full node. Set requests when a task depends on capacity fitting.
- **"Node went down, pods should reschedule instantly."** The default 300s toleration for `unreachable:NoExecute` keeps them ~5 minutes before eviction. That delay is expected.
- **"Pending must have a FailedScheduling event."** Not if no scheduler owns the pod — a wrong `schedulerName` or a direct `nodeName` produces Pending with **no** scheduler events. Check both fields.
- **"Anti-affinity surplus is a bug."** With required per-host anti-affinity and more replicas than nodes, the extras stay Pending by design. Fewer replicas, more nodes, or `preferred` anti-affinity.
- **"`maxSkew` is a per-domain cap."** It's the max *difference* between the busiest and emptiest eligible domain, not a per-domain limit. `maxSkew: 1` over 3 hosts / 6 pods gives 2-2-2, not "≤1 per host".
- **Removing a taint/label: forgetting the trailing dash.** `k taint nodes n1 key=value:NoSchedule` *adds*; `...NoSchedule-` (dash) *removes*. Same for labels: `k label node n1 key-`.

---

## Speed patterns

Aliases assumed: `alias k=kubectl`, `export do="--dry-run=client -o yaml"`.

**Label a node and pin with `nodeSelector` (fastest scheduler-respecting placement):**
```bash
k label node cka-worker disktype=ssd
k run web --image=nginx:1.27 $do > p.yaml   # then add nodeSelector: {disktype: ssd} under spec
```

**Force a node instantly (accepts the risk):** add `nodeName: cka-worker` under `spec` in the generated YAML — no labels, no affinity.

**Taint / untaint / find taints:**
```bash
k taint nodes cka-worker workload=batch:NoSchedule
k taint nodes cka-worker workload-                 # remove all 'workload' taints
k get nodes -o json | jq '.items[]|{name:.metadata.name,taints:.spec.taints}'
# no jq? describe:
k describe node cka-worker | grep -i taint
```

**Cordon + drain for maintenance (the reflex flag set):**
```bash
k drain cka-worker --ignore-daemonsets --delete-emptydir-data
# ... work ...
k uncordon cka-worker
```

**See what's requested vs allocatable when diagnosing Insufficient cpu/memory:**
```bash
k describe node cka-worker | sed -n '/Allocated resources/,/Events/p'
```

**Prove a pod is a static pod:**
```bash
k get pod <p>-<node> -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'   # Node
```

**Create a static pod on a kind worker (write manifest on your box, copy into the node):**
```bash
k run web --image=nginx:1.27 $do > web.yaml
docker cp web.yaml cka-worker:/etc/kubernetes/manifests/web.yaml
k get pods -A | grep web-cka-worker          # mirror appears
```

**PriorityClass in one shot:** `k create priorityclass high-priority --value=1000000 --description="crit"` (add `--preemption-policy=Never` to jump the queue without evicting). Faster than writing YAML. `--global-default=true` marks it the default for pods that name no class.

**Decode a Pending pod in two commands:**
```bash
k get pod <p> -o wide                         # STATUS Pending, NODE none
k describe pod <p> | sed -n '/Events:/,$p'    # the FailedScheduling tally (or silence)
```

**Generate an affinity skeleton fast:** `kubectl explain pod.spec.affinity.nodeAffinity --recursive` reminds you of the exact field nesting when you blank on `nodeSelectorTerms` vs `matchExpressions`.

---

## Docs map

Everything below is reachable in-exam from `kubernetes.io/docs`. Know the paths cold — searching wastes minutes.

| What you need | Exact doc path |
|---|---|
| Assign pods to nodes (nodeSelector, nodeName) | `/docs/concepts/scheduling-eviction/assign-pod-node/` |
| Node affinity / pod affinity full reference | `/docs/concepts/scheduling-eviction/assign-pod-node/#affinity-and-anti-affinity` |
| Taints and tolerations (effects, built-ins, eviction) | `/docs/concepts/scheduling-eviction/taint-and-toleration/` |
| Topology spread constraints | `/docs/concepts/scheduling-eviction/topology-spread-constraints/` |
| Pod priority and preemption | `/docs/concepts/scheduling-eviction/pod-priority-preemption/` |
| Scheduler framework / extension points | `/docs/concepts/scheduling-eviction/scheduling-framework/` |
| Kube-scheduler overview | `/docs/concepts/scheduling-eviction/kube-scheduler/` |
| Configure multiple schedulers / profiles | `/docs/tasks/extend-kubernetes/configure-multiple-schedulers/`, `/docs/reference/scheduling/config/` |
| Static pods | `/docs/tasks/configure-pod-container/static-pod/` |
| Safely drain a node | `/docs/tasks/administer-cluster/safely-drain-node/` |
| PodDisruptionBudget concept + task | `/docs/concepts/workloads/pods/disruptions/`, `/docs/tasks/run-application/configure-pdb/` |
| Resource requests/limits & scheduling | `/docs/concepts/configuration/manage-resources-containers/` |
| DaemonSet scheduling & default tolerations | `/docs/concepts/workloads/controllers/daemonset/#taints-and-tolerations` |
| `kubectl taint` / `cordon` / `drain` reference | `/docs/reference/generated/kubectl/kubectl-commands` |

---

## Checkpoint

Time targets are exam-realistic. If you exceed them, drill the pattern until the YAML nesting is muscle memory.

- Can you place a pod on a specific labelled node with `nodeSelector` — label the node and write the pod — in **under 2 minutes**?
- Can you write a required node-affinity rule for "(zone-a OR zone-b) AND ssd" and explain why it's one term vs two in **under 3 minutes**?
- Can you taint a node `NoSchedule`, write a matching `Exists` toleration, and confirm the pod schedules there (with an affinity to actually pull it) in **under 4 minutes**?
- Can you spread 6 replicas 2-2-2 across the 3 kind nodes with `topologySpreadConstraints` (`maxSkew: 1`, `DoNotSchedule`) in **under 4 minutes**?
- Can you drain a worker with a DaemonSet and an `emptyDir` pod present, choosing the right flags without trial-and-error, in **under 2 minutes**?
- Given a PDB with `ALLOWED DISRUPTIONS: 0` blocking a drain, can you identify it and unblock the drain in **under 3 minutes**?
- Can you create a static pod on `cka-worker` and prove it's static via the `-cka-worker` mirror and the `Node` owner reference in **under 4 minutes**?
- Can you create a `PriorityClass`, schedule a high-priority pod that preempts a low-priority one, and read `Preempted by` from the victim's events in **under 5 minutes**?
- Given three `Pending` pods — one untolerated taint, one unsatisfiable affinity, one Insufficient cpu — can you name each root cause from `describe` events in **under 3 minutes total**?
- Can you explain, in 30 seconds each, the difference between `nodeName`/`nodeSelector`/node-affinity and between taints/tolerations vs affinity — and why a toleration alone does not attract a pod?
