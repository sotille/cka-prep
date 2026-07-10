# Week 01 — Exercises: Cluster Architecture & Core Concepts

Lab setup: kind cluster `cka` running (`kind get clusters` → `cka`; nodes `cka-control-plane`, `cka-worker`, `cka-worker2`), context `kind-cka` active, aliases loaded:

```bash
alias k=kubectl
export do="--dry-run=client -o yaml"
export now="--grace-period=0 --force"
```

Tasks that need pre-existing or broken state include a **Setup** fence — run it first, don't read it as part of the task. Time yourself honestly: the target includes verification, not just typing.

Exam-flavor note (once for the whole file): where a task says `docker exec -it cka-control-plane bash`, the real exam equivalent is `ssh <control-plane-node>` then `sudo -i`. Everything else runs identically.

---

## Task 1 — kubectl recon (warmup, 5 min)

Context: fresh cluster, namespace `default`.

1. List all nodes with their internal IPs, OS image, and container-runtime version in one command.
2. Write the InternalIP of every node, space-separated, to `/tmp/node-ips.txt` using jsonpath.
3. List all pods in `kube-system` sorted by creation time, oldest first.
4. Print the name of the single newest pod in `kube-system`.

## Task 2 — dry-run scaffolding (warmup, 4 min)

Context: namespace `default`.

1. Create a pod `web-01`, image `nginx:1.27`, exposing container port 80, label `tier=frontend` — pure CLI, no file.
2. Generate (do **not** apply) a manifest for a Deployment `api`, image `httpd:2.4`, 3 replicas, into `/tmp/api.yaml`; then apply it.
3. Generate a manifest for a pod `once` running `busybox:1.36` with command `sh -c "date; sleep 5"` that runs to completion exactly once (no restarts), save to `/tmp/once.yaml`, apply, and confirm its final phase is `Succeeded`.

## Task 3 — namespace operations (warmup, 5 min)

Context: nothing pre-exists.

1. Create namespace `team-alpha`.
2. Make `team-alpha` the default namespace for the current context; prove it with a config command.
3. Run a pod `scratch` (image `busybox:1.36`, command `sleep 3600`) with **no** `-n` flag and confirm it landed in `team-alpha`.
4. Write the list of all resource **types** that are NOT namespaced to `/tmp/cluster-scoped.txt`.
5. Reset the context's default namespace back to `default` (leave the pod running for later).

## Task 4 — jsonpath and custom-columns (exam, 6 min)

Context: `kube-system` as shipped by kind.

1. Write every **unique** container image running in `kube-system` to `/tmp/ks-images.txt`, one per line, sorted, deduplicated.
2. Using custom-columns, print two columns for every pod in `kube-system`: pod name and node it runs on, headers `POD` and `NODE`.
3. Print the kubelet version of each node using jsonpath only, one `name<TAB>version` per line.

## Task 5 — multi-container pod, shared volume (exam, 8 min)

Context: namespace `default`.

Create a pod `web-logs` with two containers sharing an `emptyDir` volume named `logs`:

- Container `writer`: image `busybox:1.36`, appends the current date to `/data/out.log` every 2 seconds.
- Container `reader`: image `busybox:1.36`, runs `tail -F /data/out.log`.

Verify with `k logs` that `reader` is streaming the dates `writer` produces.

## Task 6 — init container (exam, 6 min)

Context: namespace `default`.

Create a pod `initialized-web`: an init container `render` (image `busybox:1.36`) writes the text `week01` to `/work/index.html` on a shared `emptyDir`; the main container `web` (image `nginx:1.27`) serves that file from `/usr/share/nginx/html`. Verify by exec'ing `cat /usr/share/nginx/html/index.html` inside `web`.

## Task 7 — native sidecar (exam, 8 min)

Context: namespace `default`.

Create a pod `app-sidecar` where:

- Main container `app` (image `busybox:1.36`) writes a timestamp to `/var/log/app/app.log` every 3 seconds.
- A **sidecar** container `shipper` (image `busybox:1.36`) runs `tail -F /var/log/app/app.log`, must start **before** the main container, and must keep running for the pod's lifetime. Use the **native sidecar** mechanism, not a plain second container.

Verify: `k get pod app-sidecar` shows `2/2` READY and `k logs app-sidecar -c shipper` shows the timestamps.

## Task 8 — deployment scale, rollout, rollback (exam, 6 min)

Context: namespace `default`.

1. Create Deployment `frontend`, image `nginx:1.25`, 4 replicas.
2. Scale it to 6.
3. Roll out image `nginx:1.27`, annotate the change-cause `bump to 1.27`, and wait for the rollout to complete.
4. Roll it back to the previous revision and confirm the running image is `nginx:1.25` again.

## Task 9 — inspect the control plane on kind (exam, 7 min)

Context: kind cluster; you have `docker` on the host.

1. List the static-pod manifests the control-plane kubelet runs.
2. Read the `--service-cluster-ip-range` flag value from the API-server manifest.
3. Find the `--data-dir` etcd uses.
4. List the control-plane component pods in `kube-system` and identify how you'd tell a mirror (static) pod from an ordinary one.

Exam flavor: on real kubeadm nodes these files are directly under `/etc/kubernetes/manifests` after you `ssh` + `sudo -i`; no `docker exec` layer.

## Task 10 — CRD and custom resource (exam, 7 min)

Context: namespace `default`.

Setup — install a CRD and one custom resource:

```bash
cat <<'EOF' | k apply -f -
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.demo.cka.io
spec:
  group: demo.cka.io
  scope: Namespaced
  names:
    plural: widgets
    singular: widget
    kind: Widget
    shortNames: ["wd"]
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                size:
                  type: string
                replicas:
                  type: integer
EOF

cat <<'EOF' | k apply -f -
apiVersion: demo.cka.io/v1
kind: Widget
metadata:
  name: blue-widget
  namespace: default
spec:
  size: large
  replicas: 3
EOF
```

1. Confirm the CRD is installed and print its group, version, and scope.
2. Confirm the new `Widget` type is served by the API and find its short name.
3. List all `Widget` custom resources across all namespaces.
4. Print the `spec.size` of `blue-widget` with jsonpath.
5. Create a second `Widget` named `red-widget` with `size: small` and `replicas: 1` using `$do` scaffolding is not possible for CRs — write the manifest by hand and apply it.

## Task 11 — kubeconfig contexts (exam, 5 min)

Context: current context `kind-cka`.

1. Print the current context name and the clusters/users/contexts defined, using config subcommands only.
2. Create a **new context** named `cka-alpha` that reuses the existing `kind-cka` cluster and `kind-cka` user but defaults to namespace `team-alpha`.
3. Switch to `cka-alpha`, run `k get pods` (no `-n`), and confirm it queries `team-alpha`.
4. Switch back to `kind-cka`.

## Task 12 — api-resources and explain superpowers (exam, 5 min)

Context: any namespace.

1. Without opening the docs, find the exact apiVersion and short name of `NetworkPolicy` and of `HorizontalPodAutoscaler`.
2. Find the full schema path of `tolerations` on a Pod using `explain --recursive`.
3. Show the fields available under `deployment.spec.strategy.rollingUpdate`.
4. Write the names of all resource types in the `apps` API group to `/tmp/apps-kinds.txt`.

## Task 13 — HARD: a pod that will not schedule (hard, 8 min)

Context: namespace `default`.

Setup:

```bash
cat <<'EOF' | k apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: stuck
  namespace: default
spec:
  nodeSelector:
    disktype: ssd
  containers:
    - name: app
      image: nginx:1.27
EOF
```

The pod `stuck` stays `Pending`. Diagnose **why** using only `kubectl` (do not read the setup fence as the answer — arrive at it from cluster state), then make it schedule and reach `Running` **without editing or deleting the pod's `nodeSelector`** and without deleting the pod. State in one line what stage of the scheduling pipeline was blocking it.

## Task 14 — HARD: pod adoption, reaping, and the selector-immutability trap (hard, 12 min)

Context: namespace `default`.

Setup:

```bash
k create deployment web --image=nginx:1.27 --replicas=2
k run web-legacy --image=nginx:1.27 --labels="app=web"
```

1. Explain, with evidence from the cluster, whether the standalone pod `web-legacy` (labels `app=web`, no `ownerReferences`) is owned by — or at risk from — the `web` Deployment's ReplicaSet. Print the ReplicaSet's **actual** selector to justify your answer.
2. Create a **bare** ReplicaSet `web-rs` (no Deployment) with `replicas: 1`, selector `matchLabels: {app: web}`, and template labels `app=web`. Observe what it does to `web-legacy` and explain — with `ownerReferences` as evidence — why this ReplicaSet endangers `web-legacy` when the Deployment's ReplicaSet never could.
3. The team now wants `web-rs` to manage **only** pods labelled `app=web,track=stable`, to run 2 replicas, and to stop controlling `web-legacy`. Change `web-rs`'s selector accordingly. (You will hit the immutability trap — solve it correctly, and preserve the already-adopted `web-legacy`.) Confirm the reworked `web-rs` runs 2 `Running` pods carrying both labels and that `web-legacy` still exists and is no longer owned by any ReplicaSet.

## Task 15 — HARD: break and restore the scheduler on kind (hard, 10 min)

Context: kind cluster; `docker` on host. This task deliberately stops the scheduler, so do it when no one else needs the lab.

1. On `cka-control-plane`, move `kube-scheduler.yaml` out of `/etc/kubernetes/manifests/` (to `/tmp`), then confirm the scheduler pod disappears from `kube-system`.
2. Create a pod `orphan` (image `nginx:1.27`) in `default` and observe its status and its Events. Contrast the failure signature with Task 13's.
3. Restore the manifest, confirm the scheduler comes back, and confirm `orphan` schedules and reaches `Running`.
4. In one line: what is the tell that distinguishes "scheduler is down" from "no node fits this pod"?

---

# SOLUTIONS

## Solution 1 — kubectl recon

```bash
# 1. nodes with IP / OS / runtime
k get nodes -o wide

# 2. InternalIPs to file (space-separated)
k get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' > /tmp/node-ips.txt

# 3. kube-system pods, oldest first
k get pods -n kube-system --sort-by=.metadata.creationTimestamp

# 4. newest pod name = last line of the sort, first column
k get pods -n kube-system --sort-by=.metadata.creationTimestamp -o name | tail -1
```

Why: `-o wide` adds INTERNAL-IP/OS-IMAGE/CONTAINER-RUNTIME columns; the `[?(@.type=="InternalIP")]` jsonpath filter picks the right address entry; `--sort-by` takes a jsonpath into each item, and sorts ascending, so `tail -1` is the newest.

## Solution 2 — dry-run scaffolding

```bash
# 1. pod, pure CLI
k run web-01 --image=nginx:1.27 --port=80 --labels="tier=frontend"

# 2. deployment manifest, then apply
k create deploy api --image=httpd:2.4 --replicas=3 $do > /tmp/api.yaml
k apply -f /tmp/api.yaml

# 3. run-to-completion pod
k run once --image=busybox:1.36 --restart=Never $do -- sh -c 'date; sleep 5' > /tmp/once.yaml
k apply -f /tmp/once.yaml
k wait --for=jsonpath='{.status.phase}'=Succeeded pod/once --timeout=30s
k get pod once   # STATUS Completed, phase Succeeded
```

`/tmp/once.yaml` produced by the scaffold:

```yaml
apiVersion: v1
kind: Pod
metadata:
  creationTimestamp: null
  labels:
    run: once
  name: once
spec:
  containers:
    - args:
        - sh
        - -c
        - date; sleep 5
      image: busybox:1.36
      name: once
      resources: {}
  dnsPolicy: ClusterFirst
  restartPolicy: Never
status: {}
```

Why: `--restart=Never` makes `kubectl run` create a bare Pod (not a Deployment) whose completion yields phase `Succeeded`; everything after `--` becomes the container args.

## Solution 3 — namespace operations

```bash
# 1. create
k create namespace team-alpha

# 2. pin default ns for current context, then prove it
k config set-context --current --namespace=team-alpha
k config view --minify -o jsonpath='{..namespace}{"\n"}'   # prints team-alpha

# 3. run without -n, confirm placement
k run scratch --image=busybox:1.36 -- sleep 3600
k get pod scratch -o jsonpath='{.metadata.namespace}{"\n"}'  # team-alpha

# 4. cluster-scoped types to file
k api-resources --namespaced=false -o name > /tmp/cluster-scoped.txt

# 5. reset default ns
k config set-context --current --namespace=default
```

Why: `set-context --current --namespace` writes the default namespace into the active context so subsequent commands need no `-n`; `api-resources --namespaced=false` is the authoritative source of cluster-scoped types (Node, PV, StorageClass, ClusterRole, CRD, IngressClass, PriorityClass, …).

## Solution 4 — jsonpath and custom-columns

```bash
# 1. unique images
k get po -n kube-system -o jsonpath='{.items[*].spec.containers[*].image}' \
  | tr ' ' '\n' | sort -u > /tmp/ks-images.txt

# 2. custom columns
k get po -n kube-system -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName

# 3. kubelet version per node
k get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.kubeletVersion}{"\n"}{end}'
```

Why: jsonpath `[*]` flattens all containers' images onto one space-separated line, so `tr`+`sort -u` dedupes them; `custom-columns` maps a header to a jsonpath expression; the `{range}…{end}` construct iterates items to emit one line each with a real newline.

## Solution 5 — multi-container pod, shared volume

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web-logs
  namespace: default
spec:
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c", "while true; do date >> /data/out.log; sleep 2; done"]
      volumeMounts:
        - name: logs
          mountPath: /data
    - name: reader
      image: busybox:1.36
      command: ["sh", "-c", "tail -F /data/out.log"]
      volumeMounts:
        - name: logs
          mountPath: /data
  volumes:
    - name: logs
      emptyDir: {}
```

```bash
k apply -f web-logs.yaml
k logs web-logs -c reader --tail=5   # streaming dates written by writer
```

Why: both containers mount the same `emptyDir` at `/data`, so `writer`'s appends are visible to `reader`'s `tail -F`; the shared volume is the only coupling needed.

## Solution 6 — init container

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: initialized-web
  namespace: default
spec:
  initContainers:
    - name: render
      image: busybox:1.36
      command: ["sh", "-c", "echo week01 > /work/index.html"]
      volumeMounts:
        - name: web
          mountPath: /work
  containers:
    - name: web
      image: nginx:1.27
      volumeMounts:
        - name: web
          mountPath: /usr/share/nginx/html
  volumes:
    - name: web
      emptyDir: {}
```

```bash
k apply -f initialized-web.yaml
k exec initialized-web -c web -- cat /usr/share/nginx/html/index.html   # week01
```

Why: the init container runs to completion first, writing the file into the shared `emptyDir`; nginx then starts and serves the already-populated volume — init containers are the exam-standard way to prepare data before the main container.

## Solution 7 — native sidecar

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-sidecar
  namespace: default
spec:
  initContainers:
    - name: shipper           # native sidecar = initContainer + restartPolicy Always
      image: busybox:1.36
      restartPolicy: Always
      command: ["sh", "-c", "tail -F /var/log/app/app.log"]
      volumeMounts:
        - name: logs
          mountPath: /var/log/app
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "mkdir -p /var/log/app; while true; do date >> /var/log/app/app.log; sleep 3; done"]
      volumeMounts:
        - name: logs
          mountPath: /var/log/app
  volumes:
    - name: logs
      emptyDir: {}
```

```bash
k apply -f app-sidecar.yaml
k get pod app-sidecar                 # 2/2 READY
k logs app-sidecar -c shipper --tail=5
```

Why: `restartPolicy: Always` on an init container makes it a native sidecar — the kubelet starts it during the init phase (so it's up before `app`), keeps it alive for the pod's lifetime, and it counts as a ready container (`2/2`). A plain second `containers` entry would give no start-ordering guarantee.

## Solution 8 — deployment scale, rollout, rollback

```bash
k create deployment frontend --image=nginx:1.25 --replicas=4
k scale deployment frontend --replicas=6
k set image deployment/frontend nginx=nginx:1.27
k annotate deployment/frontend kubernetes.io/change-cause="bump to 1.27"
k rollout status deployment/frontend

k rollout undo deployment/frontend
k rollout status deployment/frontend
k get deploy frontend -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'   # nginx:1.25
```

Why: `set image` changes `.spec.template`, creating a new ReplicaSet (revision 2); `rollout undo` with no `--to-revision` copies the previous revision's template back, restoring `nginx:1.25`. The container name in `set image` (`nginx=`) must match the template's container name, which `kubectl create deployment` names after the **image base name** (`nginx` here, from `nginx:1.25`) — **not** after the deployment name — verify with `k get deploy frontend -o jsonpath='{.spec.template.spec.containers[0].name}'` if unsure.

## Solution 9 — inspect the control plane on kind

```bash
# 1. static-pod manifests
docker exec cka-control-plane ls /etc/kubernetes/manifests
# etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml

# 2. service CIDR flag from the apiserver manifest
docker exec cka-control-plane grep -- '--service-cluster-ip-range' /etc/kubernetes/manifests/kube-apiserver.yaml
# --service-cluster-ip-range=10.96.0.0/12

# 3. etcd data-dir
docker exec cka-control-plane grep -- '--data-dir' /etc/kubernetes/manifests/etcd.yaml
# --data-dir=/var/lib/etcd

# 4. control-plane pods and mirror-pod tell
k get pods -n kube-system -o wide | egrep 'apiserver|etcd|scheduler|controller-manager'
```

Why: kubeadm/kind run the control plane as static pods managed by the control-plane kubelet from `/etc/kubernetes/manifests`; the API objects for them are **mirror pods** whose names are suffixed with the node name (e.g. `kube-apiserver-cka-control-plane`) and which cannot be edited via the API — you change them by editing the file on the node. `--service-cluster-ip-range=10.96.0.0/12` matches this lab's `serviceSubnet` from `kind-config.yaml`.

## Solution 10 — CRD and custom resource

```bash
# 1. CRD present + group/version/scope
k get crds | grep widgets
k get crd widgets.demo.cka.io -o jsonpath='{.spec.group}{" "}{.spec.versions[0].name}{" "}{.spec.scope}{"\n"}'
# demo.cka.io v1 Namespaced

# 2. type served + short name
k api-resources | grep -i widget
# widgets   wd   demo.cka.io/v1   true   Widget

# 3. all Widget CRs everywhere
k get widgets -A

# 4. spec.size of blue-widget
k get widget blue-widget -o jsonpath='{.spec.size}{"\n"}'   # large
```

```yaml
apiVersion: demo.cka.io/v1
kind: Widget
metadata:
  name: red-widget
  namespace: default
spec:
  size: small
  replicas: 1
```

```bash
k apply -f red-widget.yaml
k get widgets
```

Why: once the CRD is applied, the API server serves the new kind exactly like a built-in — `get`, `describe`, jsonpath, short names, and RBAC all work. There is no imperative generator for arbitrary CRs, so you author the manifest by hand against the CRD's `openAPIV3Schema`. The CRD itself is cluster-scoped; the `Widget` instances are namespaced because `spec.scope: Namespaced`.

## Solution 11 — kubeconfig contexts

```bash
# 1. inspect
k config current-context           # kind-cka
k config get-contexts

# 2. create a new context reusing cluster + user, new default ns
k config set-context cka-alpha --cluster=kind-cka --user=kind-cka --namespace=team-alpha

# 3. switch and prove
k config use-context cka-alpha
k get pods                          # lists team-alpha (the scratch pod from Task 3)
k config view --minify -o jsonpath='{..namespace}{"\n"}'   # team-alpha

# 4. switch back
k config use-context kind-cka
```

Why: a context is just a named binding of an existing cluster + user + optional namespace; `set-context <name>` with those three flags creates it without touching credentials, and `use-context` activates it. `--minify` restricts `config view` to the active context, so the namespace it prints is the one in effect.

## Solution 12 — api-resources and explain superpowers

```bash
# 1. apiVersion + short name
k api-resources | egrep -i 'networkpolicy|horizontalpodautoscaler'
# networkpolicies          netpol   networking.k8s.io/v1   true   NetworkPolicy
# horizontalpodautoscalers hpa      autoscaling/v2         true   HorizontalPodAutoscaler

# 2. tolerations schema path
k explain pod --recursive | grep -i tolerations
# → pod.spec.tolerations
k explain pod.spec.tolerations

# 3. rollingUpdate fields
k explain deployment.spec.strategy.rollingUpdate

# 4. apps group kinds to file
k api-resources --api-group=apps -o name > /tmp/apps-kinds.txt
```

Why: `api-resources` is the offline map of every served type (name, short name, group/version, namespaced, kind); `explain --recursive | grep` locates any field's exact nesting without a doc tab; `--api-group` filters the map to one group (`apps` → deployments, replicasets, statefulsets, daemonsets).

## Solution 13 — HARD: a pod that will not schedule

```bash
# Diagnose from cluster state
k get pod stuck                        # STATUS Pending
k describe pod stuck | sed -n '/Events/,$p'
# Warning  FailedScheduling  ... 0/3 nodes are available:
#   3 node(s) didn't match Pod's node affinity/selector.
k get pod stuck -o jsonpath='{.spec.nodeSelector}{"\n"}'   # {"disktype":"ssd"}
k get nodes -L disktype                # no node carries disktype=ssd

# Fix WITHOUT touching the pod: satisfy the selector by labelling a node
k label node cka-worker disktype=ssd
k get pod stuck -w                      # → Running (Ctrl-C when Running)
```

Why: the pod was blocked at the scheduler **filter** stage — the `NodeAffinity` predicate (which also evaluates `nodeSelector`) eliminated every node because none matched `nodeSelector: disktype=ssd`, hence the `FailedScheduling` event ("didn't match Pod's node affinity/selector"). Since we may not edit the pod, we make a node satisfy the constraint by adding the missing label; the scheduler re-evaluates the still-Pending pod on its next cycle and binds it. One line: **the scheduler's node-filter predicate rejected all nodes for a nodeSelector mismatch.**

## Solution 14 — HARD: pod adoption, reaping, and the selector-immutability trap

```bash
# 1. Is web-legacy owned by / at risk from the Deployment's ReplicaSet?
k get pod web-legacy -o jsonpath='{.metadata.ownerReferences}{"\n"}'   # empty → no owner
k get rs -l app=web -o jsonpath='{.items[0].spec.selector}{"\n"}'
# {"matchLabels":{"app":"web","pod-template-hash":"6f8c9dcb5d"}}
```

**No — and not at risk.** A Deployment always builds its ReplicaSet's selector with the auto-generated `pod-template-hash` label (here `app=web,pod-template-hash=6f8c9dcb5d`), and every pod that RS creates carries the same hash. `web-legacy` has only `app=web` and **no** `pod-template-hash`, so it does **not** match the RS selector: the RS never sees it, never adopts it, and never reaps it. The `pod-template-hash` mechanism exists precisely to stop a Deployment's ReplicaSet from cross-adopting stray pods that merely share the app label. Confirm the non-event with `k describe rs -l app=web | sed -n '/Events/,$p'` — there is no adoption in the Events.

```bash
# 2. a BARE ReplicaSet whose selector really matches web-legacy
cat <<'EOF' | k apply -f -
apiVersion: apps/v1
kind: ReplicaSet
metadata:
  name: web-rs
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
EOF

k get pod web-legacy -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'   # ReplicaSet/web-rs
k get rs web-rs      # DESIRED 1, CURRENT 1 — web-legacy IS that replica
```

A hand-authored ReplicaSet's selector is exactly what you wrote — `app=web`, with **no** `pod-template-hash` — so it matches `web-legacy`. Because `web-legacy` matches the selector **and** has no controller `ownerReference`, the ReplicaSet **adopts** it: `web-legacy` now carries an `ownerReferences` entry pointing at `web-rs` and is counted as the one desired replica (so the RS creates no pod of its own). It is now genuinely **at risk** — `k scale rs web-rs --replicas=0` or `k delete rs web-rs` (default cascade) reaps `web-legacy` with it. This is the adoption/reaping the Deployment could never cause. (The Deployment's own hash-labelled pods do match `app=web`, but they already have a controller owner, so `web-rs` cannot claim them — overlapping bare-RS selectors are a documented footgun, not an adoption.)

```bash
# 3. retarget the selector — it is IMMUTABLE, so delete (orphaning) and recreate
k delete rs web-rs --cascade=orphan     # detaches web-legacy instead of reaping it
cat <<'EOF' | k apply -f -
apiVersion: apps/v1
kind: ReplicaSet
metadata:
  name: web-rs
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
      track: stable
  template:
    metadata:
      labels:
        app: web
        track: stable
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
EOF

# confirm
k get pods -l app=web,track=stable                                    # 2 Running, both labels (web-rs's fresh pods)
k get pod web-legacy -o jsonpath='{.metadata.ownerReferences}{"\n"}'  # empty again → orphaned and safe
```

Why: a ReplicaSet's `.spec.selector` is **immutable** — `k edit`/`k apply` a changed selector fails with `field is immutable`, so the only route is delete-and-recreate. Deleting with `--cascade=orphan` detaches the RS's pods (clearing their `ownerReferences`) instead of garbage-collecting them, which is what preserves the already-adopted `web-legacy`. The recreated `web-rs` selects `app=web,track=stable`; `web-legacy` (only `app=web`) no longer matches, so it is neither adopted nor counted, and `web-rs` spins up two fresh pods carrying both labels. The selector must equal the template labels or the API server rejects the object with `selector does not match template labels`.

## Solution 15 — HARD: break and restore the scheduler on kind

```bash
# 1. remove the scheduler manifest → kubelet stops the static pod
docker exec cka-control-plane mv /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/kube-scheduler.yaml
sleep 15
k get pods -n kube-system | grep scheduler        # gone

# 2. create a pod and watch it hang
k run orphan --image=nginx:1.27
k get pod orphan                                    # Pending
k describe pod orphan | sed -n '/Events/,$p'        # NO FailedScheduling event — total silence

# 3. restore
docker exec cka-control-plane mv /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/kube-scheduler.yaml
sleep 15
k get pods -n kube-system | grep scheduler          # Running again
k get pod orphan -w                                  # → Running (Ctrl-C when Running)
```

Why: the scheduler is a static pod; removing its manifest makes the kubelet tear the pod down, and with nothing evaluating unscheduled pods, `orphan` sits `Pending` with **no scheduling events at all**. Restoring the file makes the kubelet recreate the static pod within ~15s; the revived scheduler picks up the still-Pending pod and binds it. One line: **scheduler-down = `Pending` with zero `FailedScheduling` events (silence); no-node-fits = `Pending` with a `FailedScheduling` event naming the reason.**

---

Cleanup (optional, to reset the lab for the next module):

```bash
k delete pod web-01 once scratch web-logs initialized-web app-sidecar stuck orphan web-legacy --ignore-not-found $now
k delete rs web-rs --ignore-not-found
k delete deploy api frontend web --ignore-not-found
k delete widget blue-widget red-widget --ignore-not-found
k delete crd widgets.demo.cka.io --ignore-not-found
k delete ns team-alpha --ignore-not-found
k label node cka-worker disktype- 2>/dev/null
k config delete-context cka-alpha 2>/dev/null
k config use-context kind-cka
```
