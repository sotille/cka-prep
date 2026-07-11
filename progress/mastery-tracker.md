# CKA Mastery Tracker

Per-competency mastery matrix. One table per exam domain; rows are the concrete sub-skills that make up each curriculum line from the coverage map (`course/00-exam-masterclass.md` §8). You mark each row over time until the whole board is green.

This is the **honesty ledger** for the course. The modules teach, the drills compress, this file tells you — coldly — what is actually exam-ready and what is still a liability.

## Legend

| Mark | Meaning |
|---|---|
| 🔴 | Not yet — can't do it, or only with heavy doc-crawling / hand-holding. |
| 🟡 | Slow-or-shaky — you get there, but over the time target, or with a wrong turn you had to back out of. |
| 🟢 | Fast-and-correct — done inside the time target, verified, no fumbling. |

**The rule (do not cheat it):** a row goes 🟢 **only when you did it correctly, UNDER the time target, WITHOUT docs** (or with only the one docs page the exam would also let you use, and still inside the clock). Docs time is task time. If you needed to look up the apiVersion, it is not 🟢. Verified-or-it-didn't-happen: an unverified pass is 🟡 at best.

## How to use with spaced repetition

- Fill **1st pass (date)** the first day you complete the sub-skill at all (any speed). This anchors the schedule.
- Fill **Timed <target?** with `Y`/`N` the first time you attempt it against the clock. The target is in the Competency cell (e.g. `≤4m`).
- Update **Confidence** every time you touch it. Only ever promote to 🟢 under the rule above; any fumble drops it a level.
- Set **Last drilled** to the date each time you re-drill.
- **Re-drill cadence by current colour:** 🔴 → **next day**; 🟡 → **in 3 days**; 🟢 → **weekly** (then graduate to the twice-weekly speed-drill circuits). A 🟢 you haven't touched in >10 days is no longer 🟢 — knock it to 🟡 and re-time it.
- Work weight-first: the tables are ordered by exam weight. When time is short, drill top-of-page.

Blank cells: `—` = not started. Fill dates as `MM-DD`.

---

## Troubleshooting — 30%

Primary: `course/week-09-troubleshooting`, reinforced across `course/week-04-lifecycle-observability` and `labs/breakfix`. The biggest domain — no 🔴 allowed here to pass the gate.

| Competency (sub-skill, time target) | Module | 1st pass (date) | Timed <target? | Confidence | Last drilled |
|---|---|---|---|---|---|
| Clusters/nodes: Node NotReady → diagnose to kubelet (≤6m) | week-09 | — | — | 🔴 | — |
| Clusters/nodes: read `journalctl -u kubelet` and act (≤4m) | week-09 | — | — | 🔴 | — |
| Clusters/nodes: cordon → drain (`--ignore-daemonsets --delete-emptydir-data`) → uncordon (≤4m) | week-09 | — | — | 🔴 | — |
| Clusters/nodes: node kubeconfig/cert path problems (≤6m) | week-09 | — | — | 🔴 | — |
| Clusters/nodes: recognize Memory/Disk/PID pressure from `describe node` (≤3m) | week-09 | — | — | 🔴 | — |
| Components: apiserver static-pod down → fix manifest + kubelet (≤8m) | week-09 | — | — | 🔴 | — |
| Components: etcd health / member check with certs (≤6m) | week-05 | — | — | 🔴 | — |
| Components: scheduler / controller-manager static-pod logs (≤5m) | week-09 | — | — | 🔴 | — |
| Components: `crictl ps` / `crictl logs` when kubectl is down (≤5m) | week-09 | — | — | 🔴 | — |
| Components: restart a static pod by moving its manifest (≤3m) | week-09 | — | — | 🔴 | — |
| Resource usage: `k top nodes` / `k top pods` read-and-interpret (≤2m) | week-04 | — | — | 🔴 | — |
| Resource usage: install/verify metrics-server (≤5m) | week-04 | — | — | 🔴 | — |
| Resource usage: `describe node` allocated vs capacity to find the culprit (≤4m) | week-04 | — | — | 🔴 | — |
| Logs: `k logs` current + `--previous` for a crashed container (≤2m) | week-04 | — | — | 🔴 | — |
| Logs: multi-container `-c` and label `-l` streaming (≤2m) | week-04 | — | — | 🔴 | — |
| Logs: correlate `describe` Events with logs to name a root cause (≤4m) | week-04 | — | — | 🔴 | — |
| Services/net: svc → endpoints → pod-readiness chase (≤5m) | week-09 | — | — | 🔴 | — |
| Services/net: DNS check from `busybox:1.28` (≤3m) | week-09 | — | — | 🔴 | — |
| Services/net: spot a NetworkPolicy blocking traffic (≤5m) | week-09 | — | — | 🔴 | — |
| Services/net: kube-proxy / iptables sanity check (≤5m) | week-09 | — | — | 🔴 | — |

---

## Cluster Architecture — 25%

Primary: `course/week-01-architecture`, `course/week-05-cluster-maintenance`, `course/week-06-security-rbac`. The other gate domain — every row must reach 🟢.

| Competency (sub-skill, time target) | Module | 1st pass (date) | Timed <target? | Confidence | Last drilled |
|---|---|---|---|---|---|
| RBAC: create Role + RoleBinding imperatively (≤3m) | week-06 | — | — | 🔴 | — |
| RBAC: create ClusterRole + ClusterRoleBinding (≤3m) | week-06 | — | — | 🔴 | — |
| RBAC: reuse a ClusterRole via a namespaced RoleBinding (≤3m) | week-06 | — | — | 🔴 | — |
| RBAC: verify with `k auth can-i --as` (user + SA) (≤2m) | week-06 | — | — | 🔴 | — |
| RBAC: wire ServiceAccount → RoleBinding → pod (≤5m) | week-06 | — | — | 🔴 | — |
| RBAC: issue a user cert via CSR (signerName + approve) (≤8m) | week-06 | — | — | 🔴 | — |
| Infra prep: kernel modules + sysctl (br_netfilter, overlay) (≤5m) | week-01 | — | — | 🔴 | — |
| Infra prep: containerd runtime + CRI socket (≤5m) | week-01 | — | — | 🔴 | — |
| Infra prep: install kubeadm/kubelet/kubectl from `pkgs.k8s.io` (≤5m) | week-05 | — | — | 🔴 | — |
| kubeadm: `kubeadm init` with pod CIDR + admin.conf → kubeconfig (≤8m) | week-05 | — | — | 🔴 | — |
| kubeadm: join a worker + regenerate a join token (≤5m) | week-05 | — | — | 🔴 | — |
| kubeadm: install a CNI and confirm nodes Ready (≤5m) | week-05 | — | — | 🔴 | — |
| Lifecycle: `kubeadm upgrade plan` + repo bump one minor (≤4m) | week-05 | — | — | 🔴 | — |
| Lifecycle: upgrade control plane (`upgrade apply`) (≤8m) | week-05 | — | — | 🔴 | — |
| Lifecycle: upgrade worker (`upgrade node` → drain → kubelet → uncordon) (≤8m) | week-05 | — | — | 🔴 | — |
| Lifecycle: etcd snapshot **save** (etcdctl) with cert flags (≤5m) | week-05 | — | — | 🔴 | — |
| Lifecycle: etcd snapshot **restore/status** (etcdutl, 3.6) (≤8m) | week-05 | — | — | 🔴 | — |
| HA: stacked vs external etcd + quorum math (≤4m) | week-05 | — | — | 🔴 | — |
| HA: LB in front of apiservers; add 2nd control-plane node (≤8m) | week-05 | — | — | 🔴 | — |
| Packaging: `helm install/upgrade/uninstall` + `helm template` (≤5m) | week-02 | — | — | 🔴 | — |
| Packaging: `kubectl -k` overlay with image/patch (≤5m) | week-02 | — | — | 🔴 | — |
| Extension IF: identify CRI socket + use crictl (≤3m) | week-01 | — | — | 🔴 | — |
| Extension IF: map a symptom to CNI vs CSI vs CRI (≤3m) | week-01 | — | — | 🔴 | — |
| CRDs: apply a CRD, confirm Established, create a CR (≤5m) | week-01 | — | — | 🔴 | — |
| CRDs: install an operator and inspect its owned resources (≤6m) | week-01 | — | — | 🔴 | — |

---

## Services & Networking — 20%

Primary: `course/week-08-networking`, reinforced in `course/week-09-troubleshooting`.

| Competency (sub-skill, time target) | Module | 1st pass (date) | Timed <target? | Confidence | Last drilled |
|---|---|---|---|---|---|
| Pod connectivity: pod-to-pod by IP and via ClusterIP (≤3m) | week-08 | — | — | 🔴 | — |
| Pod connectivity: cross-namespace FQDN reach (≤3m) | week-08 | — | — | 🔴 | — |
| Pod connectivity: read Endpoints / EndpointSlice for a svc (≤2m) | week-08 | — | — | 🔴 | — |
| NetworkPolicy: default-deny ingress (≤4m) | week-08 | — | — | 🔴 | — |
| NetworkPolicy: allow from podSelector (≤4m) | week-08 | — | — | 🔴 | — |
| NetworkPolicy: allow from namespaceSelector (labelled ns) (≤4m) | week-08 | — | — | 🔴 | — |
| NetworkPolicy: egress default-deny + DNS 53 (UDP+TCP) allow (≤6m) | week-08 | — | — | 🔴 | — |
| NetworkPolicy: reason AND vs OR in a `from:` block (≤2m) | week-08 | — | — | 🔴 | — |
| Services: expose ClusterIP + verify endpoints (≤2m) | week-08 | — | — | 🔴 | — |
| Services: NodePort in 30000–32767 + reach it (≤3m) | week-08 | — | — | 🔴 | — |
| Services: LoadBalancer behavior in kind (pending EIP) (≤2m) | week-08 | — | — | 🔴 | — |
| Services: debug an empty-endpoints service (≤4m) | week-08 | — | — | 🔴 | — |
| Services: headless service per-pod records (≤3m) | week-08 | — | — | 🔴 | — |
| Gateway API: install CRDs/controller + GatewayClass/Gateway (≤8m) | week-08 | — | — | 🔴 | — |
| Gateway API: HTTPRoute host/path attached via parentRefs (≤6m) | week-08 | — | — | 🔴 | — |
| Ingress: deploy controller + Ingress host/path + ingressClassName (≤8m) | week-08 | — | — | 🔴 | — |
| Ingress: attach a TLS secret to an Ingress (≤5m) | week-08 | — | — | 🔴 | — |
| CoreDNS: resolve svc + pod dashed record from busybox:1.28 (≤3m) | week-08 | — | — | 🔴 | — |
| CoreDNS: edit the Corefile (forward/hosts) and reload (≤5m) | week-08 | — | — | 🔴 | — |

---

## Workloads & Scheduling — 15%

Primary: `course/week-02-workloads-config`, `course/week-03-scheduling`, `course/week-04-lifecycle-observability`.

| Competency (sub-skill, time target) | Module | 1st pass (date) | Timed <target? | Confidence | Last drilled |
|---|---|---|---|---|---|
| Deployments: create + scale imperatively with `$do` (≤2m) | week-02 | — | — | 🔴 | — |
| Deployments: `set image` + `rollout status` (≤2m) | week-02 | — | — | 🔴 | — |
| Deployments: `rollout undo` + `rollout history` (≤2m) | week-02 | — | — | 🔴 | — |
| Deployments: tune maxSurge / maxUnavailable (≤4m) | week-02 | — | — | 🔴 | — |
| Config: ConfigMap from literal/file → env (envFrom) + volume (≤4m) | week-02 | — | — | 🔴 | — |
| Config: Secret → env and volume mount (≤4m) | week-02 | — | — | 🔴 | — |
| HPA: `k autoscale` (requests + metrics-server present) (≤3m) | week-02 | — | — | 🔴 | — |
| Probes: livenessProbe httpGet with timing fields (≤4m) | week-04 | — | — | 🔴 | — |
| Probes: readinessProbe gating endpoints (≤4m) | week-04 | — | — | 🔴 | — |
| Probes: startupProbe for a slow starter (≤4m) | week-04 | — | — | 🔴 | — |
| Scheduling: set requests/limits + predict QoS class (≤3m) | week-03 | — | — | 🔴 | — |
| Scheduling: taint a node + tolerate it (≤3m) | week-03 | — | — | 🔴 | — |
| Scheduling: nodeSelector / nodeAffinity (operators) (≤5m) | week-03 | — | — | 🔴 | — |
| Scheduling: topologySpreadConstraints (maxSkew/whenUnsatisfiable) (≤5m) | week-03 | — | — | 🔴 | — |
| Scheduling: PriorityClass + observe preemption (≤5m) | week-03 | — | — | 🔴 | — |

---

## Storage — 10%

Primary: `course/week-07-storage`. Lightest domain — cap the time you spend, but every row still needs to reach at least 🟡 and no 🔴 by exam day.

| Competency (sub-skill, time target) | Module | 1st pass (date) | Timed <target? | Confidence | Last drilled |
|---|---|---|---|---|---|
| StorageClass: create with provisioner/reclaimPolicy/bindingMode (≤4m) | week-07 | — | — | 🔴 | — |
| StorageClass: mark one default + confirm annotation (≤2m) | week-07 | — | — | 🔴 | — |
| Dynamic prov: PVC triggers a dynamic PV (≤3m) | week-07 | — | — | 🔴 | — |
| Dynamic prov: observe WaitForFirstConsumer binding timing (≤3m) | week-07 | — | — | 🔴 | — |
| Volumes: pick correct access mode RWO/ROX/RWX/RWOP (≤2m) | week-07 | — | — | 🔴 | — |
| Volumes: Retain vs Delete reclaim behavior after PVC delete (≤4m) | week-07 | — | — | 🔴 | — |
| PV/PVC: static PV + PVC bind (capacity/mode/class match) (≤4m) | week-07 | — | — | 🔴 | — |
| PV/PVC: mount a PVC into a pod and write to it (≤3m) | week-07 | — | — | 🔴 | — |
| PV/PVC: diagnose a Pending PVC (≤4m) | week-07 | — | — | 🔴 | — |

---

## Exam-readiness gate

You are ready to sit the CKA when **both** conditions hold:

1. **Every competency in the 30% (Troubleshooting) and 25% (Cluster Architecture) domains is 🟢** — those two domains are 55% of the exam and produce the most predictable, scriptable tasks. No 🟡, no 🔴, in either table.
2. **No domain contains a single 🔴.** Services & Networking, Workloads & Scheduling, and Storage may still carry a few 🟡, but nothing red anywhere on the board.

Until both are true, keep drilling the reddest, heaviest rows first: a 🔴 in Troubleshooting outranks a 🟡 in Storage every single time. Re-run the timed circuits in `drills/speed-drills.md` and log the colour changes here after each session.
