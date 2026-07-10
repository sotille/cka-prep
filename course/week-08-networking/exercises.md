# Week 08 Exercises — Services & Networking

**Lab setup.** All tasks run on the 3-node kind cluster `cka` (context `kind-cka`, nodes `cka-control-plane`, `cka-worker`, `cka-worker2`). Conventions assumed: `alias k=kubectl`, `export do="--dry-run=client -o yaml"`, `export now="--grace-period=0 --force"`.

Two caveats before you start:

1. **NetworkPolicy enforcement:** kind's default CNI (kindnet) does **not** enforce NetworkPolicy — your policies (tasks 11–14) will be accepted but won't drop a single packet on the `cka` cluster. Write and verify them structurally there, then re-run the ladder on a Calico-backed cluster to see real drops:

   ```bash
   cat <<'EOF' > kind-calico.yaml
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   name: cka-netpol
   networking:
     disableDefaultCNI: true
     podSubnet: 192.168.0.0/16
   nodes:
   - role: control-plane
   - role: worker
   EOF
   kind create cluster --config kind-calico.yaml
   kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
   kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=calico-node --timeout=300s
   ```

   (Or use the free killercoda CKA playgrounds, which enforce policies.) Delete it afterwards: `kind delete cluster --name cka-netpol`.

2. **macOS + kind:** node IPs (172.18.0.x) are not routable from the host. Test NodePorts from a pod or via `docker exec` into a node container, not from your Mac's shell.

Exam-flavor note (applies throughout): the real exam runs kubeadm clusters — you `ssh node01` and `sudo -i` for node-level work; on kind substitute `docker exec -it <node> bash`.

---

## Tasks

### Task 1 — Three-tier app with every service type (exam, 12 min)

Context: namespace `three-tier` does not exist yet; nothing pre-exists.

Create namespace `three-tier` and deploy:

- `web`: deployment, image `nginx:1.27`, 2 replicas, exposed as a **NodePort** Service `web` on port 80 with nodePort **30100**.
- `api`: deployment, image `registry.k8s.io/e2e-test-images/agnhost:2.53`, 2 replicas, container command `/agnhost netexec --http-port=8080`, exposed as a **ClusterIP** Service `api` with port **8080**.
- `db`: deployment, image `postgres:16-alpine`, 1 replica, env `POSTGRES_PASSWORD=exam`, exposed as a **ClusterIP** Service `db` on port **5432**.
- `legacy-db`: an **ExternalName** Service aliasing `db.three-tier.svc.cluster.local`.
- `web-lb`: a **LoadBalancer** Service for `web` on port 80. State (in a comment or scratch note) why its EXTERNAL-IP stays `<pending>` on kind.

Then, from a `busybox:1.28` test pod in `three-tier`, demonstrate all of: short-name lookup (`api`), `svc.ns` lookup, full FQDN lookup, a pod dashed-IP record lookup, and an HTTP request to `api:8080/hostname`.

### Task 2 — Headless Service + StatefulSet DNS drill (exam, 8 min)

Context: namespace `state` does not exist yet.

Create namespace `state`, a headless Service `web-hs` (port 80, selector `app=web-ss`), and a StatefulSet `web-ss` (2 replicas, image `nginx:1.27`, `serviceName: web-hs`). Prove with nslookup that (a) `web-hs.state.svc.cluster.local` returns **both pod IPs**, and (b) `web-ss-0.web-hs.state.svc.cluster.local` returns exactly one. Compare with the ClusterIP answer you got for `api` in task 1 and note the difference.

### Task 3 — Broken Service: selector mismatch (warmup, 5 min)

Setup:

```bash
k create ns svc-debug
k -n svc-debug create deploy web --image=nginx:1.27 --replicas=2
k -n svc-debug apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: webapp
  ports:
  - port: 80
    targetPort: 80
EOF
```

A Service `web` in namespace `svc-debug` returns connection failures although all pods are Running and Ready. Diagnose and fix it **without deleting the Service**. Verify the fix with an HTTP request from a test pod.

### Task 4 — Broken Service: targetPort mismatch (exam, 5 min)

Setup:

```bash
k create ns svc-port
k -n svc-port create deploy api --image=nginx:1.27 --replicas=2
k -n svc-port apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: api
spec:
  selector:
    app: api
  ports:
  - port: 8080
    targetPort: 8080
EOF
```

Clients calling `api.svc-port:8080` get connection refused. Endpoints are **not** empty. Find the root cause and fix the Service (clients must keep using port 8080). Verify.

### Task 5 — NodePort with a fixed port (warmup, 4 min)

Setup:

```bash
k create ns svc-node
k -n svc-node create deploy hello --image=nginx:1.27
```

Expose deployment `hello` in `svc-node` on node port **30200** (service port 80). `kubectl expose` alone cannot do this — use whatever exam-legal path is fastest. Verify from a pod that `NODE_IP:30200` serves nginx.

### Task 6 — ExternalName alias (warmup, 3 min)

Context: namespace `svc-debug` from task 3.

Team A's app is hardcoded to call `search.svc-debug.svc.cluster.local:80`, but the real search endpoint is the Service `web` in the same namespace. Create a Service `search` in `svc-debug` of type ExternalName pointing at `web.svc-debug.svc.cluster.local` and prove the alias resolves (CNAME) from a busybox:1.28 pod.

### Task 7 — Service without selector + manual endpoints (exam, 8 min)

Setup:

```bash
k create ns svc-manual
k -n svc-manual run backend --image=nginx:1.27
```

Create a Service `manual-svc` in `svc-manual` (port 80) **without any selector**, then wire it manually to the `backend` pod's IP so that `wget http://manual-svc.svc-manual` works from a test pod. Do it once with a legacy `Endpoints` object; state (comment) what the modern EndpointSlice equivalent would look like.

### Task 8 — sessionAffinity + traffic policy semantics (warmup, 4 min)

Context: namespace `three-tier` from task 1.

Configure Service `api` so that a given client IP sticks to the same backend pod for **1 hour**. Then answer in one sentence each (write as comments in a scratch file):
- What changes for Service `web` (NodePort) if you set `externalTrafficPolicy: Local`?
- Why can that setting make requests to some nodes fail?

### Task 9 — Ingress: path routing for two backends + TLS (exam, 10 min)

Setup (installs the nginx ingress controller on kind, creates backends and cert):

```bash
# controller (kind flavor); label a node first because the manifest node-selects ingress-ready=true
k label node cka-worker ingress-ready=true --overwrite
k apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.1/deploy/static/provider/kind/deploy.yaml
k -n ingress-nginx wait --for=condition=Ready pod -l app.kubernetes.io/component=controller --timeout=300s

k create ns ingress-lab
k -n ingress-lab create deploy app1 --image=registry.k8s.io/e2e-test-images/agnhost:2.53 -- /agnhost serve-hostname --port 8080
k -n ingress-lab create deploy app2 --image=registry.k8s.io/e2e-test-images/agnhost:2.53 -- /agnhost serve-hostname --port 8080
k -n ingress-lab expose deploy app1 --port=80 --target-port=8080
k -n ingress-lab expose deploy app2 --port=80 --target-port=8080

openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout tls.key -out tls.crt -subj "/CN=app.example.com"
k -n ingress-lab create secret tls web-tls --cert=tls.crt --key=tls.key
```

Create an Ingress `web` in `ingress-lab` (class `nginx`) such that `https://app.example.com/app1` routes to Service `app1` and `https://app.example.com/app2` routes to `app2`, both with `pathType: Prefix`, TLS terminated with secret `web-tls`. Verify both paths over HTTPS (port-forward to the controller; you can't rely on host networking on macOS).

Exam-flavor note: on the real exam the controller and often the secret already exist — the graded artifact is the Ingress object plus reachability.

### Task 10 — Gateway API with an 80/20 canary split (hard, 15 min)

Setup:

```bash
k create ns gw-lab
k -n gw-lab create deploy app-v1 --image=registry.k8s.io/e2e-test-images/agnhost:2.53 -- /agnhost serve-hostname --port 8080
k -n gw-lab create deploy app-v2 --image=registry.k8s.io/e2e-test-images/agnhost:2.53 -- /agnhost serve-hostname --port 8080
k -n gw-lab expose deploy app-v1 --port=80 --target-port=8080
k -n gw-lab expose deploy app-v2 --port=80 --target-port=8080
```

1. Install the Gateway API **standard channel** CRDs.
2. Create a GatewayClass `lab-gwc` with controllerName `example.com/lab-controller`.
3. Create a Gateway `web-gw` in `gw-lab` using `lab-gwc`, one HTTP listener on port 80 named `http`, routes allowed from the **same namespace** only.
4. Create an HTTPRoute `split` in `gw-lab` attached to `web-gw`, hostname `app.gw.example.com`, routing `PathPrefix /` with an **80/20 weight split** between `app-v1:80` and `app-v2:80`, and adding response... no — adding a **request header** `X-Canary: enabled` on all matched requests.
5. Show the route's status conditions and explain (one line) why the Gateway is not `Programmed` on this cluster.

Exam-flavor note: the exam cluster will have a real controller and usually pre-installed CRDs; your job is the resource specs.

### Task 11 — NetworkPolicy ladder, rung 1: default-deny ingress (warmup, 3 min)

Setup (shared by tasks 11–14):

```bash
k create ns netpol-lab
k -n netpol-lab run frontend --image=registry.k8s.io/e2e-test-images/agnhost:2.53 --labels="role=frontend" -- /agnhost netexec --http-port=8080
k -n netpol-lab run api --image=registry.k8s.io/e2e-test-images/agnhost:2.53 --labels="role=api" -- /agnhost netexec --http-port=8080
k -n netpol-lab run db --image=registry.k8s.io/e2e-test-images/agnhost:2.53 --labels="role=db" -- /agnhost netexec --http-port=5432
k -n netpol-lab expose pod api --port=8080
k -n netpol-lab expose pod db --port=5432
k create ns clients
k label ns clients team=qa --overwrite
k -n clients run tester --image=registry.k8s.io/e2e-test-images/agnhost:2.53 --labels="role=tester" -- /agnhost netexec --http-port=8080
```

Deny **all ingress** to **all pods** in `netpol-lab` with a single NetworkPolicy named `default-deny-ingress`. Egress must remain unrestricted. Verify (on the Calico cluster) that `frontend` can no longer reach `api:8080`.

### Task 12 — Rung 2: allow frontend → api on 8080 (exam, 6 min)

Context: `netpol-lab` with the deny from task 11 in place.

Create NetworkPolicy `allow-frontend-to-api` so that **only** pods labeled `role=frontend` in `netpol-lab` can reach pods labeled `role=api` on **TCP 8080**. All other ingress to `api` stays denied. Verify: frontend→api succeeds; db→api fails.

### Task 13 — Rung 3: egress lockdown with DNS exception (hard, 10 min)

Context: `netpol-lab` as after task 12.

1. Deny **all egress** from all pods in `netpol-lab` (`default-deny-egress`).
2. Re-allow **DNS** (UDP and TCP 53) to any namespace for all pods (`allow-dns`).
3. Allow pods labeled `role=api` **egress** to pods labeled `role=db` on **TCP 5432** (`allow-api-to-db`).
4. Allow **ingress** to pods labeled `role=db` from pods labeled `role=api` on **TCP 5432** (`allow-api-to-db-ingress`). Rung 1's `default-deny-ingress` isolates `db` too, so the api-side egress allow is necessary but not sufficient — `db` must also admit the connection or it dies at the receiver's ingress.

Verify: `api` can resolve names and connect to `db:5432`; `api` can NOT reach `frontend:8080`; `frontend` can still reach `api:8080` (rung 2 must keep working — explain in one line why the egress deny would have silently broken it if you had skipped step 2... check name vs IP behavior).

### Task 14 — Rung 4: cross-namespace allow, AND semantics (exam, 7 min)

Context: `netpol-lab` and `clients` namespaces from the task-11 setup.

Extend ingress to `api` pods: additionally allow **only** pods labeled `role=tester` living in the namespace **named** `clients` (select the namespace by its automatic name label, not by `team=qa`) to reach TCP 8080. Pods with other labels in `clients` must stay blocked — i.e., you need AND semantics in a single `from` element. Verify tester→api succeeds and that a label-less pod in `clients` fails.

### Task 15 — CoreDNS break/fix (hard, 10 min)

Setup (breaks DNS deliberately — run exactly as given):

```bash
kubectl -n kube-system get configmap coredns -o yaml > coredns-backup.yaml
kubectl -n kube-system apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes broken.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
    }
EOF
kubectl -n kube-system rollout restart deployment coredns
```

Cluster-internal DNS is failing: pods cannot resolve any `*.svc.cluster.local` name, yet CoreDNS pods are Running and Ready and external names still resolve. Diagnose end-to-end (test pod → resolv.conf → coredns pods → logs → config) and fix. Finish by confirming `kubernetes.default` resolves again. Do NOT just apply the backup blindly — walk the tree first, then fix by editing.

### Task 16 — CNI inspection on the nodes (warmup, 5 min)

Context: the stock `cka` kind cluster.

On node `cka-worker`, locate the CNI configuration and plugin binaries. Answer (scratch notes): (a) which CNI is installed and what file declares it, (b) which chained plugins the conflist references, (c) where the binaries live, (d) name two cluster symptoms you'd see if `/etc/cni/net.d` were empty on a fresh node.

Exam-flavor note: on the exam this is `ssh node01` + `sudo ls /etc/cni/net.d`; on kind it's `docker exec`.

---

## SOLUTIONS

### Solution 1 — Three-tier app

```bash
k create ns three-tier

# web + fixed NodePort (expose can't set nodePort -> generate, edit, apply)
k -n three-tier create deploy web --image=nginx:1.27 --replicas=2
k -n three-tier expose deploy web --port=80 --type=NodePort $do > web-svc.yaml
# edit web-svc.yaml: add nodePort: 30100 under the port entry, then:
k apply -f web-svc.yaml

# api
k -n three-tier create deploy api --image=registry.k8s.io/e2e-test-images/agnhost:2.53 --replicas=2 -- /agnhost netexec --http-port=8080
k -n three-tier expose deploy api --port=8080 --target-port=8080

# db
k -n three-tier create deploy db --image=postgres:16-alpine
k -n three-tier set env deploy/db POSTGRES_PASSWORD=exam
k -n three-tier expose deploy db --port=5432

# externalname + loadbalancer
k -n three-tier create service externalname legacy-db --external-name=db.three-tier.svc.cluster.local
k -n three-tier expose deploy web --name=web-lb --port=80 --type=LoadBalancer
```

The finished `web` Service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: three-tier
spec:
  type: NodePort
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 80
    nodePort: 30100
```

DNS shape drills:

```bash
k -n three-tier run dns-test --image=busybox:1.28 --rm -it --restart=Never -- sh
# inside:
nslookup api                                  # short name (search path supplies three-tier.svc.cluster.local)
nslookup api.three-tier                       # svc.ns
nslookup api.three-tier.svc.cluster.local     # FQDN
nslookup legacy-db.three-tier.svc.cluster.local   # CNAME -> db.three-tier.svc.cluster.local
wget -qO- --timeout=2 http://api:8080/hostname && echo
exit

# pod dashed-IP record (run from your shell)
PODIP=$(k -n three-tier get pod -l app=api -o jsonpath='{.items[0].status.podIP}')
k -n three-tier run dns-test2 --image=busybox:1.28 --rm -it --restart=Never -- nslookup ${PODIP//./-}.three-tier.pod.cluster.local
```

`web-lb` EXTERNAL-IP stays `<pending>` because kind has no cloud controller / LB implementation to allocate one (MetalLB or cloud-provider-kind would fix it); the Service still works via its ClusterIP and allocated NodePort.

Why: one namespace exercises all five service types plus every DNS record shape you must recognize on the exam.

### Solution 2 — Headless + StatefulSet DNS

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-hs
  namespace: state
spec:
  clusterIP: None
  selector:
    app: web-ss
  ports:
  - port: 80
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: web-ss
  namespace: state
spec:
  serviceName: web-hs
  replicas: 2
  selector:
    matchLabels:
      app: web-ss
  template:
    metadata:
      labels:
        app: web-ss
    spec:
      containers:
      - name: nginx
        image: nginx:1.27
        ports:
        - containerPort: 80
```

```bash
k create ns state
k apply -f headless.yaml   # the two docs above
k -n state get pods -w     # wait for web-ss-0, web-ss-1

k -n state run dns-test --image=busybox:1.28 --rm -it --restart=Never -- sh
# inside:
nslookup web-hs.state.svc.cluster.local       # TWO A records (pod IPs) - no VIP
nslookup web-ss-0.web-hs.state.svc.cluster.local   # exactly one pod IP
exit
```

Difference vs task 1: `api` resolved to a single ClusterIP (kube-proxy DNATs it); `web-hs` has no ClusterIP — DNS itself returns pod IPs and clients connect directly, which is how StatefulSets get stable per-pod identity.

Why: headless-vs-VIP resolution is a recurring exam discriminator and the basis of StatefulSet networking.

### Solution 3 — Selector mismatch

```bash
k -n svc-debug describe svc web            # Endpoints: <none>  => selector problem
k -n svc-debug get pods --show-labels      # pods carry app=web
k -n svc-debug get svc web -o jsonpath='{.spec.selector}'   # {"app":"webapp"} - mismatch

k -n svc-debug patch svc web -p '{"spec":{"selector":{"app":"web"}}}'
# (k edit svc web -n svc-debug works too)

k -n svc-debug describe svc web            # Endpoints now populated
k -n svc-debug run t --image=busybox:1.28 --rm -it --restart=Never -- wget -qO- --timeout=2 http://web
```

Why: empty endpoints with Ready pods = selector/label mismatch, always — fix the selector to match pod labels.

### Solution 4 — targetPort mismatch

```bash
k -n svc-port describe svc api             # Endpoints populated: podIP:8080
k -n svc-port get pods -o jsonpath='{.items[0].spec.containers[0].ports}'   # may be empty; nginx listens on 80
k -n svc-port exec deploy/api -- ls /etc/nginx/conf.d/   # or just know nginx:80

k -n svc-port patch svc api --type='json' -p='[{"op":"replace","path":"/spec/ports/0/targetPort","value":80}]'

k -n svc-port run t --image=busybox:1.28 --rm -it --restart=Never -- wget -qO- --timeout=2 http://api.svc-port:8080
```

Fixed Service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: svc-port
spec:
  selector:
    app: api
  ports:
  - port: 8080       # client-facing port unchanged
    targetPort: 80   # where nginx actually listens
```

Why: populated endpoints + refused connections means the port is wrong, not the selector — endpoints record `podIP:targetPort` whether or not anything listens there.

### Solution 5 — Fixed NodePort

```bash
k -n svc-node expose deploy hello --port=80 --type=NodePort
k -n svc-node patch svc hello -p '{"spec":{"ports":[{"port":80,"nodePort":30200}]}}'

# verify from a pod (macOS: node IPs unreachable from host)
NODE_IP=$(k get node cka-worker -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
k run t --image=busybox:1.28 --rm -it --restart=Never -- wget -qO- --timeout=2 http://$NODE_IP:30200
```

Why: expose + strategic-merge patch (ports merge on the `port` key) is the fastest legal route to a fixed nodePort.

### Solution 6 — ExternalName

```bash
k -n svc-debug create service externalname search --external-name=web.svc-debug.svc.cluster.local
k -n svc-debug run t --image=busybox:1.28 --rm -it --restart=Never -- nslookup search.svc-debug.svc.cluster.local
# answer shows: canonical name = web.svc-debug.svc.cluster.local, then web's ClusterIP
```

```yaml
apiVersion: v1
kind: Service
metadata:
  name: search
  namespace: svc-debug
spec:
  type: ExternalName
  externalName: web.svc-debug.svc.cluster.local
```

Why: ExternalName is pure DNS (CNAME) — no proxying, no endpoints — ideal for aliasing without touching clients.

### Solution 7 — Manual endpoints

```bash
PODIP=$(k -n svc-manual get pod backend -o jsonpath='{.status.podIP}')
echo $PODIP   # substitute below
```

```yaml
apiVersion: v1
kind: Service
metadata:
  name: manual-svc
  namespace: svc-manual
spec:                # note: NO selector
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: v1
kind: Endpoints
metadata:
  name: manual-svc   # MUST equal the Service name
  namespace: svc-manual
subsets:
- addresses:
  - ip: 10.244.1.10  # replace with the backend pod IP from $PODIP
  ports:
  - port: 80
```

```bash
k apply -f manual.yaml
k -n svc-manual run t --image=busybox:1.28 --rm -it --restart=Never -- wget -qO- --timeout=2 http://manual-svc
```

Modern equivalent — an EndpointSlice labeled back to the Service instead of name-matching:

```yaml
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: manual-svc-1
  namespace: svc-manual
  labels:
    kubernetes.io/service-name: manual-svc
addressType: IPv4
endpoints:
- addresses:
  - "10.244.1.10"    # replace with the backend pod IP
  conditions:
    ready: true
ports:
- port: 80
  protocol: TCP
```

Why: with no selector, no controller writes endpoints — you supply them, and the Service name (or the `kubernetes.io/service-name` label) is the join key.

### Solution 8 — sessionAffinity + traffic policy

```bash
k -n three-tier patch svc api -p '{"spec":{"sessionAffinity":"ClientIP","sessionAffinityConfig":{"clientIP":{"timeoutSeconds":3600}}}}'
k -n three-tier get svc api -o yaml | grep -A4 sessionAffinity
```

```yaml
# resulting fragment
spec:
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 3600
```

- `externalTrafficPolicy: Local` on `web`: nodes stop forwarding NodePort traffic to pods on other nodes, no SNAT is applied, so the app sees the real client IP.
- Requests to a node that hosts **no** `web` pod are dropped — by design; external LBs are expected to health-check `healthCheckNodePort` and avoid such nodes.

Why: affinity is kube-proxy-implemented per source IP; Local trades universal reachability for source-IP preservation.

### Solution 9 — Ingress with TLS

Fast path:

```bash
k -n ingress-lab create ingress web --class=nginx \
  --rule="app.example.com/app1*=app1:80,tls=web-tls" \
  --rule="app.example.com/app2*=app2:80,tls=web-tls"
```

Equivalent YAML (what the one-liner generates; `*` ⇒ `pathType: Prefix`):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
  namespace: ingress-lab
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - app.example.com
    secretName: web-tls
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /app1
        pathType: Prefix
        backend:
          service:
            name: app1
            port:
              number: 80
      - path: /app2
        pathType: Prefix
        backend:
          service:
            name: app2
            port:
              number: 80
```

Verify:

```bash
k -n ingress-lab get ingress web        # ADDRESS populated once the controller syncs
k -n ingress-nginx port-forward svc/ingress-nginx-controller 8443:443 &
curl -sk --resolve app.example.com:8443:127.0.0.1 https://app.example.com:8443/app1   # app1 pod name
curl -sk --resolve app.example.com:8443:127.0.0.1 https://app.example.com:8443/app2   # app2 pod name
kill %1
```

Why: one host, two Prefix paths, TLS secret referenced by name — the canonical exam Ingress; `k create ingress --rule` is dramatically faster than hand-writing the nested backend structure.

### Solution 10 — Gateway API canary

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
k get crd | grep gateway    # gatewayclasses, gateways, httproutes, ...
```

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: lab-gwc
spec:
  controllerName: example.com/lab-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web-gw
  namespace: gw-lab
spec:
  gatewayClassName: lab-gwc
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: split
  namespace: gw-lab
spec:
  parentRefs:
  - name: web-gw
  hostnames:
  - app.gw.example.com
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    filters:
    - type: RequestHeaderModifier
      requestHeaderModifier:
        add:
        - name: X-Canary
          value: enabled
    backendRefs:
    - name: app-v1
      port: 80
      weight: 80
    - name: app-v2
      port: 80
      weight: 20
```

```bash
k apply -f gateway.yaml
k -n gw-lab get gateway,httproute
k -n gw-lab describe gateway web-gw     # Programmed: False/Unknown
k -n gw-lab describe httproute split    # parent status: no controller has accepted it
```

The Gateway never reaches `Programmed` because no controller watches `controllerName: example.com/lab-controller` — the CRDs store the spec, but a controller (Istio, Envoy Gateway, nginx-gateway-fabric...) must exist to build a dataplane. On the exam one will.

Why: this is the full new-curriculum Gateway chain — CRDs → GatewayClass → Gateway (listener + allowedRoutes) → HTTPRoute (parentRefs, hostname, weighted backendRefs, filter).

### Solution 11 — Default-deny ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: netpol-lab
spec:
  podSelector: {}
  policyTypes:
  - Ingress
```

```bash
k apply -f deny-ingress.yaml
k -n netpol-lab describe netpol default-deny-ingress
# on the Calico cluster:
k -n netpol-lab exec frontend -- /agnhost connect api.netpol-lab.svc.cluster.local:8080 --timeout=2s
# -> TIMEOUT (dropped). On stock kind (kindnet) this still connects - no enforcement.
```

Why: `podSelector: {}` isolates every pod in the namespace for ingress; listing only `Ingress` in policyTypes leaves egress untouched.

### Solution 12 — Allow frontend → api

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-api
  namespace: netpol-lab
spec:
  podSelector:
    matchLabels:
      role: api
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          role: frontend
    ports:
    - protocol: TCP
      port: 8080
```

```bash
k apply -f allow-fe-api.yaml
k -n netpol-lab exec frontend -- /agnhost connect api.netpol-lab.svc.cluster.local:8080 --timeout=2s   # OK (exit 0, silent)
k -n netpol-lab exec db       -- /agnhost connect api.netpol-lab.svc.cluster.local:8080 --timeout=2s   # TIMEOUT
```

Why: policies are additive — this allow-rule punches exactly one hole (frontend, TCP 8080) through the rung-1 deny; everything else stays dropped.

### Solution 13 — Egress lockdown + DNS

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: netpol-lab
spec:
  podSelector: {}
  policyTypes:
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: netpol-lab
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-to-db
  namespace: netpol-lab
spec:
  podSelector:
    matchLabels:
      role: api
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          role: db
    ports:
    - protocol: TCP
      port: 5432
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-to-db-ingress
  namespace: netpol-lab
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

`allow-api-to-db` (api's *egress*) and `allow-api-to-db-ingress` (db's *ingress*) are a matched pair: rung 1's namespace-wide `default-deny-ingress` isolates `db` for ingress just like every other pod, so opening only api's egress leaves the connection to time out at db's ingress. Both sides must permit the flow.

```bash
k apply -f egress-ladder.yaml
k -n netpol-lab exec api      -- /agnhost connect db.netpol-lab.svc.cluster.local:5432 --timeout=2s        # OK
k -n netpol-lab exec api      -- /agnhost connect frontend-ip-not-allowed:8080 --timeout=2s                # (use the frontend pod IP) TIMEOUT
k -n netpol-lab exec frontend -- /agnhost connect api.netpol-lab.svc.cluster.local:8080 --timeout=2s       # still OK? see below
```

Nuance the task asked for: frontend's *egress* is now denied too, so frontend→api only works because... it doesn't — until you notice `allow-dns` covers DNS only, not TCP 8080 egress. Rung 2 governed api's *ingress*; rung 3's deny governs frontend's *egress*. To keep frontend→api working you must also add an egress allow from `role=frontend` to `role=api` on TCP 8080 (same shape as `allow-api-to-db`). If you skipped `allow-dns`, even permitted flows would fail at name resolution while direct pod-IP connections still worked — the classic "DNS-shaped" netpol failure.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-egress-to-api
  namespace: netpol-lab
spec:
  podSelector:
    matchLabels:
      role: frontend
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          role: api
    ports:
    - protocol: TCP
      port: 8080
```

Why: a connection must be allowed by the sender's egress policies AND the receiver's ingress policies; and any egress lockdown without a UDP+TCP 53 exception breaks service discovery namespace-wide.

### Solution 14 — Cross-namespace AND

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-clients-testers
  namespace: netpol-lab
spec:
  podSelector:
    matchLabels:
      role: api
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: clients
      podSelector:            # same element as namespaceSelector => AND
        matchLabels:
          role: tester
    ports:
    - protocol: TCP
      port: 8080
```

```bash
k apply -f cross-ns.yaml
k -n clients exec tester -- /agnhost connect api.netpol-lab.svc.cluster.local:8080 --timeout=2s   # OK
k -n clients run other --image=registry.k8s.io/e2e-test-images/agnhost:2.53 --labels="role=other" -- /agnhost netexec --http-port=8080
k -n clients exec other -- /agnhost connect api.netpol-lab.svc.cluster.local:8080 --timeout=2s    # TIMEOUT
```

Why: keeping both selectors in ONE `from` element requires both to match (namespace `clients` AND label `role=tester`); a second `-` would have turned it into an OR and admitted every pod in `clients` — the exact mistake graders bait.

### Solution 15 — CoreDNS break/fix

```bash
# 1. Reproduce and scope
k run t --image=busybox:1.28 --rm -it --restart=Never -- nslookup kubernetes.default          # FAILS
k run t --image=busybox:1.28 --rm -it --restart=Never -- nslookup kubernetes.io               # works => forward path fine
# => only cluster zone broken

# 2. Pod's nameserver correct?
k run t2 --image=busybox:1.28 --restart=Never -- sleep 3600
k exec t2 -- cat /etc/resolv.conf          # nameserver == kube-dns ClusterIP => not the problem
k -n kube-system get svc kube-dns

# 3. CoreDNS healthy?
k -n kube-system get pods -l k8s-app=kube-dns    # Running, Ready
k -n kube-system logs -l k8s-app=kube-dns        # no crash; queries for cluster.local NXDOMAIN

# 4. Config
k -n kube-system get cm coredns -o yaml          # kubernetes plugin zone reads "broken.local" - root cause

# 5. Fix: restore the zone
k -n kube-system edit cm coredns                 # broken.local -> cluster.local
k -n kube-system rollout restart deploy coredns
k -n kube-system rollout status deploy coredns

# 6. Confirm
k run t3 --image=busybox:1.28 --rm -it --restart=Never -- nslookup kubernetes.default   # resolves
k delete pod t2 $now
```

(The `reload` plugin would pick up the edit within ~30–45s without a restart; the restart is deterministic under exam time pressure.) Cleanup safety net: `k -n kube-system apply -f coredns-backup.yaml` restores the original if your edit goes sideways.

Why: "internal names fail, external work, pods Ready" fingerprints the `kubernetes` plugin zone in the Corefile — the debug tree walks client → path → server → config in strict order so you never guess.

### Solution 16 — CNI inspection

```bash
docker exec cka-worker ls /etc/cni/net.d
# 10-kindnet.conflist
docker exec cka-worker cat /etc/cni/net.d/10-kindnet.conflist
docker exec cka-worker ls /opt/cni/bin
```

Answers:

- (a) kindnet, declared by `/etc/cni/net.d/10-kindnet.conflist` (the runtime loads the lexicographically first file in that dir).
- (b) The conflist chains `ptp` (creates the veth pair / per-pod point-to-point link) with `portmap` (implements hostPort); kindnet itself programs inter-node pod routes.
- (c) `/opt/cni/bin` — `ptp`, `portmap`, `host-local` (IPAM), `loopback`, etc.
- (d) Nodes stuck `NotReady` with `container runtime network not ready ... cni plugin not initialized`, and any non-hostNetwork pod stuck `ContainerCreating` with sandbox network setup errors — while hostNetwork pods (kube-proxy, static control-plane pods) run normally.

Why: locating `/etc/cni/net.d` + `/opt/cni/bin` and recognizing the missing-CNI symptom pair is exactly what the curriculum's "CNI awareness" line means.
