# Week 08 Masterclass — Services & Networking (20% of the exam, feeding the 30% Troubleshooting domain)

> **Weight correction:** the week-08 notes header says networking is 30% of the exam. That was the pre-Feb-2025 curriculum. Current weights: **Troubleshooting 30%, Cluster Architecture/Installation/Configuration 25%, Services & Networking 20%, Workloads & Scheduling 15%, Storage 10%.** Networking still punches above 20% because a large share of troubleshooting tasks are networking failures (empty endpoints, dead DNS, missing CNI). Confirm live weights on the CNCF curriculum page before exam day.

## What the exam actually asks

| Topic | Domain (weight) | Typical task shape |
|---|---|---|
| Service types, ports, selectors | Services & Networking (20%) | "Expose deployment X internally on port N", "make it reachable on NodePort 30xxx" |
| Broken Service / empty endpoints | Troubleshooting (30%) | "Pods Running but app unreachable through the Service — fix" |
| CoreDNS | Troubleshooting (30%) | "Pods cannot resolve service names — diagnose and repair" |
| Ingress | Services & Networking | "Route /a to svc A, /b to svc B on host H, TLS with secret S" |
| Gateway API (added Feb 2025) | Services & Networking | "Create Gateway + HTTPRoute", "split traffic 80/20 between two Services" |
| NetworkPolicy | Services & Networking | "Only pods labeled X may reach pods labeled Y on port N; deny all else" |
| CNI awareness (added Feb 2025) | Cluster Architecture (25%) + Troubleshooting | "Node NotReady, pods ContainerCreating — identify/install the network plugin" |
| kube-proxy / traffic paths | Troubleshooting | Rarely asked directly; it is the mental model you debug with |

Not asked: writing a CNI plugin, BGP/Calico internals, service meshes, IPv6 dual-stack configuration from memory.

---

## 1. The Kubernetes network model

Four invariants, implemented by the CNI plugin, assumed by everything above it:

1. Every pod gets its own IP from the cluster pod CIDR. Each node owns a slice: `kubectl get node cka-worker -o jsonpath='{.spec.podCIDR}'`.
2. Every pod can reach every other pod, on any node, **without NAT**. The CNI makes pod IPs routable cluster-wide (plain routes, VXLAN overlay, or eBPF, depending on plugin).
3. Node agents (kubelet, kube-proxy) can reach every pod on their node.
4. Containers in one pod share a single network namespace: they talk over `localhost` and cannot reuse the same port.

Debugging consequences you will exploit all week:

- Pod IPs are real. `curl POD_IP:PORT` bypasses Services, kube-proxy, and DNS entirely — it is your ground-truth test ("is the app itself alive?").
- Service ClusterIPs are **not** real. No interface anywhere holds them; they exist only as DNAT rules programmed by kube-proxy on every node. You cannot ping a ClusterIP (ICMP is not translated); you can only connect to declared ports.
- NAT appears only at edges: external client → NodePort, and pod → internet (masquerade).

---

## 2. Services deep-dive

### The pipeline: selector → EndpointSlice → kube-proxy rules

A Service is two things: a stable virtual IP + port, and a label query. The EndpointSlice controller continuously evaluates `spec.selector` against **ready** pods and writes the result into EndpointSlice objects. kube-proxy on every node watches EndpointSlices and programs DNAT rules: ClusterIP:port → one of the endpoint IP:targetPorts.

```bash
k get endpointslices -n prod -l kubernetes.io/service-name=api   # modern object
k get endpoints api -n prod                                      # legacy mirror, still populated
k describe svc api -n prod | grep -i endpoints                   # fastest exam check
```

EndpointSlices (`discovery.k8s.io/v1`) shard endpoints (default 100 per slice) and carry per-endpoint topology and conditions. The legacy `Endpoints` object still exists and mirrors the same data for most services — either is fine for exam verification; `describe svc` is faster than both.

Critical: **unready pods are removed from endpoints.** A failing readinessProbe silently drains a Service. "Pods Running, service dead" → check `k get pods` READY column before you touch the Service.

### port vs targetPort vs nodePort

```yaml
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: prod
spec:
  type: NodePort
  selector:
    app: api
  ports:
  - name: http
    port: 80          # the Service's own port (ClusterIP:80)
    targetPort: 8080  # container port traffic is DNATed to; defaults to port if omitted
    nodePort: 30080   # port on EVERY node; allocated from 30000-32767 if omitted
    protocol: TCP
```

- `port` — what clients dial on the ClusterIP / DNS name.
- `targetPort` — where the pod actually listens. **Defaults to `port`**; the classic bug is exposing `--port=80` for an app on 8080 and never setting `--target-port`.
- `nodePort` — only for NodePort/LoadBalancer. Default allocatable range **30000–32767** (apiserver flag `--service-node-port-range`). `kubectl expose` has **no flag to pin it** — generate YAML and set it, or patch after.

`targetPort` can be a **name**, resolved per-pod against `containerPort` names:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
  ports:
  - port: 80
    targetPort: http-web   # each pod may map http-web to a different number
```

Named targetPorts decouple the Service from the container port number (canary on a new port without touching the Service). Failure mode: no container port carries that name → that pod contributes no usable endpoint → connection refused/timeouts with pods happily Running.

### The five service types

| Type | What it adds | DNS answer | Exam notes |
|---|---|---|---|
| **ClusterIP** (default) | Virtual IP inside cluster | A record → ClusterIP | The default; `headless` is ClusterIP with `clusterIP: None` |
| **NodePort** | ClusterIP + a port on every node's IP | same A record | Range 30000–32767; reachable on ALL nodes regardless of pod placement |
| **LoadBalancer** | NodePort + external LB via cloud controller | same + external IP | On kind/bare metal stays `<pending>` forever unless MetalLB / cloud-provider-kind is installed — that is expected, not a bug |
| **ExternalName** | No proxying at all — DNS CNAME | CNAME → `spec.externalName` | No selector, no endpoints, no ports needed; TLS clients will see the external cert name (SNI mismatch is your problem) |
| **Headless** (`clusterIP: None`) | No VIP, no kube-proxy rules | A records → **all ready pod IPs** | Client-side load balancing; foundation of StatefulSet per-pod DNS |

### Services without selectors + manual endpoints

Omit the selector and the control plane creates **no** endpoints — you supply them. This is how you point a stable in-cluster name at an external database or a legacy VM:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: external-db
  namespace: prod
spec:
  ports:
  - port: 5432
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: external-db-1
  namespace: prod
  labels:
    kubernetes.io/service-name: external-db   # this label is the ONLY link to the Service
addressType: IPv4
ports:
- name: ""            # must match the Service port's name ("" because it is unnamed)
  protocol: TCP
  port: 5432
endpoints:
- addresses:
  - "10.10.0.5"
```

The legacy equivalent — an `Endpoints` object with `metadata.name` equal to the Service name — still works and is shorter to type. Either way: the port **name** must match between Service and endpoints, and the endpoint port is the *real* destination port (targetPort is meaningless without a selector).

### sessionAffinity

```yaml
apiVersion: v1
kind: Service
metadata:
  name: sticky
spec:
  selector:
    app: web
  ports:
  - port: 80
  sessionAffinity: ClientIP        # only other value: None
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 600          # default 10800 (3h)
```

Implemented in kube-proxy (iptables `recent` module / IPVS persistence). Source-IP based only — there is no cookie affinity at the Service level (that's an Ingress-controller feature).

### externalTrafficPolicy: Cluster vs Local

Applies to NodePort/LoadBalancer traffic arriving from outside:

| | `Cluster` (default) | `Local` |
|---|---|---|
| Node without local endpoint | forwards to another node (extra hop) | **drops** the connection |
| Client source IP | lost (SNAT to node IP) | **preserved** |
| Load spread | even across all endpoints | only across endpoints local to hit nodes |
| LB integration | all nodes healthy | `healthCheckNodePort` marks endpointless nodes unhealthy |

`Local` is the answer to "the app must see real client IPs". The trap: with `Local`, curling the NodePort on a node that hosts no pod of that Service times out — that is by design, not a broken Service. (`internalTrafficPolicy` is the same idea for in-cluster ClusterIP traffic; know it exists.)

---

## 3. kube-proxy

kube-proxy runs as a DaemonSet (`kube-system/kube-proxy` on kubeadm clusters; kind's equivalent is also `kube-proxy`) and turns Service/EndpointSlice state into packet-mangling rules on every node. It is **not** in the data path itself in iptables/ipvs/nftables modes — the kernel is.

| Mode | Mechanism | Notes |
|---|---|---|
| `iptables` | chains `KUBE-SERVICES` → `KUBE-SVC-*` → `KUBE-SEP-*`, random DNAT | default; rule count scales with services×endpoints |
| `ipvs` | kernel IPVS virtual servers, hash-based lookup | better at scale, real LB algorithms (`rr`, `lc`...); needs kernel modules |
| `nftables` | native nftables tables | newer; alpha 1.29, beta 1.31 and still maturing (not GA in the ~1.33 timeframe) — confirm current status; one to *recognize* |

Config lives in the **kube-proxy ConfigMap**, mounted by the DaemonSet:

```bash
k -n kube-system get cm kube-proxy -o yaml | grep -E 'mode|clusterCIDR'
k -n kube-system get ds kube-proxy
# change mode: edit the ConfigMap, then restart the pods:
k -n kube-system rollout restart ds kube-proxy
```

Ground-truth inspection on a node (kind: `docker exec -it cka-worker bash`):

```bash
iptables-save | grep -c KUBE-SVC        # service chains exist?
iptables-save | grep my-service         # rules for one service (comments carry ns/name)
ipvsadm -Ln                             # ipvs mode
conntrack -L | grep 30080               # existing NAT sessions
```

Debug value: if `describe svc` shows endpoints but connections to the ClusterIP fail from a pod, suspect kube-proxy (pod crashed? mode mismatch? stale rules) — check `k -n kube-system logs ds/kube-proxy`. Also remember the DNAT happens **on the client's node**: a broken kube-proxy only breaks Services for pods on that node.

---

## 4. DNS: CoreDNS

### Architecture

CoreDNS runs as Deployment `coredns` (2 replicas) in `kube-system`, fronted by Service `kube-dns` (name kept for compatibility) on a fixed ClusterIP (10.96.0.10 on default kind/kubeadm service CIDRs). kubelet injects that IP into every `ClusterFirst` pod's `/etc/resolv.conf` (kubelet config `clusterDNS`). Config is a **Corefile** in ConfigMap `kube-system/coredns`:

```yaml
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
        kubernetes cluster.local in-addr.arpa ip6.arpa {
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
```

Plugins that matter:

- `kubernetes cluster.local ...` — serves the cluster zone from the API (watch on Services/EndpointSlices). `pods insecure` enables pod-IP records; `fallthrough in-addr.arpa` lets non-cluster reverse lookups continue to `forward`.
- `forward . /etc/resolv.conf` — everything not in the cluster zone goes to the node's upstream resolvers. **This is the seam**: break it and external names die while `*.cluster.local` still resolves; break the `kubernetes` zone and it's the opposite.
- `loop` — crash-loops CoreDNS if it detects a forwarding loop (classic on hosts with systemd-resolved's 127.0.0.53). CoreDNS CrashLoopBackOff + "Loop ... detected" in logs → fix upstream resolv.conf.
- `reload` — Corefile edits are picked up automatically within ~2 minutes; `k -n kube-system rollout restart deploy coredns` when impatient.
- `log` — not present by default; add it inside the server block to log every query (your best debugging lever).

### Record shapes

| Object | Record | Example |
|---|---|---|
| Service | `<svc>.<ns>.svc.cluster.local` → A (ClusterIP) | `api.prod.svc.cluster.local` → 10.96.4.7 |
| Headless service | same name → A per **ready** pod IP | 3 answers for 3 replicas |
| Named service port | `_<port>._<proto>.<svc>.<ns>.svc.cluster.local` → SRV | `_http._tcp.api.prod.svc.cluster.local` |
| Pod (needs `pods insecure/verified`) | `<ip-dashed>.<ns>.pod.cluster.local` | `10-244-1-5.prod.pod.cluster.local` |
| StatefulSet pod via headless svc | `<pod>.<svc>.<ns>.svc.cluster.local` | `db-0.db-hl.prod.svc.cluster.local` |

Per-pod records under a headless service require the pod's `hostname`/`subdomain` to line up — a StatefulSet does this for you via `spec.serviceName`, which is why headless-service-name must equal the StatefulSet's `serviceName` or pod DNS silently doesn't exist. This gives stable per-replica identity (`db-0` keeps its name across rescheduling even though the IP changes).

### resolv.conf, search domains, and the ndots:5 trap

Inside any ClusterFirst pod in namespace `prod`:

```text
search prod.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

Resolution rules: a name with fewer than `ndots` (5) dots is tried against each search domain **first**, then as-is. Consequences:

- `api` → `api.prod.svc.cluster.local` — same-namespace shorthand works.
- `api.other` → `api.other.svc.cluster.local` — cross-namespace shorthand works.
- `example.com` (1 dot < 5) → tries `example.com.prod.svc.cluster.local`, `example.com.svc.cluster.local`, `example.com.cluster.local` (each as A+AAAA) **before** the real query. That's up to 6–8 wasted queries per lookup — the classic "external DNS is slow/flaky from pods" ticket. Fix: use an FQDN with a trailing dot (`example.com.`), or set `dnsConfig` with `ndots:1`.

### dnsPolicy

| Value | Behavior |
|---|---|
| `ClusterFirst` | default for pods; cluster zone → CoreDNS, rest forwarded |
| `Default` | inherit the **node's** resolv.conf (misleading name — not the default) |
| `ClusterFirstWithHostNet` | required to keep cluster DNS for `hostNetwork: true` pods (they'd otherwise get `Default`) |
| `None` | blank slate; must supply `spec.dnsConfig` (nameservers/searches/options) |

### Debugging DNS end-to-end

The ladder, in order — stop at the first broken rung:

```bash
# 0. a proper client. busybox:1.28 works; MODERN busybox nslookup is broken/misleading — do not use :latest
k run dnsq --image=busybox:1.28 --rm -it --restart=Never -- nslookup kubernetes.default
# better: the docs dnsutils pod (dig + nslookup):
k apply -f https://k8s.io/examples/admin/dns/dnsutils.yaml
k exec -it dnsutils -- nslookup kubernetes.default

# 1. is the pod even pointed at CoreDNS?
k exec -it dnsutils -- cat /etc/resolv.conf     # nameserver must equal kube-dns ClusterIP

# 2. is the kube-dns Service wired?
k -n kube-system get svc kube-dns
k -n kube-system get endpointslices -l k8s-app=kube-dns   # empty => CoreDNS pods not ready

# 3. are the CoreDNS pods alive, and what do they say?
k -n kube-system get pods -l k8s-app=kube-dns
k -n kube-system logs -l k8s-app=kube-dns
k -n kube-system describe cm coredns              # read the Corefile: zone right? forward right?

# 4. bypass the Service — query a CoreDNS pod IP directly to isolate kube-proxy vs CoreDNS
k exec -it dnsutils -- dig @POD_IP kubernetes.default.svc.cluster.local +short

# 5. remediation levers
k -n kube-system edit cm coredns                   # fix Corefile (add `log` while you're there)
k -n kube-system rollout restart deploy coredns
k -n kube-system scale deploy coredns --replicas=3 # if asked to scale DNS
```

Split-brain diagnosis: cluster names fail but external work → `kubernetes` plugin/zone problem. External fail but cluster names work → `forward` problem (or upstream). Everything fails → resolv.conf points at the wrong IP, kube-dns service/endpoints broken, or a NetworkPolicy is eating port 53.

---

## 5. Ingress

An Ingress is **pure configuration** — HTTP(S) host/path routing rules. Without an ingress **controller** watching them, applying an Ingress does exactly nothing, silently. On the exam a controller is installed; on kind you install one:

```bash
k apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.1/deploy/static/provider/kind/deploy.yaml
```

(The kind provider manifest wants a node labeled `ingress-ready=true` — `k label node cka-worker ingress-ready=true` — and host port mappings in the kind config for real external access; port-forwarding the controller Service works for verification regardless.)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop
  namespace: prod
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - shop.example.com
    secretName: shop-tls          # MUST be a Secret of type kubernetes.io/tls in this namespace
  defaultBackend:                  # catch-all when no rule matches
    service:
      name: catalog
      port:
        number: 8080
  rules:
  - host: shop.example.com
    http:
      paths:
      - path: /cart
        pathType: Prefix
        backend:
          service:
            name: cart
            port:
              number: 8080
      - path: /admin
        pathType: Exact
        backend:
          service:
            name: admin
            port:
              number: 8080
```

Load-bearing details:

- `ingressClassName` selects the controller. Omit it and no default IngressClass exists (annotation `ingressclass.kubernetes.io/is-default-class: "true"`) → the Ingress is ignored by every controller. `k get ingressclass` first.
- `pathType`:
  - `Exact` — byte-for-byte match.
  - `Prefix` — **element-wise on `/`-split segments**: `/foo` matches `/foo`, `/foo/`, `/foo/bar`, but **not** `/foobar`. This is the exam-favorite distinction.
  - `ImplementationSpecific` — controller decides (nginx treats it like a location prefix; regex paths need it plus annotations).
- TLS: `k create secret tls shop-tls --cert=tls.crt --key=tls.key` produces the required `kubernetes.io/tls` secret (keys `tls.crt`/`tls.key`). The `tls.hosts` list must cover the rule host for the controller to serve the cert via SNI.
- Annotations are controller-specific and not part of the API. Recognize `nginx.ingress.kubernetes.io/rewrite-target` (strip/rewrite the matched path before proxying, often with capture groups + `ImplementationSpecific` regex paths) and `nginx.ingress.kubernetes.io/ssl-redirect`. Do not memorize more; the nginx-ingress docs are not allowed in-exam, but tasks that need an annotation will show it.
- Verification: `k describe ingress shop` shows the resolved backends and — crucially — `<error: endpoints "cart" not found>` style warnings when a backend Service is missing.

Speed: `k create ingress shop --rule="shop.example.com/cart*=cart:8080,tls=shop-tls" --class=nginx $do` — `*` after the path means `pathType: Prefix`, no `*` means `Exact`. Multiple `--rule` flags allowed. Generate, eyeball, apply.

---

## 6. Gateway API (curriculum addition)

Gateway API is the successor to Ingress: role-separated, protocol-aware, expressive (traffic splits, header matching, filters) — all `gateway.networking.k8s.io/v1`. It ships as **CRDs, not core** — nothing works until they're installed:

```bash
k apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
k api-resources | grep gateway
```

### Resource model — three layers, three roles

```text
GatewayClass  (infra provider: "this controller implements gateways")
   └── Gateway  (cluster operator: "open these listeners on this class")
         └── HTTPRoute / GRPCRoute / ...  (app developer: "route this traffic to my Services")
```

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: example-gc
spec:
  controllerName: example.net/gateway-controller   # which controller claims this class
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main-gw
  namespace: infra
spec:
  gatewayClassName: example-gc
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    hostname: "*.example.com"     # only routes under this wildcard attach here
    allowedRoutes:
      namespaces:
        from: Selector             # Same | All | Selector
        selector:
          matchLabels:
            gateway-access: "true"
  - name: https
    port: 443
    protocol: HTTPS
    hostname: shop.example.com
    tls:
      mode: Terminate
      certificateRefs:
      - kind: Secret
        name: shop-tls
    allowedRoutes:
      namespaces:
        from: Same
```

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop-route
  namespace: shop
spec:
  parentRefs:
  - name: main-gw
    namespace: infra          # cross-namespace attach requires the Gateway's allowedRoutes to permit it
    sectionName: http         # attach to one specific listener (optional)
  hostnames:
  - shop.example.com
  rules:
  - matches:                   # elements in ONE match are ANDed; separate matches are ORed
    - path:
        type: PathPrefix       # PathPrefix | Exact | RegularExpression
        value: /api
      method: GET
      headers:
      - name: x-canary
        value: "true"
    filters:
    - type: RequestHeaderModifier
      requestHeaderModifier:
        set:
        - name: x-env
          value: prod
        remove:
        - x-debug
    backendRefs:
    - name: api-v2
      port: 8080
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:               # traffic split: weights are relative, not percentages
    - name: web-v1
      port: 80
      weight: 80
    - name: web-v2
      port: 80
      weight: 20
```

A redirect filter (HTTP→HTTPS is the canonical use):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: https-redirect
  namespace: shop
spec:
  parentRefs:
  - name: main-gw
    namespace: infra
    sectionName: http
  rules:
  - filters:
    - type: RequestRedirect
      requestRedirect:
        scheme: https
        statusCode: 301
```

Mechanics to internalize:

- Attachment is a **handshake**: the route's `parentRefs` must name the Gateway *and* the Gateway's listener `allowedRoutes` must admit the route's namespace, *and* route `hostnames` must intersect the listener `hostname`. Any miss → route status `Accepted: False` (read `k describe httproute`).
- `weight` on backendRefs is the exam's canary primitive: 80/20 above sends ~20% of matching requests to v2. A backendRef to a nonexistent Service flips the rule to 500s, visible in route status `ResolvedRefs: False`.
- Filters you should recognize: `RequestHeaderModifier` (set/add/remove), `RequestRedirect` (scheme/hostname/port/statusCode), `URLRewrite` (path rewrite, the Gateway-native replacement for nginx's rewrite-target annotation).

### Ingress vs Gateway

| | Ingress | Gateway API |
|---|---|---|
| API group | `networking.k8s.io/v1`, in-core | `gateway.networking.k8s.io/v1`, **CRDs** |
| Scope | HTTP/HTTPS only | HTTP, gRPC, TCP/UDP/TLS (extended) |
| Roles | one object, one owner | GatewayClass / Gateway / Route split across teams |
| Traffic split | controller annotations (nonstandard) | `backendRefs.weight`, first-class |
| Header/method match | annotations only | first-class in `matches` |
| Rewrites/redirects | annotations | typed `filters` |
| Cross-namespace | no (per-ns Ingress) | routes attach across namespaces via allowedRoutes |
| TLS | `tls` block on the Ingress | per-listener `tls` on the Gateway |

---

## 7. NetworkPolicy

### The model — memorize these sentences exactly

- Policies are **additive allow-lists**. There is no deny rule and no ordering; the union of everything allowed by any policy is allowed.
- A pod starts **non-isolated** (all traffic allowed). The moment *any* policy **selects** it for a direction, that direction flips to default-deny and only the union of matching rules passes.
- `spec.podSelector` selects pods **in the policy's own namespace only**. `podSelector: {}` = every pod in that namespace — never cluster-wide.
- `policyTypes` declares which directions the policy isolates. **If omitted**, it defaults to `Ingress`, plus `Egress` only when the spec contains an `egress` section. Two precise corollaries: (a) a policy whose `policyTypes` lists only `Ingress` says *nothing* about egress — egress stays unrestricted no matter what, even if you wrote `egress:` rules (they're dead text); (b) `policyTypes: [Ingress, Egress]` with no `egress:` rules = **deny all egress** for selected pods.
- Reply packets are always allowed (connection-tracked). Policies constrain connection *initiation* only.

### Default-deny recipes (keep these in your head, not the docs)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: prod
spec:
  podSelector: {}
  policyTypes:
  - Ingress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: prod
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```

### The OR vs AND trap — one dash decides

```yaml
# OR: from pods labeled role=web (in THIS namespace),
#     or from ANY pod in namespaces labeled team=ops
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-allow-or
  namespace: prod
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
          role: web
    - namespaceSelector:
        matchLabels:
          team: ops
    ports:
    - protocol: TCP
      port: 8080
```

```yaml
# AND: only pods labeled role=web IN namespaces labeled team=ops
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-allow-and
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          team: ops
      podSelector:            # NO dash: same from-element as the namespaceSelector => AND
        matchLabels:
          role: web
    ports:
    - protocol: TCP
      port: 8080
```

Separate `-` elements in a `from`/`to` list = OR. `namespaceSelector` and `podSelector` inside **one** element = AND (pods matching the podSelector inside namespaces matching the namespaceSelector). Also: a bare `podSelector` in `from` matches pods in the **policy's** namespace; to reach across namespaces you *must* involve a `namespaceSelector`.

Selecting a namespace **by name**: every namespace carries the immutable auto-label `kubernetes.io/metadata.name`, so no manual labeling needed:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-frontend-ns
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: frontend
```

### Egress, DNS, ipBlock, port ranges

**Any egress policy must allow DNS or everything by-name dies.** A ports-only rule (no `to`) allows those ports to *all* destinations:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: egress-locked
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
  - Egress
  egress:
  - ports:                     # DNS exception: UDP AND TCP 53 (TCP is used for large/retried answers)
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
  - to:
    - podSelector:
        matchLabels:
          app: db
    ports:
    - protocol: TCP
      port: 5432
  - to:
    - ipBlock:
        cidr: 203.0.113.0/24
        except:
        - 203.0.113.7/32
    ports:
    - protocol: TCP
      port: 443
  - to:
    - podSelector: {}
    ports:
    - protocol: TCP
      port: 30000
      endPort: 32767           # contiguous range; requires port to be numeric, not named
```

`ipBlock` is for cluster-**external** CIDRs; pod IPs may be SNATed before policy evaluation depending on CNI, so never use ipBlock to match pods — use selectors.

### Enforcement is the CNI's job

The API server accepts NetworkPolicies unconditionally; **dropping packets is CNI work**. kind's default CNI (kindnet) does **not** implement NetworkPolicy — your policies validate but nothing is enforced. To practice real semantics:

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
k apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
k -n kube-system wait --for=condition=Ready pod -l k8s-app=calico-node --timeout=300s
```

(Or use the free killercoda CKA playgrounds, which enforce policies.) The exam clusters use enforcing CNIs — write policies as if every byte matters.

---

## 8. CNI: what it is and how it fails

CNI is a spec + plugin binaries the container runtime invokes at pod-sandbox creation/deletion to wire the network namespace: create veth, assign IP (IPAM), install routes. Two filesystem locations to know cold:

| Path | Contents |
|---|---|
| `/etc/cni/net.d/` | plugin configuration (`*.conf`/`*.conflist`; lexicographically first file wins) |
| `/opt/cni/bin/` | plugin binaries (`calico`, `flannel`, `ptp`, `bridge`, `host-local`, `portmap`, `loopback`, ...) |

Installing a CNI is (almost always) applying a manifest that runs a DaemonSet which drops the binary and config onto each node:

```bash
# Calico
k apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
# Flannel
k apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

**Missing/broken CNI symptom set** (a top-tier troubleshooting scenario):

- Nodes stuck `NotReady`; `k describe node` condition reason: `KubeletNotReady ... container runtime network not ready: NetworkReady=false reason:NetworkPluginNotReady message:Network plugin returns error: cni plugin not initialized`.
- New pods stuck `ContainerCreating`; describe shows `FailedCreatePodSandBox`.
- **hostNetwork pods still run** (kube-proxy, the CNI DaemonSet itself) — that asymmetry is the fingerprint.

Diagnosis path: `k describe node` → on the node, `ls /etc/cni/net.d/` (empty? malformed?) and `ls /opt/cni/bin/` → check the CNI DaemonSet pods in `kube-system`. On kind, node access is `docker exec -it cka-worker bash`; on the exam it's `ssh node01` + `sudo -i`.

kind ships **kindnet** (config `/etc/cni/net.d/10-kindnet.conflist`, a `ptp`+`portmap` chain with `host-local` IPAM using each node's podCIDR). Remember from above: kindnet ignores NetworkPolicy.

---

## 9. Traffic paths — the four you debug with

1. **Pod → pod, same node.** veth pair per pod into the root namespace (bridge or point-to-point routes). No NAT, no kube-proxy. If this fails, the CNI is broken.
2. **Pod → pod, cross node.** CNI routing: node-level routes to the peer node's podCIDR (kindnet/Calico non-overlay) or encapsulation (VXLAN in Flannel/Calico overlay). Still no NAT — source pod IP arrives intact.
3. **Pod → Service (ClusterIP).** DNS resolves name → ClusterIP; the **client node's** kube-proxy rules DNAT ClusterIP:port → chosen endpoint podIP:targetPort; then it's path 1 or 2. Return traffic un-DNATs via conntrack. Nobody "hosts" the ClusterIP — tcpdump for it on the wire and you'll find nothing beyond the client node.
4. **External → NodePort.** Client hits `nodeIP:30080`; DNAT to an endpoint. With `externalTrafficPolicy: Cluster` the endpoint may be on another node — traffic is SNATed to the ingress node's IP (client IP lost) and hops. With `Local`, no SNAT, no hop, but endpoint-less nodes drop.

---

## 10. Traps

| Wrong assumption | Correction |
|---|---|
| "`kubectl expose --port=80` is enough; targetPort will figure itself out" | `targetPort` defaults to `port`. App on 8080 exposed with `--port=80` → connection refused. Always pass `--target-port`. |
| "There's a flag to pin the nodePort on `kubectl expose`" | There isn't. Generate YAML (`$do`), add `nodePort: 30080`, apply — or patch afterwards. |
| "Pods are Running, so the Service's endpoints are fine" | Unready pods are pulled from endpoints. Failing readinessProbe = Running pods + empty EndpointSlice. Check the READY column and `describe svc`. |
| "I wrote `egress:` rules, so egress is restricted" | Only if `Egress` is in `policyTypes`. Omitted `policyTypes` includes Egress **only when an egress section exists** — but an explicit `policyTypes: [Ingress]` makes your egress rules dead text. |
| "`- podSelector` and `- namespaceSelector` as separate items = both must match" | Separate `-` items are **OR**. AND requires both selectors in **one** from-element (single dash). |
| "`podSelector: {}` in a NetworkPolicy selects all pods in the cluster" | Namespace-scoped. It selects all pods in the policy's namespace, nothing more. |
| "Default-deny egress is safe; my apps use Services" | Services are resolved by DNS. No UDP+TCP 53 exception → every by-name connection fails. Always add the DNS rule. |
| "nslookup in busybox:latest is trustworthy" | Modern busybox nslookup is broken against cluster DNS (bogus errors). Use `busybox:1.28` or the docs `dnsutils` pod with `dig`. |
| "`pathType: Prefix` is string-prefix matching" | Element-wise per `/` segment: `/foo` matches `/foo/bar` but **not** `/foobar`. `Exact` matches bytes. |
| "I applied the Ingress; routing is live" | No controller (or no matching `ingressClassName`, or no default IngressClass) → the Ingress is inert with no error. `k get ingressclass` first. |
| "Gateway API is built in, apiVersion v1 proves it" | It's CRDs. `k api-resources | grep gateway` empty → install `standard-install.yaml` first. Cross-ns routes also need the listener's `allowedRoutes` to admit them. |
| "My NetworkPolicy didn't drop anything on kind, so it's wrong" | kindnet doesn't enforce NetworkPolicy at all. Validate semantics on Calico-backed kind or killercoda. |
| "`externalTrafficPolicy: Local` broke my NodePort — some nodes time out" | By design: nodes without a local endpoint drop. That's the price of source-IP preservation. |
| "DNS is flaky only for external names — must be the upstream" | Check ndots:5 first: short external names generate up to ~8 search-domain queries. FQDN with trailing dot or `dnsConfig.options.ndots=1`. |
| "TLS secret is any secret with a cert in it" | Ingress TLS requires type `kubernetes.io/tls` with keys `tls.crt`/`tls.key` — `k create secret tls` gets it right. |
| "The headless Service just needs to exist for StatefulSet pod DNS" | Its name must equal the StatefulSet's `spec.serviceName`, or `pod-0.svc...` records never appear. |
| "kube-proxy mode is a DaemonSet flag" | It's in the `kube-proxy` ConfigMap (`mode:` field). Edit the CM, then `rollout restart ds kube-proxy`. |
| "ipBlock can whitelist a pod's IP" | Pod traffic may be SNATed before evaluation; ipBlock is for external CIDRs. Match pods with selectors. |

---

## 11. Speed patterns

```bash
# --- Services ---
k expose deploy web --port=80 --target-port=8080                      # ClusterIP
k expose deploy web --type=NodePort --port=80 --target-port=8080      # NodePort (random port)
k expose deploy web --type=NodePort --port=80 $do > s.yaml            # then set nodePort: 30080, apply
k create service externalname search --external-name=example.com     # ExternalName
k patch svc web -p '{"spec":{"externalTrafficPolicy":"Local"}}'
k get svc web -o jsonpath='{.spec.ports[0].nodePort}{"\n"}'

# --- Instant truth about a Service ---
k describe svc web | grep -iE 'selector|port|endpoints'   # empty Endpoints = selector/readiness bug
k get pods -l app=web -o wide                              # do label & READY agree with the selector?
k get endpointslices -l kubernetes.io/service-name=web

# --- Test clients (memorize both) ---
k run tmp --image=busybox:1.28 --rm -it --restart=Never -- wget -qO- -T 2 http://web.prod:80
k run tmp --image=busybox:1.28 --rm -it --restart=Never -- nslookup web.prod.svc.cluster.local
k apply -f https://k8s.io/examples/admin/dns/dnsutils.yaml && k exec -it dnsutils -- dig +short web.prod.svc.cluster.local

# --- Ingress one-liner ('*' suffix => Prefix, none => Exact) ---
k create ingress shop --class=nginx \
  --rule="shop.example.com/cart*=cart:8080,tls=shop-tls" \
  --rule="shop.example.com/catalog*=catalog:8080,tls=shop-tls" \
  --default-backend=catalog:8080
k create secret tls shop-tls --cert=tls.crt --key=tls.key

# --- CoreDNS ---
k -n kube-system get pods -l k8s-app=kube-dns
k -n kube-system logs -l k8s-app=kube-dns --tail=20
k -n kube-system edit cm coredns && k -n kube-system rollout restart deploy coredns
k -n kube-system scale deploy coredns --replicas=3

# --- NetworkPolicy: no imperative command exists ---
# Fastest legal path: kubernetes.io/docs "Network Policies" page -> copy the full example -> surgery.
# Keep the two default-deny recipes memorized; only the allow rules deserve doc time.

# --- Gateway API ---
k get gatewayclass; k get gateway -A; k describe httproute r -n ns   # status.conditions tell you why it's not Accepted

# --- Node-level (kind: docker exec -it cka-worker bash; exam: ssh node01 && sudo -i) ---
ls /etc/cni/net.d/ && ls /opt/cni/bin/
iptables-save | grep web        # kube-proxy rules mention svc names in comments
```

Triage flow for "service unreachable", in strict order (60–90 seconds total): `describe svc` (endpoints?) → `get pods -l …` (labels? READY?) → `curl POD_IP:PORT` from a pod (app alive?) → ports (`port`/`targetPort`/named port match?) → DNS (`nslookup svc`) → NetworkPolicy in the namespace (`k get netpol`) → kube-proxy/CNI last.

---

## 12. Docs map

| You need | kubernetes.io path |
|---|---|
| Service types, ports, selector-less services | `/docs/concepts/services-networking/service/` |
| Virtual IPs, kube-proxy modes, traffic policies | `/docs/reference/networking/virtual-ips/` |
| EndpointSlices | `/docs/concepts/services-networking/endpoint-slices/` |
| DNS record shapes, dnsPolicy, dnsConfig, ndots | `/docs/concepts/services-networking/dns-pod-service/` |
| DNS debugging walkthrough (dnsutils pod lives here) | `/docs/tasks/administer-cluster/dns-debugging-resolution/` |
| CoreDNS/Corefile customization | `/docs/tasks/administer-cluster/dns-custom-nameservers/` |
| Ingress (pathType table, TLS, defaultBackend) | `/docs/concepts/services-networking/ingress/` |
| Ingress controllers list | `/docs/concepts/services-networking/ingress-controllers/` |
| Gateway API concepts + examples | `/docs/concepts/services-networking/gateway/` |
| NetworkPolicy (copy-paste source for every policy) | `/docs/concepts/services-networking/network-policies/` |
| Declare network policy tutorial | `/docs/tasks/administer-cluster/declare-network-policy/` |
| CNI / network plugins | `/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/` |
| Debug Services (the triage bible) | `/docs/tasks/debug/debug-application/debug-service/` |
| StatefulSet pod identity / stable network IDs | `/docs/concepts/workloads/controllers/statefulset/` |

Habit: open `network-policies` and `dns-pod-service` in Firefox tabs at exam start — they're the two pages you'll copy from under time pressure.

---

## 13. Checkpoint

Time yourself. All on the kind lab unless noted.

- Can you expose a deployment on ClusterIP with `port != targetPort` and prove it serves, in **2 minutes**?
- Can you pin a NodePort to 30080 (generate-edit-apply) and verify from a node, in **4 minutes**?
- Can you diagnose an empty-endpoints Service (selector typo vs readiness vs named-port mismatch) in **4 minutes**?
- Can you write default-deny-ingress + default-deny-all from memory, no docs, in **2 minutes**?
- Can you write "allow frontend→api on TCP 8080, allow api egress to db:5432 + DNS" with docs, in **6 minutes**?
- Can you write the cross-namespace AND policy (ns label + pod label, one from-element) without the dash bug, in **5 minutes**?
- Can you create an Ingress with two Prefix paths, a defaultBackend, and TLS from a secret, in **6 minutes**?
- Can you create a Gateway + HTTPRoute with an 80/20 split and explain each status condition, in **8 minutes**?
- Can you run the full DNS triage ladder (client pod → resolv.conf → kube-dns svc → CoreDNS logs → Corefile) in **6 minutes**?
- Can you list, from memory: CNI config dir, CNI binary dir, the two symptoms of a missing CNI, and the hostNetwork fingerprint, in **1 minute**?
- Can you state precisely what `policyTypes: [Ingress]` plus a written `egress:` section does, in **30 seconds**? (The egress rules do nothing; egress is unrestricted.)
