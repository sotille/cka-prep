# Week 01 — Exercises: Architecture & Core Concepts

Lab setup: kind cluster `cka` running (`kind get clusters` shows `cka`; nodes `cka-control-plane`, `cka-worker`, `cka-worker2`), context `kind-cka` active, aliases loaded (`alias k=kubectl; export do="--dry-run=client -o yaml"; export now="--grace-period=0 --force"`). Tasks with pre-existing/broken state include a **Setup** fence — run it first, don't read it as part of the task. Time yourself for real: the target includes verification.

Exam flavor, once for the whole file: where a task says `docker exec -it <node> bash`, the real exam equivalent is `ssh <node>` then `sudo -i`.

---

## Task 1 — kubectl recon (warmup, 5 min)

Context: fresh cluster, namespace `default`.

1. List all nodes with their internal IPs, OS image, and container runtime version in one command.
2. Write the InternalIP of every node, space-separated, to `/tmp/node-ips.txt` using jsonpath.
3. List all pods in `kube-system` sorted by creation time, oldest first.
4. Print the name of the newest pod in `kube-system`.

## Task 2 — dry-run scaffolding (warmup, 4 min)

Context: namespace `default`.

1. Create a pod `web-01`, image `nginx:1.27`, exposing container port 80, with label `tier=frontend` — pure CLI, no file.
2. Generate (do not apply) a manifest for a Deployment `api` with image `httpd:2.4` and 3 replicas into `/tmp/api.yaml`, then apply it.
3. Generate a manifest for a pod `once` running `busybox:1.36` with command `sh -c "date; sleep 5"` that must run to completion exactly once (no restarts), save to `/tmp/once.yaml`, apply, and confirm its final phase is `Succeeded`.

## Task 3 — namespace operations (warmup, 4 min)

Context: nothing pre-exists.

1. Create namespace `team-alpha`.
2. Make `team-alpha` the default namespace for the current context; prove it with a config command.
3. Run a pod `scratch` (image `busybox:1.36`, command `sleep 3600`) without any `-n` flag and confirm it landed in `team-alpha`.
4. Write the list of all resource *types* that are NOT namespaced to `/tmp/cluster-scoped.txt`.
5. Reset the context default namespace to `default` (leave the pod running for later tasks).

## Task 4 — jsonpath and custom-columns (exam, 6 min)

Context: `kube-system` as shipped by kind.

1. Write every unique container image running in namespace `kube-system` to `/tmp/ks-images.txt`, one per line, sorted, no duplicates.
2. Using custom-columns, print two columns for all pods in `kube-system`: pod name and node it runs on, headers `POD` and `NODE`.
3. Print the kubelet version of each node using jsonpath only.

## Task 5 — multi-container pod, shared volume (exam, 8 min)

Context: namespace `default`.

Create a pod `web-logs` with two containers sharing an `emptyDir` volume named `logs`:

- Container `writer`: image `busybox:1.36`, appends the current date to `/data/out.log` every 2 seconds.
- Container `reader`: image `busybox:1.36`, runs `tail -F /data/out.log`.

Verify with pod logs that `reader` is streaming the dates written by `writer`.

## Task 6 — init container (exam, 6 min)

Context: namespace `default`.

Create a pod `initialized-web`: an init container `render` (image `busybox:1.36`) writes the text `week01` to `/work/index.html` on a shared `emptyDir`; the main container `web` (image `nginx:1.27`) serves that file from `/usr/share/nginx/html`. Verify by exec'ing a `cat` of the served file from inside `web`.

## Task 7 — native sidecar (exam, 8 min)

Context: namespace `default`.

Create a pod `app-sidecar` where:

- Main container `app` (image `busybox:1.36`) writes a timestamp to `/var/log/app/app.log` every 3 seconds.
- A **sidecar** container `shipper` (image `busybox:1.36`) runs `tail -F /var/log/app/app.log` and must be implemented so it starts **before** the main container and keeps running for the pod's lifetime (use the native sidecar mechanism, not a plain second container).

Verify: `k get pod app-sidecar` shows `2/2` READY, and `k logs app-sidecar -c shipper` shows the timestamps.

## Task 8 — deployment lifecycle under pressure (exam, 6 min)

Context: namespace `default`. Do the whole task CLI-only; no YAML files.

1. Create Deployment `release` image `nginx:1.26`, 2 replicas.
2. Scale to 5 replicas.
3. Update the image to `nginx:1.27` and record the change-cause annotation "bump to 1.27". Wait for the rollout to finish.
4. Update the image to `nginx:1.99-does-not-exist`. Observe what the rollout does.
5. Roll back to the last working version and prove (a) rollout is healthy, (b) the running image is `nginx:1.27`.

## Task 9 — pod lifecycle forensics (exam, 8 min)

Context: namespace `default`.

1. Create three pods, all running `sh -c "sleep 5; exit 1"` with image `busybox:1.36`, one per restartPolicy: `p-always` (Always), `p-onfailure` (OnFailure), `p-never` (Never).
2. Before checking: write down your prediction of each pod's `status.phase` and STATUS column ~2 minutes from now.
3. Verify with a `--field-selector` query which pods are in phase `Failed`, and with jsonpath print the restart count and last-state exit code of `p-always`.
4. Explain (one sentence each) why the three differ.

## Task 10 — the selector immutability wall (hard, 10 min)

Context: namespace `default`.

**Setup:**

```bash
k create deployment legacy-api --image=nginx:1.27 --replicas=2
```

Compliance requires every pod of `legacy-api` to carry the label `tier: backend`, and requires the Deployment's selector to match on **both** `app: legacy-api` and `tier: backend`.

1. Try to do it with `k edit deployment legacy-api` (change selector + template labels). Record the exact error you hit.
2. Achieve the required end state anyway, with the least disruption you can justify.
3. Prove: `k get deploy legacy-api -o jsonpath='{.spec.selector.matchLabels}'` shows both labels, pods carry both labels, 2/2 available.

## Task 11 — control-plane surgery on kind (hard, 12 min)

Context: whole cluster. This simulates the exam's "cluster X does not schedule pods" scenario.

1. Exec into the control-plane node and list the static pod manifests directory.
2. Break the scheduler: move `kube-scheduler.yaml` out of the manifests directory (e.g. to `/root/`). Confirm from outside that the scheduler mirror pod is gone.
3. Create a pod `victim` (image `nginx:1.27`). Describe the classic no-scheduler signature: what is the phase, and what do the events show?
4. Without fixing the scheduler, get a pod `bypass` (image `nginx:1.27`) running on `cka-worker` anyway.
5. Restore the scheduler, confirm the mirror pod returns, and confirm `victim` gets scheduled retroactively.

## Task 12 — crictl on a worker node (exam, 6 min)

Context: uses Deployment `api` from Task 2 (recreate it if gone: `k create deploy api --image=httpd:2.4 --replicas=3`).

1. Find which node one of the `api` pods runs on.
2. Exec into that node and, using only crictl (no kubectl): list the pod sandboxes, find the container belonging to that `api` pod, print its last 5 log lines, and list the `httpd` image with its tag.
3. Bonus: on the same node, check kubelet health the way you would on the exam (service status + last log lines).

## Task 13 — CRDs and custom resources (exam, 8 min)

Context: an "operator's" CRD is installed by the setup below (no controller behind it — inspection is the point).

**Setup:**

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: backups.stable.example.com
spec:
  group: stable.example.com
  scope: Namespaced
  names:
    plural: backups
    singular: backup
    kind: Backup
    shortNames:
      - bk
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
                source:
                  type: string
                schedule:
                  type: string
                retainDays:
                  type: integer
EOF
```

1. Without reading the setup fence: discover what CRDs exist on the cluster, and for this one determine its group, scope, shortnames, and served version — using kubectl only.
2. Use `k explain` to inspect the spec schema of the custom kind.
3. Create a `Backup` named `nightly-etcd` in namespace `default` with `source: etcd`, `schedule: "0 2 * * *"`, `retainDays: 7`.
4. List it three ways: by kind, by shortname, by fully-qualified plural.group. Then print just its `retainDays` with jsonpath.
5. One-sentence answer in `/tmp/operator.txt`: why does creating this Backup object cause no actual backup to run?

## Task 14 — kubeconfig contexts (exam, 5 min)

Context: single kind cluster, context `kind-cka`.

1. Create a new context `cka-alpha` that reuses the existing `kind-cka` cluster and user but defaults to namespace `team-alpha`.
2. Switch to it, and prove with a single command that both the context and its namespace are active.
3. From `cka-alpha`, list pods with no `-n` flag — you should see the `scratch` pod from Task 3.
4. Print the API server URL of the current context using `k config view` flags (no grep).
5. Switch back to `kind-cka`.

## Task 15 — delete a node and observe (hard, 10 min)

Context: whole cluster.

**Setup:**

```bash
k create deployment node-lab --image=nginx:1.27 --replicas=4
k rollout status deployment/node-lab
```

1. Record which `node-lab` pods run on `cka-worker2`.
2. Delete the Node object `cka-worker2` (the object, not the container). Watch what happens to those pods and where the Deployment's replacement pods land. Explain which controllers did what.
3. Bring `cka-worker2` back into the cluster (hint: the kubelet self-registers; you control the node's "machine" with docker) and verify it becomes `Ready` and receives its DaemonSet pods (`kindnet`, `kube-proxy`) again.
4. Cleanup: `k delete deploy node-lab api release legacy-api web-logs 2>/dev/null; k delete pod web-01 app-sidecar initialized-web p-always p-onfailure p-never victim bypass $now 2>/dev/null; k delete ns team-alpha`.

---

# SOLUTIONS

## Solution 1 — kubectl recon

```bash
# 1 — -o wide carries INTERNAL-IP, OS-IMAGE, CONTAINER-RUNTIME
k get nodes -o wide

# 2
k get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' > /tmp/node-ips.txt

# 3
k get pods -n kube-system --sort-by=.metadata.creationTimestamp

# 4 — newest = last line of the oldest-first sort
k get pods -n kube-system --sort-by=.metadata.creationTimestamp -o name | tail -1
```

Why: `--sort-by` takes a jsonpath; combining it with `-o name | tail -1` answers "newest/oldest X" questions without reading timestamps.

## Solution 2 — dry-run scaffolding

```bash
# 1
k run web-01 --image=nginx:1.27 --port=80 --labels=tier=frontend

# 2
k create deployment api --image=httpd:2.4 --replicas=3 $do > /tmp/api.yaml
k apply -f /tmp/api.yaml

# 3 — --restart=Never is the load-bearing flag
k run once --image=busybox:1.36 --restart=Never $do -- sh -c "date; sleep 5" > /tmp/once.yaml
k apply -f /tmp/once.yaml
sleep 8 && k get pod once -o jsonpath='{.status.phase}{"\n"}'   # Succeeded
```

Generated `/tmp/once.yaml` (for reference):

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

Why: with the default `restartPolicy: Always` the pod would restart after exit 0 forever (CrashLoopBackOff on success) and never reach `Succeeded`.

## Solution 3 — namespace operations

```bash
# 1
k create namespace team-alpha

# 2
k config set-context --current --namespace=team-alpha
k config get-contexts        # NAMESPACE column shows team-alpha on the * row

# 3
k run scratch --image=busybox:1.36 -- sleep 3600
k get pod scratch -o jsonpath='{.metadata.namespace}{"\n"}'   # team-alpha

# 4
k api-resources --namespaced=false -o name > /tmp/cluster-scoped.txt

# 5
k config set-context --current --namespace=default
```

Why: resources follow the *context's* namespace, not `default` — this is the mechanic behind "my pod disappeared" traps.

## Solution 4 — jsonpath and custom-columns

```bash
# 1 — tr splits the space-separated jsonpath output into lines
k get pods -n kube-system -o jsonpath='{.items[*].spec.containers[*].image}' \
  | tr ' ' '\n' | sort -u > /tmp/ks-images.txt
cat /tmp/ks-images.txt

# 2
k get pods -n kube-system -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName

# 3
k get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.kubeletVersion}{"\n"}{end}'
```

Why: `jsonpath | tr | sort -u` is the canonical "unique images to a file" answer; the range/end form gives you line-per-item output for any list.

## Solution 5 — multi-container pod, shared volume

```bash
k run web-logs --image=busybox:1.36 $do -- sh -c 'while true; do date >> /data/out.log; sleep 2; done' > /tmp/web-logs.yaml
# edit: rename container to writer, add volume + second container
vim /tmp/web-logs.yaml
```

Final manifest:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web-logs
spec:
  volumes:
    - name: logs
      emptyDir: {}
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
```

```bash
k apply -f /tmp/web-logs.yaml
k get pod web-logs            # 2/2 Running
k logs web-logs -c reader     # streaming dates
```

Why: containers never share a filesystem implicitly — the emptyDir mount on both sides is the whole pattern; `-c` selects the container for logs/exec.

## Solution 6 — init container

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: initialized-web
spec:
  volumes:
    - name: workdir
      emptyDir: {}
  initContainers:
    - name: render
      image: busybox:1.36
      command: ["sh", "-c", "echo week01 > /work/index.html"]
      volumeMounts:
        - name: workdir
          mountPath: /work
  containers:
    - name: web
      image: nginx:1.27
      volumeMounts:
        - name: workdir
          mountPath: /usr/share/nginx/html
```

```bash
k apply -f /tmp/initialized-web.yaml
k get pod initialized-web             # watch Init:0/1 -> PodInitializing -> Running
k exec initialized-web -c web -- cat /usr/share/nginx/html/index.html   # week01
```

Why: the init container runs to completion before `web` starts; the emptyDir outlives it, handing off the rendered file.

## Solution 7 — native sidecar

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-sidecar
spec:
  volumes:
    - name: applog
      emptyDir: {}
  initContainers:
    - name: shipper
      image: busybox:1.36
      restartPolicy: Always        # <- this one field turns an init container into a sidecar
      command: ["sh", "-c", "tail -F /var/log/app/app.log"]
      volumeMounts:
        - name: applog
          mountPath: /var/log/app
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "while true; do date >> /var/log/app/app.log; sleep 3; done"]
      volumeMounts:
        - name: applog
          mountPath: /var/log/app
```

```bash
k apply -f /tmp/app-sidecar.yaml
k get pod app-sidecar                 # 2/2 Running (sidecar counts in READY)
k logs app-sidecar -c shipper         # timestamps
```

Why: `initContainers` + `restartPolicy: Always` is the native sidecar (beta/on-by-default v1.29, stable v1.33): guaranteed start-before-app, runs for pod lifetime, restarts independently. A plain second container would give no ordering guarantee.

## Solution 8 — deployment lifecycle under pressure

```bash
# 1
k create deployment release --image=nginx:1.26 --replicas=2

# 2
k scale deployment release --replicas=5

# 3
k set image deployment/release nginx=nginx:1.27
k annotate deployment/release kubernetes.io/change-cause="bump to 1.27"
k rollout status deployment/release

# 4 — rollout starts, new RS pods stuck ImagePullBackOff, rollout status hangs;
#     old pods keep serving because maxUnavailable=25% throttles the teardown
k set image deployment/release nginx=nginx:1.99-does-not-exist
k get pods -l app=release             # mix of Running (old RS) and ImagePullBackOff (new RS)
k rollout status deployment/release   # ctrl+c after observing it stall

# 5
k rollout undo deployment/release
k rollout status deployment/release   # successfully rolled out
k get deployment release -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'   # nginx:1.27
k rollout history deployment/release  # note: undo created a NEW revision
```

Why: a rollback is just re-promoting the previous ReplicaSet's template — which is also why a botched rollout never takes down all replicas: the old RS is still there, still scaled.

## Solution 9 — pod lifecycle forensics

```bash
# 1
k run p-always --image=busybox:1.36 --restart=Always -- sh -c "sleep 5; exit 1"
k run p-onfailure --image=busybox:1.36 --restart=OnFailure -- sh -c "sleep 5; exit 1"
k run p-never --image=busybox:1.36 --restart=Never -- sh -c "sleep 5; exit 1"

# wait ~2 min, then:
k get pods p-always p-onfailure p-never
# p-always     0/1  CrashLoopBackOff  (phase: Running)
# p-onfailure  0/1  CrashLoopBackOff  (phase: Running)
# p-never      0/1  Error             (phase: Failed)

# 3
k get pods --field-selector=status.phase=Failed          # only p-never
k get pod p-always -o jsonpath='restarts={.status.containerStatuses[0].restartCount} lastExit={.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'
```

Why, one sentence each:

- `p-always`: Always restarts on any exit, so the pod stays phase `Running` while cycling through exponential backoff (`CrashLoopBackOff` is a container waiting-reason, not a phase).
- `p-onfailure`: identical here because the exit code is non-zero; it would differ on exit 0 (pod would go `Succeeded`).
- `p-never`: no restart is ever attempted, all containers terminated with non-zero, so the pod reaches terminal phase `Failed` (STATUS shows `Error`).

## Solution 10 — the selector immutability wall

```bash
# 1 — the attempt
k edit deployment legacy-api
# change .spec.selector.matchLabels and .spec.template.metadata.labels to add tier: backend, save
# -> rejected: "spec.selector: Invalid value: ... field is immutable"

# 2 — the accepted fix: recreate with the corrected spec
k get deployment legacy-api -o yaml > /tmp/legacy-api.yaml
vim /tmp/legacy-api.yaml   # add tier: backend to BOTH selector.matchLabels and template.metadata.labels;
                           # strip status:, metadata.uid/resourceVersion/creationTimestamp/generation
k delete deployment legacy-api
k apply -f /tmp/legacy-api.yaml
```

Corrected manifest (cleaned):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: legacy-api
  labels:
    app: legacy-api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: legacy-api
      tier: backend
  template:
    metadata:
      labels:
        app: legacy-api
        tier: backend
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
```

```bash
# 3
k get deploy legacy-api -o jsonpath='{.spec.selector.matchLabels}{"\n"}'   # {"app":"legacy-api","tier":"backend"}
k get pods -l app=legacy-api,tier=backend                                  # 2 pods Running
k get deploy legacy-api                                                    # 2/2 AVAILABLE
```

Why: `apps/v1` selectors are immutable by design (mutable selectors orphan pods), so the only paths are recreate (brief downtime — exam-acceptable) or a parallel second Deployment then delete the old one (zero downtime — mention it if the task forbids downtime). One-liner alternative to delete+apply: `k replace --force -f /tmp/legacy-api.yaml`. Note `--cascade=orphan` does NOT give a clean zero-downtime path here: the new ReplicaSet's selector includes a fresh `pod-template-hash`, so it will not adopt the orphans and you would leak unmanaged pods.

## Solution 11 — control-plane surgery on kind

```bash
# 1
docker exec -it cka-control-plane bash
ls /etc/kubernetes/manifests
# etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml

# 2 (inside the node)
mv /etc/kubernetes/manifests/kube-scheduler.yaml /root/kube-scheduler.yaml
exit
# outside — kubelet noticed the file vanish and killed the static pod within seconds:
k get pods -n kube-system | grep scheduler        # gone

# 3
k run victim --image=nginx:1.27
k get pod victim                                   # Pending
k describe pod victim | tail -5                    # Events: <none>  <- the signature
# Pending + ZERO events = nothing tried to schedule it = scheduler is down.
```

Step 4 — scheduling is just setting `spec.nodeName`; do it yourself:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: bypass
spec:
  nodeName: cka-worker
  containers:
    - name: web
      image: nginx:1.27
```

```bash
k apply -f /tmp/bypass.yaml
k get pod bypass -o wide       # Running on cka-worker, no scheduler involved

# 5
docker exec cka-control-plane mv /root/kube-scheduler.yaml /etc/kubernetes/manifests/kube-scheduler.yaml
k get pods -n kube-system | grep scheduler   # kube-scheduler-cka-control-plane Running (mirror pod is back)
k get pod victim -o wide                      # now scheduled and Running — the watch queue drained retroactively
```

Why: static pods are managed purely by kubelet file-watch on `staticPodPath`; a pod with `nodeName` preset skips the scheduler entirely, which is both the workaround and the proof of diagnosis.

## Solution 12 — crictl on a worker node

```bash
# 1
k get pods -l app=api -o wide     # note NODE column, e.g. cka-worker

# 2
docker exec -it cka-worker bash
crictl pods --name api                          # sandbox list, grab the POD ID if needed
crictl ps | grep api                            # container ID for the httpd container
crictl logs --tail=5 <container-id>
crictl images | grep httpd                      # docker.io/library/httpd  2.4
exit

# 3 — bonus, inside the node
docker exec -it cka-worker bash
systemctl status kubelet --no-pager | head -5   # active (running)
journalctl -u kubelet --no-pager | tail -20
exit
```

Why: when kubectl is unavailable or lying (API down, kubelet sick), `crictl ps/pods/logs` against the containerd socket is the ground truth; `crictl ps -a` additionally shows crashed containers that `crictl ps` hides.

## Solution 13 — CRDs and custom resources

```bash
# 1
k get crds                                            # backups.stable.example.com
k get crd backups.stable.example.com -o yaml | head -30   # group, scope: Namespaced, versions
k api-resources | grep stable.example.com             # backups  bk  stable.example.com/v1  true  Backup

# 2
k explain backup.spec            # shows source, schedule, retainDays from the CRD schema
k explain backup --recursive     # full tree
```

```yaml
apiVersion: stable.example.com/v1
kind: Backup
metadata:
  name: nightly-etcd
  namespace: default
spec:
  source: etcd
  schedule: "0 2 * * *"
  retainDays: 7
```

```bash
k apply -f /tmp/backup.yaml

# 4
k get backup
k get bk
k get backups.stable.example.com
k get backup nightly-etcd -o jsonpath='{.spec.retainDays}{"\n"}'   # 7

# 5
echo "A CRD only registers the API type; without an operator/controller watching Backup objects and reconciling them, nothing acts on the stored spec." > /tmp/operator.txt
```

Why: the CRD gives you storage, validation, and kubectl support for a new kind — behavior requires a controller; `<plural>.<group>` is the collision-proof way to address any resource type.

## Solution 14 — kubeconfig contexts

```bash
# 1 — reuse cluster+user names exactly as they appear in `k config get-contexts`
k config set-context cka-alpha --cluster=kind-cka --user=kind-cka --namespace=team-alpha

# 2
k config use-context cka-alpha
k config get-contexts            # * on cka-alpha, NAMESPACE=team-alpha

# 3
k get pods                       # scratch pod, no -n needed

# 4
k config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'

# 5
k config use-context kind-cka
```

Why: a context is only a named (cluster, user, namespace) tuple — creating one costs nothing and `--minify` scopes `config view` to the active context, making jsonpath extraction deterministic.

## Solution 15 — delete a node and observe

```bash
# 1
k get pods -l app=node-lab -o wide | grep cka-worker2

# 2
k delete node cka-worker2
k get pods -l app=node-lab -o wide -w    # old pods on worker2 disappear; replacements appear on cka-worker
```

What did what: deleting the Node object makes the pod garbage collector (in kube-controller-manager) delete pods bound to a nonexistent node; the ReplicaSet controller sees replicas < desired and creates replacements; the scheduler binds them to the only remaining worker. Note the kubelet process on `cka-worker2` is still running — only the API object is gone.

```bash
# 3 — restart the "machine"; on restart the kubelet self-registers (--register-node defaults to true)
docker restart cka-worker2
k get nodes -w                            # cka-worker2 reappears, NotReady -> Ready
k get pods -n kube-system -o wide | grep cka-worker2   # kindnet + kube-proxy DaemonSet pods recreated
```

Why: node identity is just an API object continuously asserted by the kubelet; DaemonSet pods return automatically because the DaemonSet controller targets *nodes*, while the rescheduled Deployment pods stay where they are — Kubernetes never rebalances running pods on node re-join (that asymmetry is a favorite exam misconception).

```bash
# 4 — cleanup
k delete deploy node-lab api release legacy-api web-logs 2>/dev/null
k delete pod web-01 app-sidecar initialized-web p-always p-onfailure p-never victim bypass once $now 2>/dev/null
k delete ns team-alpha
k delete crd backups.stable.example.com
```
