# Week 06 — Security & RBAC Exercises

Lab: the 3-node kind cluster `cka` (context `kind-cka`), aliases assumed: `alias k=kubectl`, `export do="--dry-run=client -o yaml"`, `export now="--grace-period=0 --force"`. Run every task from the host terminal. Where a task needs pre-existing (or pre-broken) resources, run the **setup** fence first. A cleanup fence for the whole set is at the bottom.

Exam-flavor note (applies to all tasks): on the real exam the control plane is a kubeadm node you SSH into with sudo; on kind, substitute `docker exec -it cka-control-plane bash`. RBAC itself is identical.

---

## Task 1 — kubeconfig recon and a new context (warmup, 3 min)

Context: fresh lab, current context `kind-cka`. Nothing pre-exists.

Using only `kubectl config` commands (do not open the kubeconfig file):

1. Write the current context name to `/tmp/ctx.txt`.
2. Write the API server URL of the current context's cluster to `/tmp/server.txt`.
3. Create a new context `dev-context` using the same cluster and user as `kind-cka` but with default namespace `dev-team`.
4. Switch to it, prove the default namespace took effect, then switch back to `kind-cka`.

## Task 2 — Role + RoleBinding for a user (warmup, 4 min)

Context: namespace `dev-team` may not exist yet — create it.

Create a Role `pod-reader` in namespace `dev-team` allowing get, list, and watch on pods. Bind it to user `jane` with a RoleBinding `jane-pod-reader`. Verify with `kubectl auth can-i` that jane can list pods in `dev-team`, cannot delete pods in `dev-team`, and cannot list pods in `default`.

## Task 3 — Permission audit with can-i --list (warmup, 3 min)

Setup:

```bash
k create ns ops
k -n ops create sa runner
k -n ops create role runner-role --verb=get,list,create,delete --resource=pods,configmaps
k -n ops create rolebinding runner-rb --role=runner-role --serviceaccount=ops:runner
```

Context: namespace `ops` with ServiceAccount `runner` and some RBAC already applied (setup above).

Write the complete permission list of ServiceAccount `runner` in namespace `ops` to `/tmp/runner-perms.txt`. Then answer with a single can-i command each: can it delete configmaps in `ops`? Can it list secrets in `ops`?

## Task 4 — ClusterRole for nodes, bound to a group (exam, 4 min)

Context: nothing pre-exists.

Create a ClusterRole `node-inspector` allowing get, list, and watch on nodes. Bind it with a ClusterRoleBinding `node-inspector-ops` to the group `ops-team`. Verify that a member of `ops-team` can list nodes but cannot delete them. Explain (one sentence, to yourself) why a RoleBinding could never make this work.

## Task 5 — Built-in ClusterRole granted per-namespace (exam, 5 min)

Context: nothing pre-exists.

Create namespace `staging` and ServiceAccount `app-viewer` in it. Using the **built-in** `view` ClusterRole (create no new role objects), give `app-viewer` read-only access to namespace `staging` only. Verify: it can list pods in `staging`, cannot list pods in `default`, and cannot list secrets even in `staging`.

## Task 6 — Logs yes, exec no: subresource RBAC (exam, 6 min)

Setup:

```bash
k create ns audit
k -n audit create sa log-bot
k -n audit run target --image=busybox:1.36 --command -- sh -c 'while true; do date; sleep 5; done'
```

Context: namespace `audit` with SA `log-bot` and a running pod `target` (setup above).

Grant `log-bot` exactly enough to run `kubectl logs` against pods in `audit` — and nothing more. It must NOT be able to exec, list pods, or read anything else. Verify with can-i: get pods → yes, get pods/log → yes, create pods/exec → no, list pods → no. State in one line why `pods/log` alone would not have been enough.

## Task 7 — Extend `view` without editing it: aggregation (exam, 5 min)

Context: nothing pre-exists.

The built-in `view` ClusterRole cannot see nodes. Without editing `view` itself, extend it so any subject bound to `view` can also get and list nodes. Prove it: show the nodes rule appearing inside `view`'s rules, then bind `view` to a test user via a ClusterRoleBinding and confirm `can-i list nodes` says yes. Clean up the test binding.

## Task 8 — Fix the Forbidden (exam, 7 min)

Setup:

```bash
k create ns web
k -n web create sa ci-bot
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deploy-manager
  namespace: web
rules:
- apiGroups: [""]
  resources: ["deployments"]
  verbs: ["get", "list", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: deploy-manager-binding
  namespace: web
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: deploy-manager
subjects:
- kind: ServiceAccount
  name: ci-bot
  namespace: default
EOF
```

Context: namespace `web` contains SA `ci-bot`, a Role `deploy-manager`, and a RoleBinding `deploy-manager-binding` (setup above). The CI system authenticating as `system:serviceaccount:web:ci-bot` reports `deployments.apps is forbidden` when listing deployments in `web`.

Diagnose and fix so `ci-bot` can get/list/update/patch deployments in `web`. Do not grant anything beyond that. There are exactly two planted bugs. Verify with can-i before and after.

## Task 9 — Full user onboarding via CSR (hard, 12 min)

Context: namespace `dev-team` exists (task 2 — create it if you skipped). Nothing else pre-exists. Work in a scratch directory.

Onboard a new engineer end-to-end:

1. Generate a 2048-bit RSA key and a CSR for username `carlos`, group `developers`.
2. Submit it as a `certificates.k8s.io/v1` CertificateSigningRequest named `carlos`, signed by the kube-apiserver client signer, valid for 24 hours.
3. Approve it and extract the issued certificate to `carlos.crt`.
4. Add credentials `carlos` and a context `carlos` (cluster `kind-cka`, namespace `dev-team`) to your kubeconfig.
5. Grant the **group** `developers` full CRUD (get,list,watch,create,update,patch,delete) on pods, deployments, and services in `dev-team` only.
6. Verify as carlos: listing pods in `dev-team` works; listing pods in `default` is Forbidden.

Also answer: why does `k auth can-i list pods -n dev-team --as carlos` (no group flag) return `no` even though your setup is correct?

## Task 10 — ServiceAccount token against the API, inside and out (hard, 10 min)

Context: namespace `default`. Nothing pre-exists.

1. Create SA `api-probe` and give it get/list on pods in `default` (least privilege — a Role, not `view`).
2. Run a pod `probe` (image `curlimages/curl:8.8.0`, command `sleep 3600`) that runs as `api-probe`.
3. From inside `probe`, using only the mounted ServiceAccount files, curl the API server over HTTPS with proper CA verification and list the pods of `default`.
4. From the host, mint a fresh 10-minute token for `api-probe` with kubectl and use it in a curl against the API server URL to do the same.
5. Prove least privilege: the same in-pod curl against `/api/v1/namespaces/kube-system/pods` must return 403.

## Task 11 — SA hygiene: no token mount + registry credentials (exam, 5 min)

Context: namespace `default`. Nothing pre-exists.

1. Create SA `quiet-sa` that does **not** automount its API token into pods.
2. Run pod `silent` (busybox, sleep) as `quiet-sa` and prove there is no token mounted at the standard path.
3. Create a docker-registry Secret `regcred` (server `registry.example.com`, user `felipe`, any password) and attach it to `quiet-sa` as an image pull secret, so every pod using this SA inherits it. Show the resulting SA object.

## Task 12 — runAsUser / runAsGroup / fsGroup and the override rule (exam, 5 min)

Context: namespace `default`. Nothing pre-exists.

Create pod `ctx-demo` with two busybox containers (`main`, `sidecar`), both sleeping, sharing an `emptyDir` volume at `/data`:

- Pod level: runAsUser 1000, runAsGroup 3000, fsGroup 2000.
- Container `sidecar` only: runAsUser 2000.

Before exec'ing in, write down the expected `id` output of each container. Then verify both, and show that files under `/data` are group-owned by 2000.

## Task 13 — Capabilities and read-only root filesystem (exam, 5 min)

Context: namespace `default`. Nothing pre-exists.

Create pod `locked-down` (busybox, sleep) whose container: runs as root (UID 0), drops ALL capabilities then adds back only NET_ADMIN, has a read-only root filesystem, but keeps `/tmp` writable. Verify: the capability sets in `/proc/1/status` reflect NET_ADMIN, writing to `/etc` fails, writing to `/tmp` succeeds.

## Task 14 — Restricted namespace: reject, read the error, comply (hard, 8 min)

Context: nothing pre-exists.

1. Create namespace `secure-apps` enforcing the `restricted` Pod Security Standard, with `warn` and `audit` at `restricted` too.
2. Attempt to run a plain pod `naive` (busybox, sleep) in it. Capture the full rejection message to `/tmp/psa-error.txt`.
3. Using the rejection message as your checklist, create pod `compliant` (busybox, sleep) that the namespace accepts. It must actually reach Running.
4. Bonus (do it — it is the highest-value lesson of the task): create a non-compliant Deployment `web` (image nginx, 2 replicas) in `secure-apps`, observe that `kubectl apply` succeeds anyway, and find where the PSA rejection is actually recorded.

---

# SOLUTIONS

## Solution 1 — kubeconfig recon

```bash
k config current-context > /tmp/ctx.txt
k config view --minify -o jsonpath='{.clusters[0].cluster.server}' > /tmp/server.txt
k config set-context dev-context --cluster=kind-cka --user=kind-cka --namespace=dev-team
k config use-context dev-context
k config view --minify -o jsonpath='{.contexts[0].context.namespace}'   # dev-team
k config use-context kind-cka
```

Why: `--minify` collapses the config to the active context, making jsonpath indices stable; a context is just a (cluster, user, namespace) tuple, so a new context needs no new credentials. The namespace does not need to exist for the context to be created.

## Solution 2 — Role + RoleBinding

```bash
k create ns dev-team
k -n dev-team create role pod-reader --verb=get,list,watch --resource=pods
k -n dev-team create rolebinding jane-pod-reader --role=pod-reader --user=jane
k auth can-i list pods -n dev-team --as jane      # yes
k auth can-i delete pods -n dev-team --as jane    # no
k auth can-i list pods -n default --as jane       # no
```

Equivalent YAML (what the imperative commands generate):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: dev-team
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jane-pod-reader
  namespace: dev-team
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: pod-reader
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: jane
```

Why: pods are core (`apiGroups: [""]`); the three no-answers prove least privilege and namespace scoping — always close the loop with can-i.

## Solution 3 — can-i --list audit

```bash
k -n ops auth can-i --list --as=system:serviceaccount:ops:runner | tee /tmp/runner-perms.txt
k -n ops auth can-i delete configmaps --as=system:serviceaccount:ops:runner   # yes
k -n ops auth can-i list secrets --as=system:serviceaccount:ops:runner        # no
```

Why: `can-i --list` performs a SelfSubjectRulesReview under impersonation — the fastest exam-legal way to dump a subject's effective permissions in a namespace.

## Solution 4 — ClusterRole + group

```bash
k create clusterrole node-inspector --verb=get,list,watch --resource=nodes
k create clusterrolebinding node-inspector-ops --clusterrole=node-inspector --group=ops-team
k auth can-i list nodes --as=whoever --as-group=ops-team     # yes
k auth can-i delete nodes --as=whoever --as-group=ops-team   # no
```

Why: nodes are cluster-scoped, so only combination 3 (ClusterRole + ClusterRoleBinding) can grant them — through a RoleBinding, cluster-scoped rules are inert. `--as` is still required with `--as-group` because impersonation always needs a username.

## Solution 5 — view via RoleBinding

```bash
k create ns staging
k -n staging create sa app-viewer
k -n staging create rolebinding app-viewer-view --clusterrole=view --serviceaccount=staging:app-viewer
k auth can-i list pods -n staging --as=system:serviceaccount:staging:app-viewer     # yes
k auth can-i list pods -n default --as=system:serviceaccount:staging:app-viewer     # no
k auth can-i list secrets -n staging --as=system:serviceaccount:staging:app-viewer  # no
```

Why: combination 2 of the binding matrix — a ClusterRole's rules clamped to one namespace by a RoleBinding. `view` deliberately excludes secrets, which is why the last check says no; that's a feature, not a bug.

## Solution 6 — subresource RBAC

```bash
k -n audit create role log-reader --verb=get --resource=pods,pods/log
k -n audit create rolebinding log-bot-logs --role=log-reader --serviceaccount=audit:log-bot
k auth can-i get pods -n audit --as=system:serviceaccount:audit:log-bot                      # yes
k auth can-i get pods --subresource=log -n audit --as=system:serviceaccount:audit:log-bot    # yes
k auth can-i create pods --subresource=exec -n audit --as=system:serviceaccount:audit:log-bot # no
k auth can-i list pods -n audit --as=system:serviceaccount:audit:log-bot                     # no
```

Generated role for reference:

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

Why: `kubectl logs` performs a `get` on the pod object first (to resolve containers), then reads `pods/log` — `pods/log` alone breaks kubectl while raw API calls work. `kubectl exec` needs `create` on `pods/exec`, which we never granted. Gotcha if you tried `kubectl --token=$(k -n audit create token log-bot) -n audit logs target`: if your kubeconfig user carries client certs, TLS-level cert auth wins before the bearer token is read — you'd still be admin. Verify with `can-i --as`, or curl with only the token.

## Solution 7 — aggregation

```bash
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: view-nodes
  labels:
    rbac.authorization.k8s.io/aggregate-to-view: "true"
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list"]
EOF

k get clusterrole view -o jsonpath='{.aggregationRule}'; echo
k get clusterrole view -o yaml | grep -B1 -A3 nodes   # -o yaml renders `- nodes` unquoted
k create clusterrolebinding tmp-view-test --clusterrole=view --user=viewer-test
k auth can-i list nodes --as=viewer-test    # yes
k delete clusterrolebinding tmp-view-test
```

Why: `view` carries an `aggregationRule` selecting the label `rbac.authorization.k8s.io/aggregate-to-view: "true"`; a controller unions matching ClusterRoles' rules into `view` within seconds. Editing `view.rules` directly would be overwritten by that same controller — the label is the only durable mechanism.

## Solution 8 — fix the Forbidden

```bash
# 1. Reproduce
k -n web auth can-i list deployments --as=system:serviceaccount:web:ci-bot   # no
# 2. Inspect both objects
k -n web get role deploy-manager -o yaml         # bug 1: apiGroups [""] — deployments live in "apps"
k -n web get rolebinding deploy-manager-binding -o yaml   # bug 2: subject namespace "default", SA lives in "web"
# 3. Fix the role (rules are mutable)
k -n web patch role deploy-manager --type=json \
  -p='[{"op":"replace","path":"/rules/0/apiGroups/0","value":"apps"}]'
# 4. Fix the binding subject (subjects are mutable; only roleRef is immutable)
k -n web patch rolebinding deploy-manager-binding --type=json \
  -p='[{"op":"replace","path":"/subjects/0/namespace","value":"web"}]'
# 5. Verify
k -n web auth can-i list deployments --as=system:serviceaccount:web:ci-bot   # yes
k -n web auth can-i delete deployments --as=system:serviceaccount:web:ci-bot # no — nothing extra granted
```

Why: two independent planted bugs, each individually fatal: the wrong apiGroup makes the rule match nothing (deployments are `apps`, not core), and the wrong subject namespace grants a *different* SA (`default/ci-bot`, which doesn't even exist). `kubectl edit` on both objects is an equally valid fix path; patch is shown because it's scriptable and precise.

## Solution 9 — CSR onboarding

```bash
mkdir -p /tmp/carlos && cd /tmp/carlos

# 1. key + CSR: CN = username, O = group
openssl genrsa -out carlos.key 2048
openssl req -new -key carlos.key -subj "/CN=carlos/O=developers" -out carlos.csr

# 2. CSR object — request must be single-line base64
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

# 3. approve + harvest
k get csr carlos                      # Pending
k certificate approve carlos
k get csr carlos -o jsonpath='{.status.certificate}' | base64 -d > carlos.crt
openssl x509 -in carlos.crt -noout -subject -enddate   # CN=carlos, O=developers, ~24h

# 4. kubeconfig
k config set-credentials carlos --client-certificate=carlos.crt --client-key=carlos.key --embed-certs=true
k config set-context carlos --cluster=kind-cka --user=carlos --namespace=dev-team

# 5. RBAC for the group
k -n dev-team create role dev-edit \
  --verb=get,list,watch,create,update,patch,delete \
  --resource=pods,deployments,services
k -n dev-team create rolebinding dev-edit-developers --role=dev-edit --group=developers

# 6. verify — impersonation with group, then the real certificate path
k auth can-i create pods -n dev-team --as carlos --as-group developers   # yes
kubectl --context carlos -n dev-team get pods                            # works (empty list is success)
kubectl --context carlos get pods -n default                             # Error ... Forbidden
```

Why: the cert's O field is what makes carlos a member of `developers` — the API server extracts groups from the certificate at authentication time. That's also the answer to the question: `--as carlos` impersonates only the username with no groups attached, so a grant bound to the group is invisible to it; add `--as-group developers` or test with the real cert. Note `expirationSeconds` must be ≥600 and the signer may cap it (controller-manager `--cluster-signing-duration`).

Exam-flavor note: identical on the real exam; the only difference is you might be told to run openssl on a specific node over SSH.

## Solution 10 — SA token, curl inside and out

```bash
# 1. identity + least privilege
k create sa api-probe
k create role pod-lister --verb=get,list --resource=pods
k create rolebinding api-probe-lister --role=pod-lister --serviceaccount=default:api-probe

# 2. pod running as the SA (overrides beat editing generated YAML for one field)
k run probe --image=curlimages/curl:8.8.0 \
  --overrides='{"spec":{"serviceAccountName":"api-probe"}}' \
  --command -- sleep 3600
k wait --for=condition=Ready pod/probe --timeout=60s

# 3. in-pod: token + CA are mounted; kubernetes.default.svc always resolves to the apiserver
k exec probe -- sh -c '
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -s --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/api/v1/namespaces/default/pods | head -20'

# 4. from the host: TokenRequest-minted, short-lived, stored nowhere
TOKEN=$(k create token api-probe --duration=10m)
APISERVER=$(k config view --minify -o jsonpath='{.clusters[0].cluster.server}')
curl -sk -H "Authorization: Bearer $TOKEN" "$APISERVER/api/v1/namespaces/default/pods" | head -20

# 5. least privilege proof — expect 403 Forbidden in the JSON status
k exec probe -- sh -c '
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -s -o /dev/null -w "%{http_code}\n" \
  --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/api/v1/namespaces/kube-system/pods'
```

Why: the projected token in the pod is TokenRequest-issued, ~1h, rotated by kubelet, and bound to the pod's lifetime — the modern replacement for the legacy non-expiring Secret tokens (auto-creation removed in v1.24). The host-side curl uses `-k` because the kind CA isn't in your local trust store; inside the pod the mounted `ca.crt` gives proper verification. A 403 on kube-system proves authentication succeeded and authorization (correctly) refused — 401 would mean a broken token.

## Solution 11 — automount off + imagePullSecrets

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: quiet-sa
  namespace: default
automountServiceAccountToken: false
EOF

k run silent --image=busybox:1.36 \
  --overrides='{"spec":{"serviceAccountName":"quiet-sa"}}' \
  --command -- sleep 3600
k wait --for=condition=Ready pod/silent --timeout=60s
k exec silent -- ls /var/run/secrets/kubernetes.io/serviceaccount
# ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory

k create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=felipe --docker-password=s3cret
k patch serviceaccount quiet-sa -p '{"imagePullSecrets":[{"name":"regcred"}]}'
k get sa quiet-sa -o yaml
```

Resulting SA (relevant fields):

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: quiet-sa
  namespace: default
automountServiceAccountToken: false
imagePullSecrets:
- name: regcred
```

Why: `automountServiceAccountToken: false` on the SA stops the token projection for every pod using it (a pod-level `spec.automountServiceAccountToken` would override the SA's setting if present). `imagePullSecrets` on the SA is inherited by all its pods at admission time — existing pods keep their old spec; only new pods pick it up.

## Solution 12 — securityContext precedence

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ctx-demo
spec:
  securityContext:
    runAsUser: 1000
    runAsGroup: 3000
    fsGroup: 2000
  volumes:
  - name: data
    emptyDir: {}
  containers:
  - name: main
    image: busybox:1.36
    command: ["sleep", "3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  - name: sidecar
    image: busybox:1.36
    command: ["sleep", "3600"]
    securityContext:
      runAsUser: 2000
    volumeMounts:
    - name: data
      mountPath: /data
```

```bash
k apply -f ctx-demo.yaml
k wait --for=condition=Ready pod/ctx-demo --timeout=60s
k exec ctx-demo -c main -- id
# uid=1000 gid=3000 groups=2000,3000
k exec ctx-demo -c sidecar -- id
# uid=2000 gid=3000 groups=2000,3000
k exec ctx-demo -c main -- sh -c 'touch /data/f && ls -ln /data/f'
# -rw-r--r--    1 1000     2000    ... /data/f
```

Why: container-level `runAsUser` overrides pod-level for that container only (`sidecar` → 2000); `runAsGroup` stays inherited (3000); `fsGroup` (pod-only field) becomes the volume's group and a supplementary group of every process — which is why new files under `/data` land group 2000 and `id` shows it in `groups=`. Exact `groups=` ordering/content varies slightly by runtime version; the presence of 2000 is the point.

## Solution 13 — capabilities + read-only rootfs

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: locked-down
spec:
  volumes:
  - name: tmp
    emptyDir: {}
  containers:
  - name: main
    image: busybox:1.36
    command: ["sleep", "3600"]
    securityContext:
      runAsUser: 0
      readOnlyRootFilesystem: true
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
        add: ["NET_ADMIN"]
    volumeMounts:
    - name: tmp
      mountPath: /tmp
```

```bash
k apply -f locked-down.yaml
k wait --for=condition=Ready pod/locked-down --timeout=60s
k exec locked-down -- sh -c 'grep Cap /proc/1/status'
# CapPrm/CapEff = 0000000000001000  (bit 12 = CAP_NET_ADMIN only)
k exec locked-down -- sh -c 'touch /etc/x'   # touch: /etc/x: Read-only file system
k exec locked-down -- sh -c 'touch /tmp/x && echo writable'   # writable
```

Why: `drop: ALL` + `add: NET_ADMIN` yields exactly one capability (verify: `capsh --decode=0000000000001000` on any Linux box → `cap_net_admin`); capability names are written without the `CAP_` prefix. `readOnlyRootFilesystem` locks the container image's filesystem, so anything that must write needs an explicit volume — the `/tmp` emptyDir pattern. Kept UID 0 deliberately: added capabilities apply to the root user's sets; a non-root UID would show empty effective caps despite the `add`.

## Solution 14 — restricted PSA

```bash
# 1. namespace + labels
k create ns secure-apps
k label ns secure-apps \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted --overwrite

# 2. rejection — capture stderr
k -n secure-apps run naive --image=busybox:1.36 --command -- sleep 3600 2> /tmp/psa-error.txt
cat /tmp/psa-error.txt
```

Expected rejection (wording varies slightly by version):

```text
Error from server (Forbidden): pods "naive" is forbidden: violates PodSecurity "restricted:latest":
allowPrivilegeEscalation != false (container "naive" must set securityContext.allowPrivilegeEscalation=false),
unrestricted capabilities (container "naive" must set securityContext.capabilities.drop=["ALL"]),
runAsNonRoot != true (pod or container "naive" must set securityContext.runAsNonRoot=true),
seccompProfile (pod or container "naive" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

```bash
# 3. the memorized compliance block — the error message is the checklist
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: compliant
  namespace: secure-apps
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
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
EOF
k -n secure-apps get pod compliant   # Running

# 4. bonus: the silent Deployment failure
k -n secure-apps create deployment web --image=nginx --replicas=2   # succeeds! (with a Warning header)
k -n secure-apps get deploy web      # 0/2 — and no error on the deployment
k -n secure-apps describe rs -l app=web | grep -A4 Events
# Warning  FailedCreate ... violates PodSecurity "restricted:latest": ...
k -n secure-apps get events --sort-by=.lastTimestamp | tail -5
```

Why: PSA's `enforce` gates only Pod objects, so workload controllers apply cleanly and fail downstream — the rejection lives in the **ReplicaSet's** events, the single most useful fact for PSA troubleshooting. `runAsUser: 1000` is required here because busybox's image USER is root and `runAsNonRoot: true` alone would produce `CreateContainerConfigError` at the kubelet. busybox `sleep` runs fine as UID 1000; a real nginx would additionally need a non-root-capable image (e.g., `nginxinc/nginx-unprivileged`) — image choice is part of PSA compliance, not just securityContext.

---

## Cleanup

```bash
k delete ns dev-team ops staging audit web secure-apps --ignore-not-found $now 2>/dev/null
k delete clusterrole node-inspector view-nodes --ignore-not-found
k delete clusterrolebinding node-inspector-ops --ignore-not-found
k delete role pod-lister --ignore-not-found
k delete rolebinding api-probe-lister --ignore-not-found
k delete sa api-probe quiet-sa --ignore-not-found
k delete pod probe silent ctx-demo locked-down --ignore-not-found $now
k delete secret regcred --ignore-not-found
k delete csr carlos --ignore-not-found
k config delete-context carlos 2>/dev/null; k config delete-context dev-context 2>/dev/null
k config unset users.carlos
k config use-context kind-cka
```
