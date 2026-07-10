# Week 06 — Security & RBAC Masterclass (Cluster Architecture 25%, feeds Troubleshooting 30%)

RBAC is the single most predictable scoring opportunity on the CKA. Almost every sitting includes at least one "create a Role/ClusterRole and bind it" task and one "user X gets Forbidden, fix it" task, and both are fully verifiable in-exam with `kubectl auth can-i` — you can *know* you scored the points before moving on. This module covers the API server's authn → authz → admission pipeline, RBAC internals, the CSR-based user onboarding flow, ServiceAccounts, SecurityContext, and Pod Security Admission. NetworkPolicy is deliberately deferred to week 08 (Services & Networking), where it belongs on the current curriculum.

One version caveat up front: everything here targets the post-Feb-2025 curriculum. Check the live competency list at the CNCF curriculum page before exam day.

---

## What the exam actually asks

| Topic | Domain | Weight contribution | Typical task |
|---|---|---|---|
| Role/ClusterRole + bindings | Cluster Architecture, Installation & Configuration | 25% domain — RBAC is its most-tested slice | "Create a ClusterRole `deployment-clusterrole` that only allows create on Deployments…" |
| ServiceAccounts | Cluster Architecture | same domain | "Create SA, bind it, use it in a pod" |
| CSR / new user onboarding | Cluster Architecture | same domain | "Issue a certificate for user `carlos` and give him access to…" |
| Forbidden / permission debugging | Troubleshooting | 30% domain | "The `dev` user cannot list pods in `web`. Fix without granting more than needed." |
| SecurityContext | Workloads & Scheduling | 15% domain | "Run the container as UID 1000 with NET_ADMIN, no privilege escalation" |
| Pod Security Admission | Workloads & Scheduling / Cluster Architecture | crosses both | "Label the namespace `restricted` and make the failing pod schedulable" |
| kubeconfig surgery | Cluster Architecture + exam survival | every question | context switching, new credentials, new contexts |

Realistic expectation: 2–4 tasks (8–12% of total points) directly on this module's content, plus RBAC knowledge silently required by Helm/operator/troubleshooting tasks.

---

## The request path: every API call runs the same gauntlet

Every request to the kube-apiserver — from kubectl, a kubelet, a controller, or curl — passes three gates in order:

```text
request ──> [1. Authentication] ──> [2. Authorization] ──> [3. Admission control] ──> etcd
             who are you?            may you do this?        mutate + validate object
             (401 if no)             (403 if no)             (4xx with reason if no)
```

Error codes are diagnostic gold: **401 Unauthorized = authentication failed** (bad/expired cert, bad token). **403 Forbidden = authenticated fine, RBAC said no.** A PSA rejection or admission webhook denial arrives as a 4xx with an explicit message naming the admission plugin. When troubleshooting access, first decide which gate rejected you — the fix is completely different for each.

### Gate 1 — Authentication: the chain

The API server runs a chain of authenticator modules; the first one that positively identifies the request wins. Configured by kube-apiserver flags (visible in `/etc/kubernetes/manifests/kube-apiserver.yaml` on kubeadm clusters):

| Authenticator | Flag | Identity produced |
|---|---|---|
| X.509 client certs | `--client-ca-file=/etc/kubernetes/pki/ca.crt` | username = cert **CN**, groups = cert **O** fields (one O per group) |
| ServiceAccount tokens (JWT) | `--service-account-key-file`, `--service-account-signing-key-file` (keys `sa.pub`/`sa.key`) | `system:serviceaccount:<ns>:<name>`, groups `system:serviceaccounts`, `system:serviceaccounts:<ns>` |
| Bootstrap tokens | `--enable-bootstrap-token-auth` | used by `kubeadm join`, group `system:bootstrappers` |
| Static token file | `--token-auth-file` | legacy, avoid; requires apiserver restart to change |
| OIDC | `--oidc-issuer-url`, `--oidc-client-id`, … | username/groups from JWT claims. **Awareness only on CKA** — you will not configure an IdP |
| Webhook token auth / auth proxy | `--authentication-token-webhook-config-file` | external — awareness only |

Facts that decide exam questions:

- **Kubernetes has no User API object.** `kubectl get users` does not exist. A "user" is just a string an authenticator asserts. Creating a user = issuing a credential that authenticates as that string (in practice: a client cert via the CSR API).
- **Groups are also just strings** asserted at authentication time (cert O fields, JWT claims). There is no API to list a group's members. To grant a group access, you simply reference the group name in a binding — membership is decided by whatever the certificate says.
- **`system:masters` is a hardcoded superuser group** in the API server — it bypasses authorization entirely, no RBAC binding needed, and cannot be revoked except by reissuing/rotating certs. This is why `kubernetes-admin` (kubeadm's admin kubeconfig, O=kubernetes-admin in modern kubeadm; historically O=system:masters) is dangerous to imitate. Never sign user certs with O=system:masters.
- Requests that authenticate with nothing become `system:anonymous` / group `system:unauthenticated` (anonymous auth is on by default, but RBAC grants it almost nothing).

### Gate 2 — Authorization: `--authorization-mode`

```bash
# on a kubeadm control plane node (exam):
grep authorization-mode /etc/kubernetes/manifests/kube-apiserver.yaml
# on the kind lab:
docker exec cka-control-plane grep authorization-mode /etc/kubernetes/manifests/kube-apiserver.yaml
```

Typical value: `--authorization-mode=Node,RBAC`. Modes are evaluated **in order**; each can allow, deny, or abstain ("no opinion"), and the first allow/deny wins.

| Mode | What it does |
|---|---|
| `Node` | Special-purpose authorizer for kubelets (user `system:node:<name>`, group `system:nodes`). Grants each kubelet access only to resources related to pods scheduled on it. Works in tandem with the `NodeRestriction` admission plugin. |
| `RBAC` | Role-based access control via API objects — the mode you manipulate on the exam. |
| `Webhook` | Delegates the decision to an external HTTP service (SubjectAccessReview). Awareness only. |
| `ABAC` | Legacy JSON policy file, requires apiserver restart per change. Awareness only — know it exists and that RBAC replaced it. |
| `AlwaysAllow` / `AlwaysDeny` | Testing modes. `AlwaysAllow` disables authorization. |

Version note: since v1.29+ clusters can use a structured `--authorization-config` file instead of the flag; kubeadm clusters on the exam still use the flag form.

### Gate 3 — Admission control

After authz, admission plugins **mutate** (defaulting, injection) then **validate** (reject) the object. Enabled via `--enable-admission-plugins` on the apiserver (many are on by default; the flag adds to defaults).

What CKA expects: awareness of the flag, plus two plugins by name:

- **`NodeRestriction`** — limits kubelets to modifying only their own Node object and pods bound to them, and blocks kubelets from setting arbitrary labels (protects `node-restriction.kubernetes.io/*` labels). Enabled by default on kubeadm (`--enable-admission-plugins=NodeRestriction`). Pairs with the `Node` authorizer.
- **`PodSecurity`** — the Pod Security Admission controller (see PSA section). Built-in and enabled by default since v1.25.

```bash
docker exec cka-control-plane grep enable-admission-plugins /etc/kubernetes/manifests/kube-apiserver.yaml
```

---

## TLS and PKI: where the certs live

kubeadm puts the cluster PKI in `/etc/kubernetes/pki` on control plane nodes:

| File | Role |
|---|---|
| `ca.crt` / `ca.key` | Cluster CA — signs apiserver serving cert, kubelet client certs, and CSR-API-issued user certs |
| `apiserver.crt` / `apiserver.key` | API server's serving certificate (SANs include service IP, `kubernetes.default`, node names) |
| `apiserver-kubelet-client.*` | apiserver's client cert for talking *to* kubelets |
| `front-proxy-ca.*`, `front-proxy-client.*` | aggregation layer (extension API servers) |
| `etcd/ca.crt`, `etcd/server.*`, `etcd/peer.*` | etcd's own CA and certs (used in etcd backup tasks — week on cluster maintenance) |
| `sa.key` / `sa.pub` | **Not certs** — RSA keypair that signs/verifies ServiceAccount JWTs |

Inspection and expiry — memorize both:

```bash
# decode any cert: who is it, which groups, when does it expire
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A2 Validity
openssl x509 -in carlos.crt -noout -subject   # subject=CN = carlos, O = developers

# kubeadm's built-in expiry report (real exam; on kind prefix with docker exec cka-control-plane)
kubeadm certs check-expiration
kubeadm certs renew all        # renews everything signed by the cluster CA
```

Exam-flavor note: on the real exam you SSH to the control plane node and use `sudo`; on the kind lab the "node" is a container — `docker exec -it cka-control-plane bash`.

## kubeconfig anatomy

A kubeconfig is three lists plus a pointer:

```yaml
apiVersion: v1
kind: Config
clusters:
- name: kind-cka
  cluster:
    server: https://127.0.0.1:6443
    certificate-authority-data: LS0tLS1CRUdJTg== # base64 CA bundle (truncated example)
users:
- name: kind-cka
  user:
    client-certificate-data: LS0tLS1CRUdJTg== # base64 client cert (or token / exec plugin)
    client-key-data: LS0tLS1CRUdJTg==
contexts:
- name: kind-cka
  context:
    cluster: kind-cka
    user: kind-cka
    namespace: default
current-context: kind-cka
```

A **context = (cluster, user, optional namespace)**. All manipulation is `kubectl config` — never hand-edit on the exam:

```bash
k config get-contexts                 # list; * marks current
k config current-context
k config use-context kind-cka
k config set-credentials carlos --client-certificate=carlos.crt --client-key=carlos.key --embed-certs=true
k config set-context carlos --cluster=kind-cka --user=carlos --namespace=dev-team
k config view --minify                # only the current context's effective config
k config view --minify -o jsonpath='{.clusters[0].cluster.server}'
```

`--embed-certs=true` inlines the files as base64 so the kubeconfig is portable; without it, the config stores file paths.

---

## RBAC deep dive

### The model

```text
Subject (User | Group | ServiceAccount) ──[RoleBinding/ClusterRoleBinding]──> Role/ClusterRole ──> rules (verbs × apiGroups × resources)
```

RBAC is **purely additive**. There is no deny rule. A subject's effective permission is the union of every rule in every role reachable through every binding. "Remove access" always means deleting/narrowing a binding or role, never adding a deny.

Four object kinds, all `rbac.authorization.k8s.io/v1`:

| Kind | Scope | Holds |
|---|---|---|
| `Role` | namespaced | rules over **namespaced** resources in its own namespace |
| `ClusterRole` | cluster-scoped | rules over anything: namespaced resources, cluster-scoped resources (nodes, namespaces, PVs, CRDs), and `nonResourceURLs` |
| `RoleBinding` | namespaced | subjects ↔ one roleRef; grants apply **only in the binding's namespace** |
| `ClusterRoleBinding` | cluster-scoped | subjects ↔ one ClusterRole; grants apply everywhere |

### The binding matrix — internalize all four combinations

| # | roleRef | Binding | Result |
|---|---|---|---|
| 1 | Role | RoleBinding (ns X) | Subjects get the Role's rules **in namespace X only**. The bread-and-butter grant. |
| 2 | ClusterRole | RoleBinding (ns X) | Subjects get the ClusterRole's rules **restricted to namespace X**. Rules about cluster-scoped resources inside that ClusterRole are inert through this binding. This is how you define a permission set **once** and hand it out per-namespace — the built-in `view`/`edit`/`admin` roles are designed for exactly this. |
| 3 | ClusterRole | ClusterRoleBinding | Subjects get the rules **cluster-wide**: all namespaces, cluster-scoped resources, nonResourceURLs. The only way to grant access to nodes, PVs, namespaces themselves. |
| 4 | Role | ClusterRoleBinding | **Invalid.** A ClusterRoleBinding's roleRef must be a ClusterRole; the API rejects it. |

Combination 2 is the most-missed on exams: "give the SA read access to namespace staging using the built-in view role" is one `kubectl create rolebinding --clusterrole=view` — no new role needed.

**`roleRef` is immutable.** You can edit a binding's `subjects` freely, but changing what it points to requires delete + recreate (`kubectl replace --force` works too). Rules inside Roles/ClusterRoles are freely mutable.

### Verbs

| Verb | Maps to |
|---|---|
| `get` | GET single object |
| `list` | GET collection — **returns full objects**, so `list` without `get` still exposes everything via `kubectl get pods -o yaml` |
| `watch` | long-poll stream of changes |
| `create` | POST |
| `update` | PUT (full replace) |
| `patch` | PATCH (also what `kubectl edit`, `apply`, `scale` use under the hood) |
| `delete` | DELETE single object |
| `deletecollection` | DELETE collection |
| `impersonate` | act as another user/group/SA — what powers `--as` |
| `bind`, `escalate` | create bindings to / modify roles with permissions you don't yourself hold (escalation-prevention escape hatches) |
| `*` | everything |

Escalation prevention: RBAC only lets you create/update a role containing permissions **you already hold** (or you hold `escalate`), and only lets you bind roles you could yourself use (or you hold `bind`). This is why a namespace `admin` can't mint themselves cluster-admin.

### apiGroups — the #1 silent point-loser

The `apiGroups` field takes the group **without version**. The core group is the **empty string**, not "core", not "v1":

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: dev
rules:
- apiGroups: [""]              # core: pods, services, configmaps, secrets, nodes, pvcs...
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]          # deployments, statefulsets, daemonsets, replicasets
  resources: ["deployments"]
  verbs: ["get", "list"]
```

A Role granting `deployments` under `apiGroups: [""]` is syntactically valid, applies cleanly, and grants **nothing** — the classic broken-RBAC troubleshooting scenario. When unsure which group a resource lives in: `k api-resources | grep -i <name>` (APIVERSION column; group is the part before `/`).

### resourceNames — object-level narrowing

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: app-config-editor
  namespace: dev
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["app-config"]
  verbs: ["get", "update", "patch"]
```

Constraints that show up as traps:

- Works for `get`, `update`, `patch`, `delete` — requests that target a named object.
- **Cannot restrict `create`** (the name isn't known at authorization time) or `deletecollection`.
- **Does not grant `list`/`watch`** — those are collection-level requests, authorized without a name. A name-scoped rule with `verbs: ["list"]` is effectively dead.
- No wildcards in names.

### Subresources — `pods/log`, `pods/exec`, and friends

Subresources are authorized separately from their parent. Granting `pods` does not grant `pods/log`.

| Subresource | Verb kubectl needs | Used by |
|---|---|---|
| `pods/log` | `get` | `kubectl logs` |
| `pods/exec` | `create` | `kubectl exec` (POST) |
| `pods/attach` | `create` | `kubectl attach` |
| `pods/portforward` | `create` | `kubectl port-forward` |
| `deployments/scale` | `patch`/`update` | `kubectl scale` |
| `pods/status`, `*/status` | `patch`/`update` | controllers writing status |

Trap inside the trap: `kubectl logs` first does a `get` on the **pod** (to resolve containers), *then* reads `pods/log`. A role with only `pods/log` makes raw API calls work but `kubectl logs` fail. Grant both:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: log-reader
  namespace: audit
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get"]
```

Imperative form handles subresources natively: `k create role log-reader --verb=get --resource=pods,pods/log`.

### nonResourceURLs — ClusterRole only

Endpoints that aren't objects (`/healthz`, `/livez`, `/readyz`, `/metrics`, `/version`, `/api`). Only meaningful in a ClusterRole bound by ClusterRoleBinding:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: healthz-reader
rules:
- nonResourceURLs: ["/healthz", "/healthz/*"]
  verbs: ["get"]
```

### Aggregated ClusterRoles

A ClusterRole can declare an `aggregationRule` instead of authoring rules; a controller in kube-controller-manager continuously unions in the rules of every ClusterRole matching the label selector:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: monitoring
aggregationRule:
  clusterRoleSelectors:
  - matchLabels:
      rbac.example.com/aggregate-to-monitoring: "true"
rules: []   # controller-managed; anything you write here is overwritten
```

The built-ins use this: `admin`, `edit`, and `view` aggregate any ClusterRole labeled `rbac.authorization.k8s.io/aggregate-to-admin|edit|view: "true"`. Practical consequence: to extend what `view` can see (e.g., after installing a CRD), you don't edit `view` — you create a new labeled ClusterRole and the controller merges it within seconds. Operators ship such roles routinely; recognizing the label answers "why can view suddenly see this CRD".

### Default ClusterRoles worth knowing cold

| Name | Intent |
|---|---|
| `cluster-admin` | everything, everywhere (`*` on `*.*` plus nonResourceURLs). Bound to group `system:masters` by the `cluster-admin` ClusterRoleBinding |
| `admin` | full control within a namespace (via RoleBinding), including roles/rolebindings; not resource quotas or the namespace itself |
| `edit` | read/write most namespaced objects, **no** roles/bindings, can read secrets |
| `view` | read-only namespaced objects, **cannot read secrets** |
| `system:node`, `system:kube-scheduler`, ... | component roles — leave them alone |

---

## The verification loop: `kubectl auth can-i`

Never submit an RBAC task without closing the loop. Grant → verify takes ten seconds and converts "probably right" into points:

```bash
k auth can-i get pods -n dev --as jane                                  # user
k auth can-i list nodes --as anyuser --as-group ops-team                # group (--as still required)
k auth can-i create deployments -n web --as system:serviceaccount:web:ci-bot   # SA
k auth can-i get pods --subresource=log -n audit --as system:serviceaccount:audit:log-bot
k auth can-i --list -n ops --as system:serviceaccount:ops:runner        # full permission dump
k auth can-i delete nodes --all-namespaces --as jane
k auth whoami                                                           # who am I actually (v1.28+)
```

Mechanics you must understand, not just memorize:

- `can-i` issues a real `SelfSubjectAccessReview` (or with `--as`, an impersonated one) — the answer comes from the actual authorizer chain, so it is authoritative.
- Impersonation (`--as`, `--as-group`) requires the `impersonate` verb — as cluster-admin on the lab and exam you have it.
- **`--as jane` does not infer jane's groups.** Group membership lives in the certificate; impersonation only asserts what you pass. If access was granted to group `developers`, then `can-i --as jane` says **no** while the real jane (cert with O=developers) succeeds. Test group grants with `--as jane --as-group developers`.
- RBAC changes are live immediately — authorization is evaluated per-request against etcd-backed objects. No pod restart, no token refresh needed for permission changes.

---

## New user onboarding: the full CSR flow

Kubernetes never stores users, but its CSR API turns the cluster CA into a certificate vending machine. This is THE canonical exam task for "create user X with access to Y". The kubernetes.io CSR docs page ("Certificate Signing Requests → Normal user") contains this flow nearly copy-paste ready — know where it is, but be able to type it blind.

**Step 1 — key + CSR (openssl, client side):**

```bash
openssl genrsa -out carlos.key 2048
openssl req -new -key carlos.key -subj "/CN=carlos/O=developers" -out carlos.csr
```

CN becomes the username; each O becomes a group. Choose them to match the bindings you'll create.

**Step 2 — CSR object (base64 the PEM, one line):**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: carlos
spec:
  request: $(cat carlos.csr | base64 | tr -d "\n")
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages:
  - client auth
EOF
```

- `signerName: kubernetes.io/kube-apiserver-client` = "sign with the cluster CA for client authentication". Other built-in signers (`kubelet-serving`, `kube-apiserver-client-kubelet`) exist for node certs — using the wrong one stalls or mis-issues.
- `usages` must be `client auth` for a user cert.
- `expirationSeconds` (min 600) requests a lifetime; the signer may cap it (controller-manager `--cluster-signing-duration`). Honored since v1.22.
- `tr -d "\n"` matters: GNU `base64` wraps at 76 chars and a wrapped value breaks the field (alternative: `base64 -w0` on Linux).

**Step 3 — approve and harvest:**

```bash
k get csr                          # carlos: Pending
k certificate approve carlos       # (deny exists too: k certificate deny carlos)
k get csr carlos -o jsonpath='{.status.certificate}' | base64 -d > carlos.crt
openssl x509 -in carlos.crt -noout -subject -enddate    # sanity: CN, O, expiry
```

Approval only flips a condition; the actual signing is done by kube-controller-manager (it holds `ca.key`). If a CSR sits Approved with an empty `.status.certificate`, suspect the controller-manager or a wrong signerName.

**Step 4 — kubeconfig:**

```bash
k config set-credentials carlos --client-certificate=carlos.crt --client-key=carlos.key --embed-certs=true
k config set-context carlos --cluster=kind-cka --user=carlos --namespace=dev-team
```

**Step 5 — authorize (nothing works until RBAC exists):**

```bash
k -n dev-team create role dev-edit --verb=get,list,watch,create,update,patch,delete --resource=pods,deployments,services
k -n dev-team create rolebinding dev-edit-b --role=dev-edit --group=developers   # or --user=carlos
```

**Step 6 — verify like the exam grader would:**

```bash
k auth can-i create pods -n dev-team --as carlos --as-group developers   # yes
kubectl --context carlos -n dev-team get pods                            # real cert path
kubectl --context carlos get pods -n default                             # Forbidden — scoping proven
```

---

## ServiceAccounts

SAs are the machine identity: namespaced API objects, authenticating as `system:serviceaccount:<ns>:<name>`. Every namespace gets a `default` SA; every pod runs as one (the `default` SA unless `spec.serviceAccountName` says otherwise). `serviceAccountName` is immutable on a running pod — changing it means recreating the pod.

```bash
k create serviceaccount ci-bot -n web
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: runner
  namespace: web
spec:
  serviceAccountName: ci-bot
  containers:
  - name: main
    image: busybox:1.36
    command: ["sleep", "3600"]
```

### Tokens: modern (TokenRequest) vs legacy (Secret)

This changed hard in v1.24 and older material lies to you:

| | Modern (v1.24+) | Legacy (pre-1.24 behavior) |
|---|---|---|
| Pod token | **projected volume** at `/var/run/secrets/kubernetes.io/serviceaccount/` (`token`, `ca.crt`, `namespace`), issued via TokenRequest API | mounted from an auto-created Secret |
| Lifetime | ~1h, auto-rotated by kubelet, **bound to the pod** (invalid after pod deletion) | non-expiring |
| Ad-hoc token | `kubectl create token <sa> [--duration=1h] [-n ns]` → prints JWT to stdout, stored nowhere | read from the SA's Secret |
| Auto-created Secret per SA | **No** | Yes |

If a task genuinely needs a long-lived token (rare, discouraged), create the legacy Secret explicitly and the token controller populates it:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ci-bot-token
  namespace: web
  annotations:
    kubernetes.io/service-account.name: ci-bot
type: kubernetes.io/service-account-token
```

### Turning the token mount off

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: quiet-sa
automountServiceAccountToken: false
```

Also settable per-pod at `spec.automountServiceAccountToken`; **the pod field wins** when both are set. Hardening default for workloads that never call the API.

### Image pull secrets on the SA

Attach a registry credential to the SA and every pod using that SA inherits it — no per-pod `imagePullSecrets`:

```bash
k create secret docker-registry regcred --docker-server=registry.example.com \
  --docker-username=felipe --docker-password=s3cret
k patch serviceaccount default -p '{"imagePullSecrets":[{"name":"regcred"}]}'
```

### Using the token from inside a pod

The mounted trio is everything curl needs:

```bash
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/api/v1/namespaces/default/pods
```

`kubernetes.default.svc` resolves to the apiserver's ClusterIP Service in every cluster. A 403 here means the SA lacks RBAC — the identity worked.

---

## SecurityContext

Two levels; know the split and the precedence:

| Field | Pod level (`spec.securityContext`) | Container level (`spec.containers[].securityContext`) | Notes |
|---|---|---|---|
| `runAsUser` / `runAsGroup` | yes | yes | container **overrides** pod |
| `runAsNonRoot` | yes | yes | kubelet-enforced check at start |
| `fsGroup` | **yes only** | — | supplemental GID applied to mounted volumes' files |
| `capabilities` | — | **yes only** | `add:` / `drop:`, names without the `CAP_` prefix |
| `privileged` | — | yes only | full host device access — everything short of being the host |
| `allowPrivilegeEscalation` | — | yes only | sets `no_new_privs`; `privileged: true` or `CAP_SYS_ADMIN` implies it true |
| `readOnlyRootFilesystem` | — | yes only | mount writable `emptyDir` where the app must write |
| `seccompProfile` | yes | yes | `type: RuntimeDefault` for the runtime's default filter |

Everything in one annotated pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ctx-demo
spec:
  securityContext:            # pod level: applies to all containers unless overridden
    runAsUser: 1000
    runAsGroup: 3000
    fsGroup: 2000             # files in volumes get group 2000
    seccompProfile:
      type: RuntimeDefault
  volumes:
  - name: scratch
    emptyDir: {}
  containers:
  - name: main
    image: busybox:1.36
    command: ["sleep", "3600"]
    volumeMounts:
    - name: scratch
      mountPath: /scratch
    securityContext:          # container level: wins on conflict
      runAsUser: 2000         # this container runs as 2000, not 1000
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
        add: ["NET_BIND_SERVICE"]
```

Behavioral facts:

- `runAsNonRoot: true` without `runAsUser`, on an image whose USER is root (or numeric-unknown): kubelet refuses to start the container — `CreateContainerConfigError`, message "container has runAsNonRoot and image will run as root". Fix by setting a numeric `runAsUser` or using a non-root image.
- Verification is `k exec <pod> -- id` (uid/gid/groups) and `k exec <pod> -- cat /proc/1/status | grep Cap` (capability bitmaps).
- Added capabilities are meaningful mostly for root-ish processes; a non-root UID with `add: ["NET_ADMIN"]` does not get effective NET_ADMIN without file capabilities — don't combine blindly.
- `fsGroup` shows up as group ownership on volume mounts and in the process's supplementary groups.

---

## Pod Security Admission (PSA)

PodSecurityPolicy was **removed in v1.25**; PSA is its in-tree replacement — a namespace-label-driven admission controller (`PodSecurity`, on by default). No objects to create; you label namespaces.

### Labels

```bash
k label ns secure-apps \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted --overwrite
```

Three **modes** × three **levels**:

| Mode | Effect |
|---|---|
| `enforce` | non-compliant **Pods are rejected** at creation |
| `warn` | creation succeeds, client gets a warning header (you see it in kubectl output) |
| `audit` | creation succeeds, violation recorded in the audit log |

| Level | Meaning |
|---|---|
| `privileged` | anything goes (default when unlabeled) |
| `baseline` | blocks known privilege escalations: `privileged: true`, host namespaces (`hostNetwork`/`hostPID`/`hostIPC`), `hostPath` volumes, most `hostPorts`, capabilities beyond a safe default list, unsafe sysctls, explicitly `Unconfined` seccomp |
| `restricted` | baseline **plus requirements**: `runAsNonRoot: true`; `seccompProfile.type: RuntimeDefault` (or Localhost); `capabilities.drop: ["ALL"]` (only `NET_BIND_SERVICE` may be added back); `allowPrivilegeEscalation: false`; volumes limited to configMap/secret/emptyDir/projected/downwardAPI/csi/ephemeral/PVC |

The optional `-version` suffix labels (`enforce-version` etc.) pin the policy definition to a Kubernetes minor version (`latest` if unset) — matters when upgrading clusters, one-line awareness for the exam.

### The memorized compliance block

Making an arbitrary pod `restricted`-compliant is a formula. Burn this into muscle memory:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: compliant
  namespace: secure-apps
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000            # needed if the image's USER is root
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: main
    image: busybox:1.36
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
```

### PSA's nastiest behavior: silent Deployment failure

`enforce` gates **Pod objects only**. A non-compliant Deployment applies without error; the ReplicaSet then fails to create pods. `kubectl get deploy` shows `0/3` with no events on the Deployment itself. The evidence lives on the **ReplicaSet**:

```bash
k -n secure-apps describe rs -l app=web | grep -A5 Events
# Warning  FailedCreate ... violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false, ...
```

The rejection message enumerates every violation — it is a literal to-do list for the fix.

---

## Where CKA stops and CKS begins

CKA covers RBAC, ServiceAccounts, cert issuance, SecurityContext, and PSA labels; CKS takes over at runtime security (Falco), AppArmor/seccomp profile authoring, image scanning and supply chain, secrets encryption at rest, audit policy, and network policy hardening — don't burn CKA prep hours there.

---

## Traps

1. **`apiGroups: ["core"]` or `["v1"]`.** Wrong. Core is the empty string `""`. And Deployments are NOT core — `apps`. A role with the wrong group applies cleanly and grants nothing. When a "valid-looking" role doesn't work, check the group first.
2. **Editing `roleRef`.** Immutable — the apiserver rejects the update. Delete and recreate the binding (`k delete rolebinding X` + recreate, or `k replace --force -f`). `subjects` on the other hand ARE mutable — don't recreate a binding just to fix a subject.
3. **`--serviceaccount=name` in `kubectl create rolebinding`.** The format is `namespace:name` (`--serviceaccount=web:ci-bot`). Omitting the namespace errors out; writing the wrong one silently grants a different SA.
4. **RoleBinding subject `namespace` field for SAs.** A subject `kind: ServiceAccount` requires `namespace:` — and it is the namespace **the SA lives in**, not where the binding is. Pointing it at the wrong namespace is a classic planted bug.
5. **`can-i --as jane` returning `no` for a group-based grant.** Impersonation asserts only what you pass. Add `--as-group developers`. Conversely: verifying an SA is `--as system:serviceaccount:ns:name`, never `--as-group`.
6. **CSR base64 wrapping.** GNU `base64` wraps at 76 columns; a wrapped `spec.request` is rejected or corrupts. Always `| tr -d "\n"` (or `base64 -w0`).
7. **CSR stuck Pending / Approved-but-no-cert.** Pending = you forgot `kubectl certificate approve`. Approved with empty `.status.certificate` = wrong `signerName` or controller-manager not signing. Also: `expirationSeconds` below 600 is rejected at create.
8. **Expecting `kubectl get users`.** No such resource. Users/groups exist only inside credentials. To find "what can jane do", it's `k auth can-i --list --as jane`; to find "what grants mention jane", grep the bindings: `k get rolebindings,clusterrolebindings -A -o wide | grep jane`.
9. **`resourceNames` with `list`/`create`.** Name-scoping cannot gate `create` (no name yet) and does not grant `list`/`watch` (collection-scope). A name-restricted role granting only `list` is a no-op.
10. **`pods/log` without `pods`.** `kubectl logs` first `get`s the pod, then the log subresource. Grant both or kubectl fails while raw curl works — maximally confusing under time pressure.
11. **ClusterRole + RoleBinding ≠ cluster-wide.** The grant is clamped to the binding's namespace, and any cluster-scoped rules (nodes, PVs) in the ClusterRole are inert through it. Nodes access requires a ClusterRoleBinding, full stop.
12. **PSA rejects pods, not workloads.** Deployment applies fine, `0/3` ready, nothing in `kubectl get events` for the Deployment. Look at the **ReplicaSet's** events. Also: PSA judges pods at **create** — labeling a namespace `enforce=restricted` does not evict existing non-compliant pods.
13. **`runAsNonRoot: true` without a numeric UID** on a root image → `CreateContainerConfigError`. The kubelet can't prove non-rootness. Set `runAsUser: 1000`.
14. **Putting `capabilities`/`allowPrivilegeEscalation` at pod level or `fsGroup` at container level.** Schema validation rejects it. fsGroup = pod-only; capabilities/privileged/allowPrivilegeEscalation/readOnlyRootFilesystem = container-only.
15. **Restarting pods after RBAC changes.** Unnecessary — authorization is evaluated per request. But changing a pod's `serviceAccountName` DOES require pod recreation (immutable field). Know which is which.
16. **`kubectl --token=...` while your kubeconfig has client certs.** The TLS client cert authenticates at the handshake before the bearer token is considered — you're still admin and your "test" proves nothing. Test SA tokens with `can-i --as` or from a clean context/curl.
17. **Signing user certs with O=system:masters.** Instant unrevokable superuser — and on the exam, a likely zero for granting excessive permissions.
18. **Wrong context.** Every exam question header tells you which context to use. RBAC created on the wrong cluster is a silent zero. `k config use-context` first, always.

---

## Speed patterns

**Imperative for everything RBAC.** Never hand-write RBAC YAML unless the task demands a file:

```bash
k create role pod-reader --verb=get,list,watch --resource=pods -n dev
k create role log-reader --verb=get --resource=pods,pods/log -n audit          # subresource inline
k create clusterrole node-inspector --verb=get,list,watch --resource=nodes
k create rolebinding rb1 --role=pod-reader --user=jane -n dev
k create rolebinding rb2 --clusterrole=view --serviceaccount=staging:app-viewer -n staging
k create clusterrolebinding crb1 --clusterrole=node-inspector --group=ops-team
k create serviceaccount ci-bot -n web
k create token ci-bot -n web --duration=1h
```

**The 10-second verification loop** — after every grant:

```bash
k auth can-i <verb> <resource> -n <ns> --as <subject>    # expect yes
k auth can-i delete <resource> -n <ns> --as <subject>    # expect no (prove least privilege)
```

**Resource → apiGroup lookup:** `k api-resources | grep -i deploy` beats guessing.

**Field-name recall without docs:** `k explain pod.spec.securityContext` and `k explain pod.spec.containers.securityContext` — instant, offline, authoritative.

**CSR flow:** the docs page `Certificate Signing Requests` has the whole normal-user flow as copyable blocks — one search away in the exam Firefox. Type the openssl lines yourself (faster), paste the CSR manifest.

**PSA:** one label command, `--overwrite` to be idempotent:

```bash
k label ns X pod-security.kubernetes.io/enforce=restricted --overwrite
```

**Restricted compliance:** paste your memorized 8-line securityContext block (pod: runAsNonRoot+runAsUser+seccomp; container: allowPrivilegeEscalation false + drop ALL), then re-apply.

**Find what grants a subject:**

```bash
k get rolebindings,clusterrolebindings -A -o wide | grep -i jane
```

**Decode any cert fast:**

```bash
openssl x509 -in cert.crt -noout -subject -enddate
```

---

## Docs map

| Need | kubernetes.io path (exam Firefox: search the boldface term) |
|---|---|
| RBAC reference, all YAML shapes, default roles, aggregation | `/docs/reference/access-authn-authz/rbac/` — search **rbac** |
| CSR normal-user flow (copy-paste blocks) | `/docs/reference/access-authn-authz/certificate-signing-requests/` — search **certificate signing requests** |
| Authentication chain, cert CN/O semantics | `/docs/reference/access-authn-authz/authentication/` |
| Authorization modes | `/docs/reference/access-authn-authz/authorization/` |
| Admission controllers list (NodeRestriction) | `/docs/reference/access-authn-authz/admission-controllers/` |
| ServiceAccount tasks (tokens, imagePullSecrets, automount) | `/docs/tasks/configure-pod-container/configure-service-account/` |
| SecurityContext task page (all fields with examples) | `/docs/tasks/configure-pod-container/security-context/` |
| Pod Security Standards (what baseline/restricted require, exact fields) | `/docs/concepts/security/pod-security-standards/` — search **pod security standards** |
| PSA namespace labels | `/docs/concepts/security/pod-security-admission/` |
| kubeconfig structure | `/docs/concepts/configuration/organize-cluster-access-kubeconfig/` |
| kubeadm cert management | `/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/` |

---

## Checkpoint

Time yourself. Every item is a realistic exam task; the target includes verification.

- Can you create a Role + RoleBinding granting a user get/list/watch on pods in one namespace, and prove it with `can-i --as`, in **3 minutes**?
- Can you run the full CSR onboarding (openssl key+CSR → CSR object → approve → extract cert → kubeconfig credentials+context → RBAC → verify with the new context) in **10 minutes** without opening the docs?
- Can you grant a ServiceAccount read access to exactly one namespace by binding the built-in `view` ClusterRole with a RoleBinding in **2 minutes**?
- Can you explain from memory which of the 4 role/binding combinations is invalid and why ClusterRole+RoleBinding doesn't grant nodes access — in **30 seconds**?
- Can you debug a Forbidden error (wrong apiGroup + wrong subject namespace planted) to a working `can-i` yes in **5 minutes**?
- Can you write the RBAC rule for "kubectl logs but not kubectl exec" (pods + pods/log get, no pods/exec) in **2 minutes**?
- Can you create an SA, mint a token with `k create token`, and curl the API server from inside a pod using the mounted token in **8 minutes**?
- Can you label a namespace `restricted` and convert a rejected pod into a compliant one (runAsNonRoot, seccomp RuntimeDefault, drop ALL, allowPrivilegeEscalation false) in **5 minutes**?
- Can you set pod-level runAsUser/fsGroup with a container-level override and predict the exact `id` output of each container **before** exec'ing in?
- Can you state where the cluster CA lives on a kubeadm node and decode a cert's CN/O/expiry with openssl in **1 minute**?
