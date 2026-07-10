# Week 1 Masterclass — Cluster Architecture & Core Concepts (feeds Cluster Architecture 25%, Troubleshooting 30%, Workloads & Scheduling 15%)

Week 1 is the load-bearing wall of the exam. Every troubleshooting question (30% of the score) is really "which stage of the `kubectl apply → running pod` pipeline broke?" Every other question rides on kubectl fluency and kubeconfig discipline. Master the pipeline and the components; the rest of the course is applications of this model.

Version note: written against v1.31+ behavior and kept version-agnostic where possible; check the current exam version on the CNCF curriculum page (github.com/cncf/curriculum) before exam day.

## What the exam actually asks

| Week-1 topic | Exam domain (weight) | How it shows up |
|---|---|---|
| Control-plane internals, static pods | Troubleshooting (30%), Cluster Architecture (25%) | "API server is down, fix it"; "new pods stay Pending"; read a flag from a manifest in `/etc/kubernetes/manifests` |
| kubectl fluency, jsonpath, sort-by | All domains | Every task; also explicit "write X sorted by Y to file Z" tasks |
| kubeconfig contexts | All domains | Every question starts with `kubectl config use-context ...`; occasional context-creation tasks |
| Pod lifecycle, multi-container, init/sidecar | Workloads & Scheduling (15%) | "Add a sidecar that tails the app log"; "prepare X before the main container starts" |
| Deployments: scale, rollout, rollback | Workloads & Scheduling (15%) | Timed rollout/rollback; broken-rollout diagnosis |
| Namespaces, scoping | All domains | `-n` discipline; "which resources are not namespaced" discovery |
| CRDs and operators | Cluster Architecture (25%) | "List the CRDs of operator X"; create/edit a custom resource; find the controller's logs |
| kubelet, containerd, crictl | Troubleshooting (30%) | "Node NotReady, fix it"; inspect containers when kubectl can't |

Exam environment reality: PSI Bridge remote desktop (XFCE + Firefox), one allowed tab on kubernetes.io/docs + kubernetes.io/blog + helm.sh/docs. Terminal paste is Ctrl+Shift+V. The `k` / `$do` / `$now` conventions used below are what you should set up in the first 60 seconds of the exam.

---

## The life of `kubectl apply` — from keystroke to running pod

The single most valuable mental model on the exam. Every troubleshooting task is "the pipeline stopped at stage N — find N." Learn the stages and their failure signatures.

### Stage 0 — client side

1. kubectl resolves its kubeconfig: `--kubeconfig` flag beats `$KUBECONFIG` (colon-separated list, merged) beats `~/.kube/config`.
2. `current-context` selects a context; the context names a **cluster** (server URL + CA bundle), a **user** (client cert, token, or exec plugin), and optionally a default **namespace**.
3. Your YAML is parsed and **field-validated**. Since v1.27 validation is server-side and strict by default (`--validate=strict`), so a typo like `replica:` is rejected by the API server instead of silently dropped (version-dependent: older clusters validated client-side against a cached OpenAPI schema).
4. For `apply` (client-side, the default): kubectl computes a three-way merge between your file, the live object, and the `kubectl.kubernetes.io/last-applied-configuration` annotation, then sends a PATCH. `--server-side` delegates merging to the API server via managedFields. `create` is a plain POST.

Failure signatures here: `connection refused` (API server down or wrong server URL), `x509: certificate signed by unknown authority` (wrong CA — wrong cluster entry), `error validating data` (schema typo), `Unable to connect to the server: dial tcp: lookup ...` (garbage server hostname).

### Stage 1 — API server: authn → authz → admission

The request hits kube-apiserver on 6443 and passes, in order:

1. **Authentication** — client certificate (CN = username, O = groups), bearer/ServiceAccount token, or OIDC. Fails → `401 Unauthorized`.
2. **Authorization** — the union of configured authorizers (Node + RBAC on kubeadm). Any authorizer saying yes suffices. Fails → `403 Forbidden`; the message names user, verb, resource, namespace — that's the whole diagnosis, read it.
3. **Mutating admission** — plugins that *change* the object: `ServiceAccount` injects `serviceAccountName: default` plus the token projection, `LimitRanger` injects default resources, API defaulting fills unset fields (`restartPolicy: Always`, `terminationGracePeriodSeconds: 30`, `dnsPolicy: ClusterFirst`). This is why the object you read back is far bigger than the one you wrote.
4. **Schema validation** against the OpenAPI schema.
5. **Validating admission** — accept/reject only: `ResourceQuota`, `NamespaceLifecycle` (refuses creates in a Terminating namespace), validating webhooks and ValidatingAdmissionPolicy. A hung validating webhook is the classic "every create times out" failure.

### Stage 2 — etcd write

The API server is **the only component that talks to etcd**. The object is serialized (protobuf) and written under `/registry/pods/<namespace>/<name>`. The write commits through raft — it needs a quorum of etcd members. The etcd revision becomes the object's `resourceVersion`, the currency of optimistic concurrency and watches. Only after the commit does kubectl get its `201 Created`. At this instant the pod *exists* but nothing runs anywhere: `apply` returning success means **stored**, not **running**.

### Stage 3 — watch fan-out

Every controller and the scheduler run **informers**: one LIST to warm a local cache, then a long-lived WATCH from that resourceVersion. The API server pushes the new-pod event to all watchers from its watch cache. Nothing polls — that's why the pipeline is normally sub-second, and why a wedged API server freezes every controller simultaneously.

### Stage 4 — scheduler: filter → score → bind

kube-scheduler watches for pods with empty `spec.nodeName`. For each pod:

1. **Filter** — drop infeasible nodes: insufficient CPU/memory *requests* (`NodeResourcesFit`), taints without tolerations, nodeSelector/affinity mismatch, `unschedulable: true`, port conflicts, volume topology.
2. **Score** — rank survivors (resource balance, image locality, topology spread); pick the winner.
3. **Bind** — POST to the pod's `binding` subresource, which sets `spec.nodeName`. That is the scheduler's entire output. It never talks to a kubelet, never pulls an image, never starts anything.

Failure signatures: pod `Pending` with **empty** nodeName and a `FailedScheduling` event (filters killed all nodes — the event itemizes reasons per node) — or empty nodeName and **no event at all** (the scheduler itself is dead).

### Stage 5 — kubelet sync loop

The kubelet on the bound node watches for pods with `spec.nodeName` equal to its node name. Its sync loop:

1. Creates the **pod sandbox** via CRI (gRPC to containerd on `/run/containerd/containerd.sock`): a `pause` container that owns the pod's network namespace.
2. Invokes the **CNI plugin** (`ADD`) to attach the sandbox to the pod network and assign the pod IP. On kind the CNI is kindnet; config lives in `/etc/cni/net.d/`.
3. Runs **init containers** sequentially, each to completion, in order.
4. Starts app containers: image pull per `imagePullPolicy` (`Always` for `:latest`/untagged images, else `IfNotPresent`), create/start, postStart hooks, probes begin.

Failure signatures: `Pending`/`ContainerCreating` **with** nodeName set = kubelet/runtime/CNI/volume territory, not the scheduler. `ImagePullBackOff` = registry/name/tag/pull-secret. `CrashLoopBackOff` = container starts then exits — read `k logs --previous`.

### Stage 6 — status writeback

The kubelet is the source of truth for pod status. It PATCHes `status` back to the API server (persisted to etcd): phase, conditions, containerStatuses, podIP. When a node dies, its pods' status **freezes** — the pods aren't confirmed Running; the reporter is dead. The node lifecycle controller (in kube-controller-manager) notices stale node Leases (`kube-node-lease` namespace), marks the node NotReady, and the API-server-side eviction machinery kicks in after the default 5-minute `node.kubernetes.io/not-ready` toleration.

Memorize the triage split:

| Observation | Broken stage |
|---|---|
| kubectl errors (401/403/refused/x509) | client → API server |
| Object exists, nothing reacts (no RS from a Deployment) | controller-manager |
| Pending, nodeName empty | scheduler (dead if no events; constraints if FailedScheduling) |
| Pending/ContainerCreating, nodeName set | kubelet / runtime / CNI / volumes on that node |
| Running but not Ready / crash-looping | app, probes, config |

---

## Control plane, component by component

On kubeadm clusters — and kind is kubeadm inside Docker containers — every control-plane component except the kubelet runs as a **static pod** from `/etc/kubernetes/manifests/`:

```bash
docker exec cka-control-plane ls /etc/kubernetes/manifests
# etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml
```

Exam flavor: on the real exam you `ssh cluster1-controlplane1` then `sudo -i`; on kind the equivalent door is `docker exec -it cka-control-plane bash`. Same paths behind both doors.

| Component | Job | When it's down: breaks | When it's down: survives | Port |
|---|---|---|---|---|
| kube-apiserver | Stateless front door; sole etcd client; authn/authz/admission; serves watches | All kubectl, all controllers, kubelet status updates, scheduling — the entire control plane | Running containers; kube-proxy rules keep routing; kubelet restarts crashed containers per restartPolicy; static pods | 6443 |
| etcd | Raft KV store; all cluster state under `/registry/` | API server errors/timeouts on writes and most reads — blast radius ≈ apiserver down | Data plane, same as above | 2379 client, 2380 peer |
| kube-scheduler | Assigns `nodeName` to pending pods | New pods pile up Pending: no nodeName, no FailedScheduling events | Everything already scheduled | 10259 |
| kube-controller-manager | ~40 loops: Deployment→RS, RS→Pods, node lifecycle, EndpointSlice, namespace GC, ServiceAccount, PV binder, Job/CronJob | `k create deploy` yields a Deployment but **no RS, no pods**; scaling ignored; namespaces stuck Terminating; new pods never join Service endpoints; node failure never evicts | Existing pods and endpoints | 10257 |
| cloud-controller-manager | Cloud loops: node addresses/lifecycle via cloud API, LoadBalancers, routes | `type: LoadBalancer` stuck `<pending>`; new cloud nodes not initialized | Everything else | 10258 |

kind has no cloud, hence no CCM. Know the theory anyway: kubeadm split cloud logic out of KCM so on-prem clusters don't carry dead weight; symptoms above are the exam-relevant part.

### Static pods — the mechanic behind every "fix the control plane" task

The kubelet watches a directory — `staticPodPath` in `/var/lib/kubelet/config.yaml`, value `/etc/kubernetes/manifests` — and runs whatever pod manifests appear there, **with no API server involved**. It then registers read-only **mirror pods** upstream so they're visible: mirror names get the node name suffixed, e.g. `kube-apiserver-cka-control-plane`.

Consequences you will be tested on:

- `k delete pod kube-scheduler-cka-control-plane -n kube-system` achieves nothing durable — the mirror pod reappears. To actually stop a static pod, **move its manifest out of the directory**; the kubelet stops it within seconds. Move it back to restore.
- A typo in a static pod manifest = the pod silently never comes up, and if it's the API server, `kubectl` is dead too. Diagnose on the node: `crictl ps -a`, `journalctl -u kubelet | tail -50`, `/var/log/pods/kube-system_<pod>_<uid>/`.
- Editing `/etc/kubernetes/manifests/kube-apiserver.yaml` and saving IS the restart procedure: the kubelet sees the change, kills and recreates the pod. Expect 20–60s of API downtime; watch it return with `crictl ps | grep apiserver`.

Trimmed real manifest shape — know that the flags live in `spec.containers[0].command`, because "read/fix a flag" tasks are common:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-scheduler
  namespace: kube-system
spec:
  hostNetwork: true
  priorityClassName: system-node-critical
  containers:
    - name: kube-scheduler
      image: registry.k8s.io/kube-scheduler:v1.33.1   # tracks cluster version
      command:
        - kube-scheduler
        - --authentication-kubeconfig=/etc/kubernetes/scheduler.conf
        - --authorization-kubeconfig=/etc/kubernetes/scheduler.conf
        - --kubeconfig=/etc/kubernetes/scheduler.conf
        - --leader-elect=true
      volumeMounts:
        - name: kubeconfig
          mountPath: /etc/kubernetes/scheduler.conf
          readOnly: true
  volumes:
    - name: kubeconfig
      hostPath:
        path: /etc/kubernetes/scheduler.conf
        type: FileOrCreate
```

### etcd specifics to cache now (week 5 does backup/restore)

- Data dir `/var/lib/etcd` on the node, hostPath-mounted into the etcd pod.
- Quorum: N members tolerate (N−1)/2 failures; kind's single member tolerates zero — production runs 3 or 5.
- All etcdctl calls need the TLS trio; the paths are readable straight out of `/etc/kubernetes/manifests/etcd.yaml` (`--cert-file`, `--key-file`, `--trusted-ca-file`). Practice grepping that file, not memorizing paths.
- API server health without guesswork: `k get --raw /readyz?verbose` itemizes ~50 checks including etcd connectivity.

### Where component identities live

kubeadm drops one kubeconfig per client under `/etc/kubernetes/`: `admin.conf` (root kubectl on the node), `kubelet.conf`, `controller-manager.conf`, `scheduler.conf`, plus `super-admin.conf` (RBAC-bypassing, v1.29+). PKI under `/etc/kubernetes/pki/`. Scheduler and KCM do leader election through Lease objects — `k get lease -n kube-system` shows the active holder; useful in HA setups.

`kubectl get componentstatuses` is deprecated and lies; use static pod state and `/readyz` instead.

---

## Node components

### kubelet

The only cluster component running as a **systemd service** rather than a pod — something must exist before pods can. Its file layout is a standing troubleshooting question:

| What | Where (kubeadm/kind) |
|---|---|
| KubeletConfiguration | `/var/lib/kubelet/config.yaml` — `staticPodPath`, `clusterDNS`, `cgroupDriver`, eviction thresholds |
| Kubeconfig to reach the API | `/etc/kubernetes/kubelet.conf` |
| kubeadm-injected flags | `/var/lib/kubelet/kubeadm-flags.env` |
| systemd drop-in | `/etc/systemd/system/kubelet.service.d/10-kubeadm.conf` |
| Logs | `journalctl -u kubelet` (`-f`, `--no-pager`) |
| Restart | `systemctl restart kubelet`; verify `systemctl status kubelet` |

Node NotReady triage order: `systemctl status kubelet` → `journalctl -u kubelet | tail -50` → `systemctl status containerd` → does `kubelet.conf` point at the right API server → certs expired?

### kube-proxy

A DaemonSet in `kube-system`. Watches Services and EndpointSlices and programs **iptables** DNAT rules (default mode; ipvs exists, and nftables became a stable option in v1.31 — version-dependent) translating ClusterIPs to backend pod IPs. Key exam insight: kube-proxy down means **existing rules keep forwarding** — only changes (new Services, moved endpoints) stop propagating on that node. Service networking goes stale, not dark.

### containerd + crictl

The CRI runtime: kubelet → gRPC → containerd → runc. When the API server is unreachable, or you need node-level ground truth, `crictl` is kubectl-for-one-node. kind nodes ship it preconfigured (`/etc/crictl.yaml` → containerd socket):

```bash
crictl ps                          # running containers; -a includes exited
crictl ps --name kube-apiserver    # filter by name
crictl pods                        # sandboxes
crictl logs 3f2a1b0c4d5e           # logs straight from the runtime
crictl inspect 3f2a1b0c4d5e        # full status incl. logPath
crictl images
crictl exec -it 3f2a1b0c4d5e sh
```

Container logs on disk — what `kubectl logs` serves via the kubelet: `/var/log/pods/<ns>_<pod>_<uid>/<container>/0.log`, symlinked from `/var/log/containers/`. When kubectl is dead, the logs are not.

---

## API machinery: groups, versions, discovery

Every resource belongs to a **group/version**. The core group has the empty name and is served at `/api/v1` (pods, services, nodes, namespaces, configmaps, secrets); named groups live at `/apis/<group>/<version>`: `apps/v1`, `batch/v1`, `networking.k8s.io/v1`, `rbac.authorization.k8s.io/v1`, `storage.k8s.io/v1`, `gateway.networking.k8s.io/v1`, `autoscaling/v2`, `certificates.k8s.io/v1`. The `apiVersion:` field is exactly `<group>/<version>`, or bare `v1` for core.

Two commands replace half the documentation during the exam:

```bash
k api-resources                       # every kind: SHORTNAMES, APIVERSION, NAMESPACED, KIND
k api-resources --namespaced=false    # the cluster-scoped set
k api-resources --api-group=apps
k api-versions                        # served group/versions
```

And the biggest single superpower — the schema without leaving the terminal:

```bash
k explain pod.spec.containers.livenessProbe        # field docs + types
k explain deploy.spec.strategy --recursive         # whole subtree, correct nesting
k explain pod --recursive | grep -B2 -A6 tolerations   # find where a field lives
k explain hpa --api-version=autoscaling/v2 --recursive # pin a version when several are served
```

`--recursive` output is literally a YAML skeleton with types — faster than searching kubernetes.io when you only forgot field names or nesting. It reads the server's OpenAPI, so it also works for CRDs that publish a structural schema.

---

## kubeconfig anatomy and multi-context fluency

A kubeconfig is three lists plus one pointer; everything else is composition:

```yaml
apiVersion: v1
kind: Config
current-context: kind-cka
clusters:
  - name: kind-cka
    cluster:
      server: https://127.0.0.1:6443
      certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t   # base64 CA bundle, truncated
users:
  - name: kind-cka
    user:
      client-certificate-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t      # base64 client cert, truncated
      client-key-data: LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0t              # base64 key, truncated
contexts:
  - name: kind-cka
    context:
      cluster: kind-cka
      user: kind-cka
      namespace: default
```

- **cluster** = where (server URL) + trust (CA). **user** = who (cert/token/exec plugin). **context** = cluster + user + default namespace. `current-context` = the pointer.
- The exam hands you one kubeconfig with several contexts. **Every question header names its context. Run the use-context line. Every time.** Solving on the wrong cluster scores zero and may sabotage another question.

Fluency set:

```bash
k config get-contexts                                  # '*' marks current
k config use-context kind-cka
k config current-context
k config set-context --current --namespace=team-a      # default ns for the active context
k config view --minify                                 # only the active context's slice
k config view --raw                                    # include certificate data
k config set-context dev --cluster=kind-cka --user=kind-cka --namespace=dev   # compose a new context
KUBECONFIG=/tmp/a:/tmp/b kubectl config view --flatten > /tmp/merged          # merge files, exam-legal
```

---

## Namespaces — what is and is not namespaced

Namespaces scope names, RBAC, ResourceQuotas, LimitRanges and NetworkPolicies. They are not by themselves a security boundary, and they never contain nodes.

Cluster-scoped (get the authoritative list from `k api-resources --namespaced=false`): nodes, persistentvolumes, storageclasses, namespaces themselves, clusterroles, clusterrolebindings, customresourcedefinitions, ingressclasses, priorityclasses, runtimeclasses, apiservices. Namespaced: pods, deployments, services, configmaps, secrets, PVCs, roles, rolebindings, networkpolicies, serviceaccounts, and most CRs (per each CRD's `scope`).

- Built-ins: `default`, `kube-system` (control plane), `kube-public` (readable unauthenticated; cluster-info ConfigMap), `kube-node-lease` (node heartbeat Leases).
- DNS encodes the namespace: `<svc>.<ns>.svc.cluster.local`. Bare `<svc>` resolves only from the same namespace; cross-namespace needs `<svc>.<ns>` at minimum.
- Namespace deletion is asynchronous and cascades to everything inside. Stuck `Terminating` = a finalizer can't complete — usually a dead webhook or an operator uninstalled before its CRs. `k get ns <name> -o yaml` shows which condition is pending.
- `k get all` is a lie of omission: a curated subset only — no secrets, configmaps, ingresses, PVCs, roles, or custom resources. Audit explicitly: `k api-resources --verbs=list --namespaced -o name` and loop.

---

## Pod lifecycle: phases vs conditions vs container states

Three different state machines. Conflating them costs minutes.

**Phase** (`status.phase`) — coarse, exactly five values: `Pending` (accepted but not all containers running — covers unscheduled AND image-pulling AND init-running), `Running`, `Succeeded`, `Failed`, `Unknown` (node stopped reporting). **CrashLoopBackOff is not a phase** — a crash-looping pod usually shows phase `Running`.

**Conditions** (`status.conditions`) — timestamped booleans: `PodScheduled`, `Initialized` (init containers finished), `ContainersReady`, `Ready`. `Ready` gates Service endpoints: a pod failing readiness is Running, `0/1 READY`, and receives zero traffic.

**Container states** — per container: `Waiting` (reason: `ContainerCreating`, `ImagePullBackOff`, `CrashLoopBackOff`), `Running`, `Terminated` (exitCode + reason: `Completed`, `Error`, `OOMKilled`).

`restartPolicy` — pod-level, applies to all app containers: `Always` (default; the only value Deployments accept), `OnFailure` (restart on nonzero exit — Jobs), `Never`. Restarts back off exponentially 10s → 20s → ... capped at 5m, reset after 10 minutes of clean running — that's the BackOff in CrashLoopBackOff.

Termination: delete → Terminating, endpoint removal → preStop hook + SIGTERM → up to `terminationGracePeriodSeconds` (default 30) → SIGKILL. `$now` (`--grace-period=0 --force`) skips the wait and removes the API object immediately — exam standard for throwaway pods, reckless for stateful ones.

---

## Multi-container pods: init containers, native sidecars, shared fate

All containers in a pod share the **network namespace** (one IP; containers reach each other on `localhost`; ports must not collide), the IPC namespace, and any **volumes** they each mount — `emptyDir` is the standard glue. They do NOT share filesystems or PID namespaces by default (`shareProcessNamespace: true` opts in).

**Init containers** (`spec.initContainers`): run **sequentially**, each to completion, before app containers start. Use for wait-for-dependency, fetch/render config into a shared volume, permissions setup. Failure semantics: with restartPolicy `Always`/`OnFailure`, a failing init container retries with backoff (`Init:CrashLoopBackOff`); with `Never`, one init failure fails the pod permanently. Init containers that succeeded are never re-run when an app container crashes — only pod recreation reruns them.

**Native sidecars** — the curriculum-current pattern: an `initContainers` entry with `restartPolicy: Always`. Version line: beta and on-by-default in v1.29, stable in v1.33. Semantics: starts before app containers (in init order), does **not** block start of the next container on completion (only on its startupProbe, if defined), keeps running alongside the app, restarts independently, and is terminated **after** app containers on shutdown. This fixed both classic sidecar bugs: Jobs that never complete because a sidecar keeps running, and log shippers killed before the app during termination.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-with-sidecar
spec:
  volumes:
    - name: applogs
      emptyDir: {}
  initContainers:
    - name: log-shipper            # native sidecar = initContainer + restartPolicy Always
      image: busybox:1.36
      restartPolicy: Always
      command: ["sh", "-c", "tail -F /var/log/app/app.log"]
      volumeMounts:
        - name: applogs
          mountPath: /var/log/app
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "while true; do date >> /var/log/app/app.log; sleep 2; done"]
      volumeMounts:
        - name: applogs
          mountPath: /var/log/app
```

Multi-container reflexes: `k logs app-with-sidecar -c log-shipper`, `k exec app-with-sidecar -c app -- ls /var/log/app`, `k describe pod` separates Init Containers from Containers. A READY column of `1/2` says one container isn't ready; `describe` says which and why.

---

## ReplicaSet vs Deployment mechanics

A **ReplicaSet** runs one dumb loop: count pods matching `spec.selector`, diff against `spec.replicas`, create or delete. It identifies "its" pods purely by label match plus ownerReference adoption. Two exam-relevant consequences:

- A bare pod created with labels matching an RS selector gets **adopted** (ownerReference stamped) and counted; the RS is now over quota and kills one pod — usually the newest, not-yet-ready one: yours. Symptom: "my debug pod keeps vanishing."
- Removing a label from an RS-owned pod **orphans** it: the RS spawns a replacement, and the unlabeled pod keeps running unmanaged — a legitimate quarantine-for-debugging trick.

A **Deployment** manages ReplicaSets, one per pod-template version. It hashes the template into the `pod-template-hash` label, injected into each RS's selector and pods. A rollout = create the new RS and scale it up while the old scales down, governed by `strategy.rollingUpdate.maxSurge` / `maxUnavailable` (both default 25%). Old RSes stay at 0 replicas as rollback material (`revisionHistoryLimit`, default 10). **Rollback is re-activating an old RS's template** — `rollout undo` copies it back into the Deployment; revision numbers move forward, never backward (undo from rev 2 to rev 1 creates rev 3 ≡ rev 1).

```bash
k create deploy web --image=nginx:1.27 --replicas=3
k set image deploy/web nginx=nginx:1.29      # container name from create deploy = image basename
k rollout status deploy/web
k rollout history deploy/web                 # add --revision=2 for that template
k rollout undo deploy/web                    # previous revision
k rollout undo deploy/web --to-revision=1
k rollout restart deploy/web                 # bumps a template annotation -> new RS -> rolling replace
```

**Selector immutability trap**: in apps/v1, `spec.selector` of Deployments, ReplicaSets, DaemonSets and StatefulSets is **immutable**. Attempting to change it:

```text
The Deployment "web" is invalid: spec.selector: Invalid value:
v1.LabelSelector{...}: field is immutable
```

Exam-speed fix: `k replace --force -f web.yaml` (delete + recreate in one step — expect pod replacement), or explicit delete then apply. Related admission rule: `template.metadata.labels` must satisfy `selector.matchLabels` or the object is rejected outright. Immutability exists to prevent silent mass-orphaning of pods.

Know which operations create a revision (any template change: image, env, template labels) and which don't (`k scale`, pause/resume) — `scale` edits only `spec.replicas`: no new RS, no rollout, no history entry.

---

## CRDs and operators (curriculum item since Feb 2025)

A **CustomResourceDefinition** teaches the API server a new REST endpoint — nothing more. Apply a CRD and the server starts serving `/apis/<group>/<version>/.../<plural>`, storing instances in etcd like built-ins. No new binary runs. kubectl works against custom resources immediately: get, describe, apply, edit, jsonpath, and `k explain` if the CRD publishes a structural schema (mandatory in `apiextensions.k8s.io/v1`).

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: backups.ops.example.com      # must equal <plural>.<group>
spec:
  group: ops.example.com
  scope: Namespaced                  # or Cluster
  names:
    plural: backups
    singular: backup
    kind: Backup
    shortNames: [bkp]
  versions:
    - name: v1
      served: true                   # this version answers API calls
      storage: true                  # exactly one version is the etcd storage format
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                target: {type: string}
                schedule: {type: string}
```

Exam-level operations — this is nearly the whole testable surface:

```bash
k get crds                                   # CRDs are cluster-scoped
k get crds | grep -i backup                  # find an operator's CRDs
k api-resources | grep ops.example.com       # shortnames + scope + kind
k explain backup.spec                        # CR schema
k get backups -A                             # plural, singular, or shortname all work
k get backups.ops.example.com                # fully-qualified form when names collide
k describe crd backups.ops.example.com       # versions, scope, printer columns
k edit backup nightly-etcd                   # CRs edit like anything else
```

An **operator** = CRDs + a controller (typically a Deployment) that watches those CRs and reconciles reality toward `spec`, reporting into `status`. A CRD without its operator is a table with no application: you can create CRs forever and nothing happens. Troubleshooting chain for "my CR does nothing": CRD exists? → CR exists? → operator pod running? → `k logs deploy/<operator> -n <ns>` → CR's `status` and events. Two classic failure modes: deleting a CRD deletes **all its CRs**; uninstalling an operator while CRs still carry finalizers wedges namespace deletion forever.

The exam expects you to *interact* with operator-managed resources (find CRDs, create a CR from a docs example, read status) — not author CRDs from scratch.

---

## Traps

Each one: the wrong assumption → the correction.

1. **"`kubectl run` creates a Deployment."** → Since v1.18 it creates a bare Pod. Deployments come from `k create deploy`. Bare pods don't survive node failure and can't scale.
2. **"I can edit a Deployment's selector."** → Immutable in apps/v1. `k replace --force -f file.yaml`, and budget for the pods being replaced.
3. **"I deleted the mirror pod, so the static pod is gone."** → Kubelet recreates it in seconds. Static pods die only when the manifest leaves `staticPodPath`.
4. **"Phase Running means it works."** → `Ready` is a condition, not a phase. A pod failing readiness is Running, `0/1`, and out of every Service. Read the READY column.
5. **"I'll grep jsonpath for phase CrashLoopBackOff."** → It's a container *waiting reason* at `.status.containerStatuses[].state.waiting.reason`, not `.status.phase`.
6. **"`--dry-run=client` validated my manifest."** → Structure only; no admission, quota, or RBAC. `--dry-run=server` runs the full API path without persisting.
7. **"restartPolicy: OnFailure in my Deployment."** → Deployments accept only `Always`; the API rejects anything else. Run-to-completion = Job.
8. **"Pending means scheduler problem."** → Only with empty nodeName. `k get po -o wide` first: nodeName set + Pending/ContainerCreating = kubelet/CNI/volume on that node.
9. **"Namespace deletion is just slow."** → Finalizers. `k get ns <name> -o yaml`, read `status.conditions` — usually a dead webhook or orphaned operator CRs.
10. **"Init containers rerun when the app container crashes."** → They don't; only pod recreation reruns them. Exception: native sidecars (`restartPolicy: Always`) restart independently.
11. **"I'll just answer on whatever cluster is active."** → Zero points, and you may have broken a different question's cluster. Run the question's `use-context` line, verify with `k config current-context`.
12. **"`k get all` showed nothing, namespace is clean."** → `all` omits secrets, configmaps, ingresses, PVCs, roles, CRs. Enumerate explicitly.
13. **"My kind muscle memory maps 1:1 to the exam."** → Exam nodes are kubeadm VMs reached by `ssh` + `sudo -i`; kind nodes are containers reached by `docker exec`. Same file paths, same static pods, same crictl — different door.

---

## Speed patterns

Fastest exam-legal route per common task. Assumes `alias k=kubectl`, `export do="--dry-run=client -o yaml"`, `export now="--grace-period=0 --force"`.

| Task | Pattern |
|---|---|
| Pod YAML skeleton | `k run web --image=nginx:1.27 $do > pod.yaml` |
| Pod + port/labels/env | `k run web --image=nginx:1.27 --port=80 -l tier=web --env=MODE=prod $do` |
| Pod with command | `k run bb --image=busybox:1.36 $do -- sh -c "sleep 3600"` |
| Deployment skeleton | `k create deploy web --image=nginx:1.27 --replicas=3 $do > d.yaml` |
| ns / sa / cm / secret | `k create ns team-a` · `k create sa app` · `k create cm cfg --from-literal=k=v` |
| Scale | `k scale deploy web --replicas=5` |
| New image (rollout) | `k set image deploy/web nginx=nginx:1.29` |
| Watch rollout | `k rollout status deploy/web` |
| Rollback | `k rollout undo deploy/web --to-revision=1` |
| Throwaway curl pod | `k run tmp --image=busybox:1.36 --rm -it --restart=Never -- wget -qO- http://web` |
| Fast delete | `k delete pod tmp $now` |
| Default ns for context | `k config set-context --current --namespace=team-a` |
| Field path lookup | `k explain deploy.spec.strategy --recursive` |
| Shortname/scope lookup | `k api-resources \| grep -i netpol` |
| Sort anything | `k get po -A --sort-by=.metadata.creationTimestamp` |
| One field out | `k get deploy web -o jsonpath='{.spec.template.spec.containers[0].image}'` |
| Design your own table | `k get po -o custom-columns=NAME:.metadata.name,IP:.status.podIP,NODE:.spec.nodeName` |
| Events, newest last | `k get events --sort-by=.lastTimestamp` |
| Immutable-field error | `k replace --force -f file.yaml` |
| Post-defaulting truth | `k get po web -o yaml` |
| Multi-container build | Generate one container with `$do`, hand-add the second + volumes — never write the skeleton by hand |

Muscle-memory rule: **generate the outer skeleton, always.** Hand-writing `apiVersion/kind/metadata` wastes 30 seconds and invites typos; `$do` output is always syntactically perfect.

---

## Docs map

What you need → path under `kubernetes.io/docs/` (allowed in the exam browser tab).

| Need | Path |
|---|---|
| Components overview | `concepts/overview/components/` |
| kubectl quick reference | `reference/kubectl/quick-reference/` |
| Pod lifecycle, phases, conditions | `concepts/workloads/pods/pod-lifecycle/` |
| Init containers | `concepts/workloads/pods/init-containers/` |
| Native sidecars | `concepts/workloads/pods/sidecar-containers/` |
| Deployments (rollout/rollback YAML) | `concepts/workloads/controllers/deployment/` |
| ReplicaSet semantics | `concepts/workloads/controllers/replicaset/` |
| Namespaces | `concepts/overview/working-with-objects/namespaces/` |
| kubeconfig structure | `concepts/configuration/organize-cluster-access-kubeconfig/` |
| Multiple clusters / contexts how-to | `tasks/access-application-cluster/configure-access-multiple-clusters/` |
| JSONPath syntax | `reference/kubectl/jsonpath/` |
| Static pods | `tasks/configure-pod-container/static-pod/` |
| crictl debugging | `tasks/debug/debug-cluster/crictl/` |
| CRD concepts | `concepts/extend-kubernetes/api-extension/custom-resources/` |
| CRD full YAML example | `tasks/extend-kubernetes/custom-resources/custom-resource-definitions/` |
| Operator pattern | `concepts/extend-kubernetes/operator/` |
| Cluster troubleshooting entry | `tasks/debug/debug-cluster/` |

---

## Checkpoint

Time yourself cold. Miss a target → redo the matching exercise tomorrow.

- Can you narrate the full `kubectl apply → running pod` pipeline — every component, every failure signature — in 3 minutes?
- Can you create a deployment, scale to 5, roll out a new image, verify, and roll back, in 2 minutes total?
- Can you build and apply a two-container pod sharing an emptyDir and prove the sharing with `k exec`, in 5 minutes?
- Can you add a native sidecar (initContainer + `restartPolicy: Always`) to an existing pod spec, in 4 minutes?
- Can you list all cluster-scoped resource kinds and the shortname + group of `networkpolicies`, in 1 minute?
- Can you get into the control-plane node, list the static pod manifests, and read the API server's `--etcd-servers` flag, in 2 minutes?
- Can you stop and restore the scheduler via its manifest file and demonstrate the effect with a Pending pod, in 5 minutes?
- Can you compose a new kubeconfig context with a different default namespace, switch to it, verify with `config view --minify`, and switch back, in 3 minutes?
- Can you find every CRD of an installed operator, list its custom resources, and read one spec field via jsonpath, in 3 minutes?
- Can you, given only a pod name, find its node, container ID, and on-disk log path with `crictl`, in 4 minutes?
- Can you state from memory what breaks when each of kube-apiserver, etcd, kube-scheduler, kube-controller-manager is down, in 2 minutes?
