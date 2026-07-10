# CKA Mock Exam 2 — Solutions and Grading

Grade with the rubrics below. Award a component only if the finish state is actually observable on the cluster (`kubectl get ...`), not because "the command looked right". Pass line: **66/100**.

Time budgets sum to 106 minutes — the remaining 14 are your review/flag buffer, same discipline as the real exam.

**Dependency you must respect while grading:** Task 16 (the kube-scheduler is down) blocks scheduling cluster-wide. Any task that creates *new* pods — Task 2's fixed rollout, Task 8, Task 10's rollout, Task 12, Task 14 — will sit `Pending` until Task 16 is solved. Task 15's static pod is the exception: it bypasses the scheduler entirely and runs regardless. On the real exam this "fix the platform before you can finish the app tasks" ordering is exactly the skill under test.

---

## Task 1 — Certificate-based user access

**Domain:** Cluster Architecture (6%) | **Time budget:** 10 min

```bash
cd /tmp/exam2/ana
openssl genrsa -out ana.key 2048
openssl req -new -key ana.key -subj "/CN=ana" -out ana.csr

REQ=$(base64 < ana.csr | tr -d '\n')     # Linux exam terminal: base64 -w 0 ana.csr
cat <<EOF | k apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ana
spec:
  request: $REQ
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages:
  - client auth
EOF

k get csr ana                                  # Pending
k certificate approve ana
k get csr ana -o jsonpath='{.status.certificate}' | base64 -d > ana.crt

k -n dev-ana create role pod-reader --verb=get,list,watch --resource=pods
k -n dev-ana create rolebinding ana-pod-reader --role=pod-reader --user=ana

# verify — either is acceptable:
k auth can-i list pods -n dev-ana --as=ana     # yes
k config set-credentials ana --client-certificate=/tmp/exam2/ana/ana.crt \
  --client-key=/tmp/exam2/ana/ana.key --embed-certs=true
k config set-context ana --cluster=kind-cka --user=ana
k --context=ana -n dev-ana get pods            # authorized (empty list is fine)
```

Why: the CN of the client cert becomes the username; `kubernetes.io/kube-apiserver-client` is the only signer that issues client certs for users, and RBAC binds to that username.

| Component | Points |
|---|---|
| Key + CSR with CN=ana at the given paths | 1 |
| CSR object with correct signerName, usages `client auth`, expirationSeconds 86400 | 2 |
| Approved + cert extracted (base64 -d) to ana.crt | 1 |
| Role + RoleBinding correct (user `ana`, verbs get/list/watch, pods) | 1 |
| Working verification | 1 |

## Task 2 — Deployment not becoming Ready

**Domain:** Troubleshooting (8%) | **Time budget:** 8 min

Two stacked faults — fixing only the image still leaves 0 ready.

```bash
k -n troubled get pods                         # ImagePullBackOff
k -n troubled describe pod -l app=orders-api   # manifest for nginx:1.99-alpine not found
k -n troubled set image deploy/orders-api web=nginx:1.27-alpine

k -n troubled get pods                         # now Running but 0/1 READY
k -n troubled describe pod -l app=orders-api   # Readiness probe failed: ... :8080 connection refused
k -n troubled edit deploy orders-api           # readinessProbe.httpGet.port: 8080 -> 80
# or without an editor:
k -n troubled patch deploy orders-api --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":80}]'

k -n troubled get deploy orders-api            # 3/3
```

Why: `describe` shows both failures sequentially — a pulled-image failure masks the probe failure until the image is fixed; always re-check after the first fix. (The *original* bad-image pods were already scheduled before the scheduler fault, so diagnosis works immediately. But `set image` spawns a new ReplicaSet whose *new* pods must be placed by kube-scheduler — a `nodeSelector` is a constraint the scheduler evaluates, not a bypass — so they stay `Pending` and 3/3 Ready is only reachable after Task 16 is fixed, per the dependency note above.)

| Component | Points |
|---|---|
| Diagnosed and fixed the image tag | 3 |
| Diagnosed and fixed the readiness probe port | 3 |
| 3/3 Ready, Deployment edited in place (not recreated) | 2 |

## Task 3 — HorizontalPodAutoscaler

**Domain:** Workloads & Scheduling (8%) | **Time budget:** 6 min

Fast path: generate the skeleton imperatively, then add `behavior` (not settable by flag).

```bash
k -n fintech autoscale deploy checkout --name=checkout-hpa --min=2 --max=8 --cpu-percent=65
k -n fintech edit hpa checkout-hpa             # add spec.behavior below
```

Full object:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: checkout-hpa
  namespace: fintech
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout
  minReplicas: 2
  maxReplicas: 8
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 65
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
```

```bash
k -n fintech get hpa checkout-hpa
k -n fintech get hpa checkout-hpa -o jsonpath='{.spec.behavior.scaleDown.stabilizationWindowSeconds}'
```

Why: `autoscaling/v2` moved from a bare `targetCPUUtilizationPercentage` to the `metrics` list, and `behavior` is the only place scale velocity/stabilization is tunable. Modern kubectl emits v2 from `k get hpa -o yaml`, so `k edit` lets you add `behavior` cleanly.

| Component | Points |
|---|---|
| HPA exists, correct name/namespace/target | 2 |
| min 2 / max 8 | 2 |
| v2 Resource metric, CPU Utilization 65 | 2 |
| scaleDown stabilizationWindowSeconds 300 | 2 |

## Task 4 — Service serves no traffic

**Domain:** Troubleshooting (7%) | **Time budget:** 7 min

```bash
k -n commerce get endpoints catalog-svc        # <none> -> selector problem
k -n commerce get pods --show-labels           # app=catalog
k -n commerce get svc catalog-svc -o yaml      # selector app=catalogue, targetPort 8080 — both wrong
k -n commerce edit svc catalog-svc             # selector app: catalog ; targetPort: 80
k -n commerce get endpoints catalog-svc        # pod IP:80 present

k -n commerce run fetch --image=busybox:1.36 --restart=Never \
  -- sh -c 'wget -qO- http://catalog-svc'
sleep 5
k -n commerce logs fetch > /tmp/exam2/04-curl.txt
k -n commerce delete pod fetch $now
cat /tmp/exam2/04-curl.txt                     # nginx welcome page HTML
```

Why: empty Endpoints means selector mismatch; endpoints present but connection refused means wrong targetPort — this Service had both. The temporary `fetch` pod is created *after* the fix, so if it stays Pending, Task 16 (scheduler) is still broken.

| Component | Points |
|---|---|
| Selector fixed (endpoints populated) | 3 |
| targetPort fixed to 80 | 2 |
| Response body saved to /tmp/exam2/04-curl.txt | 2 |

## Task 5 — Kustomize overlay

**Domain:** Cluster Architecture (5%) | **Time budget:** 8 min

```bash
mkdir -p /tmp/exam2/kustomize/overlays/prod
```

`/tmp/exam2/kustomize/overlays/prod/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod-web
namePrefix: prod-
resources:
- ../../base
replicas:
- name: web
  count: 3
labels:
- pairs:
    env: prod
```

```bash
k create ns prod-web
k apply -k /tmp/exam2/kustomize/overlays/prod
kubectl kustomize /tmp/exam2/kustomize/overlays/prod > /tmp/exam2/05-rendered.yaml
k -n prod-web get deploy prod-web -o wide --show-labels   # 3 desired, env=prod
```

Why: overlays compose the base by reference (`resources: ../../base`), so the base stays untouched; the `replicas:` transformer matches the resource by its **pre-prefix** name (`web`); `labels:` is the current-kustomize label transformer (the older `commonLabels:` also passes — it additionally mutates selectors, which is fine on a first apply). Pods only reach Ready once Task 16 is fixed; the object graded here is the Deployment spec.

| Component | Points |
|---|---|
| Overlay references base, base unmodified | 1 |
| namespace + namePrefix correct | 1.5 |
| replicas 3 + env=prod label applied | 1.5 |
| Applied with `-k` and rendered file saved | 1 |

## Task 6 — NetworkPolicy for the database

**Domain:** Services & Networking (7%) | **Time budget:** 7 min

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: db-allow-api
  namespace: secure-api
spec:
  podSelector:
    matchLabels:
      app: db
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: api
    ports:
    - protocol: TCP
      port: 5432
```

```bash
k -n secure-api describe netpol db-allow-api
```

Why: selecting the db pods with `policyTypes: [Ingress]` makes them default-deny for ingress; the single rule whitelists api pods on 5432. Listing only `Ingress` leaves egress unrestricted — adding `Egress` to policyTypes without rules would have silently cut all egress.

| Component | Points |
|---|---|
| podSelector app=db, policyTypes Ingress only | 3 |
| from podSelector app=api (no extra namespaceSelector widening scope) | 2 |
| TCP 5432 port restriction | 2 |

## Task 7 — Node NotReady

**Domain:** Troubleshooting (8%) | **Time budget:** 5 min

```bash
k get nodes                                    # cka-worker2 NotReady
docker exec -it cka-worker2 bash               # real exam: ssh node + sudo -i
  systemctl status kubelet                     # inactive (dead)
  systemctl enable --now kubelet               # "enable" covers the reboot requirement
  systemctl status kubelet                     # active (running)
  journalctl -u kubelet --no-pager | tail      # only if start had failed
  exit
k get nodes                                    # Ready (allow ~30s)
```

Why: NotReady with a dead kubelet is the highest-frequency node failure on the exam; `enable --now` both starts it and persists across reboot. A blind `systemctl restart kubelet` scores lower — you are expected to confirm the diagnosis first.

| Component | Points |
|---|---|
| Diagnosed kubelet down (status/journalctl, not blind restart of everything) | 3 |
| kubelet started, node Ready | 3 |
| Enabled (survives reboot) | 2 |

## Task 8 — Dynamic provisioning

**Domain:** Storage (5%) | **Time budget:** 6 min

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-local
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-pvc
  namespace: storage-task
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: fast-local
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: data-pod
  namespace: storage-task
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "echo ok > /data/ok.txt && sleep 43200"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: data-pvc
```

```bash
k get sc fast-local
k -n storage-task get pvc,pod                  # Bound / Running (after Task 16 is fixed)
```

Why: with `WaitForFirstConsumer` the PVC intentionally sits `Pending` until a pod that uses it is **scheduled** — do not "debug" that binding delay. But note the compounding trap: the pod itself needs the scheduler (Task 16), and `WaitForFirstConsumer` means the PVC will not bind until the pod is scheduled. Both unblock together once the scheduler is up.

| Component | Points |
|---|---|
| StorageClass with correct provisioner/reclaim/bindingMode | 2 |
| PVC 1Gi RWO on fast-local | 1.5 |
| Pod mounts claim, PVC Bound, pod Running | 1.5 |

## Task 9 — Gateway API route

**Domain:** Services & Networking (7%) | **Time budget:** 8 min

Docs path: kubernetes.io/docs/concepts/services-networking/gateway/ has copy-pastable skeletons.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web-gw
  namespace: gateway-ns
spec:
  gatewayClassName: cka-gwc
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    hostname: shop.example.com
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop-route
  namespace: gateway-ns
spec:
  parentRefs:
  - name: web-gw
  hostnames:
  - shop.example.com
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /cart
    backendRefs:
    - name: cart
      port: 8080
  - backendRefs:
    - name: shop
      port: 80
```

```bash
k -n gateway-ns get gateway,httproute
k -n gateway-ns describe httproute shop-route
```

Why: rule order matters — the `/cart` PathPrefix match must be its own rule; a rule with `backendRefs` and no `matches` defaults to `PathPrefix /`, catching everything else. A single rule listing both backends would load-balance across them rather than route by path.

| Component | Points |
|---|---|
| Gateway: class, listener name/port/protocol/hostname | 2 |
| allowedRoutes from Same namespace | 1 |
| HTTPRoute attached via parentRefs + hostname | 1.5 |
| /cart -> cart:8080 and default -> shop:80 rules | 2.5 |

## Task 10 — PriorityClass

**Domain:** Workloads & Scheduling (7%) | **Time budget:** 5 min

```bash
k get priorityclass
# system-cluster-critical 2000000000, system-node-critical 2000001000 -> ignore
# preexisting-high 500000 -> highest user-defined -> value = 499999
```

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: critical-services
value: 499999
globalDefault: false
description: Just below the highest user-defined class.
```

```bash
k apply -f critical-services.yaml
k -n fintech patch deploy payments \
  -p '{"spec":{"template":{"spec":{"priorityClassName":"critical-services"}}}}'
k -n fintech rollout status deploy payments    # completes only after Task 16 is fixed
k -n fintech get pod -l app=payments -o jsonpath='{.items[0].spec.priority}'   # 499999
```

Why: PriorityClass is cluster-scoped and immutable in `value`; the trap is counting the two `system-*` classes (2 billion range) as "highest" — the task, like the real 2025 exam item, means user-defined ones. The patch triggers a rollout whose new pods need the scheduler (Task 16).

| Component | Points |
|---|---|
| Correct value = highest user-defined minus 1 (499999 on a fresh lab; system classes excluded) | 3 |
| globalDefault false (or omitted) | 1 |
| payments uses the class, rollout complete, pod priority verified | 3 |

## Task 11 — Certificate expiry

**Domain:** Cluster Architecture (4%) | **Time budget:** 4 min

```bash
docker exec cka-control-plane \
  openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -enddate
# notAfter=... (one year after cluster creation for kubeadm/kind defaults)
docker exec cka-control-plane \
  openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -enddate \
  | cut -d= -f2 > /tmp/exam2/11-expiry.txt

# kubeadm alternative (also present on kind nodes):
docker exec cka-control-plane kubeadm certs check-expiration

# if openssl is not installed inside the node image: copy the cert out, inspect on the host
docker cp cka-control-plane:/etc/kubernetes/pki/apiserver.crt /tmp/exam2/apiserver.crt
openssl x509 -in /tmp/exam2/apiserver.crt -noout -enddate | cut -d= -f2 > /tmp/exam2/11-expiry.txt
```

Why: the apiserver serving cert lives at `/etc/kubernetes/pki/apiserver.crt` on kubeadm-style control planes; `kubeadm certs check-expiration` shows the whole PKI at once and is the faster tool when asked about several certs. Do not grab `apiserver-kubelet-client.crt` (that is the client cert to kubelets) or `ca.crt`.

| Component | Points |
|---|---|
| Inspected the correct cert (apiserver.crt, not the CA / kubelet certs) | 2 |
| Correct date written to /tmp/exam2/11-expiry.txt | 2 |

## Task 12 — Helm release lifecycle

**Domain:** Cluster Architecture (5%) | **Time budget:** 6 min

```bash
helm install web /tmp/exam2/charts/webapp -n web --create-namespace --set replicaCount=3
k -n web get deploy web-webapp                 # 3 desired (pods Ready after Task 16)

helm upgrade web /tmp/exam2/charts/webapp -n web --reuse-values --set image.tag=1.27-alpine
k -n web get deploy web-webapp -o jsonpath='{.spec.template.spec.containers[0].image}'
# nginx:1.27-alpine — and replicas still 3

helm history web -n web | tee /tmp/exam2/12-history.txt   # revisions 1 and 2
```

Why: without `--reuse-values` (or repeating `--set replicaCount=3`) the upgrade would reset replicas to the chart default of 1 — the classic Helm upgrade trap. Grading is on release/deployment state, so a `Pending` pod (scheduler down) does not cost points here.

| Component | Points |
|---|---|
| Install into created ns with replicaCount=3 | 2 |
| Upgrade to tag 1.27-alpine with replicas still 3 | 2 |
| History with 2 revisions saved | 1 |

## Task 13 — NodePort Service and DNS

**Domain:** Services & Networking (6%) | **Time budget:** 6 min

Fastest: `expose`, then patch the auto-assigned nodePort (not settable by flag).

```bash
k -n web-frontend expose deploy frontend --name=frontend-svc --type=NodePort \
  --port=80 --target-port=80
k -n web-frontend patch svc frontend-svc \
  -p '{"spec":{"ports":[{"port":80,"nodePort":30080}]}}'
```

Equivalent declarative object:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: frontend-svc
  namespace: web-frontend
spec:
  type: NodePort
  selector:
    app: frontend
  ports:
  - port: 80
    targetPort: 80
    nodePort: 30080
```

```bash
echo "frontend-svc.web-frontend.svc.cluster.local" > /tmp/exam2/13-fqdn.txt

k -n web-frontend run dns-test --image=busybox:1.36 --restart=Never \
  -- nslookup frontend-svc.web-frontend.svc.cluster.local
sleep 5
k -n web-frontend logs dns-test                # resolves to the ClusterIP
k -n web-frontend delete pod dns-test $now

# optional reachability proof via node network:
NODE_IP=$(k get node cka-worker -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
k -n web-frontend run np-test --image=busybox:1.36 --restart=Never --rm -it \
  -- wget -qO- "http://$NODE_IP:30080"
```

Why: Service ports strategic-merge-patch by `port` key, so the one-line patch pins the nodePort; the FQDN pattern is `<svc>.<ns>.svc.cluster.local`. The `frontend` pod was scheduled before the scheduler fault, so its endpoint is live — but the throwaway `dns-test` pod needs the scheduler (Task 16) to run.

| Component | Points |
|---|---|
| NodePort Service correct, nodePort 30080 | 3 |
| Correct FQDN in /tmp/exam2/13-fqdn.txt | 1.5 |
| DNS resolution demonstrated from a pod | 1.5 |

## Task 14 — Bind a pre-provisioned PV

**Domain:** Storage (5%) | **Time budget:** 6 min

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: archive-pvc
  namespace: storage-task
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: archive
  resources:
    requests:
      storage: 2Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: archive-pod
  namespace: storage-task
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "date > /mnt/archive/ts.txt && sleep 43200"]
    volumeMounts:
    - name: archive
      mountPath: /mnt/archive
  volumes:
  - name: archive
    persistentVolumeClaim:
      claimName: archive-pvc
```

```bash
k get pv pv-archive                            # Bound
k -n storage-task get pvc archive-pvc          # Bound
k -n storage-task exec archive-pod -- cat /mnt/archive/ts.txt
```

Why: static binding matches on storageClassName + accessModes + capacity (request must be <= PV size); omitting `storageClassName: archive` would send the PVC to the cluster's default provisioner instead of this PV. The PVC binds immediately (the PV pre-exists and binding is not scheduler-gated), but `exec` only works once the pod is scheduled and Running (Task 16).

| Component | Points |
|---|---|
| PVC matches class/mode/size, PV+PVC Bound | 3 |
| Pod running with mount at /mnt/archive, file written | 2 |

## Task 15 — Static Pod on the control plane

**Domain:** Cluster Architecture (5%) | **Time budget:** 6 min

```bash
docker exec -it cka-control-plane bash          # real exam: ssh <control-plane> + sudo -i
  # confirm the static-pod dir if unsure:
  grep staticPodPath /var/lib/kubelet/config.yaml   # /etc/kubernetes/manifests
  cat > /etc/kubernetes/manifests/web-static.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: web-static
  namespace: default
spec:
  containers:
  - name: web
    image: nginx:1.27-alpine
    ports:
    - containerPort: 80
YAML
  exit

k get pod -n default -o wide | grep web-static  # web-static-cka-control-plane   Running
echo web-static-cka-control-plane > /tmp/exam2/15-staticpod.txt
```

Why: the kubelet watches `staticPodPath` and runs any manifest there directly, **bypassing the scheduler** — which is exactly why this task succeeds even while Task 16's scheduler is broken, and why it is worth doing early. The API server exposes a read-only *mirror* pod named `<pod-name>-<node-name>`; you cannot `kubectl apply`/`kubectl delete` it (the kubelet owns it) — delete the manifest file on the node to remove it. A candidate who runs `kubectl apply` instead of dropping the file gets no credit: that creates an ordinary API pod, not a static one, and it would stay `Pending` behind the broken scheduler.

| Component | Points |
|---|---|
| Manifest placed in the kubelet static-pod dir on cka-control-plane (not `kubectl apply`) | 2 |
| Mirror pod `web-static-cka-control-plane` Running with image nginx:1.27-alpine | 2 |
| Correct mirror-pod name written to /tmp/exam2/15-staticpod.txt | 1 |

## Task 16 — Pods stuck Pending cluster-wide

**Domain:** Troubleshooting (7%) | **Time budget:** 8 min

"Pending with no events" means nothing is even trying to schedule — go straight to the scheduler.

```bash
k -n recovery get pods                         # Pending
k -n recovery describe pod -l app=stuck-app    # Events: <none>  -> scheduler suspect
k -n kube-system get pods                      # kube-scheduler-cka-control-plane failing
k -n kube-system describe pod kube-scheduler-cka-control-plane
# ... exec: "kube-schedulerX": executable file not found in $PATH

docker exec -it cka-control-plane bash         # real exam: ssh + sudo -i
  vi /etc/kubernetes/manifests/kube-scheduler.yaml
  # command first element: kube-schedulerX -> kube-scheduler
  exit

k -n kube-system get pods -w                   # kubelet re-creates the static pod, Running
k -n recovery get pods                         # stuck-app schedules and runs
echo /etc/kubernetes/manifests/kube-scheduler.yaml > /tmp/exam2/16-cause.txt
```

Why: static pod manifests under `/etc/kubernetes/manifests/` are watched by the kubelet — editing the file in place *is* the permanent fix; restarting anything manually is unnecessary and `kubectl delete` on a mirror pod does nothing. Fix this early: it unblocks Tasks 2 (rollout), 8, 10, 12 and 14.

| Component | Points |
|---|---|
| Localized the fault to kube-scheduler via events/kube-system | 3 |
| Fixed the static pod manifest on the node (permanent) | 2 |
| stuck-app Running + cause path file written | 2 |

---

## Scoring

| # | Task | Domain | Weight | Your score |
|---|---|---|---|---|
| 1 | Certificate-based user access | Cluster Architecture | 6 | |
| 2 | Deployment not becoming Ready | Troubleshooting | 8 | |
| 3 | HorizontalPodAutoscaler | Workloads & Scheduling | 8 | |
| 4 | Service serves no traffic | Troubleshooting | 7 | |
| 5 | Kustomize overlay | Cluster Architecture | 5 | |
| 6 | NetworkPolicy for the database | Services & Networking | 7 | |
| 7 | Node NotReady | Troubleshooting | 8 | |
| 8 | Dynamic provisioning | Storage | 5 | |
| 9 | Gateway API route | Services & Networking | 7 | |
| 10 | PriorityClass | Workloads & Scheduling | 7 | |
| 11 | Certificate expiry | Cluster Architecture | 4 | |
| 12 | Helm release lifecycle | Cluster Architecture | 5 | |
| 13 | NodePort Service and DNS | Services & Networking | 6 | |
| 14 | Bind a pre-provisioned PV | Storage | 5 | |
| 15 | Static Pod on the control plane | Cluster Architecture | 5 | |
| 16 | Pods stuck Pending cluster-wide | Troubleshooting | 7 | |
| | **Total** | | **100** | |

Domain subtotals: Troubleshooting 30, Cluster Architecture 25, Services & Networking 20, Workloads & Scheduling 15, Storage 10.

**Pass: >= 66.** Below 60: redo the failed domains' course modules before the next mock. 60–75: re-run this exam's failed tasks cold in 3 days. Above 85 within time: you are at exam readiness for this difficulty band. If you scored well but blew the 120-minute budget, that is a *fail* on the real exam — re-run and treat the clock as the hard constraint it is.

Cleanup after grading:

```bash
kubectl delete ns troubled commerce fintech secure-api web-frontend gateway-ns \
  storage-task dev-ana recovery web prod-web --ignore-not-found
kubectl delete pv pv-archive --ignore-not-found
kubectl delete priorityclass preexisting-high critical-services --ignore-not-found
kubectl delete storageclass fast-local --ignore-not-found
kubectl delete csr ana --ignore-not-found
kubectl config delete-context ana 2>/dev/null; kubectl config delete-user ana 2>/dev/null
docker exec cka-control-plane rm -f /etc/kubernetes/manifests/web-static.yaml 2>/dev/null || true
rm -rf /tmp/exam2
```
