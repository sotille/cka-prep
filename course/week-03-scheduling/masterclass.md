# Week 03 — Scheduling: Every Mechanism That Decides Pod → Node (Workloads & Scheduling 15% · Troubleshooting 30% · Cluster Architecture 25%)

Scheduling looks like a 15% topic on the curriculum, but that undersells it three ways. First, "why is this pod Pending?" is the single most common troubleshooting task pattern, and Troubleshooting is 30% of the exam. Second, `drain`/`cordon` and static pods are graded under Cluster Architecture (25%) because they are prerequisites for node maintenance and kubeadm upgrades. Third, scheduling primitives leak into every other module: a NetworkPolicy task that pre-places pods with affinity, a storage task where a PV's node affinity blocks scheduling. Master the mechanics here and you buy back time everywhere else.

Version note: everything below is stable behavior on any exam-current Kubernetes (v1.30+). Where a field is newer or renamed, it is flagged inline. Check the live exam version at github.com/cncf/curriculum before exam day.

---

## What the exam actually asks

| Task pattern (exam voice) | Domain | What is really being tested |
|---|---|---|
| "Schedule a pod to the node labeled X" | Workloads & Scheduling (15%) | nodeSelector / node affinity YAML under time pressure |
| "Ensure no two replicas run on the same node" | Workloads & Scheduling | pod anti-affinity or topology spread, topologyKey semantics |
| "Taint node X so only pods with Y run there" | Workloads & Scheduling | taint syntax + toleration matching rules |
| "Pod Z is Pending. Find the cause and fix it" | Troubleshooting (30%) | reading `FailedScheduling` events, mapping message → mechanism |
| "Mark node X unschedulable and move workloads off it" | Cluster Architecture (25%) | cordon vs drain, drain flags, PDB interference |
| "Create a static pod on node X" / "the control plane is broken" | Cluster Architecture / Troubleshooting | staticPodPath, mirror pods, editing manifests on the node filesystem |
| "Create a PriorityClass and a pod that uses it" | Workloads & Scheduling | PriorityClass object + `priorityClassName`, preemption awareness |

The direct tasks are cheap points if you can produce affinity/toleration YAML in under 3 minutes. The Pending-forensics tasks are where prepared candidates separate from unprepared ones: the event message tells you the exact cause if you know how to read it.

---

## The scheduling pipeline: from `kubectl apply` to Running

kube-scheduler is a control loop that does one thing: for each pod with empty `spec.nodeName`, pick a node and write it. Everything else — affinity, taints, spread, priority — is configuration consumed by that loop.

### The queue

Newly created pods land in the scheduler's **active queue** (activeQ), a priority queue ordered by pod priority (higher first), then FIFO within equal priority. The scheduler pops **one pod at a time** and runs a scheduling cycle for it. Two more internal structures matter for diagnosis:

- **backoffQ** — pods that failed scheduling recently wait here with exponential backoff (1s initial, 10s cap by default) before re-entering activeQ.
- **unschedulable pool** — pods that failed with no viable node park here. They are moved back to activeQ when a relevant cluster event occurs (node added, node label changed, taint removed, pod deleted freeing resources) or after a periodic flush (every 5 minutes by default).

Practical consequence: when you fix the cause of a Pending pod (label the node, remove the taint, free resources), the pod schedules within seconds — you never need to recreate it. If it does not, your fix did not actually address the failed predicate.

### The scheduling cycle: filter, score, bind

The scheduling framework runs plugins in phases. The old terminology (predicates/priorities) still appears in docs and event messages; map it once:

| Phase | Old name | What happens | Key default plugins |
|---|---|---|---|
| PreFilter | — | precompute state, fail fast (e.g. sum pod requests) | NodeResourcesFit, InterPodAffinity, PodTopologySpread |
| **Filter** | **predicates** | eliminate nodes that *cannot* run the pod | NodeUnschedulable, TaintToleration, NodeAffinity, NodeName, NodeResourcesFit, NodePorts, VolumeBinding, InterPodAffinity, PodTopologySpread |
| PostFilter | — | runs **only if 0 nodes survive** → preemption attempt | DefaultPreemption |
| **Score** | **priorities** | rank surviving nodes 0–100, weighted sum | NodeResourcesFit (least-allocated), ImageLocality, InterPodAffinity, NodeAffinity (preferred terms), TaintToleration (PreferNoSchedule), PodTopologySpread |
| Reserve/Permit | — | in-memory reservation before the API write | VolumeBinding |
| **Bind** | — | POST to the pod's `binding` subresource, sets `spec.nodeName` | DefaultBinder |

Two details worth knowing at a senior level:

1. **Scoring is sampled on big clusters.** `percentageOfNodesToScore` limits how many feasible nodes get scored (adaptive default, floor 5%). Irrelevant on a 3-node kind cluster, but it explains why "best" placement is best-effort at scale.
2. **The kubelet re-checks admission.** Binding is the scheduler's opinion; the kubelet has the last word. On admission it re-validates resources and node affinity. A pod that slips past (or bypasses) the scheduler can be rejected by the kubelet with terminal statuses like `OutOfcpu`, `OutOfmemory`, or `NodeAffinity`. It does **not** re-check `NoSchedule` taints — which is exactly why static pods run on tainted control-plane nodes.

After bind, `status.conditions` gets `PodScheduled: True` and the kubelet takes over (image pull, container start — different failure domain, covered in week 9).

One-liner for completeness: `spec.schedulingGates` (stable in v1.30) can hold a pod out of the queue entirely — a pod Pending with a `SchedulingGated` reason is waiting for a controller to remove its gate, not failing predicates.

### Pending forensics: reading the corpse

The triage macro, in order:

```bash
k describe po -n team-a broken-pod          # Events section at the bottom
k get events -n team-a --sort-by=.lastTimestamp | tail -20
k get po -n team-a broken-pod -o jsonpath='{.status.conditions}'
```

A scheduling failure event looks like this (message anatomy is the whole game):

```text
Warning  FailedScheduling  default-scheduler
0/3 nodes are available: 1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: },
1 Insufficient cpu, 1 node(s) didn't match Pod's node affinity/selector.
preemption: 0/3 nodes are available: 3 No preemption victims found for incoming pod.
```

Read it as an accounting identity: the counts sum to the node total, and each fragment names the Filter plugin that rejected that group of nodes. The trailing `preemption:` clause (v1.24+) reports why preemption could not help either.

| Message fragment | Failing mechanism | Fix direction |
|---|---|---|
| `had untolerated taint {key: value}` | TaintToleration | add toleration to pod, or remove taint from node |
| `Insufficient cpu` / `Insufficient memory` | NodeResourcesFit | lower `requests`, free capacity, or add nodes |
| `didn't match Pod's node affinity/selector` | NodeAffinity | fix label/expression mismatch (label the node is usually fastest) |
| `didn't match pod affinity rules` / `didn't match pod anti-affinity rules` | InterPodAffinity | no matching peer pod exists / co-location forbidden everywhere |
| `didn't satisfy existing pods anti-affinity rules` | InterPodAffinity (symmetry) | an *existing* pod's anti-affinity blocks this one |
| `node(s) were unschedulable` | NodeUnschedulable | node is cordoned — `k uncordon` |
| `didn't match pod topology spread constraints` | PodTopologySpread | skew would exceed maxSkew everywhere placeable |
| `had volume node affinity conflict` | VolumeBinding | PV pinned to another node (week 7) |
| `No preemption victims found` | DefaultPreemption | nothing lower-priority to evict |
| **No events at all**, pod Pending | no scheduler picked it up | `spec.schedulerName` names a scheduler that doesn't exist, or the scheduler is down (check `kube-system`) |

Also check `status.nominatedNodeName`: if set, preemption fired and the pod is waiting for victims to finish terminating on that node.

---

## The placement toolbox: one table to orient every task

| Mechanism | Declared on | Direction | One-line semantics |
|---|---|---|---|
| `nodeName` | pod | hard assignment | bypasses the scheduler entirely |
| `nodeSelector` | pod | attract (hard) | node must carry all listed labels |
| node affinity | pod | attract (hard or soft) | expressive label matching against nodes |
| pod affinity / anti-affinity | pod | attract/repel relative to *pods* | "near/away from pods matching X", per topology domain |
| taints + tolerations | node + pod | repel | node repels all pods that don't tolerate |
| topology spread | pod | distribute | bound the pod-count skew across domains |
| PriorityClass / preemption | pod | arbitrate scarcity | who waits, who evicts whom |

The classic 30-second interview answer the notes ask for: **nodeSelector/affinity are pod-side attraction** ("I must run where..."), **taints are node-side repulsion** ("nobody runs here unless..."), and they compose — a *dedicated* node needs both, because a taint keeps others out but does nothing to pull your pods in.

---

## nodeName: the scheduler bypass

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: direct
spec:
  nodeName: cka-worker
  containers:
  - name: app
    image: nginx:1.27
```

Setting `spec.nodeName` at creation means the scheduler never sees the pod (its watch filters on empty nodeName). Consequences you must be able to reason about:

- **No Filter phase runs.** `NoSchedule` and `PreferNoSchedule` taints are ignored; cordon (`unschedulable: true`) is ignored; affinity conflicts are ignored by the scheduler — the pod goes straight to the kubelet.
- **The kubelet still has admission.** Insufficient resources → terminal `OutOfcpu`/`OutOfmemory` status (not Pending — the pod *failed*). Node affinity mismatch → `NodeAffinity` rejection.
- **NoExecute still applies.** The taint manager (in kube-controller-manager) evicts running pods regardless of how they got there.
- **Nonexistent node** → the pod sits Pending forever with no events: no kubelet claims it, no scheduler owns it. Same symptom signature as a bad `schedulerName`.
- The field is **immutable** on an existing pod, and it is exactly how the scheduler itself "assigns" pods (via the binding subresource).

Exam relevance: rarely asked directly, but it is the mechanism behind static pods and DaemonSet-style pinning, and it is a fast way to force placement in your lab. Know it as a diagnostic fact: a pod that "skipped the queue" onto a tainted node almost certainly had nodeName set.

## nodeSelector: the 90% tool

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: fast
spec:
  nodeSelector:
    disktype: ssd
  containers:
  - name: app
    image: nginx:1.27
```

All listed labels must be present on the node with exact values (pure AND, equality only). If the exam task is "run this pod on the node labeled `disktype=ssd`", this is the answer — do not write affinity YAML when two lines of nodeSelector satisfy the requirement. Label management one-liners:

```bash
k get nodes --show-labels
k label node cka-worker disktype=ssd
k label node cka-worker disktype=nvme --overwrite
k label node cka-worker disktype-          # remove
```

Every node already carries `kubernetes.io/hostname=<nodename>` — the built-in way to pin to a named node *through* the scheduler (unlike nodeName, taints and resources are still respected).

## Node affinity: expressive nodeSelector

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: affine
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: disktype
            operator: In
            values:
            - ssd
            - nvme
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 80
        preference:
          matchExpressions:
          - key: topology.kubernetes.io/zone
            operator: In
            values:
            - eu-west-1a
  containers:
  - name: app
    image: nginx:1.27
```

**Required vs preferred.** `requiredDuringSchedulingIgnoredDuringExecution` is a Filter: no matching node → Pending. `preferredDuringSchedulingIgnoredDuringExecution` is a Score: each entry has `weight` 1–100 added to matching nodes' scores; the pod lands elsewhere without complaint if no node matches. A "preferred" pod on the "wrong" node is *not* a bug — a trap the exam exploits in troubleshooting scenarios.

**IgnoredDuringExecution** means the rule is evaluated once, at scheduling. Remove the label from the node afterward and the pod keeps running. (Contrast: `NoExecute` taints, the only placement mechanism that acts on *running* pods. `requiredDuringSchedulingRequiredDuringExecution` still does not exist.)

**The AND/OR structure — the most-fumbled detail in this topic:**

- Multiple `nodeSelectorTerms` entries are **ORed** — any one term matching a node is enough.
- Multiple `matchExpressions` inside one term are **ANDed** — all must match.
- If both `nodeSelector` and `nodeAffinity.required...` are present, **both** must be satisfied (ANDed).

```yaml
# reads: (gpu exists) OR (disktype=ssd AND env!=dev)
apiVersion: v1
kind: Pod
metadata:
  name: or-demo
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: gpu
            operator: Exists
        - matchExpressions:
          - key: disktype
            operator: In
            values:
            - ssd
          - key: env
            operator: NotIn
            values:
            - dev
  containers:
  - name: app
    image: nginx:1.27
```

**Operators:**

| Operator | Matches when | Notes |
|---|---|---|
| `In` | label value in `values` list | the workhorse |
| `NotIn` | label absent **or** value not in list | doubles as anti-affinity to nodes |
| `Exists` | label key present | `values` must be empty |
| `DoesNotExist` | label key absent | `values` must be empty |
| `Gt` / `Lt` | label value parses as integer and compares | exactly one value, written as a **string**: `values: ["8"]` |

`NotIn`/`DoesNotExist` on node labels is how you express node *anti*-affinity — there is no `nodeAntiAffinity` field.

## Pod affinity and anti-affinity: placement relative to pods

Node affinity asks "what is on the node's labels?"; pod affinity asks "what pods are already running there?" That makes it strictly more expensive: the scheduler must scan pods across the cluster for every candidate node. The docs carry an explicit warning — required pod (anti-)affinity is not recommended beyond several-hundred-node clusters. Irrelevant on kind, but say it in a design review.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cache
spec:
  replicas: 2
  selector:
    matchLabels:
      app: cache
  template:
    metadata:
      labels:
        app: cache
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: cache
            topologyKey: kubernetes.io/hostname
        podAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchLabels:
                  app: web
              topologyKey: kubernetes.io/hostname
      containers:
      - name: redis
        image: redis:7
```

This is the canonical exam pattern: "no two cache replicas on the same node, prefer to co-locate with web." Note the structural asymmetry: required terms hold `labelSelector`+`topologyKey` directly; preferred terms wrap them in `podAffinityTerm` under a `weight`.

**topologyKey, explained properly.** The rule is *not* "same node" or "different node" — it is "same/different **topology domain**", where a domain is the set of nodes sharing a value for the `topologyKey` label:

- `topologyKey: kubernetes.io/hostname` → every node is its own domain → "same/different node".
- `topologyKey: topology.kubernetes.io/zone` → all nodes in a zone form one domain → anti-affinity means "different *zone*", so two replicas on different nodes in the *same* zone still violate it.

Mechanics: for affinity, a node passes if it is in a domain containing a pod matching `labelSelector`; for anti-affinity, a node fails if its domain contains a matching pod. A node **missing the topologyKey label entirely** can never satisfy pod affinity — on clusters without zone labels (like kind), a zone-based rule makes every pod Pending. `topologyKey` is mandatory and must be non-empty for all required rules.

Cross-namespace: `labelSelector` matches pods **in the pod's own namespace** by default; add `namespaces:` or `namespaceSelector:` to widen.

Two behaviors worth knowing cold:

1. **Symmetry.** Required *anti*-affinity is symmetric and enforced both ways: if running pod A repels pods labeled `app=b`, an incoming `app=b` pod is filtered off A's node even though the incoming pod declares nothing — the event says `didn't satisfy existing pods anti-affinity rules`. Affinity is not symmetric (A loving B does not drag B toward A), though the scheduler does *score* toward pods that expressed affinity for the incoming pod.
2. **Bootstrap special case.** Required pod affinity with zero matching pods anywhere would deadlock the first replica ("nothing to be near"). The scheduler special-cases this: if no pod matches the term but the **incoming pod's own labels** satisfy it, the node passes. Self-affine Deployments therefore start fine — and clump onto one node, which is usually the opposite of what the author wanted. For spreading, anti-affinity or topology spread; affinity-to-self is a clumping tool.

Cost/rigidity guidance: required anti-affinity on hostname caps your replica count at your (untolerated) node count — replica 4 on a 3-node cluster is permanently Pending. When the requirement is "spread evenly" rather than "never co-locate", topology spread constraints (below) are the better and cheaper tool.

## Taints and tolerations: node-side repulsion

A taint is `key=value:Effect` on a node. A pod is repelled from the node unless it has a matching toleration. Tolerations do **not** attract — they only remove a barrier.

```bash
k taint node cka-worker dedicated=infra:NoSchedule      # add
k taint node cka-worker dedicated=infra:NoSchedule-     # remove (exact match)
k taint node cka-worker dedicated-                      # remove all effects of key
k describe node cka-worker | grep Taints
```

The trailing `-` removal syntax is not discoverable from `--help` in a panic — memorize it.

**Effects:**

| Effect | New pods | Running pods |
|---|---|---|
| `NoSchedule` | hard-filtered | untouched — pods present before the taint keep running |
| `PreferNoSchedule` | avoided (Score-time only) | untouched |
| `NoExecute` | hard-filtered | **evicted** unless tolerated; the only mechanism that acts on running pods |

**Toleration matching.** A toleration matches a taint when keys are equal, effects are equal (an **empty `effect` matches all effects**), and:

- `operator: Equal` → `value` must also match exactly.
- `operator: Exists` → any value; omit `value` entirely.
- `operator: Exists` with **empty key** → tolerates *everything* (this is how DaemonSets like kube-proxy run everywhere).

```yaml
tolerations:
- key: dedicated
  operator: Equal
  value: infra
  effect: NoSchedule
- key: maintenance
  operator: Exists
  effect: NoExecute
  tolerationSeconds: 300
```

YAML trap: taint values like `true` must be quoted in a toleration (`value: "true"`) or the API rejects the bool.

**tolerationSeconds** (NoExecute only): "I tolerate this taint, but only for N seconds after it appears; then evict me." Omitted → tolerate forever. This is the load-bearing field for node-failure behavior:

**Built-in taints — the node lifecycle machinery.** The node controller translates node conditions into taints:

| Taint | When applied | Effect |
|---|---|---|
| `node.kubernetes.io/not-ready` | node condition Ready=False | NoExecute |
| `node.kubernetes.io/unreachable` | Ready=Unknown (kubelet stopped reporting) | NoExecute |
| `node.kubernetes.io/unschedulable` | node cordoned | NoSchedule |
| `node.kubernetes.io/memory-pressure` / `disk-pressure` / `pid-pressure` | kubelet pressure conditions | NoSchedule |
| `node.kubernetes.io/network-unavailable` | CNI not ready | NoSchedule |

The admission controller `DefaultTolerationSeconds` injects into **every** pod tolerations for `not-ready` and `unreachable` with `tolerationSeconds: 300`. Chain the mechanics: node dies → ~40s later Ready goes Unknown → `unreachable:NoExecute` taint lands → each pod's 300s toleration timer starts → pods are deleted and rescheduled ~5–6 minutes after failure. That "why did failover take 5 minutes?" question is answered entirely by this default. Tune per-pod by declaring your own toleration with a shorter `tolerationSeconds`.

Sharp edge: NoExecute evictions are performed by the taint manager as direct deletions — **they do not go through the Eviction API and do not respect PodDisruptionBudgets**. PDBs protect against *voluntary* disruption (drain), not taints.

**Dedicated-node recipe** (taints repel, they don't reserve): taint the node `team=payments:NoSchedule` *and* give the workload both a toleration (so it can enter) and a nodeSelector/affinity (so it must enter). Toleration alone lets the pod land on any other node too.

## Cordon vs drain

```bash
k cordon cka-worker      # spec.unschedulable=true → unschedulable:NoSchedule taint. Running pods untouched.
k drain cka-worker --ignore-daemonsets --delete-emptydir-data
k uncordon cka-worker    # after maintenance. Nothing comes back on its own.
```

`drain` = cordon first, then **evict** every evictable pod via the Eviction API (`pods/eviction` subresource), which is what makes it PDB-aware. Bare `kubectl delete pod` is not.

Refusals and their flags — drain is conservative and aborts with an explicit reason:

| Drain complaint | Why | Flag / action |
|---|---|---|
| `cannot delete DaemonSet-managed Pods` | DS controller would instantly recreate them (they tolerate `unschedulable`) | `--ignore-daemonsets` — leaves them running |
| `cannot delete Pods with local storage` | pod uses `emptyDir`; data dies with the pod | `--delete-emptydir-data` (old name `--delete-local-data`, pre-v1.20) |
| `cannot delete Pods declaring no controller` | bare pod; nothing will recreate it | `--force` — deletes it permanently |
| hangs repeating `Cannot evict pod as it would violate the pod's disruption budget` | Eviction API returns 429 while `ALLOWED DISRUPTIONS` is 0 | not a flag problem — fix the math: scale the workload up, or relax the PDB. `--timeout` bounds the retry loop; `--disable-eviction` bypasses PDBs entirely (deletes directly — last resort) |

Static (mirror) pods are silently skipped — drain cannot remove them and does not fail on them.

Failure-mode detail that costs real points: an aborted or Ctrl-C'd drain **leaves the node cordoned**. Later tasks then mysteriously fail to schedule. After any drain exercise, verify no node shows `SchedulingDisabled` in `k get nodes`. Standard maintenance sequence: `drain` → do the work (upgrade, reboot) → `uncordon`.

Exam flavor: on the real exam this appears inside kubeadm-upgrade tasks ("drain node X before upgrading") with you SSH'd into real hosts; the kubectl side is identical to the kind lab.

## Static pods: the kubelet's private workloads

A static pod is run by the **kubelet directly** from a manifest file on the node's disk — no API server involvement in its lifecycle. The kubelet watches the directory named by `staticPodPath` in its config file:

```bash
# on the node (kind: docker exec -it cka-worker bash; exam: ssh node01 + sudo)
grep staticPodPath /var/lib/kubelet/config.yaml
# staticPodPath: /etc/kubernetes/manifests
```

Kubeadm sets `/etc/kubernetes/manifests` — and runs the entire control plane from it: `etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` are static pods. This is why a broken apiserver can't be fixed with kubectl (chicken-and-egg) and why week 9's control-plane recovery drills happen in this directory.

**Mirror pods.** For visibility, the kubelet creates a read-only *mirror pod* on the API server for each static pod, named `<manifest-name>-<node-name>` — `kube-apiserver-cka-control-plane`, or your `static-web` on cka-worker appearing as `static-web-cka-worker`. The suffix is the identification tell the notes checkpoint asks for; the rigorous checks:

```bash
k get po -n kube-system kube-apiserver-cka-control-plane -o jsonpath='{.metadata.ownerReferences[0].kind}'
# Node   ← static pods are owned by the Node object; Deployment pods say ReplicaSet
k get po -n kube-system kube-apiserver-cka-control-plane -o jsonpath='{.metadata.annotations.kubernetes\.io/config\.source}'
# file
```

**Lifecycle rules that trip people:**

- `kubectl delete` on a mirror pod appears to work — and the kubelet recreates it within seconds. The API object is a projection; the source of truth is the file.
- `kubectl edit` / `apply` on a mirror pod is rejected or ineffective. To change a static pod, **edit the file on the node**.
- To **stop** one: move the manifest out of the directory (`mv /etc/kubernetes/manifests/foo.yaml /tmp/`). The kubelet notices on its file re-scan (`fileCheckFrequency`, default 20s) and kills the pod. Move it back to restart — this mv-out/mv-in cycle is also the standard way to bounce a control-plane component.
- No scheduler involvement at all: `NoSchedule` taints don't apply; the pod runs wherever the file is. Tolerations/affinity in the manifest are irrelevant to placement.
- The kubelet's admission still applies: a static pod exceeding allocatable resources or violating its own nodeSelector will be rejected by the kubelet (visible only in kubelet logs / `crictl`, since there may be no working API to post events to).

## Topology spread constraints: even distribution as a first-class primitive

Anti-affinity gives binary never-together; spread constraints give **bounded imbalance**:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 6
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: web
      containers:
      - name: app
        image: nginx:1.27
```

**Skew math.** For each domain (distinct `topologyKey` value among eligible nodes): `skew = pods-in-this-domain − min(pods in any eligible domain)`, counting only pods matching `labelSelector` in the same namespace. A node passes the filter if placing the pod there keeps skew ≤ `maxSkew`. On the 3-node kind cluster with 6 replicas and the constraint above, you converge to 2/2/2.

**Field semantics:**

- `whenUnsatisfiable: DoNotSchedule` → hard Filter (pods go Pending). `ScheduleAnyway` → demoted to a Score preference; never blocks.
- `labelSelector` is **not defaulted** — forget it and every domain counts 0 matching pods, making the constraint vacuous. It should normally match the pod's own labels.
- Multiple constraints are ANDed.
- `minDomains` (stable v1.30): with DoNotSchedule, treat fewer-than-N populated domains as skew — forces using at least N domains.
- `matchLabelKeys` (beta, on by default v1.27+): add e.g. `pod-template-hash` so each ReplicaSet generation spreads independently — without it, a rolling update counts the old RS's pods and the new pods spread lopsidedly.

**The domain-counting trap (directly reproducible on kind).** Two policy fields (v1.26+) control which nodes count as domains: `nodeAffinityPolicy` (default `Honor` — nodes failing the pod's own nodeSelector/affinity are excluded) and `nodeTaintsPolicy` (default **`Ignore`** — tainted nodes still count as domains even though the pod cannot land there). Consequence on kind: the tainted control-plane is a permanent 0-pod domain. With `maxSkew: 1`, `DoNotSchedule` and no toleration, replicas 1–2 land one per worker, and replica 3 is stuck: any worker placement makes skew (2−0)=2. Result: 2 Running, everything else Pending. Fixes: tolerate the control-plane taint (spread across 3 domains), or set `nodeTaintsPolicy: Honor` (control-plane stops being a domain), or `ScheduleAnyway`. Exercise 6 makes you hit this live.

**No rebalancing.** Like everything except NoExecute, spread is enforced at scheduling time only. Scale-downs, evictions, and node restarts can leave arbitrary skew; nothing moves running pods to fix it (that is the descheduler's job, out of exam scope). The cluster also ships built-in *soft* defaults (zone maxSkew 3, hostname maxSkew 5, ScheduleAnyway) — why vanilla Deployments spread roughly evenly with no configuration.

## PriorityClass and preemption: who wins under scarcity

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: prod-critical
value: 1000000
globalDefault: false
description: Production critical workloads
preemptionPolicy: PreemptLowerPriority
```

```bash
k create priorityclass prod-critical --value=1000000 --description="prod critical"   # imperative, exam-fast
```

Cluster-scoped, non-namespaced. `value` up to 1,000,000,000 for user classes; the system reserves higher for `system-cluster-critical` (2000000000) and `system-node-critical` (2000001000) — used by kube-system components and the reason they win every fight. At most one class may set `globalDefault: true` (applies to new pods only); otherwise unclassed pods get priority 0. Pods reference it by name:

```yaml
spec:
  priorityClassName: prod-critical
```

`priorityClassName` resolves to `spec.priority` (an integer) at admission — deleting the PriorityClass later doesn't change existing pods. A pod referencing a nonexistent class is **rejected at creation** (validation error, not Pending).

**Priority acts twice:**

1. **Queue order** — higher-priority Pending pods are popped from activeQ first.
2. **Preemption** — when a pod fails all Filters, the PostFilter (DefaultPreemption) searches for nodes where evicting lower-priority pods would make it fit. It picks the cheapest victim set (fewest PDB violations first, then lowest victim priorities), writes the pod's `status.nominatedNodeName`, and deletes victims via the eviction path with their full `terminationGracePeriodSeconds` (no SIGKILL shortcut). The preemptor then re-enters the queue — it is *not* guaranteed the nominated node; a better node can appear or a higher-priority pod can steal the space.

Mechanics that show up in questions and postmortems:

- Preemption only compares **pod priority** — never resource requests, never "importance" of the workload, never QoS class. (QoS matters for *kubelet node-pressure eviction*, a different subsystem.)
- PDBs are **best-effort** in preemption: the scheduler prefers victim sets that don't violate PDBs but will violate them if that is the only way to place the preemptor.
- Victims must have *strictly lower* priority. Equal priority never preempts.
- `preemptionPolicy: Never` → the pod still gets queue-order benefits but will not evict anyone (batch-friendly "high priority, polite").
- Forensics: `k get po -o wide` shows the preemptor Pending with `NOMINATED NODE` set; victims show `Preempted` events.

## How requests drive scheduling

The NodeResourcesFit filter compares the **sum of `requests`** of pods already assigned to a node against the node's **allocatable** (capacity minus system/kube reservations and eviction thresholds). Three things it does *not* look at:

- **Limits** — irrelevant to scheduling entirely.
- **Actual usage** — a node at 5% real CPU utilization but fully *requested* rejects new pods with `Insufficient cpu`. Scheduling is bookkeeping, not telemetry. (`kubectl top` is for node-pressure debugging, not scheduling debugging.)
- A pod with **no requests** fits anywhere resource-wise — and is the first to die under pressure (week 4/9 territory).

Effective pod request = `max(max(initContainers), sum(containers))` plus `pod overhead` if a RuntimeClass sets it — init containers run serially, so a fat init container alone can block scheduling. Forensics pair:

```bash
k describe node cka-worker | grep -A 8 'Allocated resources'   # requested vs allocatable, per resource
k get po -A -o wide --field-selector spec.nodeName=cka-worker  # who is occupying it
```

`Insufficient cpu` in a FailedScheduling event is therefore fixed by one of: lower the pod's requests, delete/scale down squatters, add nodes, or preempt via priority. On the exam, "lower the requests" is almost always the intended move — check whether the task's requests are plausibly a typo (`"1000m"` vs `"1000"`... i.e. 1 CPU vs 1000 CPUs, or `memory: 64Gi` on an 8Gi node).

## Multiple schedulers and schedulerName

Every pod has `spec.schedulerName` (default `default-scheduler`). Each scheduler process only picks up pods naming it. You can run additional schedulers — typically the same kube-scheduler binary with a KubeSchedulerConfiguration setting a different `schedulerName` and its own leader-election lock, deployed as a Deployment in kube-system. The exam needs awareness, not construction:

- Pod with `schedulerName: my-scheduler` and no such scheduler running → **Pending forever, zero events**. Nothing claims it, nothing complains. This "silent Pending" signature (shared with nodeName-to-nonexistent-node) is a deliberately nasty troubleshooting scenario: no events means *no scheduler processed the pod* — immediately check `spec.schedulerName`, then whether kube-scheduler itself is healthy in kube-system.
- `schedulerName` is immutable; fixing it means recreate (`k get po x -o yaml > f.yaml`, fix, `k replace --force -f f.yaml`).
- Which scheduler placed a pod: the `Scheduled` event's source (`k describe po` shows `default-scheduler` or your custom name).

## DaemonSets: scheduling's special child

DaemonSets earn their scheduling note: the DS controller creates one pod per eligible node, and (since v1.12; GA v1.17) the **default scheduler** binds them — the controller injects into each pod a `nodeAffinity` with a `matchFields` term on `metadata.name=<target-node>`, pinning it while keeping taints/resources honored. The controller also injects tolerations for `not-ready`, `unreachable` (both NoExecute — DS pods survive node failure taints), `disk-pressure`, `memory-pressure`, `pid-pressure`, `unschedulable`, and `network-unavailable`.

Operational consequences:

- DS pods schedule onto **cordoned** nodes (they tolerate `unschedulable`) and survive drains — hence `--ignore-daemonsets`.
- DS pods do **not** automatically tolerate custom taints or the control-plane taint. Monitoring-agent-on-every-node tasks require adding `node-role.kubernetes.io/control-plane: Exists: NoSchedule` to the DS pod template — a classic exam task.
- Limiting a DS to some nodes: `nodeSelector`/affinity in the pod template, exactly like any pod.

---

## Traps

1. **"nodeSelectorTerms are ANDed."** No — terms are **ORed**; `matchExpressions` inside a term are ANDed. Nesting two conditions as separate terms when you meant AND silently widens placement; the pod schedules "successfully" onto a wrong node and you lose the points without an error.
2. **"Tainting the node moves my pods there."** Taints repel others; they attract nothing. Dedicated-node tasks need taint + toleration + nodeSelector/affinity. If the task says "ensure *only* pods X run on the node **and** X runs there", a toleration alone is half the answer.
3. **"The toleration didn't work — the pod is still Pending."** Tolerating a taint only removes that one barrier; the pod must still pass affinity, resources, and every other Filter. Read the *full* FailedScheduling message: the taint fragment may be gone while `Insufficient cpu` remains.
4. **"nodeName respects taints."** It bypasses the scheduler: NoSchedule/cordon are ignored. But NoExecute still evicts, and the kubelet still rejects on resources (`OutOfcpu` — a *failed* pod, not Pending). Different symptom, different mechanism.
5. **Taint removal syntax.** `k taint node X key=value:NoSchedule-` — the trailing dash, with effect included (or `key-` for all). Trying `k taint node X key=null` or editing YAML wastes minutes.
6. **"PDBs protected us during the outage."** NoExecute/taint-manager evictions are direct deletions — PDBs only govern the Eviction API (drain). Also: the 5-minute failover delay after node death is the injected `tolerationSeconds: 300` defaults, not a scheduler timer.
7. **"Drain failed, so I'll fix and rerun later"** — and the node stays **cordoned**, breaking subsequent tasks with `node(s) were unschedulable`. Always `k get nodes` after drain work; uncordon what you cordoned.
8. **Editing a mirror pod.** `k edit po kube-apiserver-...` will never persist. Static pods are files; change `/etc/kubernetes/manifests/*.yaml` on the node. Similarly `k delete` on one is a no-op with extra steps (kubelet recreates it).
9. **"Cordon evicts pods."** Cordon only blocks *new* scheduling. Existing pods stay. Moving pods off is drain's job.
10. **Topology spread on kind deadlocks.** Default `nodeTaintsPolicy: Ignore` counts the tainted control-plane as an eligible 0-pod domain; with `maxSkew: 1` + `DoNotSchedule`, replica 3+ goes Pending. Tolerate the taint, set `nodeTaintsPolicy: Honor`, or use `ScheduleAnyway`. And a forgotten `labelSelector` makes the constraint count nothing — silently useless.
11. **"The scheduler will rebalance."** Nothing rebalances running pods: not spread constraints, not affinity, not priority. All placement is schedule-time except NoExecute eviction.
12. **"The node has plenty of free CPU"** (per `kubectl top`) but the pod is Pending with `Insufficient cpu` — scheduling is on *requests*, not usage. Compare `Allocated resources` in `k describe node`, not live metrics.
13. **Silent Pending, zero events.** Not a taint, not resources — nothing scheduled the pod at all. Check `spec.schedulerName` (typo'd/custom absent scheduler) or a dead kube-scheduler. `schedulerName` is immutable: recreate the pod.
14. **Hand-writing affinity YAML from memory.** There is no imperative flag for affinity/tolerations/spread. The fast path is `k run x --image=nginx $do > p.yaml` + paste the block from the docs (Assign Pods to Nodes page) and adapt. And pod-spec placement fields are immutable — fixing a live pod means `k replace --force -f`, not `k edit` (which will refuse).
15. **Gt/Lt values are strings.** `values: [8]` fails validation; `values: ["8"]` parses. Likewise toleration `value: true` must be `value: "true"`.
16. **Debugging a preferred rule as if it were required.** `preferred...` losing to other score plugins and landing "wrong" is working as designed. If the task says *must*, use `required...`; if it says *should/prefer*, points may depend on using `preferred...`.
17. **Zone topologyKeys on unlabeled clusters.** `topology.kubernetes.io/zone` on nodes without the label: pod affinity can never match (Pending); spread constraints simply have no domains. kind sets only `kubernetes.io/hostname` — label nodes yourself to simulate zones.

---

## Speed patterns

**Session setup (once per exam terminal, assumed everywhere below):**

```bash
alias k=kubectl
export do="--dry-run=client -o yaml"
export now="--grace-period=0 --force"
```

**Node labeling and tainting** — pure one-liners, no YAML ever:

```bash
k label node cka-worker disktype=ssd
k taint node cka-worker dedicated=infra:NoSchedule
k taint node cka-worker dedicated=infra:NoSchedule-
k get nodes -L disktype                      # verify labels as a column
k describe node cka-worker | grep Taints
```

**Placement YAML in under 3 minutes:** generate the skeleton, then paste-and-adapt the affinity/toleration/spread block from the docs — never type nested YAML from memory:

```bash
k run web --image=nginx:1.27 $do > p.yaml
# open kubernetes.io/docs → search "assign pods nodes" → copy required-affinity block
vim p.yaml && k apply -f p.yaml
```

Offline schema lookup when docs feel slow:

```bash
k explain pod.spec.affinity.nodeAffinity --recursive | less
k explain pod.spec.topologySpreadConstraints --recursive
k explain pod.spec.tolerations
```

**The toleration block is the one worth memorizing** (4 lines, appears constantly):

```yaml
tolerations:
- key: node-role.kubernetes.io/control-plane
  operator: Exists
  effect: NoSchedule
```

**Pending triage macro** (30 seconds to a diagnosis):

```bash
k describe po $P | tail -15                        # the FailedScheduling message
k get po $P -o jsonpath='{.spec.schedulerName}{"\n"}'   # if there were no events
k describe node cka-worker | grep -A 8 'Allocated resources'   # if Insufficient*
```

**Drain macro** (memorize as one unit, plus the closing uncordon):

```bash
k drain cka-worker --ignore-daemonsets --delete-emptydir-data --force
# ... maintenance ...
k uncordon cka-worker
```

**Immutable-field surgery** (wrong nodeSelector/schedulerName/affinity on a live pod):

```bash
k get po broken -o yaml > /tmp/p.yaml
vim /tmp/p.yaml
k replace --force -f /tmp/p.yaml     # delete+recreate in one command
```

**Imperative object creation** (no YAML needed at all):

```bash
k create priorityclass high-prio --value=100000 --description="high"
k create pdb web-pdb --selector=app=web --min-available=1 -n prod
```

**Placement verification** (end *every* scheduling task with one of these — points are graded on state, not effort):

```bash
k get po -o wide
k get po -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase
k get po -A -o wide --field-selector spec.nodeName=cka-worker
```

**Static pod fast path:**

```bash
docker exec -it cka-worker bash                       # exam: ssh node01; sudo -i
grep staticPodPath /var/lib/kubelet/config.yaml       # almost always /etc/kubernetes/manifests
k run static-web --image=nginx:1.27 $do > /etc/kubernetes/manifests/static-web.yaml  # if kubectl exists on node; else vim
```

---

## Docs map

Firefox on the exam reaches only kubernetes.io/docs, kubernetes.io/blog, helm.sh/docs. Search terms below are what to type in the docs search box.

| You need | Path under kubernetes.io | Search term |
|---|---|---|
| nodeSelector, node affinity, pod affinity YAML | `/docs/concepts/scheduling-eviction/assign-pod-node/` | "assign pods nodes" |
| Taints, tolerations, built-in taints table | `/docs/concepts/scheduling-eviction/taint-and-toleration/` | "taint toleration" |
| Topology spread fields + examples | `/docs/concepts/scheduling-eviction/topology-spread-constraints/` | "topology spread" |
| PriorityClass, preemption details | `/docs/concepts/scheduling-eviction/pod-priority-preemption/` | "priority preemption" |
| Scheduler overview (filter/score) | `/docs/concepts/scheduling-eviction/kube-scheduler/` | "kube-scheduler" |
| Framework phases (plugin names in events) | `/docs/concepts/scheduling-eviction/scheduling-framework/` | "scheduling framework" |
| Static pod how-to | `/docs/tasks/configure-pod-container/static-pod/` | "static pod" |
| Drain, PDB interplay | `/docs/tasks/administer-cluster/safely-drain-node/` | "drain node" |
| PDB creation | `/docs/tasks/run-application/configure-pdb/` | "disruption budget" |
| Multiple schedulers | `/docs/tasks/extend-kubernetes/configure-multiple-schedulers/` | "multiple schedulers" |
| DaemonSet tolerations table | `/docs/concepts/workloads/controllers/daemonset/` | "daemonset" |
| Requests/limits, allocatable | `/docs/concepts/configuration/manage-resources-containers/` | "manage resources containers" |

---

## Checkpoint

Self-test cold, on the kind cluster, timed. Redo any item you miss until it is boring.

- Can you explain nodeSelector vs node affinity vs taints vs pod affinity — who declares it, attract or repel — in 30 seconds, no notes?
- Can you label a node and land a pod on it with nodeSelector in 2 minutes, including verification with `-o wide`?
- Can you write required node affinity with `In` over two values (docs paste allowed) in 3 minutes?
- Can you taint a node, prove an ordinary pod won't schedule, then create a tolerating pod that lands there in 5 minutes?
- Can you state from memory what matches what: `Exists` vs `Equal`, empty key, empty effect, and quote the 4-line control-plane toleration?
- Can you apply a NoExecute taint and predict — before running it — which pods are evicted immediately, which after N seconds, and why DaemonSet pods stay?
- Can you produce a 2-replica deployment where replicas never co-locate (anti-affinity, hostname) in 4 minutes, and say when you'd use topology spread instead?
- Can you spread 6 replicas 2/2/2 across all 3 kind nodes with maxSkew=1 DoNotSchedule — including the control-plane toleration — in 6 minutes?
- Can you diagnose an arbitrary Pending pod (taint vs affinity vs resources vs cordon vs ghost scheduler) to a written root cause in 3 minutes from `describe` output alone?
- Can you drain a node past a blocking PDB — without deleting the PDB — and explain why eviction returned 429, in 8 minutes?
- Can you create a static pod on a kind worker, name its mirror pod before checking, prove `kubectl delete` can't kill it, and then remove it properly, in 6 minutes?
- Can you create a PriorityClass and demonstrate preemption (victim evicted, `nominatedNodeName` set) in 8 minutes?
- Can you list the three drain refusal reasons and their flags without looking?

All yes → week 3 exercises, then move on. This module's mechanics are reflex material: on the exam you should spend your thinking budget on *reading the task*, not on remembering where `topologyKey` goes.
