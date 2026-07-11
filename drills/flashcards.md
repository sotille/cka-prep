# CKA Flashcards — Active Recall Deck

High-frequency, must-be-instant facts. These are the things you recall *without thinking* so exam time goes to the keyboard, not to remembering which apiGroup a NetworkPolicy lives in. Not a substitute for the modules — a compression layer on top of them.

Lab assumed: 3-node **kind** cluster (Kubernetes **v1.36**, etcd **3.6**). Standing shell setup used throughout:

```bash
alias k=kubectl
export do="--dry-run=client -o yaml"
export now="--grace-period=0 --force"
```

## How to drill

1. **Cover the answer** (everything right of `→`). Read the question, say the answer **aloud**, then reveal. Silent recognition lies; spoken recall does not.
2. A card is "known" only when the answer comes in **under ~3 seconds** with zero hedging. Slow-but-correct is still a miss — mark it.
3. **Leitner boxes.** Box 1 = daily, Box 2 = every 3 days, Box 3 = weekly. Correct → promote one box. Wrong → straight back to Box 1. Only Box 3 cards are "banked."
4. Drill both directions where it helps: given the fact, recall the command; given the command, recall what it does.
5. Import `flashcards.csv` into Anki for spaced repetition on your phone; use this file for the read-aloud pass at the keyboard.

Format: **Q: question** → answer.

---

## API versions & apiGroups (cross-domain)

The single most common silent time-sink: writing a manifest with the wrong `apiVersion`. Bank these cold.

**Q: apiVersion for Deployment?** → `apps/v1` (same for ReplicaSet, DaemonSet, StatefulSet).
**Q: apiVersion for Job and CronJob?** → `batch/v1` (both).
**Q: apiVersion for NetworkPolicy?** → `networking.k8s.io/v1`.
**Q: apiVersion for Ingress (and IngressClass)?** → `networking.k8s.io/v1`.
**Q: apiVersion for Role, RoleBinding, ClusterRole, ClusterRoleBinding?** → `rbac.authorization.k8s.io/v1`.
**Q: apiVersion for PriorityClass?** → `scheduling.k8s.io/v1`.
**Q: apiVersion for StorageClass?** → `storage.k8s.io/v1` (also CSIDriver, VolumeAttachment).
**Q: apiVersion for CertificateSigningRequest?** → `certificates.k8s.io/v1`.
**Q: apiVersion for Gateway and HTTPRoute?** → `gateway.networking.k8s.io/v1`.
**Q: apiVersion for HorizontalPodAutoscaler?** → `autoscaling/v2`.
**Q: apiVersion for Pod, Service, ConfigMap, Secret, PV, PVC, Namespace, ServiceAccount, Node?** → `v1` (the core group).
**Q: What is the name of the core apiGroup, and how do you write it in an RBAC rule?** → the empty string; `apiGroups: [""]`.
**Q: apiVersion for PodDisruptionBudget?** → `policy/v1`.
**Q: apiVersion for a CustomResourceDefinition?** → `apiextensions.k8s.io/v1`.

---

## Cluster Architecture (25%)

### RBAC

**Q: The four Role/Binding object combinations for granting access?** → Role+RoleBinding (namespaced); ClusterRole+ClusterRoleBinding (cluster-wide); ClusterRole+RoleBinding (reuse a ClusterRole inside one namespace); ClusterRole+ClusterRoleBinding for cluster-scoped resources (nodes, PVs).
**Q: The full set of RBAC verbs?** → `get, list, watch, create, update, patch, delete, deletecollection` (plus `*`).
**Q: Which RBAC object is namespaced vs cluster-scoped?** → Role/RoleBinding are namespaced; ClusterRole/ClusterRoleBinding are cluster-scoped.
**Q: Imperatively create a Role for read-only pod access?** → `k create role dev --verb=get,list,watch --resource=pods`.
**Q: Imperatively bind a Role to user `jane`?** → `k create rolebinding dev-rb --role=dev --user=jane`.
**Q: Bind the built-in `view` ClusterRole to a ServiceAccount in namespace `app`?** → `k create rolebinding rb --clusterrole=view --serviceaccount=app:sa`.
**Q: Verify effective permissions as another user?** → `k auth can-i get pods --as=jane -n dev`.
**Q: Check what a ServiceAccount can do?** → `k auth can-i list pods --as=system:serviceaccount:app:sa`.

### CertificateSigningRequest (user certs)

**Q: signerName for a kubeadm client (user) cert?** → `kubernetes.io/kube-apiserver-client`.
**Q: usages for a client-auth CSR?** → `[client auth]`.
**Q: What goes in the CSR `.spec.request` field?** → base64 of the PEM CSR: `cat my.csr | base64 -w0`.
**Q: Approve a pending CSR?** → `k certificate approve <name>` (`k get csr` to list, `deny` to reject).

### etcd backup / restore (etcd 3.6)

**Q: Tool + command to SAVE an etcd snapshot?** → `etcdctl snapshot save snap.db`.
**Q: In etcd 3.6, which tool does snapshot `status` and `restore`?** → `etcdutl` (`etcdutl snapshot status`, `etcdutl snapshot restore`); those subcommands were removed from `etcdctl`.
**Q: Mandatory cert flags for etcdctl against a kubeadm cluster?** → `--cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/server.crt --key /etc/kubernetes/pki/etcd/server.key`.
**Q: etcd endpoint on a single control-plane node?** → `--endpoints https://127.0.0.1:2379`.
**Q: Env var to force the v3 API for etcdctl?** → `ETCDCTL_API=3`.
**Q: Check a snapshot's integrity/status in 3.6?** → `etcdutl snapshot status snap.db --write-out=table`.

### kubeadm cluster lifecycle

**Q: Upgrade order across the whole cluster?** → control-plane nodes first, then workers; **one minor version at a time** (n → n+1, no skips).
**Q: Per-node upgrade sequence?** → upgrade the `kubeadm` package → `kubeadm upgrade apply` (first CP) or `kubeadm upgrade node` (others) → `drain` → upgrade `kubelet`+`kubectl` → `systemctl restart kubelet` → `uncordon`.
**Q: Where do the Kubernetes package repos live now?** → `pkgs.k8s.io`, with a **per-minor** URL you must bump for each upgrade (e.g. `.../core:/stable:/v1.36/deb/`).
**Q: Preview what an upgrade will do?** → `kubeadm upgrade plan`.
**Q: Package hold dance around an upgrade (apt)?** → `apt-mark unhold kubeadm` → install → `apt-mark hold kubeadm` (repeat for kubelet/kubectl).
**Q: Why can't you jump two minor versions in one upgrade?** → kubeadm only supports upgrading a single minor at a time.

### Static pods & control plane

**Q: Static pod manifest directory?** → `/etc/kubernetes/manifests`.
**Q: How does the kubelet learn that directory?** → `staticPodPath` in `/var/lib/kubelet/config.yaml`.
**Q: Which control-plane components run as static pods under kubeadm?** → kube-apiserver, kube-controller-manager, kube-scheduler, etcd.
**Q: Restart a static pod?** → edit (or move out/in) its manifest in `/etc/kubernetes/manifests`; the kubelet re-reads and recreates it.

### kubeconfig locations

**Q: Admin kubeconfig on a control-plane node?** → `/etc/kubernetes/admin.conf`.
**Q: The kubelet's kubeconfig?** → `/etc/kubernetes/kubelet.conf`.
**Q: Controller-manager and scheduler kubeconfigs?** → `/etc/kubernetes/controller-manager.conf`, `/etc/kubernetes/scheduler.conf`.
**Q: Default user kubeconfig path (and overrides)?** → `~/.kube/config`; override with `$KUBECONFIG` or `--kubeconfig`.

### Extension interfaces, CRDs, packaging

**Q: The three node-level extension interfaces?** → CNI (networking), CSI (storage), CRI (container runtime).
**Q: Default containerd CRI socket?** → `unix:///run/containerd/containerd.sock`.
**Q: What object defines a brand-new resource kind?** → a CustomResourceDefinition (CRD).
**Q: Is Kustomize built into kubectl?** → yes: `k apply -k <dir>`, render with `k kustomize <dir>`.
**Q: Render a Helm chart without installing it?** → `helm template <name> <chart>` (install with `helm install <name> <chart> -n <ns>`).

### Pod Security Admission & securityContext

**Q: PSA namespace label key that blocks non-compliant pods?** → `pod-security.kubernetes.io/enforce`.
**Q: The three PSA levels?** → `privileged`, `baseline`, `restricted`.
**Q: Label to enforce the baseline profile?** → `pod-security.kubernetes.io/enforce=baseline` (swap `restricted` for the strict profile).
**Q: The three PSA modes?** → `enforce`, `audit`, `warn` (each optionally pinned with a `*-version` label).
**Q: securityContext fields required to satisfy `restricted`?** → `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, drop **ALL** capabilities, `seccompProfile.type: RuntimeDefault`, no `privileged`:

```yaml
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  seccompProfile:
    type: RuntimeDefault
  capabilities:
    drop: ["ALL"]
```

**Q: Fast doc path for a full CSR + approve example?** → search "certificate signing requests".
**Q: Fast doc path for etcd backup commands?** → search "backing up an etcd cluster".
**Q: Fast doc path for the kubeadm upgrade steps?** → search "upgrading kubeadm clusters".

---

## Workloads & Scheduling (15%)

### QoS & eviction

**Q: The three QoS classes?** → Guaranteed, Burstable, BestEffort.
**Q: What makes a pod Guaranteed?** → every container sets requests == limits for **both** CPU and memory.
**Q: What makes a pod BestEffort?** → no requests and no limits on any container.
**Q: Node under memory pressure — eviction order?** → BestEffort first, then Burstable (most over its requests), Guaranteed last.

### Requests vs limits

**Q: What does a resource *request* do?** → drives scheduling; the pod only lands on a node with that much allocatable, and it's the guaranteed reservation.
**Q: What does a resource *limit* do?** → hard cap; CPU is throttled at the limit, memory over the limit is OOMKilled.
**Q: Container exceeds its memory limit — result?** → OOMKilled (exit **137**).
**Q: Container exceeds its CPU limit — result?** → throttled, never killed.
**Q: Minimal `resources` block that yields Guaranteed QoS?** → requests equal to limits, e.g.:

```yaml
resources:
  requests:
    cpu: "500m"
    memory: "256Mi"
  limits:
    cpu: "500m"
    memory: "256Mi"
```

### Probes

**Q: The three probe types?** → livenessProbe, readinessProbe, startupProbe.
**Q: A failing readinessProbe does what?** → pulls the pod out of Service endpoints; **no** restart.
**Q: A failing livenessProbe does what?** → kubelet restarts the container.
**Q: Purpose of a startupProbe?** → guards slow-starting containers; liveness/readiness are suppressed until it first succeeds.
**Q: The probe timing fields?** → `initialDelaySeconds`, `periodSeconds`, `timeoutSeconds`, `successThreshold`, `failureThreshold`.
**Q: The probe handler types?** → `httpGet`, `tcpSocket`, `exec` (also `grpc`).

### Scheduling constraints

**Q: The three taint effects?** → `NoSchedule`, `PreferNoSchedule`, `NoExecute`.
**Q: What does `NoExecute` do that `NoSchedule` doesn't?** → also evicts already-running pods that don't tolerate the taint.
**Q: Add a taint imperatively?** → `k taint nodes n1 key=val:NoSchedule`.
**Q: Remove a taint?** → same command with a trailing dash: `k taint nodes n1 key=val:NoSchedule-`.
**Q: nodeSelector vs nodeAffinity?** → nodeSelector is an exact label match; nodeAffinity adds operators and hard/soft rules.
**Q: nodeAffinity operators?** → `In, NotIn, Exists, DoesNotExist, Gt, Lt`.
**Q: Hard vs soft nodeAffinity keys?** → `requiredDuringSchedulingIgnoredDuringExecution` (hard), `preferredDuringSchedulingIgnoredDuringExecution` (soft).
**Q: topologySpreadConstraints key fields?** → `maxSkew`, `topologyKey`, `whenUnsatisfiable`, `labelSelector`.
**Q: `whenUnsatisfiable` values?** → `DoNotSchedule` (hard), `ScheduleAnyway` (soft).
**Q: What does `maxSkew` bound?** → the maximum allowed difference in matching-pod count between any two topology domains.

### Deployments, config, autoscaling

**Q: Trigger and watch a rolling update?** → `k set image deploy/web c=nginx:1.27 && k rollout status deploy/web`.
**Q: Roll back a Deployment?** → `k rollout undo deploy/web` (`--to-revision=N` for a specific one).
**Q: See rollout history?** → `k rollout history deploy/web`.
**Q: The two rolling-update knobs?** → `maxSurge` and `maxUnavailable` (under `strategy.rollingUpdate`).
**Q: Load all keys of a ConfigMap as env vars?** → `envFrom: [{configMapRef: {name: cm}}]`.
**Q: Create a generic Secret from a literal?** → `k create secret generic s --from-literal=pass=x` (type `Opaque`, values base64 in `.data`).
**Q: Create an HPA imperatively?** → `k autoscale deploy web --min=2 --max=10 --cpu-percent=80`.
**Q: What must exist for an HPA to scale on CPU?** → CPU **requests** set on the pods, and metrics-server running.
**Q: What does a PriorityClass do, and how is it referenced?** → sets scheduling priority (higher can preempt lower); referenced via `priorityClassName` on the pod.

---

## Services & Networking (20%)

### Services & kube-proxy

**Q: NodePort default port range?** → 30000–32767 (apiserver flag `--service-node-port-range`).
**Q: Is a ClusterIP pingable?** → No — it's a virtual IP realized by iptables/IPVS rules, not bound to any interface; ICMP fails but TCP/UDP to the service port works.
**Q: kube-proxy modes?** → `iptables` (default), `ipvs`, `nftables` (newer); the old `userspace` mode is gone.
**Q: Default Service type?** → ClusterIP.
**Q: What does `k expose` create?** → a Service whose selector matches the target's pod labels.
**Q: What populates a Service's Endpoints / EndpointSlices?** → pods that match the selector **and** are Ready.
**Q: Service has zero endpoints — first two checks?** → selector labels vs pod labels, and pod readiness.
**Q: LoadBalancer Service in bare kind — external IP?** → stays `<pending>` without a provider/MetalLB; the NodePort it allocates still works.

### Cluster DNS

**Q: DNS record shape for a Service?** → `svc-name.namespace.svc.cluster.local`.
**Q: DNS A record for a Pod by IP?** → `pod-ip-dashed.namespace.pod.cluster.local` (e.g. `10-1-2-3.ns.pod.cluster.local`).
**Q: Headless Service DNS behavior?** → `clusterIP: None`; DNS returns each Ready pod's own A record (per-pod), no single VIP.
**Q: Which image gives reliable `nslookup` in drills, and why?** → `busybox:1.28`; newer busybox has a broken `nslookup` for cluster DNS.
**Q: One-liner to test DNS from a throwaway pod?** → `k run t --image=busybox:1.28 --restart=Never -it --rm -- nslookup <svc>`.
**Q: Which pods provide cluster DNS, and what fronts them?** → CoreDNS pods in `kube-system`, fronted by the `kube-dns` Service.
**Q: Typical cluster DNS service IP?** → the `.10` of the service CIDR (e.g. `10.96.0.10`).

### Ingress & Gateway API

**Q: Ingress apiVersion + kind?** → `networking.k8s.io/v1`, kind `Ingress`.
**Q: What ties an Ingress to a specific controller?** → `ingressClassName` (an IngressClass object).
**Q: What must be running for an Ingress to route at all?** → an Ingress controller (nginx, etc.).
**Q: Gateway API core apiVersion?** → `gateway.networking.k8s.io/v1`.
**Q: The three main Gateway API kinds?** → GatewayClass, Gateway, HTTPRoute.
**Q: How does an HTTPRoute attach to a Gateway?** → via `parentRefs`.

### NetworkPolicy

**Q: NetworkPolicy apiVersion?** → `networking.k8s.io/v1`.
**Q: Pod networking with no policy selecting it?** → all ingress and egress allowed (fully open).
**Q: What happens the moment a policy selects a pod for a direction?** → that direction becomes default-deny; only the listed rules are permitted.
**Q: Shape of a default-deny-all-ingress policy?** → `podSelector: {}` + `policyTypes: [Ingress]` with no ingress rules:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
```

**Q: The egress rule you must never forget when writing default-deny egress?** → allow DNS to kube-dns on **both** UDP 53 and TCP 53:

```yaml
egress:
- to: []
  ports:
  - protocol: UDP
    port: 53
  - protocol: TCP
    port: 53
```

**Q: Two separate list items under `from:` — AND or OR?** → OR (union of sources).
**Q: One `from:` item with both podSelector and namespaceSelector — AND or OR?** → AND (both must match).
**Q: What does `policyTypes` control?** → whether Ingress, Egress, or both are enforced for the selected pods.
**Q: To match a namespace by name in namespaceSelector, what must the namespace carry?** → a label, e.g. the automatic `kubernetes.io/metadata.name=<ns>`.
**Q: Fast doc path for a copy-paste NetworkPolicy?** → search "network policies"; the concept page has default-deny and allow examples.

---

## Storage (10%)

**Q: The four PV access modes?** → RWO (ReadWriteOnce), ROX (ReadOnlyMany), RWX (ReadWriteMany), RWOP (ReadWriteOncePod).
**Q: RWO scope — node or pod?** → node-level: one **node** mounts read-write (multiple pods on that node can share it).
**Q: RWOP scope?** → exactly **one pod** cluster-wide.
**Q: The two reclaim policies you actually use?** → `Retain` (keep data, clean up manually) and `Delete` (delete the backing volume); `Recycle` is deprecated.
**Q: Default reclaim policy for a dynamically provisioned PV?** → `Delete` (inherited from the StorageClass).
**Q: What does `volumeBindingMode: WaitForFirstConsumer` do?** → delays binding/provisioning until a pod using the PVC is scheduled (topology-aware).
**Q: The other volumeBindingMode value?** → `Immediate` (bind/provision as soon as the PVC is created).
**Q: What must match for a PVC to bind a PV?** → accessModes, capacity (PV ≥ PVC request), and storageClassName (plus a selector if set).
**Q: PVC stuck Pending with no dynamic provisioner — cause?** → no matching PV exists and no StorageClass is available to provision one.
**Q: Force a PVC to bind only pre-created PVs (no class)?** → set `storageClassName: ""`.
**Q: Annotation that marks a StorageClass as default?** → `storageclass.kubernetes.io/is-default-class: "true"`.
**Q: During binding, PV capacity vs PVC request?** → PV capacity must be **≥** the PVC's requested size.

---

## Troubleshooting (30%)

### Exit codes & pod states

**Q: Exit code 0?** → success / clean exit.
**Q: Exit code 1?** → general application error.
**Q: Exit code 137?** → 128+9, SIGKILL — usually OOMKilled or a forced kill.
**Q: Exit code 143?** → 128+15, SIGTERM — the graceful-termination signal.
**Q: General formula for signal exit codes?** → 128 + signal number.
**Q: What does CrashLoopBackOff mean?** → the container keeps exiting and the kubelet is backing off restarts (delay grows up to 5 min).

### Diagnosis flow

**Q: Standard pod-debug sequence?** → `k describe pod` (Events) → `k logs` (+`--previous`) → `k get events` → node/kubelet.
**Q: Read logs from a crashed *previous* container?** → `k logs <pod> -c <c> --previous`.
**Q: Pod stuck Pending — where's the reason?** → `k describe pod` Events (scheduler: insufficient cpu/mem, taints, unbound PVC).
**Q: ImagePullBackOff — what to check?** → image name/tag, registry auth (`imagePullSecrets`), and node network to the registry.
**Q: Node NotReady — first thing to check?** → the kubelet on that node (`systemctl status kubelet`, `journalctl -u kubelet`).

### Node & kubelet

**Q: Follow kubelet logs?** → `journalctl -u kubelet -f`.
**Q: kubelet config file path?** → `/var/lib/kubelet/config.yaml`.
**Q: Restart the kubelet?** → `systemctl restart kubelet`.
**Q: Node pressure conditions to look for?** → MemoryPressure, DiskPressure, PIDPressure (alongside Ready).

### Metrics & logs

**Q: Top pods by resource usage?** → `k top pods` (needs metrics-server).
**Q: Top nodes by resource usage?** → `k top nodes`.
**Q: Tail logs across all pods of a label?** → `k logs -l app=web -f --prefix`.

### Drain / cordon

**Q: Mark a node unschedulable without evicting?** → `k cordon <node>`.
**Q: Drain flags you almost always need?** → `--ignore-daemonsets --delete-emptydir-data`.
**Q: What does `k drain` actually do?** → cordons the node and evicts pods respecting PodDisruptionBudgets; DaemonSet pods require `--ignore-daemonsets`.
**Q: Undo a cordon/drain?** → `k uncordon <node>`.

### Component / API-down forensics

**Q: apiserver won't come up after you edited its static-pod manifest — where to look?** → kubelet logs (`journalctl -u kubelet`) and the manifest at `/etc/kubernetes/manifests/kube-apiserver.yaml`.
**Q: Inspect containers when `kubectl` itself is down?** → `crictl` (`crictl ps`, `crictl logs`) against the CRI socket.
