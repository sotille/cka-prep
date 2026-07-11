# Week 00 — Exercises: Fundamentals & Lab Bootstrap

Lab setup: kind cluster `cka` running (`kind get clusters` → `cka`; nodes `cka-control-plane`, `cka-worker`, `cka-worker2`), context `kind-cka` active. Unlike later weeks, several of these tasks have you *build* the aliases rather than assume them — that is the point of Week 0. Once Task 1 is done, the rest assume:

```bash
alias k=kubectl
export do='--dry-run=client -o yaml'
export now='--grace-period=0 --force'
```

Tasks that need pre-existing or broken state include a **Setup** fence — run it first, don't read it as part of the task. Time yourself honestly: the target includes verification, not just typing. Order is warmup → exam → hard.

---

## Task 1 — bootstrap the exam shell (warmup, 4 min)

Context: a fresh shell on the lab host, context `kind-cka`.

1. From memory, set up: `alias k=kubectl`; exports `do` and `now`; bash completion so tab-completion works for `k`; a `~/.vimrc` giving a 2-space, expand-tab, auto-indent editor.
2. Prove the alias and completion are live (`k versio<TAB>` should complete).
3. Confirm the current context, then list the three nodes with wide output.

## Task 2 — generator speed run (warmup, 5 min)

Context: namespace `default`.

Generate (do **not** apply) a manifest to a file with `$do`, one command each:

1. Pod `nginx-pod`, image `nginx:1.27`, container port 80 → `/tmp/p.yaml`.
2. Deployment `web`, image `httpd:2.4`, 3 replicas → `/tmp/d.yaml`.
3. ConfigMap `app-cfg` from literals `LOG_LEVEL=info` and `TIER=frontend` → `/tmp/cm.yaml`.
4. Secret `db-cred` (generic) from literal `PASSWORD=s3cret` → `/tmp/sec.yaml`.
5. Job `hello`, image `busybox:1.36`, running `echo hi` → `/tmp/j.yaml`.

Then apply exactly one of them: the Deployment.

## Task 3 — imperative CRUD (warmup, 5 min)

Context: namespace `default`.

1. Run a pod `cache`, image `redis:7`, label `app=cache` — pure CLI, no file.
2. Add label `tier=data` and annotation `owner=felipe` to it.
3. Create Deployment `api` (image `httpd:2.4`, 2 replicas); scale it to 4; then change its image to `httpd:2.4-alpine` without editing a file.
4. Force-delete the `cache` pod immediately (no 30s grace).

## Task 4 — namespace & context muscle (warmup, 5 min)

Context: nothing pre-exists.

1. Create namespace `dev`.
2. Make `dev` the default namespace for the current context; prove it with a config command.
3. Run a pod `probe` (image `busybox:1.36`, command `sleep 3600`) with **no** `-n` flag and confirm it landed in `dev`.
4. Reset the context's default namespace back to `default` (leave the pod running).

## Task 5 — skeletons from memory (exam, 7 min)

Context: namespace `default`. **No generators for this one** — hand-write the YAML.

1. Write `/tmp/mem-pod.yaml` by hand: pod `mem-pod`, image `nginx:1.27`, container port 80, label `app=mem`. Apply it.
2. Write `/tmp/mem-deploy.yaml` by hand: Deployment `mem-deploy`, image `nginx:1.27`, 2 replicas, with a correct `selector` ↔ `template` label handshake. Apply it.

Verify both are `Running` / available.

## Task 6 — one file, three objects (exam, 5 min)

Context: nothing pre-exists.

In a **single** file `/tmp/stack.yaml`, define a Namespace `shop`, a ConfigMap `web-cfg` in `shop` with data `GREETING=hello`, and a Pod `site` in `shop` (image `nginx:1.27`). Apply the whole file with one `k apply`. Confirm all three exist in `shop`.

## Task 7 — jsonpath extraction (exam, 6 min)

Context: `kube-system` as shipped by kind.

1. Write the InternalIP of every node, space-separated, to `/tmp/ips.txt`.
2. Write every **unique** container image in `kube-system`, one per line, sorted and deduplicated, to `/tmp/imgs.txt`.
3. Print each node's name and kubelet version, one `name<TAB>version` per line, using jsonpath only.

## Task 8 — custom-columns & sort-by (exam, 6 min)

Context: `kube-system`.

1. Using custom-columns, print two columns for every pod in `kube-system`: pod name and node, headers `POD` and `NODE`.
2. List all `kube-system` pods sorted by creation time, oldest first.
3. Print the name of the single newest pod in `kube-system`.

## Task 9 — the imperative→declarative bridge (exam, 6 min)

Context: namespace `default`.

1. Generate a Deployment `bridge` (image `nginx:1.25`, 2 replicas) to `/tmp/bridge.yaml` with `$do`, then apply it.
2. Edit the file to image `nginx:1.27`; **preview** the change against the live cluster before committing; then apply.
3. Recreate the Deployment from the file in a single command that force-replaces the live object (delete + recreate).

## Task 10 — create, expose, scale (exam, 4 min)

Context: namespace `default`. This is the 90-second drill — no file, no docs.

Create Deployment `shop` (image `nginx:1.27`, 3 replicas), expose it as a ClusterIP Service on port 80, scale to 5, and confirm the Service now has 5 backing endpoints.

## Task 11 — explain navigation (exam, 5 min)

Context: any cluster. Use `explain` only — no docs tab, nothing written to disk.

1. Recover the exact field path of a pod's `tolerations`.
2. List the immediate subfields of `deployment.spec.strategy.rollingUpdate`.
3. Confirm whether `restartPolicy` lives on `pod.spec` or on `pod.spec.containers`.

## Task 12 — api-resources navigation (exam, 5 min)

Context: any cluster.

1. Recover the apiVersion and short name for `CronJob`, `NetworkPolicy`, and `HorizontalPodAutoscaler`.
2. Write every cluster-scoped (non-namespaced) resource type to `/tmp/clusterscoped.txt`.
3. List every kind served by the `apps` API group.

## Task 13 — HARD: fix three broken manifests (hard, 9 min)

Context: three broken files staged below. Each has exactly one class of defect. Fix each with the **minimal** change so it applies cleanly.

Setup:

```bash
# b1: a TAB indents the name line — YAML forbids tabs for indentation
printf 'apiVersion: v1\nkind: Pod\nmetadata:\n\tname: b1\nspec:\n  containers:\n  - name: c\n    image: nginx:1.27\n' > /tmp/b1.yaml

# b2: stale apiVersion + missing selector
cat > /tmp/b2.yaml <<'EOF'
apiVersion: apps/v1beta1
kind: Deployment
metadata:
  name: b2
spec:
  replicas: 2
  template:
    metadata:
      labels:
        app: b2
    spec:
      containers:
      - name: c
        image: nginx:1.27
EOF

# b3: containers and ports written as maps, not lists
cat > /tmp/b3.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: b3
spec:
  containers:
    name: c
    image: nginx:1.27
    ports:
      containerPort: 80
EOF
```

`b3` as staged looks like this (a **map** where the schema wants a **list**):

```text
spec:
  containers:
    name: c              # WRONG: containers is a LIST — needs "- name:"
    image: nginx:1.27
    ports:
      containerPort: 80  # WRONG: ports is a LIST too
```

Diagnose and fix all three; apply each to confirm.

## Task 14 — HARD: reconstruct a manifest from a live object (hard, 8 min)

Context: a running Deployment you must clone into a clean manifest in a different namespace.

Setup:

```bash
k create ns src
k create ns dst
k create deploy recon --image=nginx:1.27 --replicas=2 -n src
```

Extract the live `recon` Deployment from `src`, strip the server-managed noise (`status`, `metadata.managedFields`, `uid`, `resourceVersion`, `creationTimestamp`, `generation`), and recreate the same Deployment in namespace `dst` from a clean manifest. Verify it becomes available in `dst`.

## Task 15 — HARD: no-docs blind speed run (hard, 10 min)

Context: namespace `default`, stopwatch running, docs tab closed. Do all six in order, no lookups.

1. Create namespace `blitz` and pin it as the current context's default.
2. Create Deployment `front` (image `nginx:1.27`, 4 replicas) and expose it on port 80.
3. Create ConfigMap `site-cfg` from literal `HELLO=world`.
4. Run a standalone pod `solo` (image `busybox:1.36`, `sleep 3600`) with label `run=solo`.
5. Write `front`'s pod names and their nodes to `/tmp/front.txt` via custom-columns.
6. Scale `front` to 6, roll the image to `nginx:1.27-alpine`, then roll that change back.

Finally, reset the context's default namespace to `default`.

---

## Solutions

### Solution 1 — bootstrap the exam shell

```bash
alias k=kubectl
export do='--dry-run=client -o yaml'
export now='--grace-period=0 --force'
source <(kubectl completion bash)
complete -o default -F __start_kubectl k
cat >> ~/.vimrc <<'EOF'
set ts=2 sw=2 et ai
EOF

# 2. prove it
type k                        # k is aliased to kubectl
k get<TAB>                    # completes verbs/resources

# 3. context + nodes
k config current-context      # kind-cka
k get nodes -o wide
```

Why: these five lines are the exam's first-60-seconds ritual; `complete -o default -F __start_kubectl k` re-points kubectl's completion function at the `k` alias, and `et` in `.vimrc` guarantees the Tab key never inserts a literal tab into YAML.

### Solution 2 — generator speed run

```bash
k run nginx-pod --image=nginx:1.27 --port=80 $do > /tmp/p.yaml
k create deploy web --image=httpd:2.4 --replicas=3 $do > /tmp/d.yaml
k create cm app-cfg --from-literal=LOG_LEVEL=info --from-literal=TIER=frontend $do > /tmp/cm.yaml
k create secret generic db-cred --from-literal=PASSWORD=s3cret $do > /tmp/sec.yaml
k create job hello --image=busybox:1.36 $do -- echo hi > /tmp/j.yaml
k apply -f /tmp/d.yaml         # apply only the Deployment
```

Why: `$do` (`--dry-run=client -o yaml`) prints the manifest without ever contacting the cluster, so nothing exists until you `apply`; `run` is the only pod generator, everything else is a `create` sub-generator; container args go after `--`.

### Solution 3 — imperative CRUD

```bash
k run cache --image=redis:7 --labels=app=cache
k label pod cache tier=data
k annotate pod cache owner=felipe
k create deploy api --image=httpd:2.4 --replicas=2
k scale deploy/api --replicas=4
k set image deploy/api httpd=httpd:2.4-alpine
k delete pod cache $now
```

Why: `label`/`annotate`/`scale`/`set image` mutate live objects in place without a file; the generated deploy names its container after the image (`httpd`), which is the target in `set image`; `$now` skips the grace period for an instant delete.

### Solution 4 — namespace & context muscle

```bash
k create ns dev
k config set-context --current --namespace=dev
k config view --minify | grep namespace          # namespace: dev
k run probe --image=busybox:1.36 -- sleep 3600    # no -n
k get pod probe -n dev                            # confirms placement
k config set-context --current --namespace=default
```

Why: `set-context --current --namespace` is the built-in, `kubens`-free way to change the default namespace, so the un-`-n`'d `run` lands in `dev`; always reset when you move to an unrelated task so nothing strays.

### Solution 5 — skeletons from memory

`/tmp/mem-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: mem-pod
  labels:
    app: mem
spec:
  containers:
    - name: mem-pod
      image: nginx:1.27
      ports:
        - containerPort: 80
```

`/tmp/mem-deploy.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mem-deploy
  labels:
    app: mem-deploy
spec:
  replicas: 2
  selector:
    matchLabels:
      app: mem-deploy
  template:
    metadata:
      labels:
        app: mem-deploy
    spec:
      containers:
        - name: web
          image: nginx:1.27
```

```bash
k apply -f /tmp/mem-pod.yaml
k apply -f /tmp/mem-deploy.yaml
k get pod mem-pod
k get deploy mem-deploy
```

Why: the two skeletons every workload grows from; the Deployment's `spec.selector.matchLabels` **must** equal `spec.template.metadata.labels` or the API server rejects it, and that selector is immutable afterward.

### Solution 6 — one file, three objects

`/tmp/stack.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: shop
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: web-cfg
  namespace: shop
data:
  GREETING: hello
---
apiVersion: v1
kind: Pod
metadata:
  name: site
  namespace: shop
spec:
  containers:
    - name: site
      image: nginx:1.27
```

```bash
k apply -f /tmp/stack.yaml
k get ns shop && k get cm,pod -n shop
```

Why: `---` separates documents in one file and `k apply -f` processes them in order (Namespace first, so the namespaced objects have a home); each namespaced object carries its own `metadata.namespace`.

### Solution 7 — jsonpath extraction

```bash
# 1. InternalIPs, space-separated
k get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' > /tmp/ips.txt

# 2. unique images in kube-system
k get po -n kube-system -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n' | sort -u > /tmp/imgs.txt

# 3. node name <TAB> kubelet version
k get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.kubeletVersion}{"\n"}{end}'
```

Why: the `[?(@.type=="InternalIP")]` filter selects the right address entry; `tr` + `sort -u` turns the space-separated image stream into a deduped list; `{range}...{end}` iterates items so you can emit one formatted line each with literal `\t`/`\n`.

### Solution 8 — custom-columns & sort-by

```bash
# 1. POD / NODE report
k get po -n kube-system -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName

# 2. oldest-first
k get po -n kube-system --sort-by=.metadata.creationTimestamp

# 3. newest pod name (last row of the ascending sort)
k get po -n kube-system --sort-by=.metadata.creationTimestamp -o name | tail -1
```

Why: custom-columns takes `HEADER:jsonpath` pairs; `--sort-by` sorts ascending on a jsonpath into each item, so `tail -1` is the newest.

### Solution 9 — the imperative→declarative bridge

```bash
k create deploy bridge --image=nginx:1.25 --replicas=2 $do > /tmp/bridge.yaml
k apply -f /tmp/bridge.yaml

# edit the file: image nginx:1.25 -> nginx:1.27  (sed shown; k edit also fine)
sed -i '' 's|nginx:1.25|nginx:1.27|' /tmp/bridge.yaml
k diff -f /tmp/bridge.yaml          # preview the change vs the live object
k apply -f /tmp/bridge.yaml         # commit it

k replace --force -f /tmp/bridge.yaml   # delete + recreate from the file
```

Why: `k diff` shows the exact pending change without applying it; `apply` is the idempotent update path; `replace --force` is the escape hatch (a delete-then-create) for when a change hits an immutable field that `apply`/`edit` can't touch.

### Solution 10 — create, expose, scale

```bash
k create deploy shop --image=nginx:1.27 --replicas=3
k expose deploy shop --port=80
k scale deploy/shop --replicas=5
k get ep shop        # 5 addresses once all pods are Ready
```

Why: `expose` builds the Service from the deployment's own labels/ports so no manifest is needed; the Service's Endpoints track *Ready* pods, so 5 replicas → 5 endpoints once they pass readiness. Drill this whole chain to under 90 seconds.

### Solution 11 — explain navigation

```bash
# 1. exact path of tolerations
k explain pod --recursive | grep -i toleration      # -> pod.spec.tolerations
k explain pod.spec.tolerations                       # confirm

# 2. rollingUpdate subfields
k explain deployment.spec.strategy.rollingUpdate     # maxSurge, maxUnavailable

# 3. where restartPolicy lives
k explain pod.spec.restartPolicy                     # exists (Always/OnFailure/Never)
k explain pod.spec.containers.restartPolicy          # exists too, but for native sidecars only
```

Why: `explain <kind> --recursive | grep` recovers any field's path from memory in seconds; `restartPolicy` is a `pod.spec` field (the pod-level one), while the container-level `restartPolicy: Always` is the separate native-sidecar mechanism — good to know both exist.

### Solution 12 — api-resources navigation

```bash
# 1. apiVersion + short name
k api-resources | grep -iE 'cronjob|networkpolic|horizontalpodautoscaler'
#   cronjobs                  cj       batch/v1              true    CronJob
#   networkpolicies           netpol   networking.k8s.io/v1  true    NetworkPolicy
#   horizontalpodautoscalers  hpa      autoscaling/v2        true    HorizontalPodAutoscaler

# 2. cluster-scoped types to file
k api-resources --namespaced=false -o name > /tmp/clusterscoped.txt

# 3. kinds in the apps group
k api-resources --api-group=apps
```

Why: `api-resources` is the offline map of every served kind — group/version, short name, and namespaced flag — which is how you recover an apiVersion for `no matches for kind` and enumerate cluster-scoped types without guessing.

### Solution 13 — fix three broken manifests

**b1** — the tab: replace the tab before `name:` with spaces (two-space indent). Fixed:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: b1
spec:
  containers:
    - name: c
      image: nginx:1.27
```

**b2** — stale group + missing selector: `apps/v1beta1` is no longer served (`no matches for kind`), and a Deployment requires a `selector` matching the template labels. Fixed:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: b2
spec:
  replicas: 2
  selector:
    matchLabels:
      app: b2
  template:
    metadata:
      labels:
        app: b2
    spec:
      containers:
        - name: c
          image: nginx:1.27
```

**b3** — map vs list: `containers` and `ports` must be lists. Fixed:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: b3
spec:
  containers:
    - name: c
      image: nginx:1.27
      ports:
        - containerPort: 80
```

```bash
k apply -f /tmp/b1.yaml && k apply -f /tmp/b2.yaml && k apply -f /tmp/b3.yaml
```

Why: three canonical failures — a tab (YAML-invalid: `converting YAML to JSON`), a dead apiVersion (`no matches for kind`, fixed via `api-resources`), and a map where the schema wants a list (`cannot unmarshal object into ... []`). Reading the error names the class of defect each time.

### Solution 14 — reconstruct a manifest from a live object

```bash
k get deploy recon -n src -o yaml > /tmp/recon-raw.yaml
# strip status + server-managed metadata, set namespace to dst, keep spec.
```

Cleaned `/tmp/recon-clean.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: recon
  namespace: dst
  labels:
    app: recon
spec:
  replicas: 2
  selector:
    matchLabels:
      app: recon
  template:
    metadata:
      labels:
        app: recon
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
```

```bash
k apply -f /tmp/recon-clean.yaml
k get deploy recon -n dst
```

Why: a live object's `status`, `metadata.managedFields`/`uid`/`resourceVersion`/`creationTimestamp`/`generation` are server-owned and must be dropped before re-creating elsewhere; keep only `apiVersion`, `kind`, identifying `metadata`, and `spec`. (In real life the fastest clone is `k create deploy recon --image=nginx:1.27 --replicas=2 -n dst $do` — but this task is specifically the strip-from-live drill.)

### Solution 15 — no-docs blind speed run

```bash
k create ns blitz
k config set-context --current --namespace=blitz
k create deploy front --image=nginx:1.27 --replicas=4
k expose deploy front --port=80
k create cm site-cfg --from-literal=HELLO=world
k run solo --image=busybox:1.36 --labels=run=solo -- sleep 3600
k get po -l app=front -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName > /tmp/front.txt
k scale deploy/front --replicas=6
k set image deploy/front nginx=nginx:1.27-alpine
k rollout undo deploy/front
k config set-context --current --namespace=default
```

Why: the whole chain is imperative and file-free — `expose` builds the Service from the deployment, `set image` triggers a rollout that `rollout undo` reverses to the prior revision, and pinning then resetting the namespace keeps every un-`-n`'d command landing where you intend. This is the shape of a real exam question compressed into one drill.
