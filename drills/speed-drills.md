# CKA Speed Drills — Daily Timed Circuits

Timed circuits, 20–30 minutes a day, one per exam domain plus a mixed circuit. The point is not learning — the domain modules do that — it is compressing known operations below exam time budgets. A task you can do in 4 minutes untimed and 9 minutes under a clock is a task you cannot do.

**Lab:** 3-node kind cluster `cka`, context `kind-cka`. Node names: `cka-control-plane`, `cka-worker`, `cka-worker2`. Standing setup, assumed by every circuit:

```bash
kubectl config use-context kind-cka
alias k=kubectl
export do="--dry-run=client -o yaml"
export now="--grace-period=0 --force"
```

## Rules

1. **Circuit A: no docs, no browser.** These are reflexes; `kubectl --help` is the only crutch allowed (it exists on the exam too).
2. **All other circuits: docs allowed** (kubernetes.io/docs, helm.sh/docs only — same as the exam) **but the clock never stops.** Docs time is task time.
3. A task **passes** only if its pass condition verifies **within the time target**. Over time = fail, even if correct. Log it as a `speed` fail.
4. Timer discipline: start the clock before reading task 1 of the circuit, stop after the last pass condition. Use `time` or a phone stopwatch face-down until done.
5. Run each circuit's **setup fence before starting the clock**; run the cleanup fence after logging.
6. Verification is part of the task. An unverified task is a fail.
7. **Graduation rule:** two consecutive 100% runs of a circuit at target → move it to twice-weekly and add time pressure (−20% targets).
8. Every fail gets one line in the scoring log with a reason: `knowledge` / `speed` / `misread` / `env`.

---

## Circuit A — Core object creation (no docs; daily; ~7 min)

```bash
# setup (before the clock)
k create ns drill-a 2>/dev/null || true
```

| # | Task | Target | Pass condition |
|---|---|---|---|
| A1 | Pod `web1`, image `nginx:1.27`, in `drill-a` | 30s | `k -n drill-a get pod web1` → Running |
| A2 | Deployment `web`, image `nginx`, 3 replicas, in `drill-a` | 30s | `k -n drill-a get deploy web -o jsonpath='{.status.readyReplicas}'` → `3` |
| A3 | Expose `web` as ClusterIP service `web`, port 80 | 30s | `k -n drill-a get endpoints web` → 3 addresses |
| A4 | ConfigMap `app-cm` with `env=prod` and `tier=web` | 20s | `k -n drill-a get cm app-cm -o jsonpath='{.data.env}'` → `prod` |
| A5 | Secret `app-sec` with `pass=s3cret` | 20s | `k -n drill-a get secret app-sec -o jsonpath='{.data.pass}' \| base64 -d` → `s3cret` |
| A6 | Scale `web` to 5 replicas | 10s | readyReplicas → `5` |
| A7 | Update `web` image to `nginx:1.27-alpine`, wait for rollout | 40s | `k -n drill-a rollout status deploy/web` → success |
| A8 | Job `once` (busybox) running `date`, in `drill-a` | 40s | `k -n drill-a get job once -o jsonpath='{.status.succeeded}'` → `1` |
| A9 | CronJob `tick` (busybox) `echo hello` every 5 minutes | 60s | `k -n drill-a get cronjob tick -o jsonpath='{.spec.schedule}'` → `*/5 * * * *` |
| A10 | Throwaway interactive pod (busybox, `--rm`, Never) — enter, `exit` | 30s | pod gone after exit: `k -n drill-a get pods` shows no `tmp` |

Reference commands (peek only after a failed run, then re-run the circuit): `k -n drill-a run web1 --image=nginx:1.27` · `k -n drill-a create deploy web --image=nginx --replicas=3` · `k -n drill-a expose deploy web --port=80` · `k -n drill-a create cm app-cm --from-literal=env=prod --from-literal=tier=web` · `k -n drill-a create secret generic app-sec --from-literal=pass=s3cret` · `k -n drill-a scale deploy web --replicas=5` · `k -n drill-a set image deploy/web nginx=nginx:1.27-alpine` · `k -n drill-a create job once --image=busybox -- date` · `k -n drill-a create cronjob tick --image=busybox --schedule="*/5 * * * *" -- echo hello` · `k -n drill-a run tmp --rm -it --image=busybox --restart=Never -- sh`

```bash
# cleanup
k delete ns drill-a --wait=false
```

## Circuit B — Workloads & Scheduling (15% domain; ~15 min)

```bash
# setup
k create ns drill-b 2>/dev/null || true
```

| # | Task | Target | Pass condition |
|---|---|---|---|
| B1 | Deployment `api` (nginx, 2 replicas) with requests cpu=100m/mem=128Mi, limits cpu=200m/mem=256Mi | 2m | `k -n drill-b get deploy api -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}'` → `100m` |
| B2 | Label `cka-worker` with `disk=ssd`; pod `pinned` (nginx) scheduled there via nodeSelector | 90s | `k -n drill-b get pod pinned -o jsonpath='{.spec.nodeName}'` → `cka-worker` |
| B3 | Taint `cka-worker2` with `gpu=true:NoSchedule`; pod `tolerant` (nginx) with matching toleration + nodeSelector landing on it (use the preset `kubernetes.io/hostname: cka-worker2` label — no need to add one) | 3m | `k -n drill-b get pod tolerant -o jsonpath='{.spec.nodeName}'` → `cka-worker2` |
| B4 | Cordon `cka-worker`, drain it (`--ignore-daemonsets --delete-emptydir-data --force`), then uncordon | 2m | `k get node cka-worker` → Ready (no SchedulingDisabled); `api` pods all Running |
| B5 | Roll `api` to image `nginx:1.27`, then `rollout undo`; confirm original image | 90s | `k -n drill-b get deploy api -o jsonpath='{.spec.template.spec.containers[0].image}'` → `nginx` |
| B6 | HPA on `api`: cpu 50%, min 1, max 4 | 60s | `k -n drill-b get hpa api` exists with MinPods 1 / MaxPods 4 |
| B7 | Pod `quiet` (busybox, `sleep 3600`) with a preferred podAntiAffinity against `app=api` pods (docs allowed) | 3m | `k -n drill-b get pod quiet` → Running; affinity present in `k -n drill-b get pod quiet -o yaml` |

Notes: `k autoscale deploy api --cpu-percent=50 --min=1 --max=4 -n drill-b` is the fast path for B6; for memory metrics or scaling behavior you must write `autoscaling/v2` YAML from the docs. Version note: `--replicas` on `kubectl create deploy` requires kubectl ≥1.19 (any current exam version qualifies).

```bash
# cleanup
k delete ns drill-b --wait=false
k taint node cka-worker2 gpu- 2>/dev/null || true
k label node cka-worker disk- 2>/dev/null || true
k uncordon cka-worker 2>/dev/null || true
```

## Circuit C — Services & Networking (20% domain; ~18 min)

```bash
# setup — includes Gateway API CRDs (one-time; pick the current release tag)
k create ns drill-c 2>/dev/null || true
k -n drill-c create deploy web --image=nginx --replicas=2
k -n drill-c run client --image=busybox --labels=role=client -- sleep 3600
k apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
```

| # | Task | Target | Pass condition |
|---|---|---|---|
| C1 | Expose `web` as ClusterIP `web` port 80; verify DNS from a temp pod (`wget -qO- http://web.drill-c.svc.cluster.local`) | 2m | wget returns nginx welcome HTML |
| C2 | NodePort service `web-np` for `web`, port 80, nodePort 30080 | 2m | `k -n drill-c get svc web-np -o jsonpath='{.spec.ports[0].nodePort}'` → `30080` |
| C3 | Default-deny-all-ingress NetworkPolicy `deny-all` in `drill-c` | 90s | `k -n drill-c describe netpol deny-all` → applies to all pods, no ingress rules |
| C4 | NetworkPolicy `allow-client`: only pods labeled `role=client` may reach `app=web` pods on TCP 80 | 3m | `k -n drill-c get netpol allow-client -o yaml` shows podSelector `app=web`, from podSelector `role=client`, port 80 |
| C5 | NetworkPolicy `allow-ns`: additionally allow all pods from namespaces labeled `team=green` | 3m | spec shows namespaceSelector matchLabels `team=green` |
| C6 | Ingress `web-ing` (networking.k8s.io/v1): host `web.example.com`, path `/`, backend `web:80` | 3m | `k -n drill-c get ingress web-ing -o jsonpath='{.spec.rules[0].host}'` → `web.example.com` |
| C7 | HTTPRoute `web-route` (gateway.networking.k8s.io/v1): parentRef `main-gw`, hostname `web.example.com`, backend `web:80` (copy base from docs) | 3m | `k -n drill-c get httproute web-route` exists; spec has parentRefs + backendRefs |

**Enforcement caveat (one line, important):** kind's default CNI (kindnet) does **not** enforce NetworkPolicy — pass conditions here are spec-correctness, not connectivity; for behavioral verification use killercoda scenarios (enforcing CNI) or a Calico-based kind cluster. Exam-flavor note: the real exam clusters enforce policies — same YAML, real blocking.

```bash
# cleanup
k delete ns drill-c --wait=false
```

## Circuit D — Storage (10% domain; ~10 min)

```bash
# setup
k create ns drill-d 2>/dev/null || true
```

| # | Task | Target | Pass condition |
|---|---|---|---|
| D1 | PV `pv-drill`: 1Gi, RWO, hostPath `/tmp/pv-drill`, storageClassName `manual` (docs copy-paste) | 2m | `k get pv pv-drill` → Available |
| D2 | PVC `pvc-drill` in `drill-d`: 1Gi, RWO, storageClassName `manual` | 90s | `k -n drill-d get pvc pvc-drill` → Bound to `pv-drill` |
| D3 | Pod `writer` (busybox, `sleep 3600`) mounting `pvc-drill` at `/data`; write a file via `k exec` | 2m | `k -n drill-d exec writer -- ls /data` shows your file |
| D4 | PVC `pvc-dyn` on kind's default SC `standard` (WaitForFirstConsumer): create it, observe Pending, attach a pod, observe Bound | 2m | Pending before pod; `k -n drill-d get pvc pvc-dyn` → Bound after |
| D5 | Create StorageClass `slow` (provisioner `rancher.io/local-path`) and make it the default; demote `standard` | 2m | `k get sc` shows `slow (default)` |

D5 fast path: `k patch storageclass standard -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'` and the mirror-image patch with `"true"` on `slow`. Exam-flavor note: on the exam the provisioner name will differ (given in the task) — the annotation mechanics are identical.

```bash
# cleanup
k delete ns drill-d --wait=false
k delete pv pv-drill 2>/dev/null || true
k delete sc slow 2>/dev/null || true
k patch storageclass standard -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

## Circuit E — Cluster architecture, RBAC, etcd (25% domain; ~20 min)

```bash
# setup
k create ns drill-e 2>/dev/null || true
```

| # | Task | Target | Pass condition |
|---|---|---|---|
| E1 | ServiceAccount `app-sa` in `drill-e` | 15s | `k -n drill-e get sa app-sa` |
| E2 | Role `pod-reader`: get, list, watch on pods | 45s | `k -n drill-e describe role pod-reader` shows the 3 verbs |
| E3 | RoleBinding `read-pods`: `pod-reader` → `app-sa` | 45s | see E4 |
| E4 | Verify the grant with `auth can-i` (both a should-pass and a should-fail check) | 30s | `k auth can-i list pods --as=system:serviceaccount:drill-e:app-sa -n drill-e` → `yes`; `... delete pods ...` → `no` |
| E5 | ClusterRole `node-viewer` (get, list on nodes) + ClusterRoleBinding `carol-nodes` for user `carol` | 90s | `k auth can-i list nodes --as=carol` → `yes` |
| E6 | etcd snapshot: save to `/var/lib/etcd/drill-snap.db` and verify status (kind adaptation below) | 5m | snapshot status prints hash/revision/keys/size table |
| E7 | Static pod `static-web` (nginx) on the control-plane node | 3m | `k get pod static-web-cka-control-plane -n default` → Running |

E6 on kind — exec into the etcd pod (the node containers do not ship etcdctl):

```bash
k -n kube-system exec etcd-cka-control-plane -- sh -c \
  'ETCDCTL_API=3 etcdctl \
   --endpoints=https://127.0.0.1:2379 \
   --cacert=/etc/kubernetes/pki/etcd/ca.crt \
   --cert=/etc/kubernetes/pki/etcd/server.crt \
   --key=/etc/kubernetes/pki/etcd/server.key \
   snapshot save /var/lib/etcd/drill-snap.db'
k -n kube-system exec etcd-cka-control-plane -- sh -c \
  'ETCDCTL_API=3 etcdctl snapshot status /var/lib/etcd/drill-snap.db -w table'
```

Exam-flavor note: on the real exam you `ssh` to the control-plane node, `sudo -i`, and run `etcdctl` on the host with the cert paths given in the task — the flags are identical, only the entry point differs. (`etcdctl snapshot status` is deprecated in favor of `etcdutl` in newer etcd releases; both syntaxes work on current exam versions.)

E7 on kind — write the manifest inside the node container:

```bash
k run static-web --image=nginx $do | docker exec -i cka-control-plane \
  tee /etc/kubernetes/manifests/static-web.yaml > /dev/null
```

Exam-flavor note: on the exam this is `ssh` + drop the file in `/etc/kubernetes/manifests/` (confirm the path via the kubelet's `staticPodPath`).

```bash
# cleanup
k delete ns drill-e --wait=false
k delete clusterrole node-viewer 2>/dev/null || true
k delete clusterrolebinding carol-nodes 2>/dev/null || true
docker exec cka-control-plane rm -f /etc/kubernetes/manifests/static-web.yaml
```

## Circuit F — Troubleshooting first-30-seconds sequences (30% domain; ~13 min)

The domain where sequence beats improvisation. Drill the opening moves until they run without thought.

```bash
# setup — creates the broken state (run before the clock, don't read it too closely)
k create ns drill-f 2>/dev/null || true
k -n drill-f run broken-image --image=nginx:1.99-doesnotexist
k -n drill-f run hungry --image=nginx \
  --overrides='{"apiVersion":"v1","spec":{"containers":[{"name":"hungry","image":"nginx","resources":{"requests":{"cpu":"64"}}}]}}'
k -n drill-f run crasher --image=busybox -- sh -c "echo boom; exit 1"
k -n drill-f create deploy web --image=nginx --replicas=2
k -n drill-f expose deploy web --port=80 --name=web-svc
k -n drill-f set selector svc web-svc 'app=webz'
```

| # | Task | Target | Pass condition |
|---|---|---|---|
| F1 | The opening sequence, from memory, on `drill-f`: pods wide → events by time → describe the worst offender | 60s | You ran exactly: `k -n drill-f get pods -o wide` → `k -n drill-f get events --sort-by=.lastTimestamp` → `k -n drill-f describe pod <worst>` |
| F2 | Fix `broken-image` | 90s | pod Running (`k -n drill-f set image pod/broken-image broken-image=nginx` or edit) |
| F3 | Diagnose why `hungry` is Pending — state the reason in one sentence, then fix by lowering the request | 2m | `k -n drill-f get pod hungry` → Running; you said "insufficient cpu: requests 64 cores" before touching anything |
| F4 | Diagnose `crasher`: extract the last words of the previous container | 90s | `k -n drill-f logs crasher --previous` shows `boom`; you can name the loop cause (exit 1 + restartPolicy Always) |
| F5 | `web-svc` has no endpoints — find why and fix without recreating the service | 2m | `k -n drill-f get endpoints web-svc` → 2 addresses (`k -n drill-f set selector svc web-svc 'app=web'`) |
| F6 | Node-down sequence, from memory (execute against `cka-worker` via `docker exec`): kubelet status → kubelet journal tail → restart kubelet | 2m | You ran the equivalents of `systemctl status kubelet`, `journalctl -u kubelet --no-pager \| tail -20`, `systemctl restart kubelet` inside the node |
| F7 | Control-plane triage: list all containers (incl. exited) on the control-plane with crictl | 60s | `docker exec cka-control-plane crictl ps -a` output read; you can point at apiserver/etcd/scheduler/controller-manager |

Exam-flavor note: F6/F7 on the exam are `ssh node01; sudo -i` — the systemctl/journalctl/crictl commands are identical; `docker exec <node>` is the kind stand-in. Getting off the node afterwards (`exit`, `exit`) is part of the drill.

```bash
# cleanup
k delete ns drill-f --wait=false
```

## Circuit G — JSONPath & output extraction (~9 min)

Docs allowed (the JSONPath reference page), but graduate to memory — these appear as sub-steps everywhere and as standalone "write X to file Y" tasks.

| # | Task | Target | Pass condition |
|---|---|---|---|
| G1 | All node InternalIPs, space-separated, into `/tmp/node-ips.txt` | 90s | file contains 3 IPs |
| G2 | Every container image in `kube-system`, one per line | 90s | one image per line, no brackets/quotes |
| G3 | All pods in all namespaces sorted by creation time | 30s | oldest first |
| G4 | Custom-columns `NAME,NODE` for all pods cluster-wide | 60s | two clean columns |
| G5 | For each node: `name Ready-status` on one line | 90s | 3 lines like `cka-worker True` |
| G6 | Print each node's taints next to its name | 60s | control-plane shows its taint, workers show none (unless circuit B left one — that's a real find) |
| G7 | Decode secret `app-sec` key `pass` (recreate it first if circuit A was cleaned) | 60s | `s3cret` on stdout |
| G8 | ClusterIP of the `kubernetes` service in `default` | 30s | a single IP, no newline noise |

Reference answers (check after the run):

```bash
k get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' > /tmp/node-ips.txt
k -n kube-system get pods -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | sort -u
k get pods -A --sort-by=.metadata.creationTimestamp
k get pods -A -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName
k get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
k get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
k -n drill-a get secret app-sec -o jsonpath='{.data.pass}' | base64 -d
k get svc kubernetes -o jsonpath='{.spec.clusterIP}'
```

## Circuit H — Helm & Kustomize (~15 min)

```bash
# setup
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
mkdir -p /tmp/drill-k/base
cat > /tmp/drill-k/base/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kapp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kapp
  template:
    metadata:
      labels:
        app: kapp
    spec:
      containers:
      - name: kapp
        image: nginx
EOF
cat > /tmp/drill-k/base/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: drill-h
resources:
- deployment.yaml
EOF
k create ns drill-h 2>/dev/null || true
```

| # | Task | Target | Pass condition |
|---|---|---|---|
| H1 | `helm repo update`, then find nginx charts in the bitnami repo | 60s | `helm search repo bitnami/nginx` lists the chart |
| H2 | Install release `web` from `bitnami/nginx` into `drill-h` with `replicaCount=2` | 2m | `helm -n drill-h status web` → deployed; 2 pods |
| H3 | Upgrade `web` to `replicaCount=3` | 60s | `k -n drill-h get deploy` shows 3 replicas; `helm -n drill-h history web` shows rev 2 |
| H4 | Roll back `web` to revision 1 | 60s | history shows rev 3 "Rollback to 1"; 2 pods again |
| H5 | Render the chart's manifests to `/tmp/web.yaml` **without** touching the cluster | 60s | `helm template web bitnami/nginx --set replicaCount=2 > /tmp/web.yaml`; file non-empty |
| H6 | Uninstall `web` | 30s | `helm -n drill-h list` empty |
| H7 | Build the kustomization at `/tmp/drill-k/base` to stdout, then apply it | 90s | `k kustomize /tmp/drill-k/base` renders; `k apply -k /tmp/drill-k/base`; deploy `kapp` in `drill-h` Ready |
| H8 | Add a `namePrefix: prod-` to the kustomization and re-apply; delete the old deployment | 2m | `k -n drill-h get deploy prod-kapp` exists; `kapp` gone |

Exam-flavor note: exam Helm tasks give you the repo URL and values in the task text — the muscle memory is `repo add → install -n ns --create-namespace --set k=v → upgrade → rollback`, exactly H1–H4.

```bash
# cleanup
helm -n drill-h uninstall web 2>/dev/null || true
k delete ns drill-h --wait=false
rm -rf /tmp/drill-k
```

## Circuit M — Mixed daily (exam pacing; hard cap 20 min)

Run under full exam rules: docs allowed, clock merciless, verify everything, flag-and-move if a task stalls (come back after M10). This circuit is the closest thing to the exam outside killer.sh.

```bash
# setup
k create ns drill-m 2>/dev/null || true
k -n drill-m run sick --image=nginx:1.99-nope
```

| # | Task | Target | Pass condition |
|---|---|---|---|
| M1 | Confirm context is `kind-cka` (yes, every time) | 10s | `k config current-context` |
| M2 | Deployment `front` (nginx, 2 replicas) + ClusterIP service on port 80, in `drill-m` | 90s | endpoints populated |
| M3 | Fix pod `sick` | 60s | Running |
| M4 | Default-deny-ingress NetworkPolicy in `drill-m` | 90s | spec correct (`k -n drill-m describe netpol`) |
| M5 | PV (`manual`, 500Mi, hostPath) + bound PVC in `drill-m` | 3m | PVC Bound |
| M6 | SA `robot` + Role + RoleBinding: robot may `create` and `list` configmaps; verify with `auth can-i` | 2m30s | `yes` / `no` pair correct |
| M7 | etcd snapshot to `/var/lib/etcd/m-snap.db` | 3m | status table prints |
| M8 | All pod images in `drill-m`, one per line, to `/tmp/m-images.txt` | 60s | file correct |
| M9 | Cordon `cka-worker2`, then uncordon | 30s | node schedulable at the end |
| M10 | Scale `front` to 4 and confirm rollout | 30s | readyReplicas 4 |

Total targets: ~15 min — the 5-minute buffer is your flag-and-move practice. Finishing at 19:59 with all passes is a pass; finishing at 21:00 with all passes is a fail. Log it that way.

```bash
# cleanup
k delete ns drill-m --wait=false
k uncordon cka-worker2 2>/dev/null || true
```

---

## Weekly rotation plan

Circuit A runs daily until you graduate it (two consecutive 100% runs at target), then every other day.

| Day | Circuits | ~Time | Focus |
|---|---|---|---|
| Mon | A + F | 20 min | Start the week on the 30% domain |
| Tue | A + E | 27 min | etcd + RBAC reflexes |
| Wed | A + C | 25 min | NetPol/Ingress/Gateway YAML speed |
| Thu | A + B + G | 30 min | Scheduling ops + extraction |
| Fri | A + D + H | 30 min | Storage + Helm/Kustomize |
| Sat | M (strict exam rules) | 20 min | Pacing rehearsal |
| Sun | rest — or re-run the week's worst circuit, once | 0–20 min | Recovery beats grinding |

**After killer.sh session 1 (Aug 8):** replace this rotation with a triage-weighted one — your weakest domain's circuit daily alongside A, everything else on the Sat mixed run. The debrief matrix in `course/week-10-final-prep/masterclass.md` tells you which circuit that is.

**Final week (Aug 10–16):** rotation continues Mon–Thu only, then Fri = one M run, Sat = optional single A run, Sun = nothing. Taper is part of the program.

## Scoring log template

Copy into `progress.md` or a notebook; one row per circuit run. The trend matters more than any single run.

| Date | Circuit | Time (total) | Passed / total | Fails (task: reason) | Notes |
|---|---|---|---|---|---|
| 2026-07-13 | A | 8:40 | 8/10 | A7: speed, A9: knowledge (cronjob syntax) | forgot `--schedule` quoting |
| 2026-07-13 | F | 14:10 | 6/7 | F6: env (node exec fumbling) | rehearse docker exec pattern |
|  |  |  |  |  |  |
|  |  |  |  |  |  |

Reading the log:

- **Same task failing twice for `knowledge`** → back to that domain module's exercises before drilling again; drilling an unknown operation just rehearses confusion.
- **`speed` fails clustering in one circuit** → run that circuit two days in a row; speed fails respond fast to repetition.
- **Any `misread` fail** → the fix is the reading protocol (read twice, extract context/namespace/names/constraints), not repetition.
- **Circuit A below 100% in August** → that is the alarm bell; nothing else matters until it's silent.
