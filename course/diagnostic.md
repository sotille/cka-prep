# CKA Diagnostic / Placement Test

**Take this BEFORE you study.** It is a 45-minute, timed self-assessment that finds your baseline and tells you *where to start* in this course. The number you get is not a grade — it is a routing signal. A low score just means "start earlier in the ramp," a high score means "skip ahead to gaps and mocks."

---

## How to take it

- **Timebox: 45 minutes total.** Start a timer. When it rings, stop and score what you finished.
- **Do it on the lab**, not on paper. This is the standard course lab: a 3-node `kind` cluster.
  - Cluster/context: `kind-cka` (nodes: `cka-control-plane`, `cka-worker`, `cka-worker2`), Kubernetes **v1.36**, etcd **3.6**, CNI **kindnet**.
  - **kindnet does NOT enforce NetworkPolicy** — policy tasks are graded on the *manifest*, not on traffic actually being blocked.
- **Shell conventions** (assume these are set):
  ```text
  alias k=kubectl
  export do='--dry-run=client -o yaml'
  export now='--grace-period=0 --force'
  ```
- **Docs**: closed-book by default. The Kubernetes docs are allowed **only** on the two tasks marked `[docs OK]` (RBAC and NetworkPolicy) — mirroring where you'd realistically reach for docs in the real exam.
- **Order**: do them in any order. Each task is self-contained; where a task needs a broken object, the manifest to apply is inline.
- Work fast and imperfectly. Triage beats perfection — a partial cluster you can fix in 3 minutes tells you more than a perfect one you spent 10 on.

**Clean up between attempts** so a retake starts fresh:
```text
k delete pod puller probed db datauser --ignore-not-found
k delete deploy web api --ignore-not-found
k delete ns apps netpol --ignore-not-found
k delete pvc data --ignore-not-found
k delete ingress web --ignore-not-found
k delete crd widgets.demo.example.com --ignore-not-found
k label node cka-worker2 tier- 2>/dev/null; true
```

---

## The 15 tasks

Three per exam domain, tagged with domain and a time target. Domains are weighted the same way the real exam is (post-Feb-2025): **Troubleshooting 30% · Cluster Architecture 25% · Services & Networking 20% · Workloads & Scheduling 15% · Storage 10%.**

### Workloads & Scheduling (15%)

**W1 — Generator speed** · `[Workloads]` · target **2 min**
Imperatively (no editor): create a Deployment `web` using image `nginx:1.27` with 3 replicas, then scale it to 5. No YAML files.

**W2 — Rollout & rollback** · `[Workloads]` · target **3 min**
On Deployment `web`: update the image to `nginx:1.28`, watch the rollout complete, then roll it back to the previous revision.

**W3 — Scheduling constraint** · `[Scheduling]` · target **3 min**
Pin a pod to a specific node. Label `cka-worker2` with `tier=db`, then create pod `db` (image `nginx:1.27`) that is only schedulable on nodes with that label. Confirm it actually lands on `cka-worker2`.

### Troubleshooting (30%)

**T1 — Probe / logs troubleshoot** · `[Troubleshooting]` · target **3 min**
Apply the pod below. It stays `Running` but never becomes `Ready`. Use `describe`/`logs` to find why, then fix it so the pod reports `1/1 Ready`.
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: probed
  labels:
    app: probed
spec:
  containers:
  - name: web
    image: nginx:1.27
    ports:
    - containerPort: 80
    readinessProbe:
      httpGet:
        path: /
        port: 8080
      initialDelaySeconds: 2
      periodSeconds: 3
```

**T2 — Broken pod fix** · `[Troubleshooting]` · target **2 min**
Apply the pod below. It will not start. Diagnose the state and fix it so the pod reaches `Running`.
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: puller
spec:
  containers:
  - name: web
    image: nginx:1.27-doesnotexist
```

**T3 — Node / kubeconfig check** · `[Troubleshooting]` · target **2 min**
Confirm your kubeconfig points at context `kind-cka` and all 3 nodes are `Ready`. Then simulate and clear a scheduling block: cordon `cka-worker2`, verify it shows `SchedulingDisabled`, then uncordon it.

### Cluster Architecture (25%)

**C1 — RBAC grant** · `[Cluster Architecture]` · target **4 min** · `[docs OK]`
In a new namespace `apps`, create ServiceAccount `deployer`. Grant it (via a namespaced Role + RoleBinding) `get,list,watch` on pods and `get,list,create` on deployments. Verify with `kubectl auth can-i` that it **can** create deployments but **cannot** delete pods in `apps`.

**C2 — etcd snapshot recall** · `[Cluster Architecture]` · target **2 min**
Write the exact command to take an etcd snapshot to `/var/lib/etcd-snapshot.db` on the control-plane node, using the standard kubeadm cert paths, plus the command to verify the snapshot. (Recall — you don't have to run it if etcdctl isn't installed on the node.)

**C3 — CRD touch** · `[Cluster Architecture]` · target **4 min**
Extend the API: apply the CRD below, then create one custom resource of that kind and list it with `k get widgets`.
```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.demo.example.com
spec:
  group: demo.example.com
  scope: Namespaced
  names:
    plural: widgets
    singular: widget
    kind: Widget
    shortNames:
    - wg
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              size:
                type: string
```

### Services & Networking (20%)

**S1 — Service + endpoints fix** · `[Services & Networking]` · target **4 min**
Apply the Deployment + Service below. `k get endpoints api` shows `<none>` — the Service has no endpoints. Find and fix the cause so the Service routes to the 2 pods.
```yaml
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
      - name: web
        image: nginx:1.27
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: api
spec:
  selector:
    app: apid
  ports:
  - port: 80
    targetPort: 80
```

**S2 — NetworkPolicy** · `[Services & Networking]` · target **3 min** · `[docs OK]`
In a new namespace `netpol`, write a NetworkPolicy named `api-allow-frontend` that allows ingress to pods labeled `app=api` **only** from pods labeled `app=frontend` on TCP `80`, and denies all other ingress to those pods. (kindnet won't enforce it — you're graded on the manifest.)

**S3 — DNS + Ingress route** · `[Services & Networking]` · target **3 min**
Two quick steps: (a) from a throwaway pod, resolve the cluster DNS name of the `api` Service in the `default` namespace; (b) create an Ingress named `web` that routes host `cka.local`, path `/` (`Prefix`), to Service `api` on port `80`.

### Storage (10%)

**St1 — StorageClass** · `[Storage]` · target **2 min**
Identify the cluster's default StorageClass and report its **provisioner** and **volumeBindingMode**.

**St2 — PVC (bind behavior)** · `[Storage]` · target **2 min**
Create PVC `data`: `1Gi`, `ReadWriteOnce`, using the default StorageClass. Check its status and explain in one line why it is (or is not yet) `Bound`.

**St3 — Mount to bind** · `[Storage]` · target **3 min**
Create a pod `datauser` (image `nginx:1.27`) that mounts PVC `data` at `/data`. Confirm the pod reaches `Running` and PVC `data` is now `Bound`.

---

## How to score

**1 point per task fully correct within its time target**, using only the docs allowed for that task. Partial credit doesn't count — either the checkable outcome is met or it isn't. Max **15**.

| Score | What it means | Where to start |
|-------|---------------|----------------|
| **0–4** | You need the full ramp. | Start at `course/week-00-fundamentals/` and go module by module, in order, through `week-10`. Don't skip. |
| **5–9** | Foundations are forming but patchy. | Skim `course/week-00-fundamentals/`, then start at `course/week-01-architecture/`. Drill the specific domains you missed (see hints below). |
| **10–12** | You have the core. | Jump to your **weak domains** + `course/week-09-troubleshooting/`, then start `mock-exams/`. Use earlier modules only for gaps. |
| **13–15** | Exam-ready-ish. | Go straight to `mock-exams/` and `drills/speed-drills.md`. Touch modules only to patch specific misses. |

### Per-domain routing hint

Independent of total score, if you missed **2 or more tasks in a domain**, prioritize that domain's modules first:

| Missed 2+ in… | Prioritize |
|---------------|-----------|
| **Troubleshooting** (T1–T3) | `course/week-04-lifecycle-observability/` + `course/week-09-troubleshooting/` + `labs/breakfix/` |
| **Cluster Architecture** (C1–C3) | `course/week-01-architecture/` + `course/week-05-cluster-maintenance/` + `course/week-06-security-rbac/` |
| **Services & Networking** (S1–S3) | `course/week-08-networking/` |
| **Workloads & Scheduling** (W1–W3) | `course/week-02-workloads-config/` + `course/week-03-scheduling/` |
| **Storage** (St1–St3) | `course/week-07-storage/` |

Weight your effort by exam weight: a single Troubleshooting miss costs more real points than a single Storage miss.

---

## Answer key — what "correct" looks like

Self-check each task against this. One to three lines each; commands assume the aliases above.

**W1** — `k create deploy web --image=nginx:1.27 --replicas=3` then `k scale deploy web --replicas=5`. Check: `k get deploy web` → `5/5`.

**W2** — `k set image deploy/web nginx=nginx:1.28` → `k rollout status deploy/web` → `k rollout undo deploy/web`. Check: `k rollout history deploy/web` and image back to `nginx:1.27`. (Container name is `nginx`, the image basename.)

**W3** — `k label node cka-worker2 tier=db`, then a pod with `spec.nodeSelector: {tier: db}`. Check: `k get pod db -o wide` → `NODE` is `cka-worker2`.
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: db
spec:
  nodeSelector:
    tier: db
  containers:
  - name: db
    image: nginx:1.27
```

**T1** — Readiness probe hits port `8080`; nginx listens on `80`. `k describe pod probed` shows `Readiness probe failed: connection refused`. Fix: set the probe `port` to `80` (edit or recreate). Check: `k get pod probed` → `1/1`.

**T2** — `ImagePullBackOff`/`ErrImagePull` (`k get pod puller`); the tag `nginx:1.27-doesnotexist` doesn't exist. Fix: set image to a real tag, e.g. `k set image pod/puller web=nginx:1.27` (or delete + recreate). Check: `Running`.

**T3** — `k config current-context` → `kind-cka`; `k get nodes` → 3× `Ready`. `k cordon cka-worker2` → status shows `Ready,SchedulingDisabled`; `k uncordon cka-worker2` clears it.

**C1** — SA + Role (verbs `get,list,watch` on `pods`; `get,list,create` on `deployments` in `apps` group) + RoleBinding in `apps`. Check: `k auth can-i create deployments --as=system:serviceaccount:apps:deployer -n apps` → `yes`; `... delete pods ...` → `no`.
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployer
  namespace: apps
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: deployer
  namespace: apps
subjects:
- kind: ServiceAccount
  name: deployer
  namespace: apps
roleRef:
  kind: Role
  name: deployer
  apiGroup: rbac.authorization.k8s.io
```

**C2** — Run on the control-plane node (`docker exec -it cka-control-plane bash`). etcd 3.6 defaults to API v3, so `ETCDCTL_API=3` is optional but harmless:
```text
etcdctl snapshot save /var/lib/etcd-snapshot.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

etcdctl --write-out=table snapshot status /var/lib/etcd-snapshot.db
```

**C3** — Apply the CRD, then a CR of kind `Widget`. Check: `k get widgets` (or `k get wg`) lists `w1`.
```yaml
apiVersion: demo.example.com/v1
kind: Widget
metadata:
  name: w1
spec:
  size: large
```

**S1** — Service selector `app: apid` doesn't match pod label `app: api` → no endpoints. Fix: change the Service selector to `app: api` (`k edit svc api`). Check: `k get endpoints api` shows 2 IPs.

**S2** — Correct manifest: `podSelector` on `app=api`, `policyTypes: [Ingress]`, one ingress rule `from` a `podSelector` `app=frontend` on TCP `80`. An empty `ingress` (or omitting the allow) would deny all; naming the frontend source is what makes it selective.
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-allow-frontend
  namespace: netpol
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 80
```

**S3** — (a) `k run bb --image=busybox:1.36 --restart=Never --rm -it -- nslookup api.default.svc.cluster.local` resolves to the Service ClusterIP. (b) Ingress routes `cka.local` `/` → `api:80`:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
spec:
  rules:
  - host: cka.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: api
            port:
              number: 80
```

**St1** — `k get storageclass`. On kind the default is `standard`, provisioner `rancher.io/local-path`, `volumeBindingMode: WaitForFirstConsumer`.

**St2** — PVC below. Check: `k get pvc data` → `Pending`. Reason (the point of the task): with `WaitForFirstConsumer`, binding is deferred until a pod actually mounts the claim — so `Pending` here is *correct*, not broken.
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: standard
  resources:
    requests:
      storage: 1Gi
```

**St3** — Pod below mounts the claim, triggering the bind. Check: `k get pod datauser` → `Running`, and `k get pvc data` → `Bound`.
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: datauser
spec:
  containers:
  - name: c
    image: nginx:1.27
    volumeMounts:
    - name: d
      mountPath: /data
  volumes:
  - name: d
    persistentVolumeClaim:
      claimName: data
```

---

## Retake it

After you finish the modules your score routed you to, **run this diagnostic again cold** (clean up first, timer on). Treat **13+/15 inside 45 minutes, closed-book except the two `[docs OK]` tasks** as your green light for `mock-exams/`. If you're not there yet, the per-domain hint above tells you exactly which week to revisit before trying again.
