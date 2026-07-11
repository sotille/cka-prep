# Week 0 Masterclass — Fundamentals & Lab Bootstrap (the entry ramp for Cluster Architecture 25%, Workloads & Scheduling 15%, and every timed task in weeks 01–10)

> 🧭 **Learning path:** [‹ Diagnostic](../diagnostic.md) · [Tier map](../LEARNING-PATH.md) · [week-01-architecture ›](../week-01-architecture/masterclass.md)


Week 0 is not on the exam. It is the tax you pay before the exam becomes winnable. The CKA gives you roughly 6 minutes per task and grades only the target cluster; the candidates who fail rarely fail on Kubernetes knowledge, they fail on speed and mechanics — hand-typing YAML that a generator could have scaffolded, editing in an environment that mangles indentation, forgetting the context switch, hunting a field name in the docs tab that `explain` would have handed them offline. Everything from week-01 onward assumes the reflexes built here are already automatic. If `k run web --image=nginx $do > web.yaml` is not muscle memory, build it now, on the lab, against a stopwatch — not on exam day.

Version note: the local lab is a 3-node kind cluster (`cka`, context `kind-cka`, nodes `cka-control-plane` / `cka-worker` / `cka-worker2`) on Kubernetes v1.36 with etcd 3.6 and the kindnet CNI (kindnet does **not** enforce NetworkPolicy — that matters in week-08, not here). The lab is deliberately newer than the exam; nothing in this module is version-sensitive. Confirm the current exam version on the CNCF curriculum page (github.com/cncf/curriculum) before exam day.

---

## What the exam actually asks

Week 0 has no domain of its own — it is the substrate under all of them. But the mechanics below are worth points on literally every task:

| Week-0 skill | Where it pays off | How it shows up |
|---|---|---|
| Imperative-first scaffolding (`$do`) | All domains | "Create a Deployment/Job/Service with X" — generate, edit, apply; never hand-type |
| kubectl verb + output-flag fluency | All domains | "Write the X of every Y sorted by Z to /opt/..."; every extraction task is jsonpath or custom-columns |
| YAML literacy (indentation, lists vs maps) | All domains | Fixing a manifest that "won't apply"; editing a live object without breaking it |
| Context / namespace discipline | All domains | Every task opens with `kubectl config use-context`; wrong context = zero points on a correct answer |
| `explain` + `api-resources` as offline reference | All domains | Recovering a field path or apiVersion without spending a doc-tab lookup |
| vim + terminal paste setup | All domains | Editing manifests without tab-corruption; pasting YAML that keeps its indentation |

Exam environment reality: a PSI Bridge remote desktop (XFCE + Firefox), one allowed docs tab restricted to kubernetes.io/docs, kubernetes.io/blog, and helm.sh/docs. Terminal paste is **Ctrl+Shift+V**. The first 60–90 seconds of the exam are spent typing this block from memory — it is the single highest-leverage thing you can memorize:

```bash
alias k=kubectl
export do='--dry-run=client -o yaml'
export now='--grace-period=0 --force'
source <(kubectl completion bash)
complete -o default -F __start_kubectl k
```

Then orient before touching anything:

```bash
k config get-contexts        # what clusters exist, which is current (the * column)
k config current-context     # where am I RIGHT NOW
k get nodes -o wide          # what does this cluster look like
```

---

## 1. The exam-speed mindset: imperative-first vs YAML-from-scratch

There are two ways to produce a Kubernetes object, and the exam rewards knowing which to reach for in under two seconds.

**Imperative-first (the default).** Generate a manifest with a generator, redirect to a file, edit the two or three fields the task actually cares about, apply. This is faster than hand-typing because kubectl fills in `apiVersion`, `kind`, the label plumbing, `selector`/`template` wiring, and all the boilerplate you would otherwise get subtly wrong.

```bash
k create deploy web --image=nginx:1.27 --replicas=3 $do > web.yaml
# edit web.yaml: add the resource limits / volume / env the task wants
k apply -f web.yaml
```

**YAML-from-scratch (the exception).** Type the manifest by hand only when there is no generator for the shape you need — a multi-container pod, an init container, a native sidecar, a pod with volumes, anything with `securityContext`, affinity, tolerations, or probes. Even then you start from a *generated skeleton* and add to it; you never open an empty file and type `apiVersion:` from a blank line. The one thing you must be able to type cold is the bare Pod skeleton (below), because it is the root that every workload manifest grows from.

Decision rule, memorized:

| Situation | Reach for |
|---|---|
| A generator exists (`run`, `create deploy/svc/cm/secret/job/cronjob/ns/sa/role/rolebinding/quota`) | Generate with `$do`, edit, apply |
| Object is a simple pod/deployment/service/configmap you can express in flags | Pure imperative, no file at all |
| Object needs fields no generator exposes (volumes, initContainers, probes, affinity) | Generate the nearest skeleton, then edit in the extra fields |
| You are asked to *modify* an existing live object | `k edit`, `k patch`, `k set`, `k label`, or `k scale` — not a rewrite |

The trap that costs minutes: writing a 30-line manifest by hand when `k run` plus one edit would have done it in 15 seconds. When in doubt, generate.

---

## 2. kubectl verb fluency

The exam is a verb-and-flag game. Know these cold; hesitation here compounds across 15–20 tasks.

### The verbs

| Verb | What it does | Exam-critical detail |
|---|---|---|
| `get` | List/read objects | Pair with output flags below; `-A`, `-l`, `--sort-by`, `-w` |
| `describe` | Human-readable object + **Events** | First stop for "why is this broken" — Events are the diagnosis |
| `create` | `POST` a new object; errors if it exists | Has sub-generators (`create deploy`, `create job`, …) |
| `apply` | Declarative create-or-update from a file | The idempotent workhorse; `-f file`, `-f dir/`, `-f -` (stdin) |
| `delete` | Remove an object | `$now` (`--grace-period=0 --force`) for a stuck pod |
| `edit` | Open live object in `$EDITOR`, apply on save | Immutable fields silently no-op or error — see Traps |
| `replace` | `PUT` — full replace; errors if absent | `--force` = delete + recreate, the escape hatch for immutable-field edits |
| `patch` | Surgically change specific fields | `--type merge|strategic|json`; great for one-field changes |
| `label` | Add/remove/overwrite labels | `--overwrite` to change an existing one; `label-` removes |
| `annotate` | Same, for annotations | `kubernetes.io/change-cause` is set this way (or via `--record`-style flags) |
| `expose` | Create a Service for a workload | `--port`, `--target-port`, `--type`; the fastest Service path |
| `scale` | Change replica count | `k scale deploy/web --replicas=5` |
| `rollout` | Manage/observe rollouts | `status`, `history`, `undo`, `restart`, `pause`, `resume` |
| `run` | Create a single **pod** | The only pod generator; `--restart=Never` for a bare pod, `--restart=OnFailure` for a Job-like |

### The output flags (this is where extraction tasks live)

| Flag | Output | Example |
|---|---|---|
| `-o wide` | Extra columns (IP, node, image) | `k get pods -o wide` |
| `-o yaml` / `-o json` | Full serialized object | `k get pod web -o yaml` |
| `-o jsonpath='...'` | One value or a stream of values | `k get nodes -o jsonpath='{.items[*].metadata.name}'` |
| `-o custom-columns=H:path` | Tabular report with your headers | `k get po -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName` |
| `-o name` | `kind/name`, one per line | `k get po -o name` — pipe-friendly |
| `--sort-by=path` | Sort rows by a jsonpath | `k get po --sort-by=.metadata.creationTimestamp` |
| `-l k=v` / `-l k` | Label selector filter | `k get po -l tier=frontend`, `-l 'env in (dev,stage)'` |
| `-A` | All namespaces | `k get po -A` |
| `--field-selector` | Server-side filter on select fields | `k get po -A --field-selector status.phase=Running` |
| `-w` | Watch (stream changes) | `k get po -w` — Ctrl-C to stop |

`--field-selector` only works on a small allowlist of fields (`metadata.name`, `metadata.namespace`, `status.phase`, `spec.nodeName` for pods; `status.phase` etc.). For anything else, filter with `-l`, jsonpath, or `grep`.

### The generators that still work

`kubectl create` grew real sub-generators after the old `--generator` flag was removed. These all accept `$do` to emit YAML instead of creating:

| Object | Command |
|---|---|
| Pod | `k run NAME --image=IMG` (only `run` makes pods) |
| Deployment | `k create deploy NAME --image=IMG --replicas=N` |
| Service | `k create svc clusterip NAME --tcp=80:80` — or `k expose ...` from a workload |
| ConfigMap | `k create cm NAME --from-literal=k=v --from-file=path` |
| Secret | `k create secret generic NAME --from-literal=k=v` |
| Role | `k create role NAME --verb=get,list --resource=pods` |
| RoleBinding | `k create rolebinding NAME --role=R --user=U` (or `--serviceaccount=ns:sa`) |
| Job | `k create job NAME --image=IMG -- CMD` |
| CronJob | `k create cronjob NAME --image=IMG --schedule='*/1 * * * *' -- CMD` |
| ResourceQuota | `k create quota NAME --hard=pods=4,cpu=2` |
| Namespace | `k create ns NAME` |
| ServiceAccount | `k create sa NAME` |

There is no generator for a multi-container pod, init containers, sidecars, PVs/PVCs, or NetworkPolicies — those you scaffold from the pod skeleton and edit.

---

## 3. YAML literacy for the exam

You do not need to love YAML; you need to stop losing points to it. Three rules cover 95% of failures.

**Indentation is structure, and it is spaces only.** A tab character anywhere in a manifest makes it invalid — this is the single most common self-inflicted wound, and it is why the vim setup below matters. Two spaces per level is the convention this whole course uses. Nesting is expressed purely by indentation depth; there are no braces.

**Lists vs maps — the distinction that trips everyone.** A **map** is key/value pairs. A **list** is items introduced by `- `. `spec.containers` is a *list* (a pod can have several), so every container starts with `- name:`. `metadata.labels` is a *map*. Getting this wrong is the classic "cannot unmarshal object into Go value of type []v1.Container" error — you wrote a map where the schema wants a list.

```yaml
metadata:
  name: demo
  labels:            # a MAP: key: value pairs
    app: web
    tier: frontend
spec:
  containers:        # a LIST: each item starts with "- "
    - name: app
      image: nginx:1.27
      env:           # a LIST of maps
        - name: TIER
          value: frontend
        - name: LOG_LEVEL
          value: info
```

**Multi-document files use `---`.** One file can hold many objects separated by a `---` line; `k apply -f file.yaml` applies them all in order. Useful for shipping a Namespace + everything in it together:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: team-alpha
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: team-alpha
data:
  LOG_LEVEL: info
```

### The two skeletons you type from memory

The bare **Pod** — the atom everything else contains:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
  labels:
    app: web
spec:
  containers:
    - name: web
      image: nginx:1.27
      ports:
        - containerPort: 80
```

The **Deployment** — a Pod template wrapped in a controller. Note the three-way label handshake: `spec.selector.matchLabels` **must** equal `spec.template.metadata.labels`, and the selector is immutable after creation.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  labels:
    app: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: nginx:1.27
          ports:
            - containerPort: 80
```

### Common field paths worth internalizing

| Path | Holds |
|---|---|
| `metadata.name` / `metadata.namespace` / `metadata.labels` | Identity and labels |
| `spec.containers[]` | The pod's containers (a list) |
| `spec.containers[].image` / `.command` / `.args` / `.env` / `.ports` | Per-container settings |
| `spec.volumes[]` + `spec.containers[].volumeMounts[]` | Storage plumbing (defined once, mounted per container) |
| `spec.template.spec.containers[]` | The **pod template** inside a Deployment/Job/DaemonSet — one level deeper |
| `spec.selector.matchLabels` | How a controller finds its pods (must match the template labels) |
| `status...` | Live state written by the system — never copy it into a new manifest |

### The fastest way to fix an invalid manifest

1. **Read the error — it names the field.** `error validating data: ValidationError(Pod.spec): unknown field "conatiners"` tells you the typo *and* the path. Since v1.27 validation is server-side and strict, so typos are rejected, not silently dropped.
2. **`no matches for kind "X"`** = wrong `apiVersion` (stale group like `apps/v1beta1`, `extensions/v1beta1`). Fix with `k api-resources | grep -i X`.
3. **"cannot unmarshal object into ... []"** = you wrote a map where a list belongs (or vice versa). Add or remove the `- `.
4. **Tab / indentation errors** = `error converting YAML to JSON: yaml: line N`. Reindent to spaces; in vim, `:set list` reveals tabs as `^I`.
5. When lost, generate a known-good skeleton with `$do` and diff your file against it.

---

## 4. The imperative → declarative bridge

The professional workflow — and the fast one — is to generate imperatively, persist to a file, then manage declaratively. The bridge has four planks:

**Generate:** `k create ... $do > f.yaml` produces a clean manifest without touching the cluster (`--dry-run=client` means kubectl never sends it).

**Edit:** open `f.yaml`, add the fields the generator can't (volumes, probes, limits), fix labels. Or edit a *live* object directly with `k edit deploy/web` — it opens the server's copy in vim and applies your changes on save.

**Apply:** `k apply -f f.yaml` is create-or-update. Re-running it after edits reconciles the live object to the file (a three-way merge against the `last-applied-configuration` annotation). This is idempotent — safe to run repeatedly.

**Diff before you apply:** `k diff -f f.yaml` shows exactly what would change on the cluster without changing it. On the exam this is how you confirm an edit does what you think before committing.

**When apply won't take it — `replace --force`:** some changes hit immutable fields (a Deployment's `selector`, a Job's `template`, a Service's `clusterIP`). `apply`/`edit` will error or silently no-op. `k replace --force -f f.yaml` deletes the object and recreates it from the file in one step — the sanctioned escape hatch. Use it deliberately; it is a delete, so anything not in the file is gone.

```bash
k create deploy web --image=nginx:1.25 $do > web.yaml   # generate
vim web.yaml                                              # edit (add limits, etc.)
k diff -f web.yaml                                        # preview
k apply -f web.yaml                                       # apply
# ...later, an immutable-field change:
k replace --force -f web.yaml                             # delete + recreate
```

`create` vs `apply` vs `replace` in one line each: `create` is a `POST` (errors if it exists), `apply` is a merge patch (create-or-update), `replace` is a `PUT` (errors if it doesn't exist; `--force` recreates).

---

## 5. Namespaces & context — the muscle memory that saves you from zero-point answers

Every exam task begins with a `kubectl config use-context <name>` line. Skipping it means solving the task perfectly on the wrong cluster, which scores nothing. Two reflexes, drilled until automatic:

**Always check context first.** Before reading a task, `k config current-context`. Before submitting, glance at it again. The lab's context is `kind-cka`; on the exam it changes per question.

```bash
k config current-context                 # where am I
k config use-context kind-cka            # go to the right cluster
```

**Pin the namespace instead of typing `-n` twenty times.** If a task lives in namespace `team-alpha`, set it as the context default once and drop `-n` for the rest of the task:

```bash
k config set-context --current --namespace=team-alpha
k config view --minify | grep namespace   # prove it stuck
```

This is the built-in replacement for `kubens` (which is not installed on the exam — don't reach for it). To find what namespaces exist and what is in one:

```bash
k get ns                                  # all namespaces
k get all -n team-alpha                   # common workload types in one (not literally everything)
```

Remember `k get all` shows a curated set (pods, services, deployments, replicasets, …) — not every kind. For a true inventory of a namespace you enumerate resource types via `api-resources` (next section). And reset the default namespace back to `default` when you move to an unrelated task, so a later stray command doesn't land in the wrong place.

---

## 6. The vim + paste setup that saves the exam

You will live in `k edit` and in manifest files, and YAML dies on tabs. Two lines of `~/.vimrc` prevent the most common failure mode:

```bash
cat >> ~/.vimrc <<'EOF'
set ts=2 sw=2 et ai
EOF
```

`ts=2 sw=2` = a two-space indent, `et` (expandtab) = the Tab key inserts spaces not a tab character, `ai` (autoindent) = new lines keep the previous indent so you type less. The catch: with `ai` (or `et`) on, **pasting** multi-line YAML makes vim auto-indent each already-indented line on top of the last, producing a cascading staircase of ever-deeper indentation. The fix is `:set paste` before you paste and `:set nopaste` after:

```text
:set paste       " turn OFF auto-indent so pasted YAML keeps its own indentation
" ... Ctrl+Shift+V to paste ...
:set nopaste     " turn auto-indent back on for hand typing
```

Terminal copy/paste in the PSI environment is **Ctrl+Shift+V** to paste (and Ctrl+Shift+C to copy) — the plain Ctrl+V/Ctrl+C are taken by the terminal. When YAML you pasted looks mangled, the cause is almost always auto-indent, and `:set paste` is the cure. If a manifest still won't parse, `:set list` renders tabs as `^I` and line-ends as `$` so you can see the offending whitespace.

---

## 7. `explain` and `api-resources` — your offline field reference

The docs tab is slow and rate-limits your attention. Two commands answer most "what's the exact name / path / version" questions without leaving the terminal.

### `kubectl api-resources` — the map of every kind

Shows every resource type the cluster serves, its short name, its API group/version, and whether it's namespaced:

```bash
k api-resources                                  # everything
k api-resources | grep -i cronjob                # recover a kind's group/version + shortname
k api-resources --namespaced=false               # cluster-scoped types (nodes, PVs, CRDs, ...)
k api-resources --namespaced=false -o name       # same, pipe-friendly, for "write them to a file"
k api-resources --api-group=apps                 # everything in one group
```

This is how you fix `no matches for kind` (find the real apiVersion), discover a short name (`netpol`, `hpa`, `pvc`), and answer "which resource types are not namespaced."

### `kubectl explain` — the schema, offline

`explain` prints the schema for any field path — the offline substitute for the API reference docs:

```bash
k explain pod.spec.containers                     # fields of a container
k explain deployment.spec.strategy.rollingUpdate  # dig to any depth with dots
k explain pod --recursive                         # the ENTIRE pod schema, one screen, no descriptions
k explain pod --recursive | grep -i toleration    # find where a field lives, fast
```

The killer pattern is `k explain <kind> --recursive | grep -i <field>` — it recovers the exact path of any field from memory in seconds. Use `explain` to confirm a field name before you type it into a manifest, so you never apply a typo. Together, `api-resources` answers "what kinds exist and how are they named," and `explain` answers "what fields does this kind have and where" — between them, you rarely need the docs tab for anything but examples.

---

## Traps

- **Wrong context, perfect answer, zero points.** `k config use-context` at the start of *every* task; glance at `current-context` before you submit.
- **A tab anywhere = invalid YAML.** `et` in `.vimrc` prevents it; `:set list` finds it. This is the #1 self-inflicted failure.
- **Auto-indent staircases your pasted YAML.** `:set paste` before Ctrl+Shift+V, `:set nopaste` after. If a pasted manifest is mis-indented, this is why.
- **Map where a list belongs (or vice versa).** `spec.containers` is a list (`- name:`), `metadata.labels` is a map. "cannot unmarshal object into []..." = you need a `- `.
- **`no matches for kind`** = stale `apiVersion`. Recover the real one with `k api-resources | grep -i <kind>`; use current groups (`apps/v1`, `batch/v1`, `v1`).
- **`k get all` is not "all".** It shows a curated set of kinds, not every resource type in the namespace. Use `api-resources` for a true inventory.
- **`--field-selector` only works on a few fields.** For arbitrary filtering use `-l`, jsonpath, or `grep`.
- **`create` errors if it exists; `replace` errors if it doesn't.** `apply` is the idempotent one. Immutable-field changes need `replace --force` (a delete + recreate).
- **`$do` never touches the cluster.** `--dry-run=client` means the object is only printed; you still have to `apply` the file. Don't assume the generate step created anything.
- **Hand-typing a manifest a generator could scaffold.** Almost always the slower path. Generate, then edit.

---

## Speed patterns

The fastest exam-legal path for each recurring Week-0 move:

| Need | Fastest path |
|---|---|
| Scaffold a Pod YAML | `k run web --image=nginx:1.27 $do > web.yaml` then edit |
| Scaffold a Deployment YAML | `k create deploy web --image=nginx:1.27 --replicas=3 $do > web.yaml` |
| Create a bare run-to-completion pod | `k run once --image=busybox:1.36 --restart=Never -- sh -c 'date; sleep 3'` |
| Create a Service for a workload | `k expose deploy web --port=80 --target-port=8080` |
| Create + expose a pod in two shots | `k run web --image=nginx --port=80` then `k expose pod web --port=80` |
| Force-delete a stuck pod | `k delete pod web $now` |
| Change a Deployment's image | `k set image deploy/web web=nginx:1.27` |
| Scale a Deployment | `k scale deploy/web --replicas=5` |
| Roll back a bad rollout | `k rollout undo deploy/web` |
| Recover a field's exact path | `k explain <kind> --recursive \| grep -i <field>` |
| Recover a kind / apiVersion | `k api-resources \| grep -i <kind>` |
| Cluster-scoped types → file | `k api-resources --namespaced=false -o name > /tmp/x.txt` |
| Nodes with IP/OS/runtime | `k get nodes -o wide` |
| Node InternalIPs via jsonpath | `k get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'` |
| Pods sorted by age | `k get pods -A --sort-by=.metadata.creationTimestamp` |
| Unique images in a namespace | `k get po -n kube-system -o jsonpath='{.items[*].spec.containers[*].image}' \| tr ' ' '\n' \| sort -u` |
| Two-column custom report | `k get po -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName` |
| Pin the default namespace | `k config set-context --current --namespace=team-alpha` |
| Preview an apply | `k diff -f web.yaml` |
| Immutable-field change | `k replace --force -f web.yaml` |

Two habits that compound across the whole course: (1) generate with `$do` and edit, never hand-type a full manifest; (2) end every build task with a `k get`/`describe`/`logs` check — it is faster than re-reading the task and catches the `Pending`/typo you'd otherwise miss.

---

## Docs-map

When you must open the tab, go straight to the path — don't search from the homepage.

| What you need | Exact kubernetes.io doc path |
|---|---|
| kubectl cheat sheet (jsonpath, sort-by, generators) | `/docs/reference/kubectl/cheatsheet/` |
| kubectl commands reference | `/docs/reference/kubectl/generated/kubectl/` |
| jsonpath support & syntax | `/docs/reference/kubectl/jsonpath/` |
| kubeconfig / multiple clusters | `/docs/tasks/access-application-cluster/configure-access-multiple-clusters/` |
| Object management (imperative vs declarative) | `/docs/concepts/overview/working-with-objects/object-management/` |
| Namespaces | `/docs/concepts/overview/working-with-objects/namespaces/` |
| Pod overview | `/docs/concepts/workloads/pods/` |
| Deployments | `/docs/concepts/workloads/controllers/deployment/` |
| Labels and selectors | `/docs/concepts/overview/working-with-objects/labels/` |

---

## Checkpoint

Self-test against the clock. If any answer is "I'd have to look it up," Week 0 isn't done. Each is "can you, in the target time":

- **Under 90s:** type the full exam-setup block from memory — aliases, `$do`/`$now` exports, completion, `.vimrc` — and verify the context.
- **Under 30s:** switch context and pin a default namespace (`use-context` + `set-context --current --namespace`), then prove the namespace stuck.
- **Under 90s:** create a Deployment, expose it as a Service, and scale it to 5 — no docs, no file.
- **Under 45s:** scaffold a Deployment manifest with `$do`, add a container resource limit, `k diff` it, then `k apply`.
- **Under 30s:** write the InternalIP of every node to a file using jsonpath.
- **Under 45s:** produce a two-column `POD NODE` custom-columns report for a namespace, and separately the unique image list for it.
- **Under 60s:** type the bare Pod skeleton from memory into a file and `k apply` it clean on the first try.
- **Under 30s:** recover the exact schema path of `tolerations` (or any field) with `explain --recursive | grep`.
- **Under 20s:** write every cluster-scoped (non-namespaced) resource type to a file.
- **Under 60s:** given a manifest that returns `no matches for kind`, name the cause and the one command that recovers the correct apiVersion.
- **Explain in one breath:** why `$do` producing a manifest does *not* mean anything exists in the cluster yet.
