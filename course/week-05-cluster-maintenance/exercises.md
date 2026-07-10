# Week 05 Exercises — Cluster Maintenance: etcd, Upgrades, Nodes

Lab: the 3-node kind cluster `cka` (context `kind-cka`; nodes `cka-control-plane`, `cka-worker`, `cka-worker2`). Aliases assumed: `alias k=kubectl`, `export do="--dry-run=client -o yaml"`, `export now="--grace-period=0 --force"`. Node access on kind is `docker exec -it <node> bash` — on the real exam it is `ssh <node>` followed by `sudo -i`; a per-task note flags other differences. Tasks 12, 13, 15, 16 are written drills (no cluster needed); task 14 runs on killercoda.

Warning for task 3: it really restores etcd — anything you created after the snapshot disappears. Do it when you don't mind resetting lab state, and read the cleanup step.

---

## Task 1 — etcd recon (warmup, 3 min)

Context: fresh cluster, namespace `default`.

From the etcd static pod configuration on `cka-control-plane`, determine and write down: (a) the data directory, (b) the client endpoint URL etcd listens on, (c) the paths of the CA cert, server cert, and server key, (d) the etcd image version. Do it twice: once through the Kubernetes API, once by reading the manifest file on the node.

## Task 2 — etcd snapshot + verification (exam, 5 min)

Context: default namespace; task 1 completed (you know the cert paths).

Create a snapshot of etcd and save it to `/var/lib/etcd/snap.db` (a path that survives pod restarts, since `/var/lib/etcd` is hostPath-backed). Then verify the snapshot and record its revision and total key count.

Exam flavor: on the exam, `etcdctl`/`etcdutl` are installed on the node itself and the target path is something like `/srv/backup/etcd.db` — you SSH in instead of exec-ing into the pod. The command is identical.

## Task 3 — full etcd restore drill (hard, 12 min)

Context: default namespace; destructive — resets cluster state to snapshot time.

Setup (creates the "before" marker):

```bash
k create deployment before-snap --image=nginx:1.27
```

1. Snapshot etcd to `/var/lib/etcd/snap.db` (as in task 2).
2. Create a second deployment `after-snap` (image `nginx:1.27`) — this one must NOT survive the restore.
3. Restore the snapshot into a new data directory and reconfigure etcd to use it.
4. Verify: `before-snap` exists, `after-snap` is gone, cluster is healthy.
5. Bounce kube-scheduler and kube-controller-manager to clear stale caches.

Exam flavor: identical flow on the exam, except you work over SSH and the restore dir is typically a sibling like `/var/lib/etcd-restore` rather than a nested dir.

## Task 4 — etcd health and membership (exam, 4 min)

Context: any state.

Against the etcd member on `cka-control-plane`, produce: (a) endpoint health, (b) endpoint status as a table (note DB size, leader status, raft term), (c) the member list. Answer: how many members does this cluster have, and how many node failures can it tolerate?

## Task 5 — certificate expiry inspection (warmup, 3 min)

Context: control-plane node `cka-control-plane`.

Determine: (a) when the apiserver certificate expires, (b) which certificate in the cluster expires soonest, (c) how long the CA certificates are valid, (d) the single command that would renew all renewable certs, and (e) what you must do immediately after renewal for it to take effect. Cross-check the apiserver cert expiry with openssl directly against the file.

## Task 6 — join command generation (exam, 5 min)

Context: control-plane node.

A new worker node must join the cluster. Produce: (a) a complete `kubeadm join` command using a fresh bootstrap token with a TTL of 2 hours, (b) the list of current tokens with their expiry, (c) the discovery CA cert hash computed manually with openssl (it must match the one in the join command).

Exam flavor: on the exam you may then actually run the join on a second node; on kind you stop after generating and verifying the command.

## Task 7 — drain and uncordon with a live workload (exam, 7 min)

Context: namespace `maint` (created in setup).

Setup:

```bash
k create ns maint
k -n maint create deployment webfarm --image=nginx:1.27 --replicas=4
k -n maint rollout status deploy/webfarm
```

Drain `cka-worker` for maintenance. All webfarm replicas must end up Running on other nodes. Then return `cka-worker` to service and prove it accepts pods again. Note: the first drain attempt without flags is expected to fail — read the error before reaching for flags.

## Task 8 — drain blocked by a PodDisruptionBudget (hard, 10 min)

Context: namespace `pdb-lab` (created in setup).

Setup:

```bash
k create ns pdb-lab
k -n pdb-lab create deployment guard --image=nginx:1.27 --replicas=4
k -n pdb-lab create poddisruptionbudget guard-pdb --selector=app=guard --min-available=4
k -n pdb-lab rollout status deploy/guard
```

Check which worker hosts `guard` pods (`k -n pdb-lab get pods -o wide`) and drain that worker (if pods sit on both, pick either). The drain will not complete. Diagnose why, unblock it *without* deleting the application and without `--disable-eviction`, and finish the drain. Uncordon when done.

## Task 9 — static pod lifecycle (exam, 8 min)

Context: node `cka-worker2`, default namespace.

Create a static pod named `static-web` (image `nginx:1.27`, container port 80) on `cka-worker2`. Then: (a) find its mirror pod through the API and note the name, (b) delete the mirror pod with kubectl and explain what happens, (c) remove the static pod permanently the correct way.

Exam flavor: identical on the exam, except the node is reached via SSH and the task may phrase it as "create a pod that survives without the API server".

## Task 10 — control-plane component outage via manifest move (exam, 6 min)

Context: control-plane node; default namespace.

Take kube-scheduler offline by moving its static pod manifest out of the manifests directory. Prove the impact: create pod `pending-test` (image `nginx:1.27`) and show it stays Pending with no scheduling events. Bring the scheduler back and confirm the pod gets scheduled. Clean up `pending-test`.

## Task 11 — namespace backup and restore with kubectl (exam, 6 min)

Context: namespace `backup-me` (created in setup).

Setup:

```bash
k create ns backup-me
k -n backup-me create deployment web --image=nginx:1.27 --replicas=2
k -n backup-me create configmap app-config --from-literal=env=prod
k -n backup-me create secret generic app-secret --from-literal=token=s3cr3t
```

Back up all deployments, configmaps, and secrets in `backup-me` to `/tmp/ns-backup.yaml`. Delete the namespace entirely. Recreate the namespace and restore everything from the backup file. Verify the deployment is back to 2/2 and the secret decodes to the original value.

## Task 12 — upgrade ordering quiz (exam, 5 min, written)

Context: paper drill, no cluster. Cluster: one control-plane node `cp1`, one worker `w1`, Debian-based, kubeadm, currently v1.32.4, target v1.33.2.

Put these 12 steps in the correct execution order (write the letter sequence):

- A. `kubectl uncordon w1`
- B. `sudo kubeadm upgrade apply v1.33.2` (on cp1)
- C. On w1: edit `/etc/apt/sources.list.d/kubernetes.list` to the v1.33 repo, `apt-get update`, unhold + install new kubeadm + hold
- D. On cp1: unhold, install new kubelet and kubectl, hold, `systemctl daemon-reload && systemctl restart kubelet`
- E. `kubectl drain w1 --ignore-daemonsets`
- F. On cp1: edit `/etc/apt/sources.list.d/kubernetes.list` to the v1.33 repo, `apt-get update`
- G. `sudo kubeadm upgrade node` (on w1)
- H. `kubectl uncordon cp1`
- I. `kubectl drain cp1 --ignore-daemonsets`
- J. `sudo kubeadm upgrade plan` (on cp1)
- K. On w1: unhold, install new kubelet and kubectl, hold, `systemctl daemon-reload && systemctl restart kubelet`
- L. On cp1: unhold kubeadm, install new kubeadm, hold, verify `kubeadm version`

Bonus question: which single step changes if the cluster has a second control-plane node cp2, and what does it become?

## Task 13 — write the upgrade runbook from memory (exam, 8 min, written)

Context: paper drill. Same cluster as task 12.

Without looking at notes or docs, write every command (with real flags and a plausible package version string) to upgrade cp1 from v1.32.4 to v1.33.2 — from the apt repo edit through uncordon. Then self-grade against the masterclass runbook: every missing `apt-mark`, wrong package suffix, or misordered step is minus one point. Target: 0 mistakes. Repeat daily until you hit the target twice in a row.

## Task 14 — real kubeadm upgrade on killercoda (exam, 25 min)

Context: kind cannot run `kubeadm upgrade` (binaries are baked into the node image), so this runs on killercoda.

1. Open killercoda.com → "Killer Shell CKA" → the cluster upgrade scenario.
2. Run the full upgrade — control plane, then worker — using only kubernetes.io docs as reference (open `/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/` and copy-adapt, exactly as you will on the exam).
3. Success criteria: `kubectl get nodes` shows all nodes `Ready` at the target version; scenario check passes; total time under 25 minutes.
4. Rerun until under 15 minutes.

## Task 15 — version-skew quiz (warmup, 3 min, written)

Context: paper drill. kube-apiserver is at v1.33.

Answer: (a) oldest and newest kubelet versions allowed; (b) allowed kubectl versions; (c) allowed kube-controller-manager/kube-scheduler versions; (d) a worker kubelet runs v1.30 — can you upgrade the control plane to v1.34 before touching that worker?; (e) why must the control plane always be upgraded before kubelets? State the answers, then verify against kubernetes.io/releases/version-skew-policy/ (the policy changed in v1.28 — know which side of it your exam version is on).

## Task 16 — HA topology reasoning (hard, 10 min, written)

Context: paper drill.

A team runs a kubeadm cluster with TWO control-plane nodes (stacked etcd) behind a load balancer, believing this gives high availability. Answer:

1. Node cp2's disk dies. What exactly happens to (a) etcd, (b) the API server on cp1, (c) already-running workloads on workers? Why?
2. Give the quorum size and tolerated failures for 1, 2, 3, 4, and 5 etcd members. Why is 4 not better than 3?
3. Stacked vs external etcd: two advantages of each, and which one `kubeadm join --control-plane` builds.
4. Write the exact command sequence to add a third control-plane node cp3 to this cluster (assume `--control-plane-endpoint` was set at init).
5. The team never set `--control-plane-endpoint` at init. What is the practical consequence for fixing their HA story?

---

# SOLUTIONS

## Solution 1 — etcd recon

Through the API:

```bash
k -n kube-system get pod etcd-cka-control-plane -o yaml | grep -E 'data-dir|cert-file|key-file|trusted-ca|listen-client|image:'
```

On the node:

```bash
docker exec cka-control-plane grep -E 'data-dir|cert-file|key-file|trusted-ca|listen-client|image:' /etc/kubernetes/manifests/etcd.yaml
```

Expected answers: (a) `--data-dir=/var/lib/etcd`; (b) `https://127.0.0.1:2379` (plus the node IP variant); (c) `--trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt`, `--cert-file=/etc/kubernetes/pki/etcd/server.crt`, `--key-file=/etc/kubernetes/pki/etcd/server.key`; (d) from the `image:` line, e.g. `registry.k8s.io/etcd:3.6.x-0` on the current kind lab (older clusters ran `3.5.x-0`). The 3.5→3.6 jump matters: etcd 3.6 removed the `etcdctl snapshot status`/`snapshot restore` subcommands (they now live only in `etcdutl`), which is why the tasks below verify and restore with `etcdutl`.

Why: everything etcdctl needs is in the manifest — grepping it beats memorizing paths and is the first move of every etcd task.

## Solution 2 — etcd snapshot + verification

```bash
k -n kube-system exec etcd-cka-control-plane -- \
  etcdctl snapshot save /var/lib/etcd/snap.db \
   --endpoints=https://127.0.0.1:2379 \
   --cacert=/etc/kubernetes/pki/etcd/ca.crt \
   --cert=/etc/kubernetes/pki/etcd/server.crt \
   --key=/etc/kubernetes/pki/etcd/server.key
```

Note the direct exec of `etcdctl` — no `sh -c '...'` wrapper. The etcd 3.6.x-0 image is distroless and has no shell, so `exec ... -- sh -c '...'` fails with `exec: "sh": executable file not found`. Drop the inline `ETCDCTL_API=3` too: it is the default since etcdctl 3.4 and can't be set without a shell anyway.

Verify with etcdutl (etcd 3.6 removed the `etcdctl snapshot status` subcommand — on older 3.5 images the deprecated `etcdctl snapshot status` still works):

```bash
k -n kube-system exec etcd-cka-control-plane -- etcdutl snapshot status /var/lib/etcd/snap.db -w table
```

Why: saving under `/var/lib/etcd` matters on kind — it is the hostPath mount, so the file lives on the node and survives pod restarts; a file written anywhere else in the container is lost. Expect thousands of keys on a live cluster — single-digit key counts mean you snapshotted the wrong thing.

## Solution 3 — full etcd restore drill

```bash
# 2. the "after" marker
k create deployment after-snap --image=nginx:1.27
k get deploy    # both before-snap and after-snap exist

# 3a. restore into a new dir (inside /var/lib/etcd so it lands on the node via hostPath)
k -n kube-system exec etcd-cka-control-plane -- \
  etcdutl snapshot restore /var/lib/etcd/snap.db --data-dir=/var/lib/etcd/restored

# 3b. repoint the static pod's hostPath (one line changes)
docker exec cka-control-plane sed -i \
  's|path: /var/lib/etcd$|path: /var/lib/etcd/restored|' \
  /etc/kubernetes/manifests/etcd.yaml

# 3c. kubelet restarts etcd; the API blips for ~30-60s
docker exec cka-control-plane sh -c 'while ! crictl ps | grep -q etcd; do sleep 2; done; crictl ps | grep etcd'
```

The volume in `etcd.yaml` after the edit (only `path:` changed — `--data-dir` and the mountPath stay `/var/lib/etcd`):

```yaml
volumes:
- hostPath:
    path: /var/lib/etcd/restored
    type: DirectoryOrCreate
  name: etcd-data
```

```bash
# 4. verify — retry until the apiserver answers
k get deploy
# before-snap   present
# after-snap    GONE — created after the snapshot

# 5. bounce scheduler + controller-manager (stale caches)
docker exec cka-control-plane sh -c \
  'mv /etc/kubernetes/manifests/kube-scheduler.yaml /etc/kubernetes/manifests/kube-controller-manager.yaml /tmp/ &&
   sleep 20 &&
   mv /tmp/kube-scheduler.yaml /tmp/kube-controller-manager.yaml /etc/kubernetes/manifests/'
```

Cleanup / rollback (optional): revert the sed (`s|path: /var/lib/etcd/restored|path: /var/lib/etcd|`), wait for etcd to restart on the original dir — `after-snap` reappears, because the old data dir was never modified. Then `docker exec cka-control-plane rm -rf /var/lib/etcd/restored` and delete the marker deployments.

Why: restore is offline and must target an empty dir; repointing the hostPath (not `--data-dir`) is the minimal, safe edit; keeping the old dir gives you rollback for free. On the exam, run `etcdutl snapshot restore` on the node itself and use a sibling dir like `/var/lib/etcd-restore`.

## Solution 4 — etcd health and membership

```bash
k -n kube-system exec etcd-cka-control-plane -- \
  etcdctl --endpoints=https://127.0.0.1:2379 \
   --cacert=/etc/kubernetes/pki/etcd/ca.crt \
   --cert=/etc/kubernetes/pki/etcd/server.crt \
   --key=/etc/kubernetes/pki/etcd/server.key \
   endpoint health

k -n kube-system exec etcd-cka-control-plane -- \
  etcdctl --endpoints=https://127.0.0.1:2379 \
   --cacert=/etc/kubernetes/pki/etcd/ca.crt \
   --cert=/etc/kubernetes/pki/etcd/server.crt \
   --key=/etc/kubernetes/pki/etcd/server.key \
   endpoint status -w table

k -n kube-system exec etcd-cka-control-plane -- \
  etcdctl --endpoints=https://127.0.0.1:2379 \
   --cacert=/etc/kubernetes/pki/etcd/ca.crt \
   --cert=/etc/kubernetes/pki/etcd/server.crt \
   --key=/etc/kubernetes/pki/etcd/server.key \
   member list -w table
```

Exec `etcdctl` directly (no `sh -c` wrapper) — the distroless etcd 3.6 image has no shell, so the wrapped form fails with `exec: "sh": executable file not found`.

Answers: one member (kind runs a single control-plane node), quorum = 1, tolerated failures = 0. The status table shows `IS LEADER = true` (a single member is always leader), the DB size, and the raft term.

Why: `endpoint status -w table` is the one-glance health check — DB size growth and leader flapping (rising raft term) are the two classic etcd trouble signals.

## Solution 5 — certificate expiry inspection

```bash
docker exec cka-control-plane kubeadm certs check-expiration
```

Read the table: (a) `apiserver` row, EXPIRES column — ~1 year from cluster creation; (b) all leaf certs are typically issued together, so they expire together (any of them is a valid answer — look for the smallest RESIDUAL TIME); (c) CAs get 10 years (bottom table); (d) `kubeadm certs renew all`; (e) restart the control-plane static pods — move the four manifests out of `/etc/kubernetes/manifests`, wait for the containers to stop, move them back. Components hold the old cert in memory until restarted.

Cross-check with openssl:

```bash
docker exec cka-control-plane openssl x509 \
  -in /etc/kubernetes/pki/apiserver.crt -noout -enddate -subject
```

Why: `check-expiration` also flags externally-managed certs and shows which CA signs what — faster and more complete than openssl-ing ten files.

## Solution 6 — join command generation

```bash
# (a) fresh token with TTL + full command in one shot
docker exec cka-control-plane kubeadm token create --ttl 2h --print-join-command

# (b) list tokens and expiry
docker exec cka-control-plane kubeadm token list

# (c) recompute the CA hash manually
docker exec cka-control-plane sh -c \
  "openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
   | openssl rsa -pubin -outform der 2>/dev/null \
   | openssl dgst -sha256 -hex | sed 's/^.* //'"
```

The hex digest must equal the `sha256:...` value in the printed join command. Why: the token authenticates the *node to the cluster* (bootstrap token → `system:bootstrappers` → auto-approved CSR), while the CA hash authenticates the *cluster to the node* — mutual trust, which is why both halves exist. Tokens live as Secrets in kube-system and die at TTL, hence "generate fresh, never reuse".

## Solution 7 — drain and uncordon with a live workload

```bash
k drain cka-worker
# ERROR: cannot delete DaemonSet-managed Pods (kindnet, kube-proxy) — expected

k drain cka-worker --ignore-daemonsets
k get nodes                              # cka-worker Ready,SchedulingDisabled
k -n maint get pods -o wide              # all 4 replicas Running on cka-worker2

k uncordon cka-worker
k get nodes                              # back to Ready

# prove it accepts pods again
k -n maint scale deploy webfarm --replicas=8
k -n maint get pods -o wide | grep cka-worker   # new replicas land there
k -n maint scale deploy webfarm --replicas=4    # tidy up
```

Why: drain = cordon + evict via the Eviction API; DaemonSet pods must be explicitly ignored because their controller would recreate them instantly. Existing pods never migrate back on uncordon — only *new* scheduling decisions consider the node, which the scale-up proves. Cleanup: `k delete ns maint`.

## Solution 8 — drain blocked by a PodDisruptionBudget

```bash
k drain cka-worker --ignore-daemonsets
# evicting pod pdb-lab/guard-...
# error when evicting pod: Cannot evict pod as it would violate the pod's disruption budget.
# (drain retries forever — Ctrl-C after reading the error)

k -n pdb-lab get pdb
# NAME        MIN AVAILABLE   ALLOWED DISRUPTIONS
# guard-pdb   4               0        <- the problem: 4 healthy of 4 required, zero headroom
```

Diagnosis: `minAvailable: 4` with exactly 4 replicas means ALLOWED DISRUPTIONS = 0; every eviction is rejected. Two legitimate fixes:

```bash
# Fix A (preferred): give the PDB headroom
k -n pdb-lab patch pdb guard-pdb -p '{"spec":{"minAvailable":2}}'

# Fix B: create headroom by scaling the app up
# k -n pdb-lab scale deploy guard --replicas=6
```

```bash
k drain cka-worker --ignore-daemonsets      # completes now
k uncordon cka-worker
k delete ns pdb-lab                          # cleanup
```

Why: PDBs gate the Eviction API, and drain uses eviction — that is the whole mechanism. `--force` would NOT have helped (it addresses unmanaged pods, not PDBs); `--disable-eviction` bypasses PDBs by deleting directly, defeating the application's protection — on the exam use it only when explicitly instructed. If your drain succeeded instantly, all guard pods were on the other worker: uncordon, and drain that one instead.

## Solution 9 — static pod lifecycle

```bash
docker exec cka-worker2 mkdir -p /etc/kubernetes/manifests
docker exec -i cka-worker2 tee /etc/kubernetes/manifests/static-web.yaml <<'EOF' >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: static-web
spec:
  containers:
  - name: web
    image: nginx:1.27
    ports:
    - containerPort: 80
EOF
```

```bash
# (a) the mirror pod — node name is appended automatically
k get pods -o wide
# static-web-cka-worker2   1/1   Running   ...   cka-worker2

# (b) delete it via the API
k delete pod static-web-cka-worker2 $now
k get pods    # it's back within seconds
```

(b) explanation: you deleted only the *mirror* pod — the API-side read-only reflection. The kubelet still has the manifest file and immediately re-registers a new mirror. The actual container was never touched (or is restarted by kubelet, not by any controller).

```bash
# (c) the only correct removal: delete the file
docker exec cka-worker2 rm /etc/kubernetes/manifests/static-web.yaml
k get pods    # gone for good
```

Why: static pods are kubelet-owned; the file under `staticPodPath` is the single source of truth. This is exactly how the control plane itself runs — which is why task 10 works.

## Solution 10 — control-plane component outage via manifest move

```bash
docker exec cka-control-plane mv /etc/kubernetes/manifests/kube-scheduler.yaml /root/
docker exec cka-control-plane sh -c 'sleep 15; crictl ps | grep -c kube-scheduler || true'   # 0

k run pending-test --image=nginx:1.27
k get pod pending-test
# STATUS: Pending, NODE: <none>
k describe pod pending-test | tail -5
# Events: none at all — no scheduler exists to even say "unschedulable"

docker exec cka-control-plane mv /root/kube-scheduler.yaml /etc/kubernetes/manifests/
k get pod pending-test -w    # scheduled and Running within ~30s
k delete pod pending-test $now
```

Why: kubelet watches the manifests directory — removing a file stops the pod, restoring it recreates it. A Pending pod with an *empty* events list is the fingerprint of a dead scheduler (versus "Insufficient cpu"-type events, which prove the scheduler is alive but unsatisfied). This is a top troubleshooting-domain pattern.

## Solution 11 — namespace backup and restore with kubectl

```bash
k -n backup-me get deploy,cm,secret -o yaml > /tmp/ns-backup.yaml
k delete ns backup-me

k create ns backup-me
k apply -f /tmp/ns-backup.yaml
k -n backup-me get deploy web          # 2/2 within seconds
k -n backup-me get secret app-secret -o jsonpath='{.data.token}' | base64 -d
# s3cr3t
```

Why: exported objects carry `resourceVersion`/`uid`/`status`, but `kubectl apply` tolerates them on creation, so a straight re-apply works. Notes that earn points: `kubectl get all` would have MISSED configmaps and secrets ("all" is a legacy alias covering only core workload types) — always name the resource list explicitly; the exported `kube-root-ca.crt` ConfigMap harmlessly overwrites the auto-created one. And strategically: this is a *supplement* to etcd snapshots, not a replacement — it captures one namespace's objects, no cluster-scoped resources, no PV data.

## Solution 12 — upgrade ordering quiz

Correct order:

```text
F  L  J  B  I  D  H  E  C  G  K  A
```

1. **F** — repo edit on cp1 (per-minor pkgs.k8s.io repo; nothing installable before this)
2. **L** — new kubeadm on cp1 (kubeadm first, always)
3. **J** — `kubeadm upgrade plan`
4. **B** — `kubeadm upgrade apply v1.33.2`
5. **I** — drain cp1
6. **D** — kubelet+kubectl on cp1, daemon-reload, restart kubelet
7. **H** — uncordon cp1 (control plane fully done before any worker)
8. **E** — drain w1
9. **C** — repo edit + kubeadm on w1
10. **G** — `kubeadm upgrade node` on w1
11. **K** — kubelet+kubectl on w1, daemon-reload, restart kubelet
12. **A** — uncordon w1

(Steps 8 and 9 may be swapped — the worker's package work can precede its drain. The invariants that must hold: F→L→J→B strictly ordered; drain before its node's kubelet restart; uncordon last per node; all of cp1 before w1's `upgrade node`.)

Bonus: with a cp2, step B happens only on cp1; cp2 runs `sudo kubeadm upgrade node` instead (plus its own repo/kubeadm/drain/kubelet/uncordon cycle) — `upgrade apply` is a once-per-cluster operation.

## Solution 13 — write the upgrade runbook from memory

Grade yourself against the masterclass runbook section. The full sequence for cp1:

```bash
sudo sed -i 's|v1.32|v1.33|' /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-mark unhold kubeadm
sudo apt-get install -y kubeadm='1.33.2-1.1'
sudo apt-mark hold kubeadm
kubeadm version -o short
sudo kubeadm upgrade plan
sudo kubeadm upgrade apply v1.33.2
kubectl drain cp1 --ignore-daemonsets
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet='1.33.2-1.1' kubectl='1.33.2-1.1'
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet
kubectl uncordon cp1
```

Common self-grade catches: package suffix `-1.1` not the dead `-00`; repo edit BEFORE apt-get update; `upgrade apply` takes `v1.33.2` (with the v), apt takes `1.33.2-1.1` (without); drain comes after `upgrade apply`, before the kubelet package. Why memory-drill this when docs are allowed? Because on the exam the docs page is your safety net, not your working memory — copy-adapting goes twice as fast when you already know what you're looking for.

## Solution 14 — real kubeadm upgrade on killercoda

No cluster solution — a success checklist:

- `kubeadm upgrade plan` was run before `apply` and its target version matched the task.
- `upgrade apply` on the control plane, `upgrade node` on the worker — not `apply` twice.
- Each node drained before its kubelet restart, uncordoned after; `kubectl get nodes` shows every node `Ready` at the target version.
- You navigated to the kubeadm-upgrade docs page by memory (bookmark-level familiarity) and adapted versions rather than typing commands freehand.
- Time under 25 minutes (rerun target: 15). On the real exam this task is worth ~7-8% — budget accordingly and skip-and-return if a step wedges.

## Solution 15 — version-skew quiz

| Question | Answer |
|---|---|
| (a) kubelet vs apiserver v1.33 | v1.30 through v1.33 — up to 3 minors older (policy since v1.28), never newer |
| (b) kubectl | v1.32, v1.33, v1.34 — ±1 minor |
| (c) controller-manager / scheduler | v1.32 or v1.33 — up to 1 older, never newer |
| (d) worker kubelet at v1.30, upgrade CP to v1.34? | No — that leaves kubelet 4 minors behind. Upgrade the worker to at least v1.31 first (and the CP moves one minor at a time anyway) |
| (e) why control plane first | The skew policy forbids any component being newer than the apiserver it talks to; upgrading kubelets first would invert that. The apiserver is the compatibility anchor — everything else is a client |

Verify against `kubernetes.io/releases/version-skew-policy/` — skew windows are version-dependent and worth 30 seconds of confirmation on exam day.

## Solution 16 — HA topology reasoning

1. With 2 stacked members, quorum is 2 — losing cp2 means etcd has 1 of 2 members and **cannot commit writes or elect a leader**. (a) etcd is unavailable; (b) cp1's apiserver is up as a process but every read/write against etcd fails — kubectl errors, controllers stall, no new pods schedule; (c) already-running workloads keep running: kubelets manage containers locally and don't need the control plane for steady state. Recovery requires forcing a new single-member etcd cluster from cp1's data (`--force-new-cluster` / restore) — an outage, not a failover.
2. Quorum `floor(n/2)+1`: 1→1 (tolerates 0), 2→2 (tolerates 0), 3→2 (tolerates 1), 4→3 (tolerates 1), 5→3 (tolerates 2). Four members tolerate exactly as many failures as three while adding a machine and widening the quorum — strictly worse economics; always run odd counts.
3. Stacked: fewer machines, simpler operations, what kubeadm builds by default. External: etcd and control-plane failure domains decoupled, etcd can be sized/tuned independently. `kubeadm join --control-plane` builds **stacked** (it adds a local etcd member to the joining node).
4. On an existing control-plane node, then on cp3:

```bash
kubeadm init phase upload-certs --upload-certs      # prints <cert-key>; secret lives 2h
kubeadm token create --print-join-command           # prints token + CA hash
# on cp3, combine both outputs:
# kubeadm join <lb-endpoint>:6443 --token <token> \
#   --discovery-token-ca-cert-hash sha256:<hash> \
#   --control-plane --certificate-key <cert-key>
```

5. Without `--control-plane-endpoint`, every kubeconfig and the apiserver cert are bound to cp1's address — there is no stable name for a second apiserver to live behind. Converting later means regenerating certs and kubeconfigs and editing the `kubeadm-config` ConfigMap by hand; kubeadm has no supported one-command path. Practical consequence: their "HA fix" is effectively a cluster rebuild — which is why the flag belongs in every `kubeadm init` you ever run, HA plans or not.
