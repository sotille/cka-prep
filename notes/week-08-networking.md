# Week 8 (Jul 27–Aug 2) — Networking ⭐ 30% OF EXAM

**Goal:** Services, Ingress, NetworkPolicies, CoreDNS, CNI.

**Time budget:** 20h (heavy week)

---

## Topics

- [ ] Services: ClusterIP, NodePort, LoadBalancer, ExternalName, Headless
- [ ] Service selectors and Endpoints
- [ ] Ingress + Ingress Controllers
- [ ] **NetworkPolicies** (ingress + egress rules)
- [ ] CoreDNS architecture and troubleshooting
- [ ] CNI basics (Weave, Calico, Flannel — recognize names only)
- [ ] Pod-to-Pod, Pod-to-Service, External-to-Service paths

## Service Types Cheat Sheet

| Type | Use | DNS |
|---|---|---|
| **ClusterIP** | Internal-only | `svc.ns.svc.cluster.local` |
| **NodePort** | External via port 30000-32767 on every node | same as ClusterIP + node IPs |
| **LoadBalancer** | Cloud LB (or MetalLB) | external IP |
| **Headless** (clusterIP: None) | Direct pod IPs (StatefulSets) | each pod gets DNS entry |
| **ExternalName** | DNS CNAME alias | CNAME to external |

## NetworkPolicy — The Critical Pattern

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
spec:
  podSelector: {}  # all pods in namespace
  policyTypes: [Ingress]
  # No `ingress:` block → all ingress denied
```

```yaml
# Allow only from same namespace, with label
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          role: frontend
    ports:
    - protocol: TCP
      port: 8080
```

## CoreDNS Troubleshooting

```bash
# Exec into pod, test DNS
k run testpod --image=busybox:1.28 --rm -it -- sh
# inside:
nslookup kubernetes.default
nslookup my-svc.my-ns
cat /etc/resolv.conf
```

## Hands-On Labs

- [ ] Deploy 3-tier app (web + api + db) with services
- [ ] Add NetworkPolicy: only frontend can talk to api
- [ ] Set up Ingress with multiple paths
- [ ] Break CoreDNS, debug it
- [ ] Test ClusterIP vs NodePort vs Headless DNS behavior

## Week 8 Checkpoint

- [ ] Create "deny all + allow only X" NetworkPolicy in 5 min
- [ ] Troubleshoot "service exists but can't reach it" in 5 min
- [ ] Set up Ingress with path-based routing in 5 min

## Insights

<!-- Add as you go — networking is where most fail. Document every gotcha. -->
