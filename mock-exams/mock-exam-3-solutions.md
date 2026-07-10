# CKA Mock Exam 3 — Solutions, Forensics and Grading (Killer-Level)

Grade against the rubrics below. Award a component only if the finish state is actually observable on the cluster (`kubectl get ...` / a file on disk), never because "the command looked right". This paper is **deliberately harder than the real exam** — read the killer-calibration table at the bottom before you judge your number. On a killer-style paper, **≥55/100 within the time box ≈ ready for the real exam.**

Time budgets sum to 126 minutes on purpose: you cannot finish everything in 120. Triage, bank the cheap points, and flag the rest — that is the graded skill.

**Central dependency:** Task 1 (kube-controller-manager down) gates most of the paper. Until it is fixed, no Deployment produces pods, no Service gets endpoints, no PVC binds, and node NotReady never surfaces. If you find yourself "fixing" a task whose object looks correct but never reconciles, stop and check Task 1.

---

## Task 1 — Deployments cluster-wide create no pods

**Domain:** Troubleshooting (8%) | **Time budget:** 10 min

**Forensics — what each command tells you:**

```bash
k -n apex get deploy canary            # READY 0/1, UP-TO-DATE 0
k -n apex get rs,pods                  # NOTHING - no ReplicaSet, no pods
k -n apex describe deploy canary       # no "Scaled up replica set" event at all
```

A Deployment with **no ReplicaSet** means the *deployment controller* never ran. Controllers live in kube-controller-manager, so go straight to it:

```bash
k -n kube-system get pods | grep controller-manager
#   kube-controller-manager-cka-control-plane   0/1   CrashLoopBackOff
k -n kube-system describe pod kube-controller-manager-cka-control-plane
#   ... exec: "kube-controller-managerX": executable file not found in $PATH
```

Fix the static-pod manifest on the node (permanent — kubelet re-reads the file):

```bash
docker exec -it cka-control-plane bash     # real exam: ssh cka-control-plane + sudo -i
  sed -i 's|- kube-controller-managerX$|- kube-controller-manager|' \
    /etc/kubernetes/manifests/kube-controller-manager.yaml
  exit
k -n kube-system get pods -w               # kubelet re-creates the static pod -> Running
k -n apex get deploy canary                # controller reconciles -> 1/1
echo /etc/kubernetes/manifests/kube-controller-manager.yaml > /tmp/exam3/01-cause.txt
k -n apex create deployment phoenix --image=nginx:1.27-alpine --replicas=3
k -n apex get deploy phoenix                # 3/3
```

**Why:** kube-controller-manager runs the deployment, replicaset, endpoint, node-lifecycle and PV-binder controllers; while it crash-loops, none of them reconcile — hence "no ReplicaSet, no pods, no events". Editing the manifest under `/etc/kubernetes/manifests/` *is* the permanent fix; the kubelet watches that directory and restarts the mirror pod. `kubectl delete` on a static/mirror pod does nothing.

| Component | Points |
|---|---|
| Localized to kube-controller-manager (no-RS reasoning + kube-system) | 3 |
| Fixed static-pod manifest on the node (permanent) + cause path file | 3 |
| canary 1/1 **and** phoenix 3/3 Ready | 2 |

## Task 2 — Certificate user, RBAC and standalone kubeconfig

**Domain:** Cluster Architecture (8%) | **Time budget:** 10 min

```bash
cd /tmp/exam3
openssl genrsa -out mara.key 2048
openssl req -new -key mara.key -subj "/CN=mara" -out mara.csr

REQ=$(base64 < mara.csr | tr -d '\n')      # Linux exam terminal: base64 -w 0 mara.csr
cat <<EOF | k apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: mara
spec:
  request: $REQ
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages:
  - client auth
EOF

k certificate approve mara
k get csr mara -o jsonpath='{.status.certificate}' | base64 -d > mara.crt   # .status.certificate stays empty (mara.crt empty) until kube-controller-manager's csrsigning controller is up - Task 1

k -n citadel create role deploy-manager \
  --verb=get,list,watch,create,update --resource=deployments
k -n citadel create rolebinding mara-deploy-manager --role=deploy-manager --user=mara
```

Build the **standalone** kubeconfig (embedded certs, own file):

```bash
KCFG=/tmp/exam3/mara.kubeconfig
SERVER=$(k config view --raw -o jsonpath="{.clusters[?(@.name=='kind-cka')].cluster.server}")
k config view --raw -o jsonpath="{.clusters[?(@.name=='kind-cka')].cluster.certificate-authority-data}" \
  | base64 -d > /tmp/exam3/ca.crt

KUBECONFIG=$KCFG k config set-cluster kind-cka \
  --server="$SERVER" --certificate-authority=/tmp/exam3/ca.crt --embed-certs=true
KUBECONFIG=$KCFG k config set-credentials mara \
  --client-certificate=/tmp/exam3/mara.crt --client-key=/tmp/exam3/mara.key --embed-certs=true
KUBECONFIG=$KCFG k config set-context mara@cka --cluster=kind-cka --user=mara --namespace=citadel
KUBECONFIG=$KCFG k config use-context mara@cka
```

Verify **using only that kubeconfig** and record the answers:

```bash
{
  echo "create deployments: $(k --kubeconfig=$KCFG auth can-i create deployments -n citadel)"
  echo "delete deployments: $(k --kubeconfig=$KCFG auth can-i delete deployments -n citadel)"
  echo "get secrets:        $(k --kubeconfig=$KCFG auth can-i get secrets -n citadel)"
} > /tmp/exam3/02-verify.txt
cat /tmp/exam3/02-verify.txt                # yes / no / no
```

**Why:** the CN of the client cert becomes the username; `kubernetes.io/kube-apiserver-client` is the only signer that mints user client certs. `auth can-i` works even as mara because every authenticated user may create `SelfSubjectAccessReview`. The Role omits `delete` and never mentions secrets, so the deny answers are structural, not accidental.

| Component | Points |
|---|---|
| Key + CSR (CN=mara), CSR object correct signer/usages/expiration, approved, crt extracted | 3 |
| Role (exactly get/list/watch/create/update on deployments) + RoleBinding to user mara | 2 |
| Standalone kubeconfig authenticates as mara + 02-verify.txt shows yes/no/no | 3 |

## Task 3 — Gateway API canary traffic split

**Domain:** Services & Networking (7%) | **Time budget:** 8 min

Docs path: kubernetes.io/docs/concepts/services-networking/gateway/ has copy-pastable skeletons. Save all three to the file and apply it:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: exam-gwc
spec:
  controllerName: example.com/exam-gateway
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web-gw
  namespace: mesh
spec:
  gatewayClassName: exam-gwc
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    hostname: web.exam3.local
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: web-split
  namespace: mesh
spec:
  parentRefs:
  - name: web-gw
  hostnames:
  - web.exam3.local
  rules:
  - backendRefs:
    - name: web-v1
      port: 80
      weight: 80
    - name: web-v2
      port: 80
      weight: 20
```

```bash
k apply -f /tmp/exam3/03-gateway.yaml
k -n mesh get gateway,httproute
k -n mesh describe httproute web-split
```

**Why:** a weighted split lives in **one rule with two `backendRefs`** carrying `weight` — not two separate rules (two rules would route by match criteria, not split traffic). `GatewayClass` is cluster-scoped, so it takes no namespace. The Gateway will never report `Programmed` here (no controller installed) — the spec is what is graded.

| Component | Points |
|---|---|
| GatewayClass exam-gwc with controllerName example.com/exam-gateway | 1.5 |
| Gateway class + listener name/port/protocol/hostname + allowedRoutes Same | 2.5 |
| HTTPRoute parentRefs + hostname + single rule, weights 80/20 on web-v1/web-v2:80 | 2.5 |
| Combined manifest saved to /tmp/exam3/03-gateway.yaml | 0.5 |

## Task 4 — The PVC that would not bind

**Domain:** Storage (6%) | **Time budget:** 8 min

**Forensics:**

```bash
k -n vault get pvc data-fast          # Pending
k get sc local-fast                   # VOLUMEBINDINGMODE = WaitForFirstConsumer
```

`WaitForFirstConsumer` + no consumer ⇒ **Pending is expected, not a fault.** Create the consumer, then look again:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: consumer
  namespace: vault
  labels:
    app: consumer
spec:
  replicas: 1
  selector:
    matchLabels:
      app: consumer
  template:
    metadata:
      labels:
        app: consumer
    spec:
      containers:
      - name: app
        image: busybox:1.36
        command: ["sh", "-c", "sleep 43200"]
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: data-fast
```

```bash
k -n vault get pod -l app=consumer                  # still Pending
k -n vault describe pod -l app=consumer             # ...didn't find available persistent volumes to bind
k get pv pv-fast -o jsonpath='{.status.phase}{"  claimRef="}{.spec.claimRef.namespace}/{.spec.claimRef.name}{"\n"}'
#   Available  claimRef=vault/ghost-claim   <- reserved to a PVC that does not exist
k patch pv pv-fast --type=json -p '[{"op":"remove","path":"/spec/claimRef"}]'
k -n vault get pvc data-fast                         # Bound
k -n vault get pod -l app=consumer -o wide           # Running on cka-worker (PV nodeAffinity)
```

**Why:** the surface symptom (Pending PVC) is a red herring — WFFC defers binding until a pod schedules. The *real* fault is a stale `claimRef` reserving `pv-fast` for a non-existent claim; a reserved PV never binds to anyone else. Clearing the claimRef frees it, and the fix touches only the PV — the PVC is untouched, as required.

| Component | Points |
|---|---|
| Recognized WFFC Pending is normal; created consumer mounting data-fast at /data | 2 |
| Diagnosed the reserved PV (claimRef to ghost) and cleared it without touching the PVC | 2 |
| data-fast Bound + consumer Running on cka-worker (the PV's pinned node) | 2 |

## Task 5 — One deployment, two independent faults

**Domain:** Troubleshooting (8%) | **Time budget:** 10 min

The first fault masks the second — fix, re-observe, fix again.

```bash
k -n orbit get pods                          # ImagePullBackOff
k -n orbit describe pod -l app=telemetry     # Failed to pull image "nginx:1.99-alpine"
k -n orbit set image deploy/telemetry web=nginx:1.27-alpine

k -n orbit get pods                          # now CreateContainerConfigError
k -n orbit describe pod -l app=telemetry     # couldn't find key auth-token in Secret orbit/telemetry-token
k -n orbit get secret telemetry-token -o jsonpath='{.data}'; echo   # the key is "token"
k -n orbit patch deploy telemetry --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/env/0/valueFrom/secretKeyRef/key","value":"token"}]'

k -n orbit get deploy telemetry              # 2/2
printf '%s\n%s\n' \
  "image tag nginx:1.99-alpine does not exist -> ImagePullBackOff" \
  "env TELEMETRY_TOKEN referenced missing Secret key auth-token; real key is token -> CreateContainerConfigError" \
  > /tmp/exam3/05-causes.txt
```

**Why:** the container is only *created* after its image resolves, so the missing-secret-key error cannot surface until the image is fixed — classic masking. The constraint "don't remove the env configuration / don't modify the Secret" forces you to correct the **key reference** rather than delete the env var or edit the Secret.

| Component | Points |
|---|---|
| Fault 1: image tag corrected to a real tag | 2.5 |
| Fault 2: secretKeyRef key corrected to `token` (env kept, Secret untouched) | 3 |
| Both root causes written to 05-causes.txt + 2/2 Ready, edited in place | 2.5 |

## Task 6 — etcd backup and restore roundtrip

**Domain:** Cluster Architecture (10%) | **Time budget:** 15 min

Do the whole sequence in order — the restore reverts anything created after the snapshot.

```bash
ETCD=etcd-cka-control-plane
E=/etc/kubernetes/pki/etcd

# 1) Snapshot. Writes into the node's /var/lib/etcd via the etcd pod's hostPath mount.
k -n kube-system exec $ETCD -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=$E/ca.crt --cert=$E/server.crt --key=$E/server.key \
  snapshot save /var/lib/etcd/exam3-snap.db
docker cp cka-control-plane:/var/lib/etcd/exam3-snap.db /tmp/exam3/exam3-snap.db

# 2) Marker created AFTER the snapshot (must be gone after restore).
k create configmap after-snap -n default

# 3) Restore into a NEW dir. Offline op - safe to run while etcd is live.
#    Reproduce the member identity the static pod boots with (read them from the manifest):
docker exec cka-control-plane grep -E '\--name=|--initial-cluster=|--initial-advertise-peer-urls=' \
  /etc/kubernetes/manifests/etcd.yaml
#    --name=cka-control-plane
#    --initial-cluster=cka-control-plane=https://172.23.0.2:2380
#    --initial-advertise-peer-urls=https://172.23.0.2:2380
k -n kube-system exec $ETCD -- etcdutl snapshot restore /var/lib/etcd/exam3-snap.db \
  --name=cka-control-plane \
  --initial-cluster=cka-control-plane=https://172.23.0.2:2380 \
  --initial-advertise-peer-urls=https://172.23.0.2:2380 \
  --data-dir=/var/lib/etcd/restore-exam3
echo /var/lib/etcd/restore-exam3 > /tmp/exam3/06-datadir.txt
```

Repoint the etcd static pod at the restored dir (it sits under the already-mounted `/var/lib/etcd`, so only the `--data-dir` flag changes):

```bash
docker exec -it cka-control-plane bash
  sed -i 's|- --data-dir=/var/lib/etcd$|- --data-dir=/var/lib/etcd/restore-exam3|' \
    /etc/kubernetes/manifests/etcd.yaml
  exit
```

Verify:

```bash
k -n kube-system get pod $ETCD              # re-created by kubelet, Running (give it ~30-60s)
k get cm after-snap                         # Error from server (NotFound)  <- restore worked
```

**Why:** the snapshot is a point-in-time; `after-snap` was written later, so a restored member never contains it. Always restore into a **fresh** directory — never over the live data dir — and reproduce `--name` / `--initial-cluster` / `--initial-advertise-peer-urls`, or etcd refuses to boot on the restored member. Repointing is a static-pod manifest edit, so the kubelet restarts etcd automatically; no `systemctl` needed on kind.

*Exam flavor: on a kubeadm host the binaries live on the node (certs under `/etc/kubernetes/pki/etcd/`) and you'd stop the kube-apiserver + etcd manifests, restore with `etcdutl`, then restore the manifests. Here the binaries exist only inside the etcd image, so snapshot/restore go through `kubectl exec`.*

| Component | Points |
|---|---|
| Snapshot with correct endpoint/cacert/cert/key, copied to /tmp/exam3 | 3 |
| after-snap CM created; restore into a NEW dir (member identity reproduced); datadir file written | 3 |
| etcd manifest repointed; API server healthy again; `after-snap` returns NotFound | 4 |

## Task 7 — Drain blocked by a PodDisruptionBudget

**Domain:** Troubleshooting (7%) | **Time budget:** 8 min

```bash
k get nodes                                  # cka-worker2 must be Ready first (Task 10)
k -n fortress get deploy ledger              # 2/2
k drain cka-worker --ignore-daemonsets --delete-emptydir-data
#   evicting pod fortress/ledger-...
#   error: Cannot evict pod as it would violate the pod's disruption budget.
printf '%s\n' \
  "PodDisruptionBudget/ledger-pdb (minAvailable: 2) - error: Cannot evict pod as it would violate the pod's disruption budget" \
  > /tmp/exam3/07-blocker.txt
```

Resolve **within the constraints** (PDB unchanged, never below 2 ready) by giving the budget headroom:

```bash
k -n fortress scale deploy ledger --replicas=3
k -n fortress rollout status deploy ledger   # 3/3 - the 3rd pod lands on cka-worker2
k drain cka-worker --ignore-daemonsets --delete-emptydir-data   # succeeds now
k uncordon cka-worker
k -n fortress scale deploy ledger --replicas=2
k -n fortress get deploy ledger              # 2/2
```

**Why:** `minAvailable: 2` with exactly 2 replicas leaves **zero** allowed disruptions, so the eviction API refuses every pod on the node — a hard deadlock. Scaling to 3 creates one unit of budget, letting drain evict cka-worker's pod while 2 stay Ready; the third pod is what makes room, and the PDB is never modified. This is why the task needs a second healthy worker.

| Component | Points |
|---|---|
| First drain attempted; blocker identified as PDB/ledger-pdb + written to file | 2 |
| Scaled up to create budget, drain completed, PDB left unmodified | 3 |
| Uncordoned cka-worker + ledger returned to 2/2 | 2 |

## Task 8 — Service, NetworkPolicy and DNS, combined

**Domain:** Services & Networking (7%) | **Time budget:** 10 min

```bash
k -n bazaar get endpoints api-svc            # <none>  -> selector problem
k -n bazaar get pods --show-labels           # api pods app=api ; frontend pods role=frontend
k -n bazaar get svc api-svc -o yaml          # selector app=api-broken, targetPort 8080 (both wrong)
k -n bazaar patch svc api-svc \
  -p '{"spec":{"selector":{"app":"api"},"ports":[{"port":80,"targetPort":80,"protocol":"TCP"}]}}'
k -n bazaar get endpoints api-svc            # pod IP:80 (needs kube-controller-manager up - Task 1)
```

NetworkPolicy:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend
  namespace: bazaar
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
          role: frontend
    ports:
    - protocol: TCP
      port: 80
```

```bash
k apply -f allow-frontend.yaml
FE=$(k -n bazaar get pod -l role=frontend -o jsonpath='{.items[0].metadata.name}')
k -n bazaar exec "$FE" -- wget -qO- http://api-svc.bazaar.svc.cluster.local > /tmp/exam3/08-dns.txt
cat /tmp/exam3/08-dns.txt                     # nginx welcome HTML
```

**Why:** empty Endpoints = selector mismatch; the Service also had the wrong `targetPort`. Endpoints only repopulate once kube-controller-manager runs (Task 1), and the FQDN only resolves once CoreDNS is fixed (Task 13) — so a green result here is proof that three separate fixes all landed. `policyTypes: [Ingress]` alone leaves egress unrestricted.

| Component | Points |
|---|---|
| api-svc selector app=api **and** targetPort 80 fixed, endpoints populated | 3 |
| allow-frontend: target app=api, from role=frontend, TCP 80 only, egress untouched | 2.5 |
| FQDN fetch body saved to /tmp/exam3/08-dns.txt | 1.5 |

## Task 9 — CronJob plus manual trigger

**Domain:** Workloads & Scheduling (6%) | **Time budget:** 6 min

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: report
  namespace: batchjobs
spec:
  schedule: "*/5 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 60
      template:
        spec:
          restartPolicy: Never
          containers:
          - name: report
            image: busybox:1.36
            command: ["sh", "-c", "date; echo report-ok"]
```

```bash
k apply -f report-cronjob.yaml
k -n batchjobs create job report-now --from=cronjob/report
k -n batchjobs get job report-now -w          # COMPLETIONS 1/1
k -n batchjobs logs job/report-now            # <date> then report-ok
```

**Why:** `backoffLimit` and `activeDeadlineSeconds` belong on `jobTemplate.spec` (the Job), not on the pod; `restartPolicy: Never` is mandatory for batch pods and satisfies "never restart in place". `kubectl create job --from=cronjob/report` clones the job template for an immediate run without altering the schedule.

| Component | Points |
|---|---|
| Schedule */5 + concurrencyPolicy Forbid + history limits 3 / 1 | 2 |
| backoffLimit 2, activeDeadlineSeconds 60, restartPolicy Never | 2 |
| report-now created `--from=cronjob/report` and Completed | 2 |

## Task 10 — Node NotReady, kubelet won't stay up

**Domain:** Troubleshooting (7%) | **Time budget:** 8 min

**Forensics:**

```bash
k get nodes                                   # cka-worker2 NotReady
                                              # (stays stale-Ready until Task 1 is fixed - node
                                              #  lifecycle is kube-controller-manager's job)
docker exec -it cka-worker2 bash              # real exam: ssh cka-worker2 + sudo -i
  systemctl status kubelet                    # activating (auto-restart) - crash-looping, not stopped
  journalctl -u kubelet --no-pager | tail -20
  #   invalid argument "maybe" for "--fail-swap-on" flag: strconv.ParseBool: parsing "maybe"
  cat /etc/default/kubelet
  #   KUBELET_EXTRA_ARGS=--runtime-cgroups=/system.slice/containerd.service --fail-swap-on=maybe
  sed -i 's| --fail-swap-on=maybe||' /etc/default/kubelet
  systemctl daemon-reload
  systemctl restart kubelet
  systemctl is-active kubelet                 # active
  exit
k get nodes                                   # cka-worker2 Ready (~30s)
echo "--fail-swap-on" > /tmp/exam3/10-cause.txt
```

**Why:** a non-boolean value for a boolean flag makes kubelet exit at flag-parse time; systemd's `Restart=always` turns that into a crash-loop (contrast: a merely stopped kubelet). The fix edits the **persistent** env file that the kubelet unit sources, so it survives restarts and reboot. On kind the unit is already enabled.

| Component | Points |
|---|---|
| Diagnosed crash-loop via journalctl and found the bad flag (not a blind restart) | 3 |
| Corrected the persistent env file, kubelet active, node Ready, survives restart | 3 |
| Offending flag `--fail-swap-on` written to /tmp/exam3/10-cause.txt | 1 |

## Task 11 — DaemonSet on every node, including control plane

**Domain:** Workloads & Scheduling (5%) | **Time budget:** 5 min

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-agent
  namespace: sentry
  labels:
    app: node-agent
spec:
  selector:
    matchLabels:
      app: node-agent
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 2
  template:
    metadata:
      labels:
        app: node-agent
    spec:
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      containers:
      - name: agent
        image: busybox:1.36
        command: ["sh", "-c", "sleep 43200"]
        resources:
          requests:
            cpu: 10m
            memory: 16Mi
```

```bash
k apply -f node-agent-ds.yaml
k -n sentry get ds node-agent                 # DESIRED 3 / READY 3 (all nodes healthy - Task 10)
k -n sentry get pods -o wide                  # one pod per node, including cka-control-plane
```

**Why:** a DaemonSet skips nodes whose taints it does not tolerate; the control-plane node carries `node-role.kubernetes.io/control-plane:NoSchedule`, so without the toleration you cap out at 2/3. `maxUnavailable` under `updateStrategy.rollingUpdate` is the DaemonSet knob (Deployments use a different structure).

| Component | Points |
|---|---|
| DaemonSet correct + requests cpu 10m / memory 16Mi | 2 |
| control-plane toleration ⇒ 3/3 across all nodes | 2 |
| updateStrategy RollingUpdate maxUnavailable 2 | 1 |

## Task 12 — Helm lifecycle: upgrade, rollback, evict the broken release

**Domain:** Cluster Architecture (7%) | **Time budget:** 8 min

```bash
helm -n helmwork list                          # web (rev 1) and broken
helm -n helmwork upgrade web /tmp/exam3/charts/webshop \
  --set replicaCount=3 --set image.tag=1.27-alpine
k -n helmwork rollout status deploy web-webshop     # 3/3

helm -n helmwork rollback web 1
k -n helmwork get deploy web-webshop           # back to 1 replica
helm -n helmwork history web | tee /tmp/exam3/12-history.txt   # 3 revisions

k -n helmwork get pods                         # broken-webshop-... ImagePullBackOff
k -n helmwork get pod -l app=broken-webshop \
  -o jsonpath='{.items[0].spec.containers[0].image}'; echo      # nginx:9.99-broken
helm -n helmwork uninstall broken
helm -n helmwork list                          # only web remains
```

**Why:** a `helm rollback` is itself a **new revision**, so install(1) → upgrade(2) → rollback(3) yields 3 in history. The failing workload pulls a non-existent tag — a *release-level* problem, so `helm uninstall` is the right tool; deleting the pods by hand leaves the release record and Helm state behind.

| Component | Points |
|---|---|
| Upgrade to replicaCount 3 + tag 1.27-alpine, rollout complete | 2.5 |
| Rollback to revision 1 (1 replica) + history (3 revisions) saved | 2.5 |
| Identified the `broken` release and `helm uninstall`ed it | 2 |

## Task 13 — Every in-cluster hostname fails to resolve

**Domain:** Services & Networking (6%) | **Time budget:** 8 min

**Forensics — the split symptom is the whole diagnosis:**

```bash
k run dnstest --image=busybox:1.36 --restart=Never -- sleep 3600
k exec dnstest -- nslookup kubernetes.default.svc.cluster.local   # ** server can't find ... NXDOMAIN
k exec dnstest -- nslookup kubernetes.io                          # resolves -> CoreDNS is up & forwarding
```

Internal fails but external works ⇒ CoreDNS runs, but its `kubernetes` plugin is bound to the wrong zone:

```bash
k -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'   # kubernetes cluster.broken in-addr.arpa ...
k -n kube-system edit cm coredns                                 # cluster.broken -> cluster.local
k -n kube-system rollout restart deploy coredns                  # deterministic reload (needs Task 1)
k -n kube-system rollout status deploy coredns
k exec dnstest -- nslookup kubernetes.default.svc.cluster.local > /tmp/exam3/13-verify.txt
k delete pod dnstest --grace-period=0 --force
cat /tmp/exam3/13-verify.txt                                     # resolves to 10.96.0.1
```

**Why:** with the `kubernetes` plugin authoritative only for `cluster.broken`, every `*.cluster.local` query fell through to `forward . /etc/resolv.conf` and NXDOMAIN'd upstream — while genuinely external names still resolved through that same forward. The `reload` plugin would pick up the ConfigMap within ~2 min; `rollout restart` forces it now (and, like everything else, needs kube-controller-manager alive).

| Component | Points |
|---|---|
| Diagnosed CoreDNS via the internal-fails/external-works split (not "the pods") | 2 |
| Corrected the cluster zone in the Corefile + reloaded CoreDNS | 2 |
| Resolved kubernetes.default.svc.cluster.local + saved to 13-verify.txt | 2 |

## Task 14 — Replace the default StorageClass

**Domain:** Storage (4%) | **Time budget:** 5 min

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: standard-retain
provisioner: rancher.io/local-path
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
```

```bash
k apply -f standard-retain-sc.yaml
k annotate sc standard storageclass.kubernetes.io/is-default-class=false --overwrite
k annotate sc standard-retain storageclass.kubernetes.io/is-default-class=true --overwrite
k get sc                                        # only standard-retain shows (default)
```

PVC with **no** storageClassName + Pod:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: scratch
  namespace: vault
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 500Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: scratch-pod
  namespace: vault
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 43200"]
    volumeMounts:
    - name: scratch
      mountPath: /scratch
  volumes:
  - name: scratch
    persistentVolumeClaim:
      claimName: scratch
```

```bash
k -n vault get pvc scratch                       # Bound
k -n vault get pvc scratch -o jsonpath='{.spec.storageClassName}{"\n"}'   # standard-retain
PV=$(k -n vault get pvc scratch -o jsonpath='{.spec.volumeName}')
k get pv "$PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}' # Retain
```

**Why:** a PVC with no `storageClassName` is stamped with whichever class holds `is-default-class=true` at admission time — so you must flip the old default **off**, or two defaults become an error and the annotation is ambiguous. WFFC keeps the PVC Pending until scratch-pod schedules; that is expected, not a fault.

| Component | Points |
|---|---|
| standard-retain created (local-path, Retain, WaitForFirstConsumer) | 1.5 |
| standard-retain is the ONLY default (old `standard` flipped off) | 1 |
| scratch (no class) Bound via new default, bound PV reclaimPolicy Retain, pod Running | 1.5 |

## Task 15 — Kustomize overlay with a patch

**Domain:** Cluster Architecture (4%) | **Time budget:** 7 min

`/tmp/exam3/kustomize/overlays/prod/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prodapps
resources:
- ../../base
replicas:
- name: notify
  count: 3
images:
- name: nginx
  newTag: 1.27-alpine
patches:
- target:
    kind: Deployment
    name: notify
  patch: |-
    - op: add
      path: /spec/template/spec/containers/0/resources
      value:
        requests:
          cpu: 50m
          memory: 64Mi
```

```bash
mkdir -p /tmp/exam3/kustomize/overlays/prod   # then write the file above
k create ns prodapps
kubectl kustomize /tmp/exam3/kustomize/overlays/prod > /tmp/exam3/15-rendered.yaml
k apply -k /tmp/exam3/kustomize/overlays/prod
k -n prodapps get deploy notify               # 3/3 (after Task 1)
k -n prodapps get deploy notify \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests}{"\n"}'   # cpu 50m, memory 64Mi
```

**Why:** the overlay composes the base by reference, so the base file is never edited; `images.newTag` bumps the tag (kustomize matches on the image *name* `nginx`), `replicas` sets the count, and the inline JSON6902 patch adds the `resources` block to container index 0 (`web`). `kubectl kustomize` renders; `kubectl apply -k` renders **and** applies.

| Component | Points |
|---|---|
| Overlay references base (base unmodified), namespace prodapps | 1.5 |
| replicas 3 + image tag 1.27-alpine | 1.5 |
| resources patch (cpu 50m / memory 64Mi) applied + rendered file saved + 3/3 Ready | 1 |

---

## Scoring

| # | Task | Domain | Weight | Your score |
|---|---|---|---|---|
| 1 | Deployments create no pods (control-plane) | Troubleshooting | 8 | |
| 2 | Certificate user, RBAC, kubeconfig | Cluster Architecture | 8 | |
| 3 | Gateway API canary traffic split | Services & Networking | 7 | |
| 4 | WaitForFirstConsumer PVC puzzle | Storage | 6 | |
| 5 | Two independent faults | Troubleshooting | 8 | |
| 6 | etcd backup and restore roundtrip | Cluster Architecture | 10 | |
| 7 | Drain blocked by PDB | Troubleshooting | 7 | |
| 8 | Service + NetworkPolicy + DNS | Services & Networking | 7 | |
| 9 | CronJob + manual trigger | Workloads & Scheduling | 6 | |
| 10 | Node NotReady, kubelet crash-loop | Troubleshooting | 7 | |
| 11 | DaemonSet on every node | Workloads & Scheduling | 5 | |
| 12 | Helm upgrade / rollback / uninstall | Cluster Architecture | 7 | |
| 13 | Cluster DNS broken | Services & Networking | 6 | |
| 14 | Replace the default StorageClass | Storage | 4 | |
| 15 | Kustomize overlay with a patch | Cluster Architecture | 4 | |
| | **Total** | | **100** | |

**Domain subtotals (this paper):** Troubleshooting 30, Cluster Architecture 29, Services & Networking 20, Workloads & Scheduling 11, Storage 10. This over-indexes Cluster Architecture and under-weights Workloads versus the live blueprint (25 / 15) — killer papers concentrate on the compound, high-blast-radius work. Do not read the domain split here as the exam's; check the CNCF curriculum page for current weights.

### Killer-style calibration

This paper is harder than the real CKA: harder faults, more chaining, and a time budget you cannot fully clear. Convert your raw score with the band below — **do not** compare it to the real 66% pass line directly.

| Raw score here | Reading |
|---|---|
| ≥ 70 within 120 min | Comfortably above real-exam standard; you have margin |
| 55 – 69 | **Exam-ready.** This is the target band — a real 66%+ is very likely |
| 40 – 54 | Borderline. Re-run the failed tasks cold, then re-sit; you are close |
| < 40 | Redo the weak domains' course modules before another mock |

The single most important number is **how fast you triaged Task 1** — if you spent 40 minutes on downstream symptoms before finding kube-controller-manager, that (not the YAML) is what will cost you on exam day. On the real exam: skim every task first, fix cluster-wide faults early, and flag anything over its time budget.

### Cleanup

Restore the sabotaged cluster state, then delete the fixtures:

```bash
# control plane + node + DNS back to healthy
docker exec cka-control-plane sed -i 's|- kube-controller-managerX$|- kube-controller-manager|' \
  /etc/kubernetes/manifests/kube-controller-manager.yaml 2>/dev/null || true
docker exec cka-worker2 sh -c \
  'printf "KUBELET_EXTRA_ARGS=--runtime-cgroups=/system.slice/containerd.service\n" > /etc/default/kubelet; \
   systemctl daemon-reload; systemctl restart kubelet' 2>/dev/null || true
kubectl -n kube-system patch cm coredns --type merge --patch-file /tmp/exam3/coredns-good.yaml
kubectl -n kube-system rollout restart deploy coredns

# if you completed Task 6, your live etcd data dir is now the restored one; to reset fully,
# point --data-dir in /etc/kubernetes/manifests/etcd.yaml back to /var/lib/etcd.

kubectl annotate sc standard storageclass.kubernetes.io/is-default-class=true --overwrite
kubectl delete ns apex citadel mesh vault orbit fortress bazaar batchjobs sentry helmwork prodapps --ignore-not-found
kubectl delete pv pv-fast --ignore-not-found
kubectl delete sc local-fast standard-retain --ignore-not-found
kubectl delete cm after-snap -n default --ignore-not-found
kubectl delete pod dnstest --ignore-not-found
kubectl delete csr mara --ignore-not-found
helm uninstall web broken -n helmwork 2>/dev/null || true
rm -rf /tmp/exam3
```
