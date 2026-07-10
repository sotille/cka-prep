# CKA Mock Exam 1 — Solutions and Grading

Grade with the rubrics below. Award a component only if the finish state is actually observable on the cluster (`kubectl get ...`) or in the file, not because "the command looked right". Pass line: **66/100**.

Time budgets sum to ~95 minutes — the remaining ~25 are your triage + review buffer. On a confidence run you should finish with time to spare; if you don't, note which tasks bled minutes.

Every task starts with `kubectl config use-context kind-cka` on the real exam. Namespaces referenced below were pre-created by the setup script.

---

## Task 1 — Least-privilege for a CI bot

**Domain:** Cluster Architecture (6%) | **Time budget:** 6 min

```bash
k -n cicd create serviceaccount deploy-bot
k -n cicd create role deployment-manager \
  --verb=get,list,watch,update,patch --resource=deployments
k -n cicd create rolebinding deploy-bot-binding \
  --role=deployment-manager --serviceaccount=cicd:deploy-bot

k auth can-i update deployments -n cicd \
  --as=system:serviceaccount:cicd:deploy-bot > /tmp/exam/task1-cani.txt
cat /tmp/exam/task1-cani.txt        # yes
```

Equivalent declarative Role:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployment-manager
  namespace: cicd
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch", "update", "patch"]
```

Why: `--resource=deployments` resolves to apiGroup `apps` automatically, so the imperative form is exact and faster; the ServiceAccount subject syntax in `--as`/`--serviceaccount` is `system:serviceaccount:<ns>:<name>` — a malformed subject is the usual lost point here.

| Component | Points |
|---|---|
| ServiceAccount `deploy-bot` in `cicd` | 1 |
| Role with exactly the five verbs on `apps/deployments` (no `create`/`delete`) | 2.5 |
| RoleBinding binds the Role to the SA | 1.5 |
| `/tmp/exam/task1-cani.txt` contains `yes` | 1 |

## Task 2 — Deployment won't come up

**Domain:** Troubleshooting (6%) | **Time budget:** 6 min

```bash
k -n apex get pods                              # ImagePullBackOff / ErrImagePull
k -n apex describe pod -l app=web-frontend | tail
# Failed to pull image "nginx:1.99-alpine": ... manifest ... not found
k -n apex set image deploy/web-frontend nginx=nginx:1.27
k -n apex rollout status deploy web-frontend    # 3/3 ready
```

Why: a single fault — a nonexistent image tag. The container is named `nginx` (see `describe`), so `set image deploy/<name> <container>=<image>` patches in place without a delete/recreate. Any real tag (`nginx:1.27`, `nginx:1.27-alpine`) is accepted.

| Component | Points |
|---|---|
| Diagnosed the bad image tag from events/describe | 2 |
| Fixed the image in place (not deleted/recreated) | 2 |
| 3/3 replicas Ready | 2 |

## Task 3 — Node not ready

**Domain:** Troubleshooting (7%) | **Time budget:** 5 min

```bash
k get nodes                                     # cka-worker2 NotReady
docker exec -it cka-worker2 bash                # real exam: ssh node + sudo -i
  systemctl status kubelet                      # inactive (dead); "disabled"
  systemctl enable --now kubelet                # start + persist across reboot
  systemctl is-enabled kubelet                  # enabled
  exit
k get nodes                                     # cka-worker2 Ready (allow ~30s)
```

Why: NotReady with a stopped kubelet is the highest-frequency node fault on the exam. The setup both stopped **and** disabled the unit, so `systemctl start` alone would pass the moment but fail the "survive a reboot" requirement — `enable --now` does both in one command.

| Component | Points |
|---|---|
| Diagnosed kubelet down (status/journalctl, not a blind restart of everything) | 3 |
| kubelet started, node returns to Ready | 2 |
| Enabled so it survives a reboot | 2 |

## Task 4 — Expose an app on a fixed node port

**Domain:** Services & Networking (6%) | **Time budget:** 5 min

Fastest: `expose`, then patch the auto-assigned nodePort (not settable by an `expose` flag).

```bash
k -n netz expose deploy echo-server --name=echo-svc --type=NodePort \
  --port=8080 --target-port=8080
k -n netz patch svc echo-svc -p '{"spec":{"ports":[{"port":8080,"nodePort":30080}]}}'

k -n netz get svc echo-svc -o jsonpath='{.spec.clusterIP}' > /tmp/exam/task4-clusterip.txt
cat /tmp/exam/task4-clusterip.txt
```

Equivalent declarative object:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: echo-svc
  namespace: netz
spec:
  type: NodePort
  selector:
    app: echo-server
  ports:
  - port: 8080
    targetPort: 8080
    nodePort: 30080
```

Why: Service ports strategic-merge-patch on the `port` key, so the one-line patch pins `nodePort: 30080` while preserving `targetPort`. The ClusterIP is assigned by the API server — read it back, don't invent it.

| Component | Points |
|---|---|
| NodePort Service selecting `app=echo-server`, port/targetPort 8080 | 3 |
| `nodePort: 30080` | 2 |
| Correct ClusterIP written to `/tmp/exam/task4-clusterip.txt` | 1 |

## Task 5 — Deployment rollout controls

**Domain:** Workloads & Scheduling (8%) | **Time budget:** 8 min

Generate the skeleton, then hand-edit resources + strategy (neither is settable by a create flag):

```bash
k -n apps create deployment api-gateway --image=nginx:1.27 --replicas=2 $do > api-gateway.yaml
# edit api-gateway.yaml to the object below, then apply
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-gateway
  namespace: apps
  labels:
    app: api-gateway
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api-gateway
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: api-gateway
    spec:
      containers:
      - name: nginx
        image: nginx:1.27
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            memory: 256Mi
```

```bash
k apply -f api-gateway.yaml
k -n apps rollout status deploy api-gateway     # 2/2 available
k -n apps set image deploy/api-gateway nginx=nginx:1.28
k -n apps rollout status deploy api-gateway     # new revision rolled out
k -n apps scale deploy api-gateway --replicas=4
k -n apps rollout history deploy api-gateway > /tmp/exam/task5-history.txt
cat /tmp/exam/task5-history.txt                 # revisions 1 and 2
```

Why: `maxUnavailable: 0` with `maxSurge: 1` is a surge-only rollout — a new pod comes up before an old one leaves, so capacity never dips. `create deployment` names the container `nginx` (image basename), which is exactly what the task wants, so `set image` targets `nginx=...`.

| Component | Points |
|---|---|
| Deployment created: image nginx:1.27, container `nginx`, 2 replicas | 2 |
| Requests cpu 100m/mem 128Mi and memory limit 256Mi | 2 |
| strategy maxSurge 1 / maxUnavailable 0 | 2 |
| Image updated to 1.28, rolled out, scaled to 4, history file saved | 2 |

## Task 6 — Pods failing to start

**Domain:** Troubleshooting (6%) | **Time budget:** 6 min

```bash
k -n commerce get pods                          # orders-api ... CreateContainerConfigError
k -n commerce describe pod -l app=orders-api | tail
# Error: couldn't find key db-pass in Secret commerce/orders-secret
k -n commerce get secret orders-secret -o jsonpath='{.data}'; echo
# real key is "db-password"
```

Fix the Deployment's secret reference (not the Secret):

```bash
k -n commerce patch deploy orders-api --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/env/0/valueFrom/secretKeyRef/key","value":"db-password"}]'
# or: k -n commerce edit deploy orders-api   -> secretKeyRef.key: db-pass -> db-password
k -n commerce rollout status deploy orders-api  # 1/1 ready
```

Why: an env var whose `secretKeyRef.key` does not exist fails the container at config time with `CreateContainerConfigError` — the pod never even reaches `Running`. The Secret is correct; the Deployment's reference is wrong, so the fix is on the Deployment.

| Component | Points |
|---|---|
| Correctly identified CreateContainerConfigError → wrong secret key (read the events, not guessed) | 3 |
| Fixed the `secretKeyRef.key` on the Deployment, Secret untouched | 2 |
| Pod becomes Ready (1/1) | 1 |

## Task 7 — etcd snapshot

**Domain:** Cluster Architecture (7%) | **Time budget:** 8 min

```bash
# save runs against the live server, so it must be etcdctl (not etcdutl), inside the etcd pod;
# write under /var/lib/etcd because that path is a hostPath to the node -> reachable by docker cp.
# no `sh -c` wrapper: the etcd image is distroless (no shell), so pass flags straight to etcdctl.
k -n kube-system exec etcd-cka-control-plane -- \
  etcdctl snapshot save /var/lib/etcd/snap.db \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key

# copy the snapshot out to the host answer path
docker cp cka-control-plane:/var/lib/etcd/snap.db /tmp/exam/task7-snapshot.db

# status is an offline op -> etcdutl (etcdctl snapshot status still works but is deprecated)
k -n kube-system exec etcd-cka-control-plane -- \
  etcdutl snapshot status /var/lib/etcd/snap.db -w table > /tmp/exam/task7-status.txt
cat /tmp/exam/task7-status.txt
ls -l /tmp/exam/task7-snapshot.db               # non-zero size
```

If you are unsure of the cert flags, grep them out of the manifest first — the first move of every etcd task:

```bash
docker exec cka-control-plane \
  grep -E 'cert-file|key-file|trusted-ca|listen-client' /etc/kubernetes/manifests/etcd.yaml
```

Why: `snapshot save` talks to a running etcd, so it needs the three client certs and lives in `etcdctl`; `snapshot status` reads a file and belongs to `etcdutl`. Writing under `/var/lib/etcd` matters on kind — that directory is the hostPath mount, so `docker cp` from the node can retrieve the file. A single-digit key count means you snapshotted the wrong endpoint.

| Component | Points |
|---|---|
| Snapshot saved with correct endpoint + all three certs | 3 |
| Snapshot copied to host `/tmp/exam/task7-snapshot.db` (non-empty) | 2 |
| Status table written to `/tmp/exam/task7-status.txt` | 2 |

## Task 8 — Static provisioning

**Domain:** Storage (5%) | **Time budget:** 6 min

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-claim
  namespace: data
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: manual
  resources:
    requests:
      storage: 500Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: data-pod
  namespace: data
spec:
  containers:
  - name: web
    image: nginx:1.27-alpine
    volumeMounts:
    - name: html
      mountPath: /usr/share/nginx/html
  volumes:
  - name: html
    persistentVolumeClaim:
      claimName: data-claim
```

```bash
k apply -f data.yaml
k get pv pv-manual-1g                            # Bound
k -n data get pvc data-claim                     # Bound to pv-manual-1g
k -n data get pod data-pod                       # Running
```

Why: static binding matches on `storageClassName` + `accessModes` + capacity (request 500Mi ≤ PV 1Gi). Omitting `storageClassName: manual` would send the PVC to the default (`standard`) provisioner and it would never touch `pv-manual-1g`.

| Component | Points |
|---|---|
| PVC matches class `manual` / RWO / ≤1Gi and binds the PV | 3 |
| Pod Running with the claim mounted at `/usr/share/nginx/html` | 2 |

## Task 9 — Lock down the database

**Domain:** Services & Networking (7%) | **Time budget:** 6 min

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: db-allow-api
  namespace: secure-apps
spec:
  podSelector:
    matchLabels:
      role: db
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          role: api
    ports:
    - protocol: TCP
      port: 5432
```

```bash
k -n secure-apps describe netpol db-allow-api
```

Why: selecting the db pods and listing `policyTypes: [Ingress]` makes them default-deny for ingress; the single rule whitelists `role=api` on 5432. Listing only `Ingress` leaves egress untouched — adding `Egress` with no egress rules would silently cut all outbound traffic from the db pods.

| Component | Points |
|---|---|
| podSelector `role=db`, policyTypes `Ingress` only | 3 |
| `from` podSelector `role=api` (no namespaceSelector widening the scope) | 2 |
| Restricted to TCP 5432 | 2 |

## Task 10 — Run a pod on the control plane

**Domain:** Workloads & Scheduling (7%) | **Time budget:** 5 min

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cp-agent
  namespace: apps
spec:
  nodeSelector:
    node-role.kubernetes.io/control-plane: ""
  tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
  containers:
  - name: agent
    image: busybox:1.36
    command: ["sleep", "86400"]
```

```bash
k apply -f cp-agent.yaml
k -n apps get pod cp-agent -o wide               # Running on cka-control-plane
```

Why: the toleration lets the pod pass the `node-role.kubernetes.io/control-plane:NoSchedule` taint; the nodeSelector then forces it onto that node. The role label's value is the empty string, matched literally with `""`. `operator: Exists` avoids caring about the taint's (empty) value. Doing this with `nodeName` was explicitly disallowed.

| Component | Points |
|---|---|
| Toleration for the control-plane taint | 3 |
| nodeSelector on the control-plane role label (no `nodeName`) | 2 |
| Pod Running on `cka-control-plane` | 2 |

## Task 11 — Service without endpoints

**Domain:** Troubleshooting (6%) | **Time budget:** 6 min

```bash
k -n commerce get endpoints catalog-svc         # <none>  -> selector problem
k -n commerce get pods -l app=catalog-api --show-labels
k -n commerce get svc catalog-svc -o yaml        # selector app=catalog (wrong; pods are app=catalog-api)
k -n commerce patch svc catalog-svc -p '{"spec":{"selector":{"app":"catalog-api"}}}'
k -n commerce get endpoints catalog-svc          # two pod IPs on :8080

k -n commerce run fetch --image=busybox:1.36 --restart=Never \
  -- sh -c 'wget -qO- http://catalog-svc.commerce/hostname'
sleep 5
k -n commerce logs fetch > /tmp/exam/task11-response.txt
k -n commerce delete pod fetch $now
cat /tmp/exam/task11-response.txt                # a catalog-api-... pod hostname
```

Why: empty Endpoints means the selector does not match any pod's labels. The Service's `targetPort: 8080` was already correct — only the selector was wrong, so the Deployment stays untouched. `agnhost netexec` answers `/hostname` with the serving pod's name, which is why the body is non-empty.

| Component | Points |
|---|---|
| Diagnosed empty endpoints → selector mismatch | 2 |
| Selector fixed to `app=catalog-api`, endpoints populated, Deployment untouched | 2 |
| Response body saved to `/tmp/exam/task11-response.txt` | 2 |

## Task 12 — Kustomize prod overlay

**Domain:** Cluster Architecture (6%) | **Time budget:** 7 min

```bash
mkdir -p /tmp/exam/task12/overlays/prod
```

`/tmp/exam/task12/overlays/prod/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod-apps
namePrefix: prod-
resources:
- ../../base
replicas:
- name: nginx-web
  count: 3
```

```bash
kubectl kustomize /tmp/exam/task12/overlays/prod    # preview: prod-nginx-web, ns prod-apps, 3 replicas
k apply -k /tmp/exam/task12/overlays/prod
k -n prod-apps get deploy prod-nginx-web            # 3/3
k -n prod-apps get svc prod-nginx-web
```

Why: an overlay composes the base by reference (`resources: ../../base`), so the base is never edited. `namespace`, `namePrefix` and `replicas` are transformers applied on top. The `replicas` transformer targets the resource by its **base** name (`nginx-web`) — the `prod-` prefix is applied afterward.

| Component | Points |
|---|---|
| Overlay references the base; base files unmodified | 2 |
| namespace `prod-apps` + namePrefix `prod-` | 2 |
| Deployment replicas set to 3 and applied with `-k` | 2 |

## Task 13 — Dynamic provisioning

**Domain:** Storage (5%) | **Time budget:** 5 min

```bash
k get sc                                          # standard (default)  rancher.io/local-path
echo standard > /tmp/exam/task13-sc.txt
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: logs-pvc
  namespace: data
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: standard
  resources:
    requests:
      storage: 200Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: logs-writer
  namespace: data
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sleep", "86400"]
    volumeMounts:
    - name: logs
      mountPath: /var/log/app
  volumes:
  - name: logs
    persistentVolumeClaim:
      claimName: logs-pvc
```

```bash
k apply -f logs.yaml
k -n data get pvc logs-pvc                         # Bound (once the pod is scheduled)
k -n data get pod logs-writer                      # Running
```

Why: the default StorageClass provisions on demand. `standard` uses `volumeBindingMode: WaitForFirstConsumer`, so the PVC intentionally stays `Pending` until `logs-writer` is scheduled — that is not a bug to chase. Omitting `storageClassName` entirely also works (the default is applied), so either form earns full credit.

| Component | Points |
|---|---|
| `standard` written to `/tmp/exam/task13-sc.txt` | 1.5 |
| PVC 200Mi RWO on the default class | 1.5 |
| Pod Running with the claim mounted, PVC Bound | 2 |

## Task 14 — Extract error logs

**Domain:** Troubleshooting (5%) | **Time budget:** 3 min

```bash
k -n commerce logs payment-processor | grep 'level=ERROR' > /tmp/exam/task14-errors.txt
wc -l /tmp/exam/task14-errors.txt                  # several lines
cat /tmp/exam/task14-errors.txt
```

Why: a single-container pod needs no `-c`. `kubectl logs` streams the full log by default; piping to `grep 'level=ERROR'` keeps exactly the requested lines. If the pod had restarted you'd add `--previous`, but this one runs continuously.

| Component | Points |
|---|---|
| Used `kubectl logs` on the right pod | 2 |
| File contains only `level=ERROR` lines (no INFO/WARN) | 3 |

## Task 15 — Gateway API routing

**Domain:** Services & Networking (7%) | **Time budget:** 7 min

Docs path: kubernetes.io/docs/concepts/services-networking/gateway/ has copy-pastable skeletons.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web-gw
  namespace: netz
spec:
  gatewayClassName: exam-gc
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: echo-route
  namespace: netz
spec:
  parentRefs:
  - name: web-gw
  hostnames:
  - echo.example.com
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: echo-svc
      port: 8080
```

```bash
k -n netz get gateway,httproute
k -n netz describe httproute echo-route
```

Why: the listener's `allowedRoutes.namespaces.from: Same` restricts attachment to the same namespace; the HTTPRoute binds to the Gateway via `parentRefs`, filters on the `echo.example.com` hostname, and sends `PathPrefix /` to `echo-svc:8080`. No controller is installed, so `Programmed` stays false — grading is on the spec, which is exactly how the CRDs are pre-installed on the real exam.

| Component | Points |
|---|---|
| Gateway: gatewayClassName `exam-gc`, listener `http`/HTTP/80 | 2.5 |
| allowedRoutes `from: Same` | 1.5 |
| HTTPRoute attached via parentRefs + hostname `echo.example.com` | 1.5 |
| Rule: PathPrefix `/` → `echo-svc:8080` | 1.5 |

## Task 16 — Custom resources

**Domain:** Cluster Architecture (6%) | **Time budget:** 6 min

```bash
k get crd | grep ops.example.com                   # backupjobs.ops.example.com
echo backupjobs.ops.example.com > /tmp/exam/task16-crd.txt
k explain backupjob.spec                            # source, schedule, retainDays
```

```yaml
apiVersion: ops.example.com/v1
kind: BackupJob
metadata:
  name: nightly
  namespace: ops
spec:
  source: /var/lib/app-data
  schedule: "0 2 * * *"
  retainDays: 14
```

```bash
k apply -f nightly.yaml
k -n ops get backupjob nightly                      # or: k -n ops get bj nightly
k -n ops get backupjob nightly -o jsonpath='{.spec.retainDays}'; echo   # 14
```

Why: a CRD's full name is `<plural>.<group>` (`backupjobs.ops.example.com`); the instance's `apiVersion` is `<group>/<version>` (`ops.example.com/v1`) and `kind` is `BackupJob`. Quote the cron string so YAML keeps it a string; leave `retainDays` unquoted so it stays an integer, matching the schema.

| Component | Points |
|---|---|
| Full CRD name written to `/tmp/exam/task16-crd.txt` | 2 |
| BackupJob `nightly` created in `ops` with correct apiVersion/kind | 2 |
| spec source/schedule (string)/retainDays (integer 14) correct | 2 |

---

## Scoring

| # | Task | Domain | Weight | Your score |
|---|---|---|---|---|
| 1 | Least-privilege for a CI bot | Cluster Architecture | 6 | |
| 2 | Deployment won't come up | Troubleshooting | 6 | |
| 3 | Node not ready | Troubleshooting | 7 | |
| 4 | Expose an app on a fixed node port | Services & Networking | 6 | |
| 5 | Deployment rollout controls | Workloads & Scheduling | 8 | |
| 6 | Pods failing to start | Troubleshooting | 6 | |
| 7 | etcd snapshot | Cluster Architecture | 7 | |
| 8 | Static provisioning | Storage | 5 | |
| 9 | Lock down the database | Services & Networking | 7 | |
| 10 | Run a pod on the control plane | Workloads & Scheduling | 7 | |
| 11 | Service without endpoints | Troubleshooting | 6 | |
| 12 | Kustomize prod overlay | Cluster Architecture | 6 | |
| 13 | Dynamic provisioning | Storage | 5 | |
| 14 | Extract error logs | Troubleshooting | 5 | |
| 15 | Gateway API routing | Services & Networking | 7 | |
| 16 | Custom resources | Cluster Architecture | 6 | |
| | **Total** | | **100** | |

Domain subtotals: Troubleshooting 30, Cluster Architecture 25, Services & Networking 20, Workloads & Scheduling 15, Storage 10.

**Pass: ≥ 66.** This is the confidence band — most first-timers who have done the weekly labs land 70–85 here.
- Below 66: you have a gap in fundamentals, not exam nerves. Redo the failed domains' course modules, then re-run this whole exam cold.
- 66–80: on track. Re-run only the tasks you lost points on, cold, in 2–3 days, then move to mock exam 2 (true exam level).
- Above 85 within time: graduate to mock exam 2, which stacks multiple faults per task and adds cluster-wide breakage.

Cleanup after grading:

```bash
kubectl delete ns cicd apex netz apps commerce secure-apps data prod-apps ops --ignore-not-found
kubectl delete pv pv-manual-1g --ignore-not-found
kubectl delete crd backupjobs.ops.example.com --ignore-not-found
docker exec cka-worker2 systemctl enable --now kubelet 2>/dev/null || true
rm -rf /tmp/exam
```
