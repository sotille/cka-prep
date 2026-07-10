# 00 — Exam Masterclass: Passing Mechanics for the CKA (applies to 100% of the exam)

This module is not about Kubernetes. It is about the other exam you are silently taking at the same time: the 2-hour, remote-desktop, docs-only, partial-credit exam format. People who know Kubernetes fail the CKA because they lose 20 minutes to the environment, burn 15 minutes on a 4% question, or never run the context-switch command. Everything below is format, strategy, and speed. Content lives in weeks 01–10.

One caveat that applies to this entire course: the CKA tracks upstream Kubernetes (exam version updates about three times a year, 4–8 weeks after each Kubernetes minor release). Before exam day, check the current exam Kubernetes version and competency list on the CNCF curriculum page (github.com/cncf/curriculum) — that page, not this repo, is authoritative.

---

## 1. The CKA in 2026: what changed in February 2025

The curriculum was restructured on **February 18, 2025**. Domain weights moved, and net-new topics were added. If you are studying from pre-2025 material (most YouTube courses, most Udemy content recorded before 2025, and — see below — parts of this repo's own notes), your priorities are miscalibrated.

Current domain weights:

| Domain | Weight | What it actually means on exam day |
|---|---|---|
| **Troubleshooting** | **30%** | Broken nodes, broken control-plane components, crashed pods, dead services, DNS failures. The single biggest domain. |
| **Cluster Architecture, Installation & Configuration** | **25%** | RBAC, kubeadm cluster lifecycle, HA control plane, **Helm, Kustomize, CRDs/operators, extension interfaces (CNI/CSI/CRI)** |
| **Services & Networking** | **20%** | Services, Ingress, **Gateway API**, NetworkPolicy, CoreDNS |
| **Workloads & Scheduling** | **15%** | Deployments, rollouts, ConfigMaps/Secrets, **autoscaling**, pod admission and scheduling |
| **Storage** | **10%** | StorageClasses, **dynamic provisioning**, PV/PVC, access modes, reclaim policies |

### Correction to this repo

`notes/week-08-networking.md` is headlined "**30% OF EXAM**". That figure comes from **pre-2025** study material. Under the current (post-Feb-2025) curriculum it is wrong: **Troubleshooting is the 30% domain; Services & Networking is 20%.**

Practical consequence: week 8 (networking) is still critical — networking failures are also a large slice of the troubleshooting domain, so the material double-dips. But **week 9 (troubleshooting) is the week that decides your exam**. If you have to choose where extra hours go, they go to troubleshooting drills, not to a fourth pass over Service types.

Topics added in Feb 2025 that older material skips entirely:

- Helm and Kustomize (install cluster components, template/patch manifests)
- Gateway API (`gateway.networking.k8s.io/v1` — GatewayClass, Gateway, HTTPRoute)
- CRDs and operators (find, inspect, and use custom resources)
- Dynamic storage provisioning (StorageClass-driven, not just manual PV creation)
- Extension interfaces awareness: CNI, CSI, CRI — including installing/recognizing a CNI plugin

Dropped or de-emphasized: manual scheduling minutiae, some kubeadm install-from-scratch weight moved toward *lifecycle* (upgrades, HA) rather than greenfield installs.

---

## 2. The exam environment: PSI Bridge remote desktop

You do not take the exam in your own terminal. You take it in **PSI Bridge**: a locked-down secure browser on your machine streams a **remote XFCE Linux desktop**. Inside that remote desktop you get a terminal (xfce4-terminal) and **Firefox**. Everything you type traverses your network to a remote VM — expect latency. If your daily driver is a tuned zsh with fzf and a 4K terminal, exam day will feel like typing through molasses. Train for it: your kind lab is fast; occasionally practice over an SSH session to a cloud VM to simulate lag.

### Firefox: what you can open

Firefox inside the remote desktop is restricted to:

- `kubernetes.io/docs` and `kubernetes.io/blog`
- `helm.sh/docs`

Nothing else. No Stack Overflow, no GitHub, no Google. Subdomains and other paths are blocked. This is why Section 6 (docs navigation) exists — the docs site search box is your only search engine.

### Copy/paste: the number-one environment trap

Clipboard behavior differs between the Firefox window and the terminal:

| Where | Copy | Paste |
|---|---|---|
| Firefox (docs) | `ctrl+c` | `ctrl+v` |
| Terminal | `ctrl+shift+c` | **`ctrl+shift+v`** |

`ctrl+v` in the terminal does nothing useful; `ctrl+c` in the terminal sends SIGINT and kills whatever is running. The muscle-memory failure mode: you copy YAML from the docs with `ctrl+c`, switch to the terminal, hit `ctrl+c` again "to be sure" — and interrupt your running command. Drill `ctrl+shift+v` until it is automatic. Right-click → Paste also works in the terminal if you blank on the shortcut. You **cannot** copy from your local machine into the remote desktop — everything starts inside the environment.

### Context switching: the silent zero

Every task begins with a line like:

```bash
kubectl config use-context kind-cka   # the exam prints the exact command per task
```

The real exam has 5–7 clusters behind one jump host, and each task tells you exactly which context to use. **Run the given command first, every task, even if you believe you are already on the right context.** Solving a task perfectly on the wrong cluster scores zero, and the grader gives no warning. Make it a reflex: read task → paste context command → then read the rest.

Verify when in doubt:

```bash
k config current-context
k get nodes   # sanity: does the node list match the cluster the task describes?
```

### SSH to nodes and the sudo pattern

Some tasks (kubelet repair, kubeadm upgrade, etcd backup) require you to work **on a node**, not from the jump host:

```bash
ssh cluster1-node1     # hostname is given in the task
sudo -i                # root shell; most node-level work needs it
# ... do the work ...
exit                   # leave root shell
exit                   # leave the node — BACK ON THE JUMP HOST
```

Two rules, both worth points:

1. **`kubectl` generally only works from the jump host** (that is where the kubeconfigs live). If `kubectl` suddenly errors with connection refused to localhost:8080, check your prompt — you are probably still root on a node.
2. **Always exit back.** Twice (`sudo -i` shell, then the SSH session). Starting the next task while stranded on the wrong host as root is a classic compound error: you lose time diagnosing why nothing works, and in the worst case you modify the wrong machine.

Exam-flavor note for this repo's lab: your kind "nodes" are containers — `docker exec -it cka-worker bash` replaces `ssh`, and you are already root. The *discipline* (get in, do the work, get out, verify from outside) is what you are training.

### The exam UI: flags and notepad

The PSI exam interface has a question list, a **flag** feature, and a built-in **notepad**. Use both; do not skip them:

- Flag every task you skip or half-finish. On your second pass, the flag list *is* your work queue.
- The notepad is the only note-taking allowed (no paper, no local text editor counts). Keep a running log: `Q7 flagged - netpol egress unclear / Q12 done but verify rollout / Q15 skipped - upgrade, big`. Two-hour exams destroy short-term memory; the notepad is external memory.

Environment misc: one active monitor only, webcam proctoring, clean desk, no talking/reading questions aloud. Check-in (ID verification, room scan) takes up to 30 minutes — arrive early; that time does not eat your 2 hours.

---

## 3. Time management: the 7-minute economy

The math: **120 minutes, 15–20 tasks** → about **7 minutes average per task** including reading, verification, and second-pass reviews. Some tasks are 90-second one-liners; some are legitimate 12-minute multi-step builds. The average only works if you harvest the cheap tasks fast.

### Triage protocol (first pass)

For each task, in order:

1. **Run the context-switch command.**
2. **Read the task and its weight** (each task shows a percentage, typically 4–13%).
3. **Form a plan in under 2 minutes.** If you can see the whole solution path — attempt it now.
4. If no plan forms in 2 minutes, or the task is a known time-sink for you: **flag, note it in the notepad, skip.** No guilt. A 4% task and a 13% task cost the same skipped, but not the same solved.
5. **Hard cap: 10 minutes per task on the first pass.** Set the discipline now in your mocks. If you hit 10 minutes, write down where you got stuck, flag, move on. Sunk-cost is the top killer of capable candidates.

### Partial credit is real — exploit it

Tasks are scored by **independent steps**, not all-or-nothing. A task worth 8% might be: create a PV (scored), create a PVC that binds it (scored), mount it in a pod (scored). Getting 2 of 3 steps banks most of the points.

Consequences:

- **Never leave a task untouched if you can do even the first step.** Creating the namespace, the bare Deployment, the Role without the binding — all of it can score.
- Do the scoring-relevant steps first. If a task says "create a Deployment with X, Y, and expose it", the Deployment is worth more than the Service — do not perfect the Service annotation while the Deployment sits uncreated.
- **Verify cheaply after every task**: `k get <thing> -n <ns>` plus one behavioral check (`k rollout status`, `k run tmp --rm -it --image=busybox:1.36 -- wget -qO- <svc>`). 20 seconds of verification protects 7 minutes of work.

### Second pass

With ~20–30 minutes left, stop opening new hard tasks. Walk the flag list: finish half-done tasks (partial credit again), then attempt skipped ones cheapest-first. Last 5 minutes: verify, don't create. A wrong edit at minute 118 with no time to check it is negative expected value.

---

## 4. The first 5 minutes: setup routine

The environment ships with `kubectl` and bash completion mostly configured, but do not assume — build the same cockpit every time, exam and practice. This is the exact block this course assumes in every solution:

```bash
alias k=kubectl
export do="--dry-run=client -o yaml"
export now="--grace-period=0 --force"
```

Usage everywhere in this course: `k run web --image=nginx $do > pod.yaml`, `k delete pod broken $now`.

Completion (usually pre-configured; two lines if not):

```bash
source <(kubectl completion bash)
complete -o default -F __start_kubectl k   # make completion work for the alias too
```

Vim, because you will live in `k edit` and manifest files — YAML dies on tabs, so:

```bash
cat >> ~/.vimrc <<'EOF'
set ts=2 sw=2 et
set number
EOF
```

(`ts`=tabstop, `sw`=shiftwidth, `et`=expandtab: the Tab key now inserts 2 spaces. `:set paste` before pasting YAML into vim if auto-indent mangles it, `:set nopaste` after.)

Finally, orient yourself:

```bash
k config get-contexts        # what clusters exist
k config current-context     # where am I NOW
k get nodes -o wide          # what does this cluster look like
```

Total budget: **under 3 minutes**. Practice the block until you can type it from memory — you will also re-type the alias lines after every `ssh` to a node if you need them there (aliases do not follow you across SSH).

What you may NOT do: install tools, modify the proctoring environment, open non-allowed sites. Everything above is exam-legal shell configuration.

---

## 5. Question-pattern taxonomy: recipes

Roughly eight patterns cover nearly every CKA task. Know the recipe cold; the specific nouns change, the shape does not.

### 5.1 Create-object ("Create a Deployment/Pod/CronJob with ...")

1. Generate, never hand-write: `k create deploy app --image=nginx --replicas=3 $do > app.yaml` (or `k run`, `k create cronjob ... --schedule="*/5 * * * *"`).
2. Edit the YAML to add what the generator can't (resources, probes, volumes, affinity).
3. `k apply -f app.yaml`.
4. Verify: `k get deploy app -n <ns>` and status is Ready.

If the object type has no generator (PV, NetworkPolicy, HTTPRoute): copy the example from the docs page (Section 6), then edit names/selectors. Never write these from a blank buffer.

### 5.2 Fix-broken-thing ("Pod X in namespace Y is not running")

1. `k get pod X -n Y` → read STATUS (Pending/CrashLoopBackOff/ImagePullBackOff/Error each has a distinct playbook).
2. `k describe pod X -n Y` → Events section bottom-up: scheduling failures, image errors, probe failures, mount errors all surface here.
3. `k logs X -n Y --previous` if it started and died; `-c <container>` for multi-container pods.
4. Fix the smallest thing that explains the evidence (image typo, missing ConfigMap, wrong nodeSelector, resource request > node capacity).
5. Verify it actually recovers: `k get pod X -n Y -w` for a few seconds. Do not trust `Running` alone — check READY `1/1`.

Node/component variant: `k get nodes` → NotReady → `ssh node` → `sudo -i` → `systemctl status kubelet`, `journalctl -u kubelet -e --no-pager | tail -30`; for control-plane pods check `/etc/kubernetes/manifests/` for a mangled static-pod manifest and `crictl ps -a` when the apiserver itself is down.

### 5.3 Upgrade / backup ("Upgrade the control plane to X" / "Snapshot etcd")

1. Docs open first — kubeadm upgrade and etcd backup pages have the full command sequences; do not free-hand.
2. Upgrade order is law: upgrade the kubeadm package first → `kubeadm upgrade plan` → `kubeadm upgrade apply vX.Y.Z` (control plane) / `kubeadm upgrade node` (workers) → then kubelet+kubectl packages → `systemctl daemon-reload && systemctl restart kubelet`. The old kubeadm binary cannot plan or apply a version newer than itself. Drain before, uncordon after, one node at a time.
3. etcd backup: `ETCDCTL_API=3 etcdctl snapshot save /path/backup.db` with `--endpoints`, `--cacert`, `--cert`, `--key` read from the etcd static-pod manifest (`/etc/kubernetes/manifests/etcd.yaml`).
4. Verify: `k get nodes` shows new version / `etcdctl snapshot status /path/backup.db -w table`.

### 5.4 RBAC grant ("Allow SA/user X to do Y on Z")

1. Decide scope: namespaced → Role+RoleBinding; cluster-wide or non-namespaced resources (nodes, PVs) → ClusterRole+ClusterRoleBinding.
2. `k create role r1 --verb=get,list --resource=pods -n ns $do` — the imperative generators handle all four object kinds.
3. `k create rolebinding rb1 --role=r1 --serviceaccount=ns:sa-name -n ns` (or `--user=`).
4. Verify with the built-in oracle: `k auth can-i list pods --as system:serviceaccount:ns:sa-name -n ns` → must print `yes` (and a negative check for something not granted).

### 5.5 Expose / route traffic ("Make Deployment X reachable ...")

1. `k expose deploy X --port=80 --target-port=8080 --name=svc-x -n ns` (add `--type=NodePort` if asked; set the specific nodePort by editing after).
2. Ingress: `k create ingress ing1 --rule="host/path=svc-x:80" $do > ing.yaml`, adjust pathType/ingressClassName.
3. Gateway API: no generator — copy Gateway+HTTPRoute skeletons from the docs, wire `parentRefs` → Gateway, `backendRefs` → Service.
4. Verify from inside: `k run tmp --rm -it --restart=Never --image=busybox:1.36 -- wget -qO- svc-x.ns.svc.cluster.local`.
5. Trap check: Service selector must match pod labels — `k get endpoints svc-x -n ns` empty means selector mismatch, and that is a troubleshooting task in disguise.

### 5.6 NetworkPolicy restriction ("Only allow A to talk to B on port P")

1. Copy the canonical example from the NetworkPolicy docs page — never from memory.
2. Set `podSelector` to the *target* (the pods being protected), `policyTypes` to what you constrain.
3. Build `ingress.from` / `egress.to` with podSelector/namespaceSelector — remember: two selectors in **one list item** = AND, two **list items** = OR.
4. Remember DNS: an egress-restricting policy usually needs UDP/TCP 53 allowed or everything breaks.
5. Verify with two `wget` probes: one that must succeed, one that must fail (timeout = blocked).

### 5.7 Storage binding ("Create a PV/PVC and use it in a pod")

1. PV (if manual provisioning asked): copy hostPath/local PV example from docs; match `capacity`, `accessModes`, `storageClassName` exactly to what the task dictates.
2. PVC: same `storageClassName` (or none for static binding to a classless PV), accessModes must be a subset, request ≤ capacity.
3. `k get pvc -n ns` → STATUS `Bound` before touching the pod. Pending PVC = mismatch in class/mode/size; fix that first.
4. Pod: `volumes.persistentVolumeClaim.claimName` + `volumeMounts` — generate the pod with `$do`, add the two stanzas.
5. Dynamic-provisioning variant: the task gives a StorageClass or asks you to create one (`provisioner`, `volumeBindingMode: WaitForFirstConsumer` means PVC stays Pending until a pod uses it — that is normal, not broken).

### 5.8 Node maintenance ("Take node X out of service ...")

1. `k drain nodeX --ignore-daemonsets --delete-emptydir-data` (add `--force` only if it complains about unmanaged pods and the task permits losing them).
2. Do the maintenance (upgrade, config change, reboot).
3. `k uncordon nodeX` — forgetting this loses the "node is schedulable again" point.
4. Verify: `k get nodes` → Ready, no `SchedulingDisabled`; check pods rescheduled.
5. Distinguish verbs: `cordon` = stop new pods only; `drain` = cordon + evict existing. Tasks choose their words deliberately.

---

## 6. Docs navigation masterclass

The kubernetes.io search box is decent, but exact search terms land you on the right page in one hop, and knowing *which pages carry copy-paste-ready YAML* is the actual skill. Bookmarks are allowed only in the sense that you may pre-know URLs; you cannot import bookmarks — so memorize search terms, not URLs.

| You need | Type into kubernetes.io search | Lands on (docs path) | Copy-paste YAML? |
|---|---|---|---|
| Any kubectl syntax | `kubectl quick reference` | reference/kubectl/quick-reference/ | commands, not YAML |
| Pod with volume/probe/env skeletons | `configure pod volume` | tasks/configure-pod-container/... task pages | **yes — best generators-gap filler** |
| PV + PVC + pod, full chain | `configure persistent volume storage` | tasks/configure-pod-container/configure-persistent-volume-storage/ | **yes — all three objects on one page** |
| StorageClass reference | `storage classes` | concepts/storage/storage-classes/ | yes |
| NetworkPolicy | `network policies` | concepts/services-networking/network-policies/ | **yes — the canonical full example** |
| Ingress | `ingress` | concepts/services-networking/ingress/ | yes (minimal + fanout + TLS) |
| Gateway API | `gateway` | concepts/services-networking/gateway/ | yes (Gateway + HTTPRoute) |
| Service types | `service` | concepts/services-networking/service/ | yes |
| DNS record shapes / debugging | `dns debugging` | tasks/administer-cluster/dns-debugging-resolution/ | yes (dnsutils pod) |
| RBAC verbs/objects reference | `rbac` | reference/access-authn-authz/rbac/ | yes |
| kubeadm upgrade sequence | `kubeadm upgrade` | tasks/administer-cluster/kubeadm/kubeadm-upgrade/ | **yes — full command sequence, follow top to bottom** |
| etcd backup/restore | `operating etcd` | tasks/administer-cluster/configure-upgrade-etcd/ | yes (snapshot save/restore) |
| Static pods | `static pod` | tasks/configure-pod-container/static-pod/ | yes |
| Drain/cordon | `safely drain node` | tasks/administer-cluster/safely-drain-node/ | commands |
| Taints/tolerations | `taint and toleration` | concepts/scheduling-eviction/taint-and-toleration/ | yes |
| Affinity/nodeSelector | `assign pods nodes affinity` | concepts/scheduling-eviction/assign-pod-node/ | yes |
| HPA | `horizontal pod autoscale walkthrough` | tasks/run-application/horizontal-pod-autoscale-walkthrough/ | yes |
| Rolling updates/rollback | `deployment` | concepts/workloads/controllers/deployment/ | yes + rollout commands |
| Init containers / sidecars | `init containers` / `sidecar containers` | concepts/workloads/pods/init-containers/ | yes |
| ConfigMap/Secret in pods | `configure pod configmap` / `distribute credentials` | tasks/configure-pod-container/configure-pod-configmap/ | yes |
| Kustomize | `kustomization` | tasks/manage-kubernetes-objects/kustomization/ | yes (kustomization.yaml examples) |
| CRDs | `custom resource definition` | tasks/extend-kubernetes/custom-resources/custom-resource-definitions/ | yes |
| JSONPath / sorting output | `jsonpath` | reference/kubectl/jsonpath/ | expressions |
| Helm anything | search on **helm.sh/docs** | helm.sh/docs/helm/ (command reference) | commands |

Technique notes:

- **Prefer `tasks/` pages over `concepts/` pages when you need YAML to steal.** Concepts explain; tasks hand you working manifests.
- Use the browser's find (`ctrl+f`) inside long pages — "kind: PersistentVolume" jumps straight to the manifest.
- The one-page **kubectl quick reference** covers 80% of imperative syntax you might blank on (`--sort-by`, `-o jsonpath`, rollout commands). Know it exists; open it early in the exam and leave the tab open.
- Tab discipline: keep 2–3 tabs max (quick reference + current task's page). Twelve open tabs in a laggy remote Firefox is self-sabotage.

---

## 7. Scoring, results, retake

- **Pass mark: 66%.** Score is the weighted sum over tasks; within a task, steps score independently (Section 3).
- **No penalty for wrong answers** — an attempted-and-wrong task scores the same as a skipped one. Attempt everything you have time for.
- **Results arrive by email within 24 hours** of finishing. You get a score, not a per-task breakdown.
- **One free retake** is included with the exam purchase. It removes catastrophic-failure pressure but do not schedule your first attempt as a "recon run" — killer.sh is your recon (Section 9); the retake is insurance for environment disasters and bad days.
- Certification is valid for **2 years**; the exam voucher itself is valid 12 months from purchase, and you must sit the retake within that window too.
- **killer.sh simulator is bundled**: two sessions, **36 hours of cluster access each**, both sessions contain the **same** question set. It is deliberately harder than the real exam — scoring ~60–70% on killer.sh typically means you are ready.

---

## 8. Curriculum coverage map (2025 curriculum → this course)

Every competency line from the current CKA curriculum, mapped to where this course covers it. Cross-cutting reinforcement: every domain also appears in `mock-exams/mock-exam-1..3` (full 2-hour simulations), `labs/breakfix` (pre-broken scenarios), and `drills/speed-drills.md` (timed repetition) — the table lists those only where they are a primary vehicle.

| Domain | Competency (curriculum line) | Primary module | Reinforced in |
|---|---|---|---|
| Cluster Architecture (25%) | Manage role based access control (RBAC) | course/week-06-security-rbac | drills/speed-drills.md, mock-exams |
| Cluster Architecture (25%) | Prepare underlying infrastructure for installing a Kubernetes cluster | course/week-01-architecture | course/week-05-cluster-maintenance |
| Cluster Architecture (25%) | Create and manage Kubernetes clusters using kubeadm | course/week-05-cluster-maintenance | labs/breakfix |
| Cluster Architecture (25%) | Manage the lifecycle of Kubernetes clusters (upgrades) | course/week-05-cluster-maintenance | mock-exams |
| Cluster Architecture (25%) | Implement and configure a highly-available control plane | course/week-05-cluster-maintenance | course/week-01-architecture |
| Cluster Architecture (25%) | Use Helm and Kustomize to install cluster components | course/week-02-workloads-config | course/week-10-final-prep |
| Cluster Architecture (25%) | Understand extension interfaces (CNI, CSI, CRI) | course/week-01-architecture | course/week-08-networking (CNI), course/week-07-storage (CSI) |
| Cluster Architecture (25%) | Understand CRDs, install and configure operators | course/week-02-workloads-config | course/week-10-final-prep |
| Workloads & Scheduling (15%) | Application deployments, rolling updates and rollbacks | course/week-02-workloads-config | drills/speed-drills.md |
| Workloads & Scheduling (15%) | Use ConfigMaps and Secrets to configure applications | course/week-02-workloads-config | drills/speed-drills.md |
| Workloads & Scheduling (15%) | Configure workload autoscaling (HPA) | course/week-03-scheduling | mock-exams |
| Workloads & Scheduling (15%) | Primitives for robust, self-healing application deployments | course/week-04-lifecycle-observability (probes) | course/week-02-workloads-config |
| Workloads & Scheduling (15%) | Configure pod admission and scheduling (limits, affinity, taints) | course/week-03-scheduling | labs/breakfix |
| Services & Networking (20%) | Understand connectivity between Pods | course/week-08-networking | course/week-09-troubleshooting |
| Services & Networking (20%) | Define and enforce Network Policies | course/week-08-networking | mock-exams |
| Services & Networking (20%) | Use ClusterIP, NodePort, LoadBalancer services and endpoints | course/week-08-networking | drills/speed-drills.md |
| Services & Networking (20%) | Use the Gateway API to manage Ingress traffic | course/week-08-networking | course/week-10-final-prep |
| Services & Networking (20%) | Know how to use Ingress controllers and Ingress resources | course/week-08-networking | drills/speed-drills.md |
| Services & Networking (20%) | Understand and use CoreDNS | course/week-08-networking | course/week-09-troubleshooting |
| Storage (10%) | Implement storage classes and dynamic volume provisioning | course/week-07-storage | mock-exams |
| Storage (10%) | Configure volume types, access modes and reclaim policies | course/week-07-storage | drills/speed-drills.md |
| Storage (10%) | Manage persistent volumes and persistent volume claims | course/week-07-storage | labs/breakfix |
| Troubleshooting (30%) | Troubleshoot clusters and nodes | course/week-09-troubleshooting | labs/breakfix |
| Troubleshooting (30%) | Troubleshoot cluster components | course/week-09-troubleshooting | course/week-05-cluster-maintenance, labs/breakfix |
| Troubleshooting (30%) | Monitor cluster and application resource usage | course/week-04-lifecycle-observability | course/week-09-troubleshooting |
| Troubleshooting (30%) | Manage and evaluate container output streams (logs) | course/week-04-lifecycle-observability | course/week-09-troubleshooting |
| Troubleshooting (30%) | Troubleshoot services and networking | course/week-09-troubleshooting | course/week-08-networking, labs/breakfix |

Sanity check against the weights: the 30% domain is covered by *two* dedicated modules (weeks 04 and 09) plus the entire breakfix lab — that ratio is intentional and mirrors where the exam points are.

---

## 9. Countdown: 2026-07-08 → exam 2026-08-17 (6 weeks out, you are in week 5)

Today is Wednesday, July 8, 2026. Exam is Monday, August 17. Per the repo's plan you are in **week 5 (Jul 6–12, cluster maintenance)** — exactly on schedule. Six calendar weeks remain: four content weeks, two simulator weeks. This is a healthy position; here is the concrete path.

| Dates | Plan week | Focus | Non-negotiables |
|---|---|---|---|
| Jul 6–12 (now) | 5 | Cluster maintenance | etcd snapshot save/restore from memory; full kubeadm upgrade sequence on a practice node; drain/uncordon reflex. This is pure exam gold — upgrade+backup tasks are near-guaranteed. |
| Jul 13–19 | 6 | Security + RBAC | All four RBAC objects via imperative commands; `k auth can-i --as` verification habit; ServiceAccount wiring. Start doing every task with a visible timer from this week on. |
| Jul 20–26 | 7 | Storage | Static PV/PVC binding rules cold; dynamic provisioning with StorageClass; WaitForFirstConsumer behavior. Lightest domain (10%) — do not let it eat more than its week. |
| Jul 27–Aug 2 | 8 | Networking (+ Gateway API) | NetworkPolicy from the docs page in under 8 min; Service/endpoints debugging; Gateway+HTTPRoute; CoreDNS test pattern. Remember: this is 20%, not 30% — see Section 1. |
| Aug 3–9 | 9 | **killer.sh session 1** + troubleshooting | Do the full 2-hour sim under real conditions (one screen, timer, docs only, no pausing) early in the week — Tuesday at the latest. Session stays up 36h: spend the rest of it dissecting every miss. Remaining days: course/week-09-troubleshooting + labs/breakfix, because troubleshooting is 30% and this is its dedicated week. |
| Aug 10–16 | 10 | **killer.sh session 2** + polish | Same questions as session 1 — target >85% and finishing with 20+ min spare. Then drills/speed-drills.md daily, mock-exams for any weak domain, re-run the Section 4 setup routine until sub-3-minutes. **Aug 15–16: taper.** Light review only, sleep. |
| **Aug 17** | — | **Exam** | Check in 30 min early. Run the setup block. Trust the triage protocol. |

**Weekly rhythm that works for a full-time job:** ~2h on 4 weekdays + one 4–6h weekend block for the week's exercises and one timed mini-mock (5 tasks, 35 minutes) — the timed block matters more than the reading.

### If you fall behind

Cut depth, never cut weeks 9–10. Priority order when compressing, driven by exam weight per remaining hour:

1. **Never sacrifice the two killer.sh weeks.** A candidate who finished only 80% of content but did both simulator sessions beats one who read everything and simulated nothing.
2. **Storage (week 7) is the first to compress** — 10% of the exam, and its recipes (Section 5.7) plus the docs page cover most of what tasks ask. One solid day + the exercises can substitute for the full week.
3. **Networking (week 8) compresses to: NetworkPolicy, Service debugging, Gateway API, CoreDNS.** Skip deep CNI internals; the exam wants installation awareness, not datapath forensics.
4. **Cluster maintenance and RBAC (weeks 5–6) do not compress** — together they anchor the 25% architecture domain and produce the most predictable, scriptable exam tasks. Guaranteed points.
5. If truly under water in week 10: drill only troubleshooting flows (`describe` → events → logs → kubelet) and the Section 5 recipes. The 30% domain plus recipe-pattern tasks clear 66% on their own if executed fast.

And if you are *ahead*: pull week 9's troubleshooting material forward. Every extra hour of breakfix practice pays more than an extra pass over anything else — it is the 30% domain and the one that punishes slow diagnosis hardest.

---

## Checkpoint

Format mechanics, not content — test yourself before week 9:

- Can you type the full setup block (aliases, exports, completion, .vimrc) from memory in under 3 minutes?
- Can you state the current five domain weights without looking?
- Can you execute the copy-paste flow (Firefox `ctrl+c` → terminal `ctrl+shift+v`) without thinking about it?
- Can you recite the SSH discipline (context command → ssh → `sudo -i` → work → `exit` → `exit` → verify from jump host)?
- Given any task, can you decide attempt-vs-flag within 2 minutes, and do you actually stop at the 10-minute cap? (Check your last mock's logs honestly.)
- Can you land on the NetworkPolicy, kubeadm-upgrade, and PV/PVC docs pages in under 30 seconds each using only the kubernetes.io search box?
- Can you name the recipe (Section 5) for any task read aloud, in under 15 seconds?
- Can you run an RBAC grant end-to-end, including the `k auth can-i --as` verification, in under 4 minutes?
- Do you know today, without checking, which killer.sh session you take in which week and how long each stays open?
