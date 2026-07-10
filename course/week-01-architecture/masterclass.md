# Week 1 Masterclass — Cluster Architecture & Core Concepts (feeds Cluster Architecture, Installation & Configuration 25%, Troubleshooting 30%, Workloads & Scheduling 15%)

Week 1 is the load-bearing wall of the whole exam. Every troubleshooting task — the largest single domain at 30% — is really the question "which stage of the `kubectl apply → running pod` pipeline broke, and where do I look?" Every other task rides on kubectl fluency and kubeconfig discipline that you either have in your fingers or you burn minutes you don't have. Master the pipeline, the components, and the API-machinery introspection tools, and the rest of the course is applications of this one model.

Version note: written against v1.31–v1.34 behavior, kept version-agnostic where possible. Native sidecars (`initContainers` with `restartPolicy: Always`) were enabled by default (beta) in v1.29 and graduated to GA/stable in v1.33 — behavior is unchanged across the exam's 1.31–1.34 range since the feature is on by default from 1.29; server-side strict validation became the default in v1.27. Check the current exam Kubernetes version on the CNCF curriculum page (github.com/cncf/curriculum) before exam day and re-confirm any version-flagged behavior below.

---

## What the exam actually asks

| Week-1 topic | Exam domain (weight) | How it shows up on the exam |
|---|---|---|
| Control-plane internals, static pods | Troubleshooting (30%), Cluster Architecture (25%) | "The API server is down, fix it"; "new pods stay `Pending`"; read/patch a flag in a manifest under `/etc/kubernetes/manifests` |
| kubectl fluency: get/describe/-o wide/jsonpath/sort-by/custom-columns | All domains | Every task; plus explicit "write the X of every Y sorted by Z to file /opt/..." tasks |
| kubeconfig contexts | All domains | Every question opens with `kubectl config use-context ...`; occasional "create a context/user" task |
| Pod lifecycle, multi-container, init/native-sidecar | Workloads & Scheduling (15%), Troubleshooting (30%) | "Add a sidecar that ships the app log"; "prepare data before the main container starts"; "why is this pod `Init:0/1`?" |
| Deployments: scale, rollout, rollback | Workloads & Scheduling (15%) | Timed rollout, then rollback to the last working revision; broken-rollout diagnosis |
| Namespaces & scoping | All domains | `-n` discipline; "which resource types are not namespaced" discovery |
| API groups/versions, `api-resources`, `explain` | All domains | Not asked directly — these are the tools that let you answer everything else without a doc tab |
| CRDs and operators | Cluster Architecture (25%) | "List the CRDs installed by operator X"; create/edit a custom resource; find the controlling operator's logs |
| kubelet, kube-proxy, containerd, crictl | Troubleshooting (30%) | "Node `NotReady`, fix it"; inspect containers with `crictl` when `kubectl` can't reach the pod |

Exam environment reality: PSI Bridge remote desktop (XFCE + Firefox), a single allowed doc tab restricted to kubernetes.io/docs, kubernetes.io/blog, and helm.sh/docs. Terminal paste is **Ctrl+Shift+V**. The `k` / `$do` / `$now` aliases used throughout this course are what you set up in the first 60 seconds of the exam:

```bash
alias k=kubectl
export do="--dry-run=client -o yaml"
export now="--grace-period=0 --force"
source <(kubectl completion bash)
complete -o default -F __start_kubectl k
```

---

## The life of `kubectl apply` — from keystroke to running pod

The single most valuable mental model in the course. Every troubleshooting task is "the pipeline stopped at stage N — find and unblock N." Learn the stages, and — more importantly — learn each stage's **failure signature** so you can localize a break in seconds instead of guessing.

### Stage 0 — client side (your laptop / the exam terminal)

1. kubectl resolves its kubeconfig. Precedence: `--kubeconfig` flag beats `$KUBECONFIG` (a colon-separated list, files **merged** left-to-right) beats `~/.kube/config`.
2. `current-context` selects a context, which names a **cluster** (API server URL + CA bundle), a **user** (client cert, token, or exec plugin), and optionally a default **namespace**.
3. Your YAML is parsed and **field-validated**. Since v1.27 validation is server-side and strict by default; a typo like `replicas` misspelled `replica` is rejected instead of silently dropped (older clusters validated client-side against a cached OpenAPI schema, and unknown fields were dropped — a classic silent-failure trap).
4. For `apply` (client-side apply is still the default): kubectl computes a three-way merge between your file, the live object, and the `kubectl.kubernetes.io/last-applied-configuration` annotation, then sends a `PATCH`. `--server-side` delegates merging to the API server via `managedFields`. `kubectl create` is a plain `POST` and errors if the object exists; `kubectl replace` is a `PUT` and errors if it does not.

Failure signatures at Stage 0: `Unable to connect to the server: connection refused` (API server down or wrong port), `x509: certificate signed by unknown authority` (wrong CA — you're pointed at the wrong cluster), `error validating data: ValidationError` (schema typo — read the field name it names), `dial tcp: lookup ... no such host` (garbage server hostname in the cluster entry).

### Stage 1 — API server: authn → authz → admission

The request reaches `kube-apiserver` on 6443 and passes, strictly in this order:

1. **Authentication** — client certificate (`CN` = username, `O` = group), bearer/ServiceAccount token, or OIDC. Failure → `401 Unauthorized`.
2. **Authorization** — the **union** of the configured authorizers (on a kubeadm cluster: `Node` then `RBAC`). Any authorizer that says *allow* is sufficient; none saying allow → `403 Forbidden`. The 403 message names the user, verb, resource, and namespace — that string is the entire diagnosis, read it before touching anything.
3. **Mutating admission** — plugins that *change* the object: `ServiceAccount` injects `serviceAccountName: default` and the projected token volume, `LimitRanger` injects default requests/limits, API-level defaulting fills unset fields (`restartPolicy: Always`, `terminationGracePeriodSeconds: 30`, `dnsPolicy: ClusterFirst`, `imagePullPolicy`). This is why the object you `get -o yaml` back is far bigger than the one you wrote.
4. **Schema validation** against the OpenAPI schema.
5. **Validating admission** — accept/reject only, no mutation: `ResourceQuota`, `NamespaceLifecycle` (refuses creates in a `Terminating` namespace), `ValidatingAdmissionWebhook`, `ValidatingAdmissionPolicy` (CEL, GA v1.30). A hung or mis-configured validating webhook is the classic "every create on this resource times out with `context deadline exceeded`" failure — check `kubectl get validatingwebhookconfigurations`.

### Stage 2 — etcd write

The API server is the **only** component that talks to etcd. The object is serialized (protobuf) and written under a key like `/registry/pods/<namespace>/<name>`. The write commits through Raft — it needs a **quorum** of etcd members (2 of 3, 3 of 5). The etcd revision becomes the object's `resourceVersion`, the currency of optimistic concurrency and of watches. Only after the commit does kubectl receive `201 Created`. At this instant the pod **exists** but runs nowhere: `apply` returning success means **stored**, not **scheduled**, and certainly not **running**. Internalize that distinction — half of "my pod isn't working" tasks are pods that are stored-but-Pending.

### Stage 3 — watch fan-out

Every controller and the scheduler run **informers**: one initial `LIST` to warm a local cache, then a long-lived `WATCH` from that `resourceVersion`. The API server pushes the new-pod event to all watchers from its watch cache. Nothing polls in a steady state — that's why the pipeline is normally sub-second, and why a wedged API server freezes every controller and the scheduler simultaneously (they all lose their watch).

### Stage 4 — scheduler: filter → score → bind

`kube-scheduler` watches for pods with an empty `spec.nodeName`. For each such pod:

1. **Filter (predicates)** — eliminate infeasible nodes: insufficient allocatable CPU/memory measured against pod **requests** (`NodeResourcesFit`), taints without matching tolerations, `nodeSelector`/`nodeAffinity` mismatch, `unschedulable: true` (cordoned), host-port conflicts, volume-topology/zone constraints (`VolumeBinding`).
2. **Score (priorities)** — rank the survivors (resource balance, image locality, pod topology spread, inter-pod affinity) and pick the winner.
3. **Bind** — the scheduler does **not** start the container. It writes a `Binding` object, which the API server persists as `spec.nodeName` on the pod. That's the scheduler's entire job.

Failure signature: pod stuck `Pending` with `Events: 0/3 nodes are available: <reason>`. Read the reason verbatim — "Insufficient cpu", "node(s) had untolerated taint", "node(s) didn't match Pod's node affinity/selector". If the scheduler itself is down, pods stay `Pending` with **no** `FailedScheduling` event at all — the tell is total silence, because nothing is even evaluating them.

### Stage 5 — kubelet sync loop

The kubelet on the bound node watches for pods whose `spec.nodeName` equals its own node name. Its sync loop, per pod:

1. Runs **admission** locally (node capacity, OS, restricted sysctls).
2. Sets up the pod sandbox via CRI: the `pause` container holds the network namespace and cgroup parent.
3. Calls the **CNI** plugin to allocate an IP and wire the veth pair (on the kind lab that's kindnetd; on real clusters Calico/Cilium/etc.).
4. Pulls images per `imagePullPolicy`, honoring `imagePullSecrets`.
5. Runs `initContainers` **to completion, in order**, then starts `containers` (native sidecars — init containers with `restartPolicy: Always` — start during the init phase and keep running).
6. Runs probes, mounts volumes and projected ServiceAccount tokens, and continuously **writes `status` back** to the API server (phase, conditions, container statuses, pod IP).

Failure signatures here are the ones you'll see most: `ImagePullBackOff`/`ErrImagePull` (bad image name/tag or missing pull secret), `CreateContainerConfigError` (missing ConfigMap/Secret referenced by env/volume), `RunContainerError`, `CrashLoopBackOff` (container starts then exits non-zero, kubelet backs off exponentially up to 5 min), `CreateContainerError`, and volume-mount failures. All of these are **kubelet-stage** problems and all of them show up in `kubectl describe pod` Events plus `kubectl logs --previous`.

### Stage 6 — CRI / containerd

The kubelet never talks to containers directly. It speaks the **CRI** gRPC API over a Unix socket (`/run/containerd/containerd.sock` on kind) to containerd, which uses `runc` to create the OCI container. When `kubectl` can't help you — API server down, pod not registering, node-level weirdness — you drop to `crictl` on the node (it reads the same CRI socket): `crictl ps`, `crictl pods`, `crictl logs <id>`, `crictl inspect <id>`.

### Stage 7 — status writeback and convergence

The kubelet reports the pod `Running` and its containers `Ready`; the API server persists that; the Deployment/ReplicaSet controllers see the new `Ready` pod through their watches and update their own `status`. Endpoints/EndpointSlice controllers add the pod IP behind any matching Service. The pipeline is a chain of independent controllers each watching, reconciling, and writing back — no central conductor. That decentralization is exactly why you localize failures by stage rather than looking for one broken "thing".

**One-line diagnostic map** to burn into memory:

| Symptom | Broke at stage | First command |
|---|---|---|
| `connection refused` / `401` / `403` on every command | 0–1 (client / apiserver / RBAC) | `kubectl get --raw /healthz`; read the 403 text |
| Pod `Pending`, `FailedScheduling` event present | 4 (scheduler filter) | `kubectl describe pod` → read the reason |
| Pod `Pending`, **no** scheduling event | 4 (scheduler process down) | `crictl ps` on control-plane; check the static pod |
| Pod `ContainerCreating` forever | 5 (CNI / volume / secret) | `kubectl describe pod` Events |
| `ImagePullBackOff` / `CrashLoopBackOff` | 5 (kubelet/runtime) | `kubectl logs --previous`; `describe` |
| Node `NotReady` | 5–6 (kubelet / containerd) | `ssh` node → `systemctl status kubelet`, `crictl ps` |

---

## Control-plane components — deep dive, failure modes, manifest locations

On a kubeadm cluster (and the kind lab, which is kubeadm-under-the-hood) the control plane runs as **static pods**: manifests live in `/etc/kubernetes/manifests/` on the control-plane node, and the kubelet watches that directory and runs whatever it finds there — no scheduler, no API server involved. Edit a file there and the kubelet restarts the pod within seconds. Move a file out and the pod stops. This is both the recovery mechanism and a favorite exam surface ("the API server won't start — a flag in its manifest is wrong").

```
/etc/kubernetes/manifests/kube-apiserver.yaml
/etc/kubernetes/manifests/etcd.yaml
/etc/kubernetes/manifests/kube-scheduler.yaml
/etc/kubernetes/manifests/kube-controller-manager.yaml
```

`kubelet` itself is **not** a static pod (it's the thing that runs them — a systemd unit). `kube-proxy` runs as a DaemonSet, not a static pod. `cloud-controller-manager` is a static pod only on cloud-provisioned clusters; kind and bare kubeadm don't run one.

### kube-apiserver

The only stateful gateway: the single writer to etcd, the enforcer of authn/authz/admission, the endpoint every kubectl and every controller connects to. Stateless itself (all state is in etcd), so it can be replicated behind a load balancer.

- **When it's down:** `kubectl` returns `connection refused`; the whole cluster is read-frozen from the operator's view. Existing pods **keep running** (kubelet and container runtime don't need the API server to keep containers alive), but nothing new schedules, no controller reconciles, no `kubectl` works. Recovery is node-local: `ssh` to the control-plane node and use `crictl ps -a | grep apiserver` and `crictl logs` to read why it crash-looped, then fix the manifest.
- **Common breakages:** a typo in a flag in `kube-apiserver.yaml` (e.g. bad `--etcd-servers`, wrong `--service-cluster-ip-range`), an expired API-server serving cert, or etcd being unreachable (the API server exits if it can't reach etcd on startup).

### etcd

The cluster's only database — a distributed key-value store using Raft consensus. Every object lives here; lose etcd without a backup and you've lost the cluster. It needs an odd number of members and a quorum to accept writes.

- **When it's down / loses quorum:** the API server can't read or write, so it becomes effectively useless even if its process is up. Pods keep running; nothing changes.
- **Backup/restore is week-05 material**, but know the shape now: `ETCDCTL_API=3 etcdctl snapshot save` and `... snapshot restore`, both needing `--endpoints`, `--cacert`, `--cert`, `--key` pointed at the etcd PKI in `/etc/kubernetes/pki/etcd/`.
- **Common breakages:** wrong cert paths in `etcd.yaml`, a full data disk, or a `--data-dir` that doesn't match after a restore.

### kube-scheduler

Watches for unscheduled pods (`spec.nodeName == ""`), runs filter→score→bind, writes the binding. Stateless; leader-elected in HA.

- **When it's down:** new pods sit `Pending` **with no scheduling event** — the giveaway. Pods you pin manually with `spec.nodeName` set bypass the scheduler and still start, which is both a diagnostic trick and an emergency workaround.
- **Common breakages:** manifest typo; failed leader election; a bad custom scheduler config.

### kube-controller-manager

A single binary hosting dozens of controllers in control loops: Deployment, ReplicaSet, Node, Job, EndpointSlice, ServiceAccount-token, PV/PVC binder, and more. Each watches its resources and drives actual state toward desired state.

- **When it's down:** the cluster stops *reconciling*. Deployments won't scale or roll out, deleted pods aren't recreated, a dead node isn't noticed (no eviction after the grace period), new ServiceAccounts get no token, PVCs don't bind. Existing steady-state workloads keep running; the cluster just stops healing and responding to change.
- **Common breakages:** manifest typo; wrong `--cluster-cidr`/`--service-cluster-ip-range`; broken leader election.

### cloud-controller-manager

The bridge to a cloud provider's API — runs the controllers that are provider-specific: Node (enrich nodes with provider metadata, delete Node objects when the VM is gone), Route (program pod-network routes), Service (provision cloud load balancers for `type: LoadBalancer`). Only present on cloud-integrated clusters. Not on kind, so `type: LoadBalancer` Services stay `<pending>` in the lab unless you add MetalLB or `cloud-provider-kind`.

- **When it's down (on a cloud cluster):** `LoadBalancer` Services never get an external IP; new cloud VMs never become usable nodes; deleted VMs leave stale `Node` objects behind.

---

## Node components

### kubelet

The node agent — the only component that runs on *every* node and the one that actually makes pods real. It's a systemd service, not a pod. Key file locations to know cold, because exam node-troubleshooting lives here:

| What | Where | Notes |
|---|---|---|
| systemd unit / drop-in | `/usr/lib/systemd/system/kubelet.service`, `/etc/systemd/system/kubelet.service.d/10-kubeadm.conf` | the drop-in points at the config file and the kubeconfig |
| **kubelet config (the important one)** | `/var/lib/kubelet/config.yaml` | `KubeletConfiguration` object: `cgroupDriver`, `clusterDNS`, `staticPodPath`, `authentication`, eviction thresholds |
| kubeconfig (how kubelet talks to apiserver) | `/etc/kubernetes/kubelet.conf` | client cert here; `/var/lib/kubelet/pki/` holds the rotated node cert |
| CA bundle | `/etc/kubernetes/pki/ca.crt` | |
| static pod dir | `/etc/kubernetes/manifests/` | set by `staticPodPath` in the config |

Restart cycle after editing config: `systemctl daemon-reload && systemctl restart kubelet`, then `journalctl -u kubelet -f` to watch. A `NotReady` node is almost always the kubelet down/crashing (bad config, wrong `cgroupDriver` vs containerd, expired cert) or containerd down. `cgroupDriver` **must match** between kubelet and containerd (`systemd` on both, on modern installs) — a mismatch is a classic silent-`NotReady`.

### kube-proxy

Runs as a DaemonSet (`kube-system`), one pod per node. Programs the node's dataplane so that Service ClusterIPs actually route to backend pod IPs — via iptables (default) or IPVS. It watches Services and EndpointSlices and rewrites rules. When it's broken on a node, pods on that node can't reach Services (DNS resolves, connection hangs) even though everything else looks healthy. Not the same thing as the CNI: kube-proxy does **Service** routing; the CNI does **pod-to-pod** connectivity and IP allocation. (Deep networking is week-08; know the division of labor now.)

### Container runtime + crictl

containerd is the CRI runtime on the kind lab. `crictl` is your node-level, kubelet's-eye-view tool — it talks the CRI socket directly, so it works even when the API server is down. Configure it once per node to silence endpoint warnings: `crictl config runtime-endpoint unix:///run/containerd/containerd.sock`.

| Task | crictl |
|---|---|
| list running containers | `crictl ps` |
| list all incl. exited | `crictl ps -a` |
| list pod sandboxes | `crictl pods` |
| container logs | `crictl logs <container-id>` |
| inspect (mounts, env, state) | `crictl inspect <container-id>` |
| image list | `crictl images` |

Mental model: `crictl` is to a single node what `kubectl` is to the cluster, minus the abstractions. Reach for it only when `kubectl` can't reach the object — otherwise `kubectl` is faster and richer.

---

## API machinery — your two exam superpowers

The exam is open-book to kubernetes.io but the doc tab is slow. Two built-in commands answer 80% of "what's the field / what's the apiVersion / is this namespaced" questions faster than the browser.

### `kubectl api-resources` — the map of everything

Lists every resource type the API server serves, with its short name, apiVersion (group), and whether it's namespaced.

```bash
k api-resources                          # everything
k api-resources --namespaced=false       # cluster-scoped types only (see Namespaces)
k api-resources --namespaced=true        # namespaced types only
k api-resources --api-group=apps         # just the apps group
k api-resources -o wide                  # adds VERBS and CATEGORIES columns
```

Use it to recover a `kind`/`apiVersion` you half-remember, to answer "which resources are not namespaced", and to discover CRDs (they appear here once installed). `kubectl api-versions` lists the enabled group/versions themselves.

### `kubectl explain` — the schema, offline

`explain` reads the live OpenAPI schema from *your* cluster, so it's always correct for the version you're on. `--recursive` dumps the entire field tree with no descriptions — perfect for "what's the exact path and nesting" without scrolling docs.

```bash
k explain pod.spec.containers                 # fields + descriptions at that level
k explain pod.spec.containers.livenessProbe   # drill in
k explain deployment.spec.strategy --recursive
k explain pod --recursive | grep -i affinity  # find where a field lives in the tree
k explain pod.spec.containers.resources        # requests/limits shape, from memory-free
```

`explain` also honors `--api-version` when a kind exists in multiple groups. On the exam, `explain --recursive | grep` is how you locate a rarely-typed field (tolerations, topologySpreadConstraints, securityContext) without a doc round-trip.

### API groups and versions

Every resource belongs to a **group** at a **version**. The *core* (legacy) group has an empty group name and shows as `apiVersion: v1` (Pods, Services, ConfigMaps, Secrets, Namespaces, Nodes, PVs, PVCs). Named groups carry `group/version`. Memorize the current stable ones the exam expects:

| apiVersion | Kinds |
|---|---|
| `v1` (core) | Pod, Service, ConfigMap, Secret, Namespace, Node, PersistentVolume(Claim), ServiceAccount, Endpoints |
| `apps/v1` | Deployment, ReplicaSet, StatefulSet, DaemonSet |
| `batch/v1` | Job, CronJob |
| `networking.k8s.io/v1` | NetworkPolicy, Ingress, IngressClass |
| `gateway.networking.k8s.io/v1` | Gateway, HTTPRoute, GatewayClass |
| `rbac.authorization.k8s.io/v1` | Role, RoleBinding, ClusterRole, ClusterRoleBinding |
| `storage.k8s.io/v1` | StorageClass, CSIDriver, VolumeAttachment |
| `autoscaling/v2` | HorizontalPodAutoscaler |
| `certificates.k8s.io/v1` | CertificateSigningRequest |
| `policy/v1` | PodDisruptionBudget |

A `no matches for kind "X" in version "Y"` error is almost always a stale apiVersion (e.g. `apps/v1beta1`) — fix it with the table above or `k api-resources | grep -i <kind>`.

---

## kubeconfig anatomy and multi-context fluency

A kubeconfig is three lists plus a pointer, and understanding the shape lets you build or repair one under time pressure:

- **clusters** — each has a `server:` URL and a CA (`certificate-authority-data`, base64) to verify it.
- **users** — credentials: `client-certificate-data`/`client-key-data`, a `token:`, or an `exec:` plugin.
- **contexts** — a named triple binding one **cluster** + one **user** + an optional default **namespace**.
- **current-context** — which context is active now.

```yaml
apiVersion: v1
kind: Config
current-context: kind-cka
clusters:
  - name: kind-cka
    cluster:
      server: https://127.0.0.1:6443
      certificate-authority-data: LS0tLS1CRUdJTi==   # base64 CA, truncated for illustration
users:
  - name: kind-cka
    user:
      client-certificate-data: LS0tLS1CRUdJTi==       # base64 client cert
      client-key-data: LS0tLS1CRUdJTi==               # base64 client key
contexts:
  - name: kind-cka
    context:
      cluster: kind-cka
      user: kind-cka
      namespace: default
```

Every exam question starts by telling you to `kubectl config use-context <ctx>`. **Do it every single task** — the fastest way to lose points is solving a task perfectly in the wrong cluster. The commands you need in your fingers:

```bash
k config get-contexts                 # list; * marks current
k config current-context              # print active context
k config use-context kind-cka         # switch context (do this first, every task)
k config set-context --current --namespace=team-alpha   # pin default ns for current context
k config view --minify                # only the active context's resolved config
k config view --minify --raw          # includes the base64 cert/key data
```

To build a context from parts (occasionally asked): `k config set-cluster`, `k config set-credentials`, `k config set-context`, then `use-context`. `set-context --current --namespace=X` is the everyday one — it saves you typing `-n X` on every command for the rest of a task.

---

## Namespaces — and what is *not* namespaced

A namespace is a scope for **names** and a boundary for RBAC, quotas, and network policy. Two pods named `web` can coexist if they're in different namespaces; a Role in namespace A grants nothing in namespace B. But not everything is namespaced — cluster-wide objects have no namespace, and knowing which is which is a recurring exam probe.

**Namespaced** (need `-n`): Pod, Deployment, ReplicaSet, Service, ConfigMap, Secret, ServiceAccount, Role, RoleBinding, PVC, Job, Ingress, NetworkPolicy, HPA, Endpoints…

**Not namespaced** (cluster-scoped): Node, Namespace itself, PersistentVolume, StorageClass, ClusterRole, ClusterRoleBinding, CustomResourceDefinition, IngressClass, APIService, PriorityClass, CSIDriver, ValidatingWebhookConfiguration…

Don't memorize the list — **derive it live**, which is also the exam answer:

```bash
k api-resources --namespaced=false          # the authoritative cluster-scoped list
k api-resources --namespaced=false -o name  # just the type names, for piping to a file
```

Namespace mechanics: creating a Deployment in a namespace that's `Terminating` fails via the `NamespaceLifecycle` admission plugin. Deleting a namespace deletes everything **namespaced** inside it (cascading) but never the cluster-scoped objects. `k get <resource> -A` (or `--all-namespaces`) queries across all namespaces — indispensable when you don't know where something lives. The four default namespaces: `default`, `kube-system` (control-plane add-ons), `kube-public` (world-readable cluster info), `kube-node-lease` (node heartbeat Lease objects).

---

## Pod lifecycle — phases vs conditions vs container states

Three different status vocabularies, and confusing them costs you troubleshooting time.

**Phase** (`status.phase`) — a coarse, top-level summary, one of five:

| Phase | Meaning |
|---|---|
| `Pending` | Accepted by the API server, not yet running on a node — unscheduled, or scheduled but images still pulling / init containers running |
| `Running` | Bound to a node, all containers created, at least one running/starting/restarting |
| `Succeeded` | All containers terminated with exit 0 and will not restart (`restartPolicy: Never`/`OnFailure` completed) |
| `Failed` | All containers terminated, at least one with non-zero exit / the system killed it |
| `Unknown` | The node's kubelet can't be reached (node `NotReady`) |

**Conditions** (`status.conditions`) — finer, orthogonal booleans that together explain readiness: `PodScheduled`, `Initialized` (init containers done), `ContainersReady`, and `Ready` (the one Services care about — a pod behind a Service receives traffic only when `Ready` is `True`). A pod can be `Running` yet `Ready: False` — that's a failing readiness probe, and it's why the Service has no endpoints.

**Container states** (`status.containerStatuses[].state`) — `Waiting` (with a reason like `ImagePullBackOff`, `CrashLoopBackOff`, `CreateContainerConfigError`), `Running`, or `Terminated` (with exit code and reason like `OOMKilled`, `Error`, `Completed`). This is the layer with the actual root cause — `kubectl describe pod` surfaces all three, and the `Reason` string is what you act on.

**`restartPolicy`** (pod-level, applies to all containers):

| Value | Behavior | Typical use |
|---|---|---|
| `Always` (default) | restart on any exit | long-running Deployment/ReplicaSet pods |
| `OnFailure` | restart only on non-zero exit | Jobs that must complete |
| `Never` | never restart | one-shot pods |

`CrashLoopBackOff` is not a phase — it's a container `Waiting` reason under `restartPolicy: Always`, with the kubelet delaying restarts exponentially (10s, 20s, 40s… capped at 5 min). The fix is never "restart it harder"; it's `kubectl logs --previous` to see why the previous instance exited.

---

## Multi-container pods — init containers, native sidecars, shared volume/network

All containers in a pod share the same **network namespace** (one pod IP; they reach each other over `localhost` and must not collide on ports) and can share **storage** via volumes. That shared context is the entire reason to co-locate containers.

### init containers

Run **in order, to completion, before** any app container starts. Each must exit 0 or the kubelet restarts it (subject to `restartPolicy`) and the pod stays `Init:0/N`. Use them for one-shot setup: render a config, wait for a dependency, populate a shared volume, run a migration.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: init-demo
spec:
  initContainers:
    - name: render
      image: busybox:1.36
      command: ["sh", "-c", "echo week01 > /work/index.html"]
      volumeMounts:
        - name: web
          mountPath: /work
  containers:
    - name: web
      image: nginx:1.27
      volumeMounts:
        - name: web
          mountPath: /usr/share/nginx/html
  volumes:
    - name: web
      emptyDir: {}
```

A pod stuck `Init:0/1` means the first init container hasn't exited 0 — `kubectl logs <pod> -c render` tells you why. This is a common troubleshooting setup.

### native sidecars (the modern, exam-relevant form)

A sidecar is a helper container that must run for the pod's whole life (log shipper, proxy, metrics agent). The old pattern — a second entry in `containers` — has two flaws: it has no ordering guarantee relative to the main container, and in a Job the pod never completes because the sidecar never exits. The **native sidecar** (enabled by default as beta in v1.29, GA/stable in v1.33) fixes both: declare it as an **init container with `restartPolicy: Always`**. The kubelet starts it during the init phase (so it's up *before* the main container), keeps it running for the pod's lifetime, and — critically — **excludes it from the Job-completion calculation**.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-with-sidecar
spec:
  initContainers:
    - name: log-shipper          # native sidecar: init container + restartPolicy Always
      image: busybox:1.36
      restartPolicy: Always
      command: ["sh", "-c", "tail -F /var/log/app/app.log"]
      volumeMounts:
        - name: logs
          mountPath: /var/log/app
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "while true; do date >> /var/log/app/app.log; sleep 3; done"]
      volumeMounts:
        - name: logs
          mountPath: /var/log/app
  volumes:
    - name: logs
      emptyDir: {}
```

Exam tell: if a task says the helper must "start before" the main app, "keep running", or lives inside a Job that must still complete, it wants a native sidecar — `restartPolicy: Always` on an init container — not a plain second container. Verify with `k get pod app-with-sidecar` showing `2/2 READY`.

### shared volume / shared network

`emptyDir` is the everyday shared scratch volume: created empty when the pod starts, mounted into every container that asks, gone when the pod dies. The two-container "writer appends to a file, reader `tail -F`s it" pattern (both mounting the same `emptyDir`) is the canonical multi-container exam task. Shared network means a sidecar proxy can reach the app on `localhost:<port>` with zero service plumbing.

---

## ReplicaSet vs Deployment — mechanics and the selector-immutability trap

A **ReplicaSet** keeps N pods matching a label selector alive: it reconciles `desired replicas` against `pods matching .spec.selector`, creating or deleting to converge. You almost never create one directly.

A **Deployment** manages ReplicaSets, not pods. Each pod template hashes to a `pod-template-hash` label; every change to `.spec.template` produces a **new ReplicaSet** and the Deployment shifts replicas from the old RS to the new one per the rollout strategy. That one indirection — Deployment → ReplicaSet(s) → Pods — explains rollouts, rollbacks, and history entirely (revisions *are* old ReplicaSets kept scaled to zero). Deep rollout math is week-02; here, own the core commands and the trap.

```bash
k create deploy web --image=nginx:1.27 --replicas=3
k scale deploy web --replicas=5
k set image deploy/web nginx=nginx:1.28      # triggers a new ReplicaSet = new revision
k rollout status deploy/web                  # blocks until done or progressDeadline
k rollout history deploy/web
k rollout undo deploy/web                     # roll back to previous revision
k rollout undo deploy/web --to-revision=2
```

**The selector-immutability trap.** A Deployment's (and ReplicaSet's) `.spec.selector` is **immutable** after creation. Trying to edit it fails with `field is immutable`. And the selector **must match** `.spec.template.metadata.labels` — if they disagree at creation, the API server rejects it (`selector does not match template labels`). Corollary trap: adopting existing pods. A ReplicaSet adopts any pod matching its selector that has no controller owner — so a hand-made pod with `app: web` can get swept up (or conversely deleted as a surplus replica) by a `web` ReplicaSet. When a task needs a selector change, you **delete and recreate** the Deployment; you cannot patch your way out.

---

## CRDs and operators (curriculum addition)

A **CustomResourceDefinition** teaches the API server a new resource **kind**. Once you `kubectl apply` a CRD, the API server serves that new type at its own group/version endpoint, and it behaves like any built-in: `kubectl get`, `describe`, RBAC, `-o yaml`, watches all work on it. The CRD adds *storage and API surface* — nothing more. It does not add behavior.

```bash
k get crds                                  # every installed CRD
k get crd <name> -o yaml                    # its group, version, scope, schema
k api-resources | grep -i <kind>            # confirm the new type is served + its short name
k get <plural> -A                           # list the custom resources of that kind
k explain <kind>.spec                        # schema-driven explain works on CRs too
```

A CRD is cluster-scoped, but the custom resources it defines can be `Namespaced` or `Cluster`-scoped (`spec.scope`). A minimal CRD for reference:

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: backups.data.example.com
spec:
  group: data.example.com
  scope: Namespaced
  names:
    plural: backups
    singular: backup
    kind: Backup
    shortNames:
      - bk
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
                schedule:
                  type: string
```

An **operator** = one or more CRDs **plus a controller** (a custom controller-manager, usually its own Deployment) that watches those custom resources and reconciles real-world state to match them. The CRD is the *what you can declare*; the operator's controller is the *what actually happens when you declare it*. Delete the operator's Deployment and the CRs still exist and are still editable — they just stop being acted upon (nothing reconciles them), exactly like a control plane with `kube-controller-manager` down. Exam-level tasks: list a given operator's CRDs, create or edit a custom resource against the CRD's schema, and — when a CR "isn't doing anything" — find and read the operator's controller **Deployment/pod logs** (usually in its own namespace) as the diagnosis.

---

## Traps

- **`apply` success ≠ running.** A `201 Created`/`configured` means *stored in etcd*, full stop. Always follow with `k get`/`describe` to confirm it actually scheduled and started. Half of "it's not working" is a `Pending` pod you never re-checked.
- **Wrong context, perfect answer, zero points.** Run `k config use-context <ctx>` at the start of *every* task. The exam grades the target cluster only.
- **Selector is immutable.** You cannot edit a Deployment/ReplicaSet `.spec.selector`, and it must equal the template labels. A selector-change task means delete-and-recreate, not `edit`.
- **Native sidecar ≠ second container.** "Starts before the main app / keeps running / Job still completes" ⇒ init container with `restartPolicy: Always`. A plain second container has no ordering guarantee and will hang a Job forever.
- **Static pods aren't scheduled.** Control-plane components under `/etc/kubernetes/manifests/` are run by the kubelet directly — the scheduler and API server play no part. You fix them by editing the file on the node, not with `kubectl edit` (there's a mirror pod in the API but editing it does nothing).
- **`kube-proxy` down ≠ CNI down.** kube-proxy broken → Services unreachable but pod-to-pod fine. CNI broken → pods stuck `ContainerCreating`/no IP. Different symptom, different fix; don't conflate them.
- **Existing pods survive a dead control plane.** API server / scheduler / controller-manager all down does **not** kill running pods — the kubelet keeps them alive. So "pods still serving traffic" does not prove the control plane is healthy.
- **`Running` ≠ `Ready`.** A pod can be `Running` with `Ready: False` (failing readiness probe) and therefore absent from its Service's endpoints. Check conditions, not just phase.
- **Stale apiVersion.** `no matches for kind` almost always means an old group/version (`extensions/v1beta1`, `apps/v1beta1`). Correct it against the api-versions table or `k api-resources`.
- **`kubectl edit` on some fields silently no-ops or errors.** Immutable fields (selectors, most `volumeClaimTemplates`, a Job's `template`) can't be edited live — recreate the object.
- **`get -o yaml` dumps managedFields and status noise.** Add `--show-managed-fields=false` (default off in recent versions) or pipe through and ignore it; don't copy `status`/`metadata.managedFields` into a new manifest.

---

## Speed patterns

The fastest exam-legal way to do each recurring Week-1 task:

| Need | Fastest path |
|---|---|
| Scaffold a pod YAML | `k run web --image=nginx:1.27 $do > web.yaml` then edit |
| Scaffold a Deployment YAML | `k create deploy web --image=nginx:1.27 --replicas=3 $do > web.yaml` |
| Run a one-shot pod to completion | `k run once --image=busybox:1.36 --restart=Never -- sh -c 'date; sleep 3'` |
| Create + expose in one shot | `k run web --image=nginx --port=80` then `k expose pod web --port=80` |
| Force-delete a stuck pod | `k delete pod web $now` |
| See a field's exact path from memory | `k explain <kind> --recursive \| grep -i <field>` |
| Recover a kind/apiVersion | `k api-resources \| grep -i <kind>` |
| Cluster-scoped types → file | `k api-resources --namespaced=false -o name > /tmp/x.txt` |
| Nodes with IP/OS/runtime | `k get nodes -o wide` |
| Node InternalIPs to a file | `k get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'` |
| Pods sorted by age (oldest first) | `k get pods -A --sort-by=.metadata.creationTimestamp` |
| Unique images in a namespace | `k get po -n kube-system -o jsonpath='{.items[*].spec.containers[*].image}' \| tr ' ' '\n' \| sort -u` |
| Two-column custom report | `k get po -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName` |
| Pin default namespace | `k config set-context --current --namespace=team-alpha` |
| Inspect control plane on kind | `docker exec cka-control-plane ls /etc/kubernetes/manifests` |
| Node-level container view (kind) | `docker exec cka-control-plane crictl ps` |
| Watch a rollout to completion | `k rollout status deploy/web` |
| Diff before applying | `k diff -f web.yaml` |

Two habits that compound: (1) always generate YAML with `$do` and edit, never hand-type a manifest from scratch; (2) always end a build task with a `k get`/`describe`/`logs` verification — it's faster than re-reading the task and catches the `Pending`/`CrashLoop` you'd otherwise miss.

---

## Docs-map

When you must open the tab, go straight to the path — don't search from the homepage.

| What you need | Exact kubernetes.io doc path |
|---|---|
| Control-plane component overview | `/docs/concepts/overview/components/` |
| Static pods & `/etc/kubernetes/manifests` | `/docs/tasks/configure-pod-container/static-pod/` |
| kubectl cheat sheet (jsonpath, sort-by) | `/docs/reference/kubectl/cheatsheet/` |
| jsonpath support & syntax | `/docs/reference/kubectl/jsonpath/` |
| kubeconfig / multi-cluster access | `/docs/tasks/access-application-cluster/configure-access-multiple-clusters/` |
| Pod lifecycle (phases, conditions, restartPolicy) | `/docs/concepts/workloads/pods/pod-lifecycle/` |
| Init containers | `/docs/concepts/workloads/pods/init-containers/` |
| Sidecar containers (native) | `/docs/concepts/workloads/pods/sidecar-containers/` |
| Deployments (rollout/rollback/scale) | `/docs/concepts/workloads/controllers/deployment/` |
| ReplicaSet (selector rules) | `/docs/concepts/workloads/controllers/replicaset/` |
| Namespaces | `/docs/concepts/overview/working-with-objects/namespaces/` |
| API groups & versioning | `/docs/reference/using-api/` |
| CustomResourceDefinitions | `/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/` |
| Operator pattern | `/docs/concepts/extend-kubernetes/operator/` |
| crictl (debug nodes) | `/docs/tasks/debug/debug-cluster/crictl/` |
| kubelet configuration | `/docs/reference/config-api/kubelet-config.v1beta1/` |

---

## Checkpoint

Self-test against the clock. If any answer is "I'd have to look it up," you're not done with Week 1. Each is phrased as "can you, in the target time":

- **Under 30s:** switch context and pin a default namespace (`use-context` + `set-context --current --namespace`).
- **Under 60s:** narrate the 7 stages from `k apply` to a `Running` pod, naming the failure signature at each.
- **Under 60s:** given "new pods stay `Pending` with no scheduling event," name the broken component and where its manifest lives.
- **Under 90s:** scaffold, from `$do`, a two-container pod sharing an `emptyDir` where one writes and the other tails — and verify with `logs`.
- **Under 90s:** convert that second container into a native sidecar and prove `2/2 READY`.
- **Under 60s:** create a Deployment, scale it to 5, roll a new image, and roll it back to the prior revision.
- **Under 30s:** write the InternalIP of every node to a file with jsonpath.
- **Under 30s:** write every cluster-scoped (non-namespaced) resource type to a file.
- **Under 45s:** on the kind lab, list the control-plane static-pod manifests and read one flag from `kube-apiserver.yaml` via `docker exec`.
- **Under 45s:** list all CRDs, pick one, and show the custom resources of its kind across all namespaces.
- **Under 20s:** recover the exact schema path of `tolerations` (or any field) using `explain --recursive | grep`.
- **Explain in one breath:** why a `Running` pod can be absent from its Service's endpoints (condition `Ready: False`).
