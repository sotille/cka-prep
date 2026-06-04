# Week 6 (Jul 13–19) — Security + RBAC

**Goal:** RBAC, ServiceAccounts, TLS certificates, kubeconfig.

**Time budget:** 16h

---

## Topics

- [ ] Authentication vs Authorization vs Admission
- [ ] TLS basics in Kubernetes (CA, certs in /etc/kubernetes/pki)
- [ ] Kubeconfig structure (clusters, users, contexts)
- [ ] ServiceAccounts (default, custom, token mounting)
- [ ] Roles + RoleBindings (namespace-scoped)
- [ ] ClusterRoles + ClusterRoleBindings (cluster-scoped)
- [ ] Certificate Signing Requests (CSR) workflow
- [ ] Network Policies (basics — deeper in Week 8)

## RBAC Mental Model

```
Subject (User/Group/SA) ──[Binding]──> Role ──> Verbs on Resources
```

- **Role** = WHAT (verbs on resources, in a namespace)
- **RoleBinding** = WHO gets WHAT
- **ClusterRole** = WHAT (verbs on resources, cluster-wide OR for non-namespaced resources)

## Speed Patterns

```bash
# Create role
k create role pod-reader --verb=get,list,watch --resource=pods $do > role.yaml

# Bind to user
k create rolebinding read-pods --role=pod-reader --user=jane -n dev $do

# Bind to ServiceAccount
k create rolebinding read-pods --role=pod-reader --serviceaccount=dev:my-sa $do

# Test permissions (auth check)
k auth can-i get pods --as=jane -n dev
k auth can-i get pods --as=system:serviceaccount:dev:my-sa
```

## CSR Workflow

```bash
# Generate key + CSR
openssl genrsa -out jane.key 2048
openssl req -new -key jane.key -out jane.csr -subj "/CN=jane/O=dev"

# Create K8s CSR object (base64 the .csr file)
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: jane
spec:
  request: $(cat jane.csr | base64 | tr -d '\n')
  signerName: kubernetes.io/kube-apiserver-client
  usages: [client auth]
EOF

# Approve
kubectl certificate approve jane

# Extract signed cert
kubectl get csr jane -o jsonpath='{.status.certificate}' | base64 -d > jane.crt
```

## Hands-On Labs

- [ ] Create user via CSR + bind to namespace-limited Role
- [ ] Create ServiceAccount + bind to ClusterRole (read-only)
- [ ] Test with `kubectl auth can-i`
- [ ] Inspect default ServiceAccount token mount

## Week 6 Checkpoint

- [ ] Create RBAC for "user X read pods only in namespace Y" in < 4 min
- [ ] Verify it works with `kubectl auth can-i`

## Insights

<!-- Add as you go -->
