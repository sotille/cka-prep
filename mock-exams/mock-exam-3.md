# CKA Mock Exam 3 — Killer-Level (deliberately HARDER than the real exam)

This paper is calibrated like killer.sh: multi-step compound tasks, interacting faults, tight time. **Scoring 50–60% here means you are on track; ≥55% ≈ exam-ready.** Do not compare your raw score against the real 66% pass mark — the calibration table in the solutions does that conversion for you.

## Rules

| Rule | Value |
|---|---|
| Duration | 120 minutes, hard stop |
| Tasks | 15, weights sum to 100% |
| Calibration | killer.sh-level; ≥55% here ≈ ready for the real exam |
| Cluster | kind cluster `cka`, kubectl context `kind-cka` |
| Allowed docs | kubernetes.io/docs, kubernetes.io/blog, helm.sh/docs — one browser tab |
| Answer files | Exactly at the paths given, under `/tmp/exam3/` (pre-created by setup) |

Before starting, run the setup **without reading it** (it contains every fault):

```bash
bash mock-exams/mock-exam-3-setup.sh
```

Assumed shell environment (course conventions):

```bash
alias k=kubectl
export do="--dry-run=client -o yaml"
export now="--grace-period=0 --force"
```

Node access: this lab substitutes `docker exec -it <node-name> bash` for the real exam's `ssh <node>` + `sudo -i`. Node names: `cka-control-plane`, `cka-worker`, `cka-worker2`. On the real exam, always return to the base terminal after node work — commands run while still SSH'd into a node are a classic point-loser.

**Triage warning — read once, then start the timer.** This exam contains three cluster-wide faults: a control-plane component is down (Task 1), one node is broken (Task 10), and cluster DNS is broken (Task 13). Most other tasks depend on at least one of them — deployments will not create pods, service endpoints will not update, and PVCs will not bind until Task 1 is solved. Skim all 15 tasks in the first 5 minutes and fix the cluster-wide faults early. Per-task time targets sum to 126 minutes: you are not expected to finish everything. That is the point.

Domain weights *approximate* the live blueprint but deliberately over-index the two hardest bands (killer-style): Troubleshooting 30, Cluster Architecture 29, Services & Networking 20, Workloads & Scheduling 11, Storage 10. The real exam is 30 / 25 / 20 / 15 / 10 — verify the current curriculum version on the CNCF curriculum page before exam day. The per-task domain tags and subtotals are in the solutions file.

---

## Task 1 — Deployments cluster-wide create no pods (8% · ~10 min · hard)

Use context `kind-cka`. Namespace `apex` pre-exists with Deployment `canary` (1 replica).

`canary` was created hours ago and still shows `READY 0/1`. It has **no ReplicaSet, no pods and no events**. Every new Deployment in the cluster shows the same symptom.

- Find the root cause on the control plane and fix it **permanently** (must survive a kubelet restart).
- Write the absolute path (on the control-plane node) of the file you fixed to `/tmp/exam3/01-cause.txt`.
- Then create Deployment `phoenix` in `apex`: image `nginx:1.27-alpine`, 3 replicas.
- Finish state: `canary` 1/1 and `phoenix` 3/3 Ready.

*Exam flavor: on the real exam this is `ssh` to the control-plane node + `sudo -i`; here `docker exec -it cka-control-plane bash`.*

## Task 2 — Certificate user, RBAC and kubeconfig (8% · ~10 min · exam)

Use context `kind-cka`. Namespace `citadel` pre-exists.

Engineer `mara` needs deployment-management rights in `citadel`, authenticated by a client certificate.

- Generate a 2048-bit RSA key at `/tmp/exam3/mara.key` and a CSR at `/tmp/exam3/mara.csr`, Common Name `mara`.
- Create a `CertificateSigningRequest` named `mara` using the built-in signer for API-server client certificates, valid for 24 hours. Approve it and save the issued certificate to `/tmp/exam3/mara.crt`.
- Create Role `deploy-manager` in `citadel` allowing `get`, `list`, `watch`, `create`, `update` on Deployments, and RoleBinding `mara-deploy-manager` granting it to user `mara`.
- Build a **standalone** kubeconfig at `/tmp/exam3/mara.kubeconfig` (embedded certs, context `mara@cka`, set as current-context) that authenticates as `mara`.
- Using only that kubeconfig, record the answers to these three checks in `/tmp/exam3/02-verify.txt`: can mara create deployments in `citadel`; can mara delete deployments in `citadel`; can mara get secrets in `citadel`. Expected pattern: yes / no / no.

*Exam flavor: identical on the real exam; the exam terminal is Linux (`base64 -w 0`), macOS needs `base64 | tr -d '\n'`.*

## Task 3 — Gateway API canary traffic split (7% · ~8 min · exam)

Use context `kind-cka`. Namespace `mesh` pre-exists with Deployments and Services `web-v1` and `web-v2` (both serve HTTP on port 80). Gateway API CRDs are installed.

- Create a GatewayClass `exam-gwc` with controller name `example.com/exam-gateway`.
- Create a Gateway `web-gw` in `mesh`: class `exam-gwc`, one HTTP listener named `http` on port 80 for hostname `web.exam3.local`, accepting routes only from the same namespace.
- Create an HTTPRoute `web-split` in `mesh` attached to `web-gw` for hostname `web.exam3.local` that sends **80% of traffic to `web-v1` and 20% to `web-v2`** (both on port 80).
- Apply all three objects **and** save the combined manifest to `/tmp/exam3/03-gateway.yaml`.

*Lab note: no gateway controller is installed, so the Gateway will never report `Programmed` — object specs are what is graded. Real-exam clusters ship the CRDs pre-installed, as here.*

## Task 4 — The PVC that would not bind (6% · ~8 min · hard)

Use context `kind-cka`. Namespace `vault` pre-exists with PVC `data-fast` (Pending). A StorageClass `local-fast` and a PersistentVolume `pv-fast` pre-exist.

Ops escalated: "PVC `data-fast` has been Pending for an hour, storage must be broken." Investigate before you fix.

- Decide whether the Pending state is actually a fault. Create a single-replica Deployment `consumer` in `vault` (image `busybox:1.36`, a long-running command, PVC `data-fast` mounted at `/data`).
- If the pod still cannot run, find the remaining fault and fix it **without deleting or recreating the PVC**.
- Finish state: `data-fast` Bound, `consumer` pod Running on the node the PV is pinned to.

## Task 5 — One deployment, two independent faults (8% · ~10 min · hard)

Use context `kind-cka`. Namespace `orbit` pre-exists with Deployment `telemetry` (2 replicas) and Secret `telemetry-token`.

`telemetry` has 0 ready replicas. There are **two unrelated faults**; fixing one will reveal the other.

- Fix both in place. Do **not** modify the Secret, do not remove the container's env configuration, do not delete/recreate the Deployment.
- Write both root causes, one per line, to `/tmp/exam3/05-causes.txt`.
- Finish state: 2/2 Ready.

## Task 6 — etcd backup and restore roundtrip (10% · ~15 min · hard)

Use context `kind-cka`. The control plane runs kubeadm-style static pods on `cka-control-plane`.

Perform all steps of this task **consecutively** — the restore reverts any API change made after the snapshot.

- Take an etcd snapshot and store it at `/var/lib/etcd/exam3-snap.db` on the control-plane node; copy it to `/tmp/exam3/exam3-snap.db` on your workstation.
- Create ConfigMap `after-snap` in namespace `default` (marker).
- Restore the snapshot into a **new directory under `/var/lib/etcd/`** (never restore over a live data dir; if you retry, use a fresh directory name each time) and repoint the etcd static pod at it.
- Write the data directory path you used to `/tmp/exam3/06-datadir.txt`.
- Finish state: API server healthy, `kubectl get cm after-snap` returns NotFound.

*Exam flavor: on the real exam you `ssh` to the node where `etcdctl`/`etcdutl` exist on the host and certs live under `/etc/kubernetes/pki/etcd/`. Here the binaries live inside the etcd pod/image — `kubectl exec` into it for the snapshot, `docker exec` into the node to edit the manifest.*

## Task 7 — Drain blocked by a PodDisruptionBudget (7% · ~8 min · hard)

Use context `kind-cka`. Namespace `fortress` pre-exists with Deployment `ledger` (2 replicas) and PDB `ledger-pdb` (`minAvailable: 2`).

`cka-worker` needs kernel maintenance. Constraints from the service owner: `ledger` must **never** drop below 2 ready replicas, and `ledger-pdb` must remain in place, unmodified.

- Drain `cka-worker` (ignore DaemonSets, delete emptyDir data if prompted). The first attempt will fail.
- Write the kind and name of the API object blocking eviction (or the exact error line) to `/tmp/exam3/07-blocker.txt`.
- Resolve the deadlock within the constraints, complete the drain, then uncordon `cka-worker` and return `ledger` to 2 replicas.

*Dependency: you need a second healthy, schedulable worker — if `cka-worker2` is still broken (Task 10), fix it first.*

## Task 8 — Service, NetworkPolicy and DNS, combined (7% · ~10 min · hard)

Use context `kind-cka`. Namespace `bazaar` pre-exists with Deployment `api` (nginx on container port 80, labels `app=api`), Deployment `frontend` (pods labeled `role=frontend`), Service `api-svc`, and a `default-deny-ingress` NetworkPolicy.

`api-svc` serves no traffic. **Do not modify the Deployments.**

- Fix `api-svc` so it selects the api pods and serves port 80 correctly. Verify it has endpoints.
- Create NetworkPolicy `allow-frontend` in `bazaar`: ingress to pods `app=api` allowed **only** from pods labeled `role=frontend` in the same namespace, **only** on TCP 80. Egress must remain unrestricted.
- From a `frontend` pod, fetch `http://api-svc.bazaar.svc.cluster.local` (the FQDN — this proves DNS) and save the response body to `/tmp/exam3/08-dns.txt`.

*Lab note: kindnet does not enforce NetworkPolicy — the object is graded on spec. Dependency: the FQDN fetch needs working cluster DNS (Task 13).*

## Task 9 — CronJob plus manual trigger (6% · ~6 min · exam)

Use context `kind-cka`. Namespace `batchjobs` pre-exists.

- Create CronJob `report` in `batchjobs`: image `busybox:1.36`, command printing the date then `report-ok`, schedule every 5 minutes.
- Requirements: concurrency policy `Forbid`, keep 3 successful and 1 failed job in history, jobs retry at most 2 times (`backoffLimit`), any job run is killed after 60 seconds (`activeDeadlineSeconds`), pods never restart in place.
- Without waiting for the schedule, trigger one run manually as Job `report-now` **derived from the CronJob**, and let it run to completion.

## Task 10 — Node NotReady, kubelet won't stay up (7% · ~8 min · hard)

Use context `kind-cka`.

Node `cka-worker2` is broken. (If it still shows `Ready`, another cluster-wide fault is masking the symptom — solve Task 1 first; node lifecycle is the controller-manager's job.)

- Diagnose on the node: the kubelet is crash-looping, not merely stopped. Find why.
- Fix it **permanently** (must survive kubelet restarts and a node reboot) and bring the node back to `Ready`.
- Write the exact offending kubelet flag to `/tmp/exam3/10-cause.txt`.

*Exam flavor: on the real exam: `ssh <node>`, `sudo -i`, `systemctl status kubelet`, `journalctl -u kubelet`. Here: `docker exec -it cka-worker2 bash` (already root).*

## Task 11 — DaemonSet on every node, including control plane (5% · ~5 min · exam)

Use context `kind-cka`. Namespace `sentry` pre-exists.

- Create DaemonSet `node-agent` in `sentry`: image `busybox:1.36`, long-running command, requests `cpu: 10m`, `memory: 16Mi`.
- It must run on **all** nodes, including the control plane.
- Rolling updates of the DaemonSet must allow up to 2 pods unavailable at once.
- Finish state: 3/3 pods Running (requires all nodes healthy — see Task 10).

## Task 12 — Helm lifecycle: upgrade, rollback, evict the broken release (7% · ~8 min · exam)

Use context `kind-cka`. Namespace `helmwork` pre-exists with two Helm releases installed from the local chart `/tmp/exam3/charts/webshop`.

- Upgrade release `web` to `replicaCount=3` and `image.tag=1.27-alpine`; wait until the rollout completes.
- Roll `web` back to revision 1 and verify the deployment returns to 1 replica.
- Save the release history (after the rollback — it must show 3 revisions) to `/tmp/exam3/12-history.txt`.
- One release in `helmwork` ships pods that can never run. Identify it and remove **the release** (not just its objects).

## Task 13 — Every in-cluster hostname fails to resolve (6% · ~8 min · hard)

Use context `kind-cka`.

Developers report that **every** Service hostname lookup fails cluster-wide (`api-svc.bazaar`, `kubernetes.default`, everything), while external names like `kubernetes.io` still resolve from pods. Nobody touched the pods.

- Find the root cause in the cluster DNS stack and fix it.
- Prove the fix: from a throwaway pod, resolve `kubernetes.default.svc.cluster.local` and save the lookup output to `/tmp/exam3/13-verify.txt`.

## Task 14 — Replace the default StorageClass (4% · ~5 min · exam)

Use context `kind-cka`. The cluster ships the `standard` StorageClass (rancher.io/local-path, current default). Namespace `vault` exists.

- Create StorageClass `standard-retain`: provisioner `rancher.io/local-path`, reclaim policy `Retain`, volume binding mode `WaitForFirstConsumer`.
- Make `standard-retain` the **only** default StorageClass in the cluster.
- Create PVC `scratch` in `vault` (500Mi, RWO, **no** `storageClassName` field) and Pod `scratch-pod` (image `busybox:1.36`, long-running) mounting it at `/scratch`.
- Finish state: PVC Bound via the new default class; the bound PV's reclaim policy is `Retain`.

## Task 15 — Kustomize overlay with a patch (4% · ~7 min · exam)

Use context `kind-cka`. A kustomize base exists at `/tmp/exam3/kustomize/base` (Deployment `notify`, container `web`, image `nginx:1.25-alpine`, 1 replica).

Create an overlay at `/tmp/exam3/kustomize/overlays/prod` that, **without editing the base**:

- Deploys into namespace `prodapps` (create the namespace).
- Sets replicas to 3 and the image tag to `1.27-alpine`.
- Patches the `web` container to add resource requests `cpu: 50m`, `memory: 64Mi`.

Render the overlay to `/tmp/exam3/15-rendered.yaml` and apply it with kubectl's built-in kustomize. Finish state: `notify` 3/3 Ready in `prodapps`.

---

Stop at 120 minutes. Grade yourself with `mock-exams/mock-exam-3-solutions.md` — apply the partial-credit rubrics honestly, then read the killer-calibration table before judging the number.
