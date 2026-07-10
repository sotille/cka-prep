# Week 02 Masterclass — Workloads & Configuration (Workloads & Scheduling 15% · Helm/Kustomize under Cluster Architecture 25% · feeds Troubleshooting 30%)

Workload controllers and configuration plumbing are the exam's bread-and-butter build tasks — and, disguised as "why is this pod broken", a large slice of the 30% troubleshooting domain. This module covers the controller internals (Deployments, DaemonSets, StatefulSets, Jobs, CronJobs), the entire ConfigMap/Secret consumption matrix, resources/QoS/eviction, quotas, HPA v2, and the two Feb-2025 curriculum additions most older courses skip: Helm and Kustomize. Where behavior is version-dependent it is flagged; verify the current exam Kubernetes version on the CNCF curriculum page before exam day.

---

## What the exam actually asks

| Topic | Domain | Weight | Typical task phrasing |
|---|---|---|---|
| Deployment rollouts, undo, scaling | Workloads & Scheduling | 15% | "Update the image... roll back to the previous working revision" |
| ConfigMaps/Secrets creation + consumption | Workloads & Scheduling | 15% | "Expose key X as env var, mount secret Y at /etc/..." |
| Resource requests/limits, HPA | Workloads & Scheduling | 15% | "Configure autoscaling between 2 and 6 replicas at 70% CPU" |
| Helm install/upgrade/rollback | Cluster Architecture | 25% | "Install chart X version Y in namespace Z", "upgrade the broken release" |
| Kustomize overlays | Cluster Architecture | 25% | "Render/apply the overlay so the image tag is X and names are prefixed" |
| Stuck rollout, ImagePullBackOff, OOMKilled, quota rejections | Troubleshooting | 30% | "Deployment X has 0 available replicas. Fix it." |
| Jobs/CronJobs | Workloads & Scheduling | 15% | "Create a Job that runs N completions, M in parallel" |

Expect 3–5 tasks drawing directly on this module, plus troubleshooting tasks whose root cause lives here (missing requests, bad rollout, secret typo, quota block).

---

## Deployments: the revision machine

A Deployment does not manage pods. It manages **ReplicaSets**, and each ReplicaSet manages pods stamped with a `pod-template-hash` label computed from the pod template. Every time you change `.spec.template` (and only `.spec.template` — scaling does not create a revision), the controller creates a new ReplicaSet and shifts replicas between old and new according to the strategy. Understanding this one indirection explains everything about rollouts:

- **Revisions are ReplicaSets.** `kubectl rollout history` just lists ReplicaSets that carry the `deployment.kubernetes.io/revision` annotation. `revisionHistoryLimit` (default 10) controls how many old, scaled-to-zero ReplicaSets are retained. Set it to 0 and you lose the ability to undo.
- **Undo is a template copy, not time travel.** `k rollout undo deploy/web --to-revision=2` copies revision 2's pod template into the Deployment, which creates a *new* revision (the highest number + 1). Revision 2 disappears from history and its ReplicaSet is re-annotated with the new number. History numbers are not stable identifiers — always inspect before pinning:

```bash
k rollout history deploy/web                      # list revisions
k rollout history deploy/web --revision=2         # show that revision's pod template (image!)
k rollout undo deploy/web --to-revision=2
k rollout status deploy/web                       # blocks until done or deadline exceeded
```

- **Change-cause**: `--record` is deprecated/removed. To populate the CHANGE-CAUSE column: `k annotate deploy/web kubernetes.io/change-cause="image bump to 1.29"` after each change. The annotation on the Deployment is copied to the current ReplicaSet.

### RollingUpdate math

```yaml
spec:
  replicas: 10
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%        # extra pods allowed ABOVE replicas — rounds UP
      maxUnavailable: 25%  # pods allowed missing BELOW replicas — rounds DOWN
```

With replicas=10 and the 25%/25% defaults: maxSurge = ceil(2.5) = 3 → up to **13** pods exist mid-rollout; maxUnavailable = floor(2.5) = 2 → at least **8** must be available at all times. The controller scales the new RS up and the old RS down in steps that never violate either bound.

- `maxSurge: 0, maxUnavailable: 0` is rejected by validation — the rollout could never make progress.
- Zero-downtime pattern: `maxSurge: 1, maxUnavailable: 0` — new pod must be Ready before an old one dies. Combine with `minReadySeconds` (pod must stay Ready N seconds before counting as available) to catch crash-on-start regressions.
- Absolute numbers are allowed and often demanded by exam tasks ("at most one pod above the desired count").

### Recreate

`strategy.type: Recreate` kills **all** old pods before creating any new ones. Full outage, but required when old and new versions cannot coexist (exclusive volume lock, singleton consumers). Trap: strategic-merge-patching `type: Recreate` onto a Deployment that has a `rollingUpdate` block fails validation ("may not be specified when strategy type is Recreate") — you must remove the block, e.g.:

```bash
k patch deploy web -p '{"spec":{"strategy":{"$retainKeys":["type"],"type":"Recreate"}}}'
```

### Pause / resume

`k rollout pause deploy/web` stops the controller from acting on template changes. Batch several edits (image + resources + env), then `k rollout resume deploy/web` — one revision instead of three. A paused Deployment never progresses; a forgotten pause looks exactly like a broken rollout (see Traps).

### progressDeadlineSeconds

Default 600. If the rollout makes no progress (no new pod becomes available) for that long, the controller sets condition `Progressing=False`, `reason: ProgressDeadlineExceeded`, and `k rollout status` exits non-zero with "exceeded its progress deadline". **Nothing is rolled back automatically** — the deployment sits half-rolled forever until you `rollout undo` or fix the template. Diagnosis chain for a stuck rollout:

```bash
k rollout status deploy/web            # tells you it's stuck
k describe deploy web                  # Conditions: Progressing False / ProgressDeadlineExceeded
k get rs -l app=web                    # new RS with desired>0, ready=0
k get pods -l app=web                  # ImagePullBackOff / CrashLoopBackOff / Pending
k describe pod <newest-pod>            # actual root cause in Events
```

---

## DaemonSets

One pod per (eligible) node. Since Kubernetes 1.12, DaemonSet pods are scheduled by the default scheduler via an injected node-affinity term — so they respect taints like everything else, except the controller auto-adds tolerations for node lifecycle taints (`node.kubernetes.io/not-ready`, `unreachable`, `disk-pressure`, `memory-pressure`, `pid-pressure`, `unschedulable`).

**Node coverage:** the control-plane taint is *not* auto-tolerated. A DaemonSet that must run on every node — the classic exam ask for a log shipper or CNI-style agent — needs:

```yaml
spec:
  template:
    spec:
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
```

Restrict coverage the other way with `nodeSelector` or node affinity in the pod template. Verify coverage with `k get ds -A` (DESIRED vs CURRENT vs READY columns) — DESIRED = number of matching nodes.

**updateStrategy:**

| Strategy | Behavior |
|---|---|
| `RollingUpdate` (default) | Replaces pods node-by-node; `maxUnavailable` default 1, `maxSurge` supported ≥1.22 (surge means old+new coexist briefly on a node — only safe if ports/hostPaths don't conflict) |
| `OnDelete` | New template applies only when *you* delete each pod — manual, node-at-a-time control |

There is no imperative `kubectl create daemonset`. Fastest scaffold: `k create deploy x --image=... $do`, change `kind: Deployment` → `DaemonSet`, delete `replicas` and `strategy` (see Speed patterns).

---

## StatefulSets

Deployments give pods lottery-ticket names; StatefulSets give them **stable identity**: ordinal names (`db-0`, `db-1`, `db-2`), stable per-pod DNS, and per-pod storage that survives rescheduling.

- **Headless service requirement:** `.spec.serviceName` must name a headless Service (`clusterIP: None`) selecting the pods. It provides per-pod DNS: `db-0.db-hl.data.svc.cluster.local`. The API server does **not** validate that the service exists — a typo silently costs you pod DNS, nothing errors. Peer discovery (databases, quorum systems) is the whole point.
- **volumeClaimTemplates:** the controller creates one PVC per pod, named `<template>-<sts>-<ordinal>` (`data-db-0`). Rescheduled or recreated pods rebind the same PVC. **PVCs are not deleted** when you scale down or delete the StatefulSet — this is a data-safety feature and a cleanup trap. (`persistentVolumeClaimRetentionPolicy` can change this; it went GA in recent versions — check the exam version's docs before relying on it.)
- **Ordered lifecycle:** with the default `podManagementPolicy: OrderedReady`, pods are created 0→N-1, each waiting for the previous to be Ready, and deleted N-1→0. One crashing pod wedges the whole scale-up. `podManagementPolicy: Parallel` launches/kills all at once (identity and storage guarantees remain).
- **Rolling update partition:** the update strategy supports staged rollouts:

```yaml
spec:
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 2   # only pods with ordinal >= 2 get the new template
```

Updates proceed highest-ordinal-first. `partition: 2` on a 3-replica set updates only `db-2` — a built-in canary. Drop partition to 0 to finish. `OnDelete` is also available. Note: `podManagementPolicy` is immutable and `volumeClaimTemplates` are effectively immutable — get them right at creation; changing them means delete (`--cascade=orphan` if you must keep pods) and recreate.

---

## Jobs

A Job runs pods to **completion** and tracks successes.

| Field | Meaning | Default |
|---|---|---|
| `completions` | Total successful pods required | 1 |
| `parallelism` | Max pods running simultaneously | 1 |
| `backoffLimit` | Retries before the Job is marked Failed | 6 |
| `activeDeadlineSeconds` | Wall-clock budget for the whole Job; overrides backoffLimit; pods are killed, Job condition `Failed`, reason `DeadlineExceeded` | unset |
| `ttlSecondsAfterFinished` | Auto-delete the Job (and its pods) N seconds after it finishes | unset (Jobs pile up forever) |
| `completionMode: Indexed` | Each pod gets a completion index (env `JOB_COMPLETION_INDEX`) — for static work partitioning | `NonIndexed` |

**restartPolicy — the exam-relevant distinction.** A Job pod template only accepts `Never` or `OnFailure` (`Always` is invalid — a common broken-manifest task):

- `OnFailure`: the **kubelet restarts the failed container in the same pod**. Retries count container restarts; when the limit is hit the pod is deleted — **your failure logs vanish**.
- `Never`: a failed pod stays (Failed phase) and the controller creates a **new pod** for the retry. Failed pods accumulate and remain inspectable via `k logs`. Prefer `Never` when you need to debug why a Job fails — which on the exam is exactly what you need.

Retry backoff is exponential (10s, 20s, 40s… capped at 6 minutes). A Job's pods are labeled with `job-name=<name>` — `k logs -l job-name=pi` gets you all output.

## CronJobs

A CronJob creates Job objects on a schedule. The controller checks every 10 seconds.

- **Schedule syntax** — standard 5-field cron: `minute hour day-of-month month day-of-week`. `*/5 * * * *` = every 5 minutes; `0 3 * * 1` = 03:00 every Monday. Macros like `@hourly` work. Times are evaluated in the kube-controller-manager's timezone (UTC on virtually every cluster) unless `.spec.timeZone: "Etc/UTC"`-style IANA name is set (stable in 1.27+).
- `concurrencyPolicy`: `Allow` (default — overlapping runs stack up), `Forbid` (skip the new run if the previous is still running), `Replace` (kill the running Job, start fresh).
- `startingDeadlineSeconds`: how late a run may start and still count. Also bounds the missed-schedule check: without it, if the controller finds **more than 100 missed schedules** (e.g. the CronJob was suspended for a week, or the controller was down), it refuses to schedule *anything* and logs an error. With it, only misses inside the deadline window are counted.
- `successfulJobsHistoryLimit` (default 3) / `failedJobsHistoryLimit` (default 1): finished Jobs retained.
- `suspend: true`: stops new Jobs; running ones finish. Un-suspending after a long gap is the classic >100-missed-schedules trigger.
- **Manual trigger** (exam favorite): `k create job run-now --from=cronjob/backup`.

The Job spec lives at `.spec.jobTemplate.spec` — two levels of `spec.template` nesting; when writing from scratch, scaffold with `k create cronjob $do` instead of typing the pyramid by hand.

---

## ConfigMaps and Secrets: every consumption mode

Creation, imperatively (always fastest):

```bash
k create cm app-config --from-literal=APP_MODE=prod --from-file=nginx.conf \
  --from-file=custom-name=./local.conf --from-env-file=app.env
k create secret generic app-secret --from-literal=DB_PASS='S3cret!' --from-file=ssh=./id_rsa
k create secret tls web-tls --cert=tls.crt --key=tls.key
k create secret docker-registry regcred --docker-server=reg.example.com \
  --docker-username=u --docker-password=p
```

### The consumption matrix

| Mode | ConfigMap | Secret | Updates propagate? |
|---|---|---|---|
| Single env var | `env[].valueFrom.configMapKeyRef` | `secretKeyRef` | **Never** (pod restart required) |
| All keys as env | `envFrom[].configMapRef` | `envFrom[].secretRef` | **Never** |
| Volume (whole object) | `volumes[].configMap` | `volumes[].secret` | Yes — kubelet refreshes; worst case ≈ kubelet sync period (1m) + cache propagation, typically well under 2 minutes |
| Volume, selected keys | `configMap.items[]` (key→path) | same | Yes |
| `subPath` mount | mounts one file into an existing dir | same | **Never** — see trap below |
| Projected volume | combine CM + Secret + downwardAPI + SA token in one mount | same | Yes (except subPath) |
| Command args | `$(VAR_NAME)` in `command`/`args` referencing an env var | same | Never |

Reference example covering the main modes in one pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: config-demo
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "echo mode=$(APP_MODE); sleep 3600"]
    env:
    - name: APP_MODE
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: APP_MODE
    envFrom:
    - secretRef:
        name: app-secret
    - configMapRef:
        name: app-config
        # optional: true    # tolerate the CM not existing
    volumeMounts:
    - name: conf
      mountPath: /etc/app          # directory of symlinked files, auto-updating
    - name: combo
      mountPath: /etc/combined
  volumes:
  - name: conf
    configMap:
      name: app-config
      items:
      - key: nginx.conf
        path: server/nginx.conf
  - name: combo
    projected:
      sources:
      - configMap:
          name: app-config
      - secret:
          name: app-secret
          items:
          - key: DB_PASS
            path: db/password
```

### The subPath no-update trap

Volume-mounted ConfigMaps update live because the kubelet writes new data into a timestamped dir and atomically flips a symlink (`..data`). A `subPath` mount bind-mounts one resolved file directly — it bypasses the symlink, so **the container keeps the file content from pod start forever**. If a task says "the app must pick up config changes", subPath is disqualified. subPath's legitimate use: dropping one file into a directory that must keep its other contents (e.g. `/etc/nginx/conf.d/custom.conf`).

Environment variables never update either — the values are injected at container start. The exam-legal refresh for env-consumed config is `k rollout restart deploy/web`.

### Secrets: data vs stringData, base64 mechanics

- `data:` values are **base64-encoded** (encoding, not encryption — anyone with GET on the secret reads them). `stringData:` is a write-only convenience: plain text in, merged into `data` on write; on key conflict `stringData` wins. You never see `stringData` when reading back.
- Hand-encoding: `echo -n 'S3cret!' | base64` — the `-n` matters; without it you embed a trailing newline and the password is silently wrong (classic "app can't authenticate" troubleshooting task).
- Decoding: `k get secret app-secret -o jsonpath='{.data.DB_PASS}' | base64 -d`.
- `--from-literal`/`--from-file` do the encoding for you — prefer them.

Secret types worth knowing:

| Type | Created by | Enforced keys / use |
|---|---|---|
| `Opaque` | `create secret generic` | arbitrary |
| `kubernetes.io/tls` | `create secret tls` | `tls.crt`, `tls.key` — Ingress/Gateway TLS |
| `kubernetes.io/dockerconfigjson` | `create secret docker-registry` | `.dockerconfigjson` — referenced by `spec.imagePullSecrets` |
| `kubernetes.io/basic-auth`, `ssh-auth` | manifest | conventional keys (`username`/`password`, `ssh-privatekey`) |
| `kubernetes.io/service-account-token` | legacy SA tokens | mostly historical; SA tokens are projected now |

### Immutable ConfigMaps/Secrets

`immutable: true` (on either) rejects all edits to data. Benefits: protects against accidental change and lets the kubelet stop watching (real apiserver load reduction at scale). It is one-way — you cannot unset it; to change the data you delete and recreate the object, then restart consumers. Kustomize's generators (below) are the systematic version of this idea: never mutate, always create-new-name.

---

## Resources, QoS, and the eviction ladder

- **Requests** are scheduler currency: the pod fits on a node only if free allocatable ≥ requests. Unrequested pods schedule anywhere and are first against the wall under pressure.
- **Limits** are runtime enforcement: CPU limit = cgroup throttling (pod runs, just slower — invisible except in latency); memory limit = cgroup hard cap → the kernel OOM-kills the container. `kubectl describe pod` shows `Last State: Terminated, Reason: OOMKilled, Exit Code: 137` (137 = 128 + SIGKILL). The fix is raising the **memory limit** (or fixing the leak) — CPU has nothing to do with 137.
- If you set only limits, requests default to the limits (this is how one-line Guaranteed pods happen).

### QoS classes

Computed, not declared — read it at `.status.qosClass`:

| Class | Condition | Under node pressure |
|---|---|---|
| `Guaranteed` | **Every** container has cpu+memory limits, and requests == limits | Evicted last |
| `Burstable` | At least one container has any request/limit, but not Guaranteed | Middle; usage-above-request evicted earlier |
| `BestEffort` | No requests, no limits anywhere | Evicted first |

Kubelet eviction (node-pressure) ranks pods by: (1) whether usage exceeds requests, (2) pod priority, (3) how much usage exceeds requests. The myth is that eviction order strictly follows QoS class (BestEffort → Burstable → Guaranteed) — in reality BestEffort and over-request Burstable land in the same "usage > requests" bucket (BestEffort's request is zero), and within it a Burstable pod far above its request goes *before* a near-idle BestEffort pod at equal priority; Guaranteed and under-request Burstable go last. The kernel OOM killer (a different mechanism, when the node runs out of memory faster than kubelet can react) uses `oom_score_adj`: BestEffort ≈ 1000 (kill me first), Guaranteed ≈ -997 (almost never).

Exam read: "the pod keeps disappearing under load" → check QoS class and requests before anything exotic.

## LimitRange and ResourceQuota

Both are namespaced admission-time policies. They do not touch running pods — only creations/updates.

**LimitRange** — per-object defaults and bounds:

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: defaults
spec:
  limits:
  - type: Container
    defaultRequest:      # injected requests when absent
      cpu: 100m
      memory: 128Mi
    default:             # injected limits when absent
      cpu: 200m
      memory: 256Mi
    min:
      cpu: 10m
      memory: 16Mi
    max:
      cpu: "1"
      memory: 1Gi
    # maxLimitRequestRatio: burst-factor cap (limit/request)
```

**ResourceQuota** — namespace-wide budget: `requests.cpu`, `requests.memory`, `limits.cpu`, `limits.memory`, `pods`, plus object counts (`count/deployments.apps`, `services`, `persistentvolumeclaims`, ...). `k describe quota -n ns` shows used vs hard.

**The interaction that makes exam tasks:** once a quota constrains `requests.*` or `limits.*` in a namespace, **every pod must specify those values or it is rejected at admission** with `403 Forbidden: failed quota ... must specify limits.cpu, requests.cpu...`. Critically, the rejection hits the **ReplicaSet's pod-creation call** — so the failure mode is a Deployment happily existing with **0 pods and no pod-level events**. The evidence lives in `k describe rs <newest>` (Events: FailedCreate) or `k get events`. Two fixes: add resources to the pod template (`k set resources`), or install a LimitRange so defaults are injected and admission passes. This is a rehearsed-or-lost troubleshooting pattern.

---

## HPA v2 (`autoscaling/v2`)

Prerequisites, both non-negotiable: **metrics-server running** (or another metrics API provider) and **CPU/memory requests set on the target's pods** — utilization is defined as a percentage *of requests*. Missing either → `TARGETS` shows `<unknown>` and nothing scales.

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web
spec:
  scaleTargetRef:            # what to scale: anything with a /scale subresource
    apiVersion: apps/v1
    kind: Deployment
    name: web
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization        # % of requests, averaged across pods
        averageUtilization: 70
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300   # default: use highest desired count of last 5 min
      policies:
      - type: Pods
        value: 1
        periodSeconds: 60               # shed at most 1 pod/min
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Percent
        value: 100
        periodSeconds: 15               # may double every 15s (a default)
```

- **Metric types:** `Resource` (cpu/memory of pods), `ContainerResource` (single container within pods), `Pods` (custom per-pod metric, `AverageValue`), `Object` (metric on another object, e.g. requests-per-second on an Ingress), `External` (metrics from outside the cluster, e.g. queue depth). Multiple metrics → HPA computes desired replicas per metric and takes the **max**.
- **The algorithm:** `desired = ceil(current × currentMetric / targetMetric)`, with a ±10% tolerance band around 1.0 to prevent flapping.
- **Behavior/stabilization:** scaleDown default stabilization is 300s (picks the highest recommendation over the window — cautious), scaleUp is 0s (react immediately, bounded by policies: default max of doubling or +4 pods per 15s, `selectPolicy: Max`).
- Imperative creation (fastest, CPU only): `k autoscale deployment web --min=2 --max=10 --cpu-percent=70`. Anything fancier (memory metric, behavior tuning): create imperatively then `k edit hpa web`, or copy the v2 skeleton from the docs.
- Don't set `.spec.replicas` on a Deployment managed by an HPA in manifests you re-apply — each apply fights the autoscaler.

---

## Multi-container patterns, SecurityContext, PriorityClass

**Init containers** run sequentially, each to completion, before app containers start; they share volumes with the pod. The canonical gate: block until a dependency is resolvable —

```yaml
spec:
  initContainers:
  - name: wait-for-db
    image: busybox:1.36
    command: ["sh", "-c", "until nslookup db.data.svc.cluster.local; do echo waiting; sleep 2; done"]
```

A pod stuck in `Init:0/1` means an init container hasn't finished — `k logs pod -c wait-for-db` reads it. **Sidecars**: the classic pattern is just a second container; since 1.29 (beta, on by default; GA later — version-dependent) a *native sidecar* is an init container with `restartPolicy: Always`, which starts before app containers, keeps running, and terminates after them — the right shape for log shippers and proxies. Ambassador (localhost proxy to elsewhere) and adapter (normalize output) are the other two named patterns; on the exam they're all "add a container to the pod spec".

**SecurityContext** — pod-level (`spec.securityContext`) applies to all containers: `runAsUser`, `runAsGroup`, `runAsNonRoot`, `fsGroup` (chowns volume files at mount — the fix for "app can't write to its PVC"), `seccompProfile`. Container-level (`containers[].securityContext`) **overrides** pod-level and holds the container-only knobs: `capabilities.add/drop`, `privileged`, `allowPrivilegeEscalation`, `readOnlyRootFilesystem`. Typical task: "run as UID 1000, non-root, add NET_ADMIN":

```yaml
spec:
  securityContext:
    runAsUser: 1000
    runAsNonRoot: true
    fsGroup: 2000
  containers:
  - name: app
    image: busybox:1.36
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
        add: ["NET_BIND_SERVICE"]
```

**Pod priority** (light, but shows up in scheduling questions): a `PriorityClass` (`scheduling.k8s.io/v1`, cluster-scoped) maps a name to an integer `value`; pods reference it via `spec.priorityClassName`. Higher-priority pending pods can **preempt** (evict) lower-priority pods to fit, unless the class sets `preemptionPolicy: Never`. `globalDefault: true` on at most one class sets the namespace-wide default. Built-ins `system-cluster-critical` / `system-node-critical` explain why kube-system pods never lose eviction fights.

## Labels, selectors, annotations discipline

- **Labels** are for identity and selection; **annotations** are for non-identifying metadata (change-cause, tool state) and cannot be selected on.
- Two selector styles: `matchLabels` (AND of equalities) and `matchExpressions` (`In`, `NotIn`, `Exists`, `DoesNotExist`). Services support only the equality map form (`spec.selector`), no expressions.
- **Deployment/StatefulSet/DaemonSet `.spec.selector` is immutable.** Editing template labels without matching the selector is rejected (`selector does not match template labels`); "fixing" it by changing the selector fails too. Real fix: delete and recreate (use `--cascade=orphan` to keep pods alive if the task demands no downtime).
- The controller chain matches by labels only: a Service selecting `app: web` happily picks up pods from *any* deployment with that label — label hygiene is a debugging tool (`k get pods -l app=web --show-labels`).
- Speed toolkit: `k label pod x tier=backend` / `k label pod x tier-` (remove) / `--overwrite`; `k get po -l 'env in (prod,staging)'`; `k annotate deploy web team=payments`.

---

## Helm

Chart = templated manifests + default `values.yaml`. Release = chart installed under a name in a namespace, with numbered revisions stored as Secrets (`sh.helm.release.v1.<name>.v<N>`) in the release namespace — that's why `helm history` survives your terminal and why RBAC on secrets can break Helm.

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm search repo nginx --versions        # find chart + app versions
helm show values bitnami/nginx           # the chart's tunables (pipe to less)

helm install web bitnami/nginx -n web --create-namespace \
  -f base-values.yaml -f prod-values.yaml --set replicaCount=3
helm upgrade web bitnami/nginx -n web --set image.tag=1.29 --version 18.2.1
helm upgrade --install web bitnami/nginx -n web    # idempotent: install if absent

helm list -A                             # all releases, all namespaces (check STATUS)
helm get values web -n web               # user-supplied values (-a for computed/all)
helm get manifest web -n web             # exactly what was applied
helm history web -n web                  # revisions with status
helm rollback web 1 -n web               # to revision 1 — creates a NEW revision
helm uninstall web -n web                # --keep-history to retain record
helm template web bitnami/nginx -f v.yaml   # offline render, nothing touches cluster
```

**Values precedence** (lowest → highest): chart's built-in `values.yaml` → `-f` files in order given (later file wins) → `--set`/`--set-string`/`--set-file` (wins over everything). `--set` syntax: `a.b=v`, lists `a[0]=v`, escaped dots `nodeSelector."kubernetes\.io/role"=worker`.

Two upgrade footguns: (1) `helm upgrade` does **not** reuse the previous release's values — it starts from chart defaults plus whatever you pass now; a bare upgrade silently reverts earlier `--set`s (`--reuse-values` merges the old ones, with its own sharp edges after chart-version bumps). (2) `helm rollback` doesn't renumber: rolling back rev 2 while at rev 3 creates rev 4 (`history` shows "Rollback to 2"). Verify with `helm get values`.

`helm.sh/docs` is allowed in the exam browser. `helm --help` and `helm <cmd> --help` are faster than the docs for flag recall.

## Kustomize

Template-free overlays: a `kustomization.yaml` lists resources and transformations; `kubectl kustomize <dir>` renders, `kubectl apply -k <dir>` applies (`delete -k`, `diff -k` also work). Kustomize is built into kubectl — no extra binary needed on the exam (the embedded version can lag the standalone `kustomize` CLI; feature edges differ).

```yaml
# kustomization.yaml — anatomy
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod            # forced onto all resources
namePrefix: prod-          # web -> prod-web (references auto-rewritten)
nameSuffix: -v2
commonLabels:              # applied to metadata AND selectors (see trap)
  team: payments
resources:                 # what to build: files, dirs (bases), URLs
  - ../../base
  - extra-service.yaml
images:                    # retag/rename without touching manifests
  - name: nginx            # match containers using image "nginx"
    newName: registry.example.com/nginx
    newTag: "1.29"
patches:                   # strategic-merge or JSON6902, inline or file
  - path: replicas-patch.yaml            # strategic merge patch file
  - target:
      kind: Deployment
      name: web
    patch: |-              # JSON6902 ops, YAML syntax
      - op: replace
        path: /spec/replicas
        value: 5
configMapGenerator:
  - name: app-config
    literals:
      - LOG_LEVEL=info
    files:
      - nginx.conf
secretGenerator:
  - name: app-secret
    literals:
      - DB_PASS=changeme
# generatorOptions:
#   disableNameSuffixHash: true
```

- **Base/overlay layout:** `base/` holds the neutral manifests + its own kustomization; `overlays/prod/` has a kustomization whose `resources: [../../base]` plus prod-only transformations. Overlays compose — an overlay can point at another overlay.
- **Strategic-merge patch** = a partial manifest (apiVersion/kind/metadata.name identify the target, the rest merges). **JSON6902** = explicit `op/path/value` operations with an explicit `target` — precision tool for lists and deletions where merge semantics fight you.
- **Generator hash suffix:** `configMapGenerator`/`secretGenerator` emit `app-config-7c9fm52k9b` — the hash of the content. Every reference *inside the same kustomize build* (env, envFrom, volumes) is rewritten automatically. Change the data → new name → new pod template hash → **automatic rolling restart**, which is the fix for "env vars never update". The trap: anything referencing the ConfigMap from *outside* the build (another tool, a raw manifest applied separately) breaks, because the name keeps moving. `disableNameSuffixHash: true` restores fixed names (and loses the auto-restart).
- **`commonLabels` warning:** it injects labels into `spec.selector` too. Adding it to an already-deployed Deployment changes the (immutable) selector → apply fails. Newer kustomize offers a `labels:` field with `includeSelectors: false`; on the exam, add commonLabels only at first deploy, or patch labels instead.

---

## Traps

1. **`--to-revision` after undo.** Assumption: revision numbers are stable, "revision 2 is always the nginx:1.25 one". Reality: undo renumbers — the restored template becomes the newest revision and the old number disappears. Always `rollout history --revision=N` to inspect *content* before pinning.
2. **Expecting auto-rollback from progressDeadlineSeconds.** Assumption: after the deadline Kubernetes reverts the deployment. Reality: it only flips the `Progressing` condition; the rollout stays wedged until you `rollout undo` or fix the image.
3. **Paused deployment mistaken for broken.** Assumption: "I set the image but nothing happens — controller bug". Reality: someone ran `rollout pause`; `k describe deploy` shows condition `Progressing / DeploymentPaused`. `rollout resume` and it moves.
4. **Recreate patch rejected.** Assumption: `type: Recreate` is a one-field change. Reality: validation rejects it while `rollingUpdate` params exist — use the `$retainKeys` patch or delete the block in an editor.
5. **`echo secret | base64` (no `-n`).** Assumption: encoded is encoded. Reality: you encoded `secret\n`; auth fails and nothing in Kubernetes will ever flag it. Use `echo -n`, or better, `--from-literal`.
6. **subPath mount "not picking up my ConfigMap edit".** Assumption: volume mounts update, this is a volume mount. Reality: subPath bypasses the atomic-symlink update mechanism — content is frozen at pod start. Mount the directory, or restart the pod.
7. **Env vars from ConfigMaps "eventually update".** Assumption: like volumes, just slower. Reality: never. `k rollout restart` is the propagation mechanism.
8. **Editing an immutable ConfigMap.** Assumption: unset `immutable` then edit. Reality: the flag is one-way and data edits are rejected; delete, recreate, restart consumers.
9. **Job with `restartPolicy: Always`.** Assumption: default pod restartPolicy is fine. Reality: invalid for Jobs — the manifest is rejected. And between the valid two, `OnFailure` deletes the evidence when backoffLimit hits; use `Never` when logs matter.
10. **Quota-blocked deployment shows no broken pods.** Assumption: if pods can't be created, pods will show errors. Reality: admission rejects the ReplicaSet's create calls — 0 pods exist, deployment looks idle. Read `k describe rs` / `k get events`. Fix requests/limits or add a LimitRange.
11. **HPA at `<unknown>`.** Assumption: HPA is broken. Reality: metrics-server absent (`k top pods` fails too) or target pods lack CPU requests — utilization % is undefined without requests.
12. **QoS Guaranteed misdiagnosis.** Assumption: setting limits on the main container makes the pod Guaranteed. Reality: *every* container (init containers count too — every container in the pod, init included) needs requests == limits for both cpu and memory; one BestEffort sidecar demotes the pod to Burstable.
13. **OOMKilled "fixed" with CPU.** Assumption: 137 = resource starvation, add CPU. Reality: 137 is SIGKILL from the memory cgroup (or eviction); raise memory limit or fix the app. CPU pressure only throttles.
14. **`helm upgrade` reverting customizations.** Assumption: upgrade keeps the values I installed with. Reality: it uses chart defaults + current flags only. Pass `-f`/`--set` again or `--reuse-values`, and verify with `helm get values`.
15. **CronJob silently dead after long suspend.** Assumption: unsuspend resumes normally. Reality: >100 missed schedules without `startingDeadlineSeconds` and the controller refuses to schedule at all. Set `startingDeadlineSeconds` on anything you might suspend.
16. **kustomize `commonLabels` on a live app.** Assumption: labels are additive metadata. Reality: they're injected into immutable selectors — apply fails, or worse, adopts/orphans pods. Decide labels before first deploy.
17. **Deployment selector "fix".** Assumption: `selector does not match template labels` is fixed by editing the selector. Reality: selector is immutable; you delete and recreate (`--cascade=orphan` to keep serving during the swap).
18. **StatefulSet PVCs after deletion.** Assumption: `k delete sts db` cleans up storage. Reality: PVCs (and data) survive by design; leftover PVCs also make a *recreated* StatefulSet reuse old data — surprising in both directions.

## Speed patterns

| Need | Fastest exam-legal path |
|---|---|
| New deployment | `k create deploy web --image=nginx:1.29 --replicas=3 $do > d.yaml` |
| Change image | `k set image deploy/web nginx=nginx:1.30` (container name = image basename when created imperatively) |
| Set resources | `k set resources deploy web --requests=cpu=100m,memory=128Mi --limits=cpu=200m,memory=256Mi` |
| Env from CM/Secret | `k set env deploy/web --from=configmap/app-config` (adds envFrom-equivalent vars) |
| Roll back | `k rollout history deploy/web` → `--revision=N` to inspect → `k rollout undo deploy/web --to-revision=N` |
| Restart to propagate config | `k rollout restart deploy/web` |
| DaemonSet scaffold | `k create deploy x --image=img $do > ds.yaml` → change `kind`, delete `replicas`+`strategy`, add tolerations |
| Job | `k create job pi --image=busybox:1.36 $do -- sh -c 'echo done' > j.yaml` → add completions/parallelism |
| CronJob | `k create cronjob backup --image=busybox:1.36 --schedule='*/5 * * * *' $do -- sh -c 'echo hi' > cj.yaml` |
| Run CronJob now | `k create job manual-1 --from=cronjob/backup` |
| CM/Secret | `k create cm c --from-literal=k=v`; `k create secret generic s --from-literal=k=v` |
| Update a CM in place | `k create cm c --from-literal=k=v2 $do \| k replace -f -` |
| Read a secret | `k get secret s -o jsonpath='{.data.k}' \| base64 -d` |
| HPA | `k autoscale deploy web --min=2 --max=6 --cpu-percent=70` |
| QoS check | `k get pod x -o jsonpath='{.status.qosClass}'` |
| Quota state | `k describe quota -n ns`; blocked creates: `k describe rs`, `k get events -n ns --sort-by=.lastTimestamp` |
| Helm idempotent deploy | `helm upgrade --install rel repo/chart -n ns --create-namespace -f values.yaml` |
| Helm inspect before touch | `helm list -A` → `helm history rel -n ns` → `helm get values rel -n ns` |
| Kustomize render/apply | `k kustomize overlays/prod` (review) → `k apply -k overlays/prod` |
| Pause-batch edits | `k rollout pause deploy/web` → several changes → `k rollout resume deploy/web` (one revision) |

YAML you should *not* type from scratch: StatefulSet, HPA with behavior, projected volumes, CronJob pyramid. Scaffold imperatively or copy the docs example, then edit. YAML you *should* be able to type cold: tolerations block, securityContext block, volumeMounts+volumes for CM/Secret, resources block.

## Docs map

| You need | kubernetes.io path |
|---|---|
| Deployment (strategy, rollback, progressDeadline) | /docs/concepts/workloads/controllers/deployment/ |
| DaemonSet (updateStrategy, tolerations table) | /docs/concepts/workloads/controllers/daemonset/ |
| StatefulSet (partition, podManagementPolicy) | /docs/concepts/workloads/controllers/statefulset/ |
| Job (backoffLimit, patterns, indexed) | /docs/concepts/workloads/controllers/job/ |
| CronJob (schedule syntax, concurrency) | /docs/concepts/workloads/controllers/cron-jobs/ |
| ConfigMap concepts + immutable | /docs/concepts/configuration/configmap/ |
| Pod+ConfigMap task page (copy-paste YAML) | /docs/tasks/configure-pod-container/configure-pod-configmap/ |
| Secret concepts (types, stringData) | /docs/concepts/configuration/secret/ |
| Secret consumption task page | /docs/tasks/inject-data-application/distribute-credentials-secure/ |
| Requests/limits | /docs/concepts/configuration/manage-resources-containers/ |
| QoS classes | /docs/tasks/configure-pod-container/quality-service-pod/ |
| LimitRange | /docs/concepts/policy/limit-range/ |
| ResourceQuota | /docs/concepts/policy/resource-quotas/ |
| HPA concepts + algorithm + behavior | /docs/tasks/run-application/horizontal-pod-autoscale/ |
| HPA walkthrough (php-apache example) | /docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/ |
| Init containers | /docs/concepts/workloads/pods/init-containers/ |
| SecurityContext (copy-paste blocks) | /docs/tasks/configure-pod-container/security-context/ |
| Priority & preemption | /docs/concepts/scheduling-eviction/pod-priority-preemption/ |
| Labels & selectors | /docs/concepts/overview/working-with-objects/labels/ |
| Kustomize (full field reference lives here) | /docs/tasks/manage-kubernetes-objects/kustomization/ |
| Helm (separate allowed site) | helm.sh/docs — Commands section; helm.sh/docs/intro/cheatsheet/ |

## Checkpoint

Run against the kind lab, clock yourself. All should be yes before moving on:

- Can you create a deployment, update its image, annotate change-cause, and roll back to a *specific* inspected revision in **3 minutes**?
- Can you diagnose a rollout stuck on ProgressDeadlineExceeded down to root cause (bad image) and restore service in **3 minutes**?
- Can you write the maxSurge/maxUnavailable numbers for replicas=6, 50%/25% without kubectl? (surge ceil(3)=3 → 9 max; unavailable floor(1.5)=1 → 5 min ready) — **30 seconds**.
- Can you build a DaemonSet that covers control-plane nodes, from a deployment scaffold, in **4 minutes**?
- Can you build a 3-replica StatefulSet with headless service and volumeClaimTemplates in **6 minutes**, and explain what happens to PVCs on scale-down in one sentence?
- Can you perform a partitioned StatefulSet canary (update only the highest ordinal) in **3 minutes**?
- Can you create a Job with completions=6, parallelism=2, backoffLimit=2, deadline 120s in **4 minutes** from scaffold?
- Can you create a CronJob (Forbid, history 2/1, startingDeadlineSeconds), suspend it, and fire a manual Job from it in **4 minutes**?
- Can you consume a ConfigMap as single env var, a Secret via envFrom, and the ConfigMap as a volume — one pod, all three — in **6 minutes**?
- Can you state from memory which consumption modes see updates and which never do — **30 seconds**?
- Can you decode a Secret key with jsonpath + base64 in **30 seconds**?
- Can you identify any pod's QoS class from `k get pod -o yaml` at sight, and fix a quota-blocked deployment in **4 minutes**?
- Can you create an HPA with `k autoscale`, then add a scaleDown stabilization window by editing, in **3 minutes**?
- Can you helm install → upgrade with `--set` → inspect history → rollback → prove values, in **5 minutes**?
- Can you build a kustomize base+overlay that retags an image and adds a namePrefix, render it, and apply it in **6 minutes**?
