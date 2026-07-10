# Week 04 Exercises — Pod Lifecycle & Observability

Lab: the 3-node kind cluster `cka` (context `kind-cka`; nodes `cka-control-plane`, `cka-worker`, `cka-worker2`). Aliases assumed: `alias k=kubectl`, `export do="--dry-run=client -o yaml"`, `export now="--grace-period=0 --force"`. Node access on kind is `docker exec -it <node> bash`; on the real exam it is `ssh <node>` followed by `sudo -i` — a per-task note flags other differences.

Prereqs: a few tasks pull public images (`nginx:1.27`, `busybox:1.36`, `polinux/stress`, `gcr.io/google-samples/hello-app:1.0`) — have internet the first time. Task 8 and the `top` parts of task 15 require **metrics-server** installed (see the masterclass "metrics-server & kubectl top" section, or the setup fence in task 8). Run each task's setup fence first; clean up namespaces with `k delete ns <name>` when done.

Difficulty: warmup / exam / hard. Hard-mode tasks are 6, 11, and 15.

---

## Task 1 — readiness probe basics (warmup, 4 min)

Context: namespace `probes` (created in setup). A deployment `web` (3 replicas, `nginx:1.27`) exists but has no health checks.

Setup:

```bash
k create ns probes
k -n probes create deployment web --image=nginx:1.27 --replicas=3
k -n probes rollout status deploy/web
```

Add an HTTP readiness probe to `web`: GET `/` on port 80, first check after 5s, every 5s. Confirm all 3 pods report `READY 1/1`. Then explain (one sentence) what a readiness failure would do versus a liveness failure.

## Task 2 — probe set for a slow-starting app (exam, 8 min)

Context: namespace `slow` (created in setup). The app takes ~30s before it listens on port 80. It currently has a liveness probe with no startup probe and is stuck restarting.

Setup:

```bash
k create ns slow
cat <<'EOF' | k apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: slowapp
  namespace: slow
spec:
  replicas: 1
  selector:
    matchLabels: { app: slowapp }
  template:
    metadata:
      labels: { app: slowapp }
    spec:
      containers:
      - name: app
        image: nginx:1.27
        command: ["sh","-c","sleep 30 && nginx -g 'daemon off;'"]
        ports:
        - containerPort: 80
        livenessProbe:
          httpGet: { path: /, port: 80 }
          periodSeconds: 5
          failureThreshold: 3
EOF
```

Watch it restart-loop for a minute (`k -n slow get pod -w`). Then fix it so the app boots cleanly: add a **startup probe** that tolerates up to ~60s of boot, keep a tight liveness probe that only starts after boot, and add a readiness probe. The pod must reach `READY 1/1` without any restarts after the fix.

## Task 3 — fix a restart loop caused by a bad liveness probe (exam, 6 min)

Context: namespace `badlive` (created in setup). A pod restarts constantly even though the app is healthy.

Setup:

```bash
k create ns badlive
cat <<'EOF' | k apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: bad-liveness
  namespace: badlive
spec:
  containers:
  - name: web
    image: nginx:1.27
    ports:
    - containerPort: 80
    livenessProbe:
      httpGet: { path: /healthz, port: 8080 }
      initialDelaySeconds: 3
      periodSeconds: 5
EOF
```

The pod's `RESTARTS` count climbs. Diagnose *why* (nginx serves `/` on port 80, not `/healthz` on 8080), then fix the liveness probe so the pod stops restarting. Prove the restart count stabilises.

## Task 4 — CrashLoopBackOff: bad command (exam, 5 min)

Context: namespace `crash1` (created in setup).

Setup:

```bash
k create ns crash1
k -n crash1 run badcmd --image=busybox:1.36 --restart=Always -- sleeep 3600
```

`badcmd` is in `CrashLoopBackOff`. Find the root cause from events/status (not by guessing), state the exit code and what it means, then fix the pod so it runs. Constraint: the container must run `sleep 3600`.

## Task 5 — CreateContainerConfigError: missing ConfigMap (exam, 6 min)

Context: namespace `crash2` (created in setup).

Setup:

```bash
k create ns crash2
cat <<'EOF' | k apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: needs-config
  namespace: crash2
spec:
  containers:
  - name: app
    image: nginx:1.27
    envFrom:
    - configMapRef:
        name: app-config
EOF
```

The pod won't start. Identify the exact reason (which object is missing) from the pod's status/events, then fix it by creating the missing ConfigMap with a key `APP_MODE=prod`. The pod must reach `Running`.

## Task 6 — CrashLoopBackOff: OOMKilled (hard, 9 min)

Context: namespace `crash3` (created in setup). Pulls `polinux/stress`.

Setup:

```bash
k create ns crash3
cat <<'EOF' | k apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: hungry
  namespace: crash3
spec:
  containers:
  - name: stress
    image: polinux/stress
    command: ["stress"]
    args: ["--vm","1","--vm-bytes","150M","--vm-hang","1"]
    resources:
      limits:
        memory: "100Mi"
      requests:
        memory: "100Mi"
EOF
```

`hungry` keeps dying. Prove it is being **OOMKilled** (show the exit code and the terminated reason from the pod object, not just `describe`). The app legitimately needs ~150Mi. Fix the pod so it runs stably. State why raising `initialDelaySeconds` or touching probes would NOT have helped.

## Task 7 — multi-container logs with --previous (exam, 6 min)

Context: namespace `multi` (created in setup). A pod has two containers; the sidecar crashes.

Setup:

```bash
k create ns multi
cat <<'EOF' | k apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: twocon
  namespace: multi
spec:
  containers:
  - name: web
    image: nginx:1.27
  - name: sidecar
    image: busybox:1.36
    command: ["sh","-c","echo SIDECAR-BOOTED-$(date +%s); sleep 3; exit 1"]
EOF
```

The `sidecar` container is restarting. Without following live, capture the log output of the **previous (crashed) instance** of the `sidecar` container and save it to `/opt/sidecar-prev.log`. Confirm the file contains the `SIDECAR-BOOTED-` line. (Then, separately, show the one command that would dump logs from *both* containers at once.)

## Task 8 — highest-CPU pod to a file with kubectl top (exam, 6 min)

Context: namespace `topns` (created in setup). Requires metrics-server.

Setup:

```bash
# metrics-server (skip if already installed). On kind you MUST add --kubelet-insecure-tls.
k apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
k -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
k -n kube-system rollout status deploy/metrics-server

# workloads: one CPU burner + two idle pods
k create ns topns
k -n topns run burner --image=busybox:1.36 --restart=Never -- sh -c "md5sum /dev/zero"
k -n topns run idle1 --image=nginx:1.27
k -n topns run idle2 --image=nginx:1.27
sleep 60   # let metrics-server collect a scrape window
```

Determine the pod in namespace `topns` consuming the most CPU and write **only its name** (nothing else) to `/opt/highest-cpu.txt`. Verify the file's contents.

## Task 9 — node InternalIPs via jsonpath (warmup, 4 min)

Context: cluster-wide.

Using a single `kubectl` command with jsonpath, extract the `InternalIP` of every node and write them to `/opt/node-ips.txt`, one IP per line. Then, separately, print just `cka-worker`'s InternalIP.

## Task 10 — all pod images across namespaces, sorted (exam, 6 min)

Context: cluster-wide.

Produce a **deduplicated, sorted** list of every container image running in the cluster (all namespaces) and write it to `/opt/all-images.txt`, one image per line. Do it with `-o custom-columns` (or jsonpath) plus standard shell — no manual editing.

## Task 11 — ephemeral debug into a distroless pod (hard, 8 min)

Context: namespace `dbg` (created in setup). The app image has no shell.

Setup:

```bash
k create ns dbg
k -n dbg run hello --image=gcr.io/google-samples/hello-app:1.0 --port=8080
k -n dbg wait --for=condition=Ready pod/hello --timeout=90s
```

`k -n dbg exec hello -- sh` fails — the image is distroless. Using `kubectl debug`, attach an ephemeral `busybox:1.36` container to the running `hello` pod and confirm the app answers on `127.0.0.1:8080` from *inside* the pod's network namespace. Capture the HTTP response body. Then show the command that lists the ephemeral container(s) now attached to the pod.

## Task 12 — node debug: read a file from the host (exam, 6 min)

Context: node `cka-control-plane`. No SSH assumed — use `kubectl debug node/`.

Without `docker exec` and without SSH, launch a debug pod on `cka-control-plane` and read the node's OS pretty name from `/etc/os-release`. Write the node's OS `PRETTY_NAME` value to `/opt/node-os.txt`. Also report how many static pod manifests exist in the node's `/etc/kubernetes/manifests` directory.

Exam flavor: identical on the exam; the node name changes and you'd typically also be allowed to `ssh` — `kubectl debug node/` is the fallback when you aren't.

## Task 13 — graceful termination with preStop (exam, 6 min)

Context: namespace `grace` (created in setup).

Setup:

```bash
k create ns grace
k -n grace create deployment fe --image=nginx:1.27 --replicas=2
k -n grace rollout status deploy/fe
```

Reconfigure `fe` so that on pod shutdown it drains connections cleanly: add a `preStop` hook that sleeps 10 seconds and set `terminationGracePeriodSeconds` to 30. Verify the settings are present on the running pods, then delete one pod and observe that it stays `Terminating` for ~10s (the preStop sleep) before disappearing.

## Task 14 — rollout, history, and undo to a revision (exam, 8 min)

Context: namespace `roll` (created in setup).

Setup:

```bash
k create ns roll
k -n roll create deployment api --image=nginx:1.24
k -n roll annotate deploy/api kubernetes.io/change-cause="init 1.24" --overwrite
k -n roll rollout status deploy/api
```

Perform: (1) update the image to `nginx:1.25` with change-cause "bump 1.25"; (2) update to `nginx:1.26` with change-cause "bump 1.26"; (3) show the rollout history — you should see 3 revisions with their change-causes; (4) roll back to the revision running `nginx:1.24` using `--to-revision`; (5) verify the deployment's container image is `nginx:1.24` again and the rollout is complete.

## Task 15 — full triage chain: stuck rollout, Ready 0/1 (hard, 12 min)

Context: namespace `stuck` (created in setup). A rollout is wedged.

Setup:

```bash
k create ns stuck
k -n stuck create deployment shop --image=nginx:1.27 --replicas=3
k -n stuck rollout status deploy/shop
# now ship a "new version" with a broken readiness probe
cat <<'EOF' | k apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
  namespace: stuck
spec:
  replicas: 3
  selector:
    matchLabels: { app: shop }
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }
  template:
    metadata:
      labels: { app: shop }
    spec:
      containers:
      - name: nginx
        image: nginx:1.27
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet: { path: /ready, port: 8080 }
          periodSeconds: 5
EOF
```

`k -n stuck rollout status deploy/shop` never returns. Diagnose the whole chain: why is the rollout stuck, what state are the new pods in (`READY`? `STATUS`?), and what is the specific misconfiguration? Fix it so the rollout completes with all pods `READY 1/1`. Then, using `kubectl top`, report which `shop` pod is using the most memory (metrics-server required).

---

# SOLUTIONS

## Solution 1 — readiness probe basics

Patch the deployment's container with a readiness probe (edit or patch). Cleanest via `k edit`, or a strategic patch:

```bash
k -n probes patch deployment web --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/readinessProbe","value":
    {"httpGet":{"path":"/","port":80},"initialDelaySeconds":5,"periodSeconds":5}}
]'
k -n probes rollout status deploy/web
k -n probes get pods
```

The container spec after the patch (what `k edit` would show):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: probes
spec:
  replicas: 3
  selector:
    matchLabels: { app: web }
  template:
    metadata:
      labels: { app: web }
    spec:
      containers:
      - name: nginx
        image: nginx:1.27
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5
```

Why: a **readiness** failure removes the pod from the Service's endpoints (no traffic) but does **not** restart it; a **liveness** failure restarts the container.

## Solution 2 — probe set for a slow-starting app

Add a startup probe (up to ~60s: `failureThreshold: 12 × periodSeconds: 5`), a liveness probe (runs only after startup passes), and a readiness probe. Apply the corrected Deployment:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: slowapp
  namespace: slow
spec:
  replicas: 1
  selector:
    matchLabels: { app: slowapp }
  template:
    metadata:
      labels: { app: slowapp }
    spec:
      containers:
      - name: app
        image: nginx:1.27
        command: ["sh","-c","sleep 30 && nginx -g 'daemon off;'"]
        ports:
        - containerPort: 80
        startupProbe:
          httpGet: { path: /, port: 80 }
          periodSeconds: 5
          failureThreshold: 12      # ~60s boot budget
        livenessProbe:
          httpGet: { path: /, port: 80 }
          periodSeconds: 5
          failureThreshold: 3
        readinessProbe:
          httpGet: { path: /, port: 80 }
          periodSeconds: 5
```

```bash
k apply -f slowapp.yaml
k -n slow get pod -w      # reaches 1/1 after ~30s, RESTARTS stays 0
```

Why: while the startup probe runs, liveness/readiness are suspended, so the 30s boot can't trip the liveness probe — the restart loop disappears and detection stays tight once up.

## Solution 3 — fix a restart loop from a bad liveness probe

Diagnose:

```bash
k -n badlive describe pod bad-liveness | sed -n '/Events/,$p'
# Warning  Unhealthy  ... Liveness probe failed: HTTP probe failed with statuscode: ... / connection refused
k -n badlive get pod bad-liveness    # RESTARTS climbing
```

The probe hits `/healthz:8080`; nginx serves `/` on `80`. A running pod's `livenessProbe` is **immutable** — `k edit`/`k patch` on the probe is rejected (`Pod "bad-liveness" is invalid: spec: Forbidden: pod updates may not change fields other than spec.containers[*].image, ...`). Delete and recreate the pod with the corrected probe (`path: /`, `port: 80`):

```bash
k -n badlive delete pod bad-liveness --now
```

Recreate with the fixed livenessProbe:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: bad-liveness
  namespace: badlive
spec:
  containers:
  - name: web
    image: nginx:1.27
    ports:
    - containerPort: 80
    livenessProbe:
      httpGet:
        path: /
        port: 80
      initialDelaySeconds: 3
      periodSeconds: 5
```

```bash
k -n badlive apply -f bad-liveness.yaml
k -n badlive get pod bad-liveness -w   # RESTARTS stops incrementing
```

Why: the liveness probe was checking an endpoint the app never serves, so every check failed and the kubelet kept restarting a perfectly healthy container.

## Solution 4 — CrashLoopBackOff: bad command

```bash
k -n crash1 describe pod badcmd | sed -n '/State/,/Events/p'
# Last State: Terminated  Reason: StartError, Exit Code: 128
k -n crash1 get pod badcmd -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}{" "}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
# 128 StartError
```

Exit **128** with reason **StartError** = containerd could not start the container because the binary doesn't exist (`exec: "sleeep": executable file not found in $PATH`) — `sleeep` is a typo. (127 "command not found" only appears when a *shell* runs the bad command; a direct exec of a missing binary surfaces as 128/StartError.) Fix by recreating with the correct command (a pod's `command` is immutable, so delete + recreate):

```bash
k -n crash1 delete pod badcmd --now
k -n crash1 run badcmd --image=busybox:1.36 --restart=Always -- sleep 3600
k -n crash1 get pod badcmd    # Running
```

Why: the container never started because `sleeep` isn't a binary — containerd fails the exec with `reason: StartError` and exit 128; correcting the command to `sleep` fixes it.

## Solution 5 — CreateContainerConfigError: missing ConfigMap

```bash
k -n crash2 describe pod needs-config | sed -n '/Events/,$p'
# Warning  Failed  ... Error: configmap "app-config" not found
k -n crash2 get pod needs-config     # STATUS: CreateContainerConfigError
```

The `envFrom` references ConfigMap `app-config`, which doesn't exist. Create it:

```bash
k -n crash2 create configmap app-config --from-literal=APP_MODE=prod
k -n crash2 get pod needs-config -w   # transitions to Running once the CM exists
```

Why: `CreateContainerConfigError` means a referenced config object is missing; the kubelet retries and succeeds the moment the ConfigMap is created (no pod recreate needed).

## Solution 6 — CrashLoopBackOff: OOMKilled

Prove OOM from the object, not just describe:

```bash
k -n crash3 get pod hungry -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}{" "}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
# 137 OOMKilled
```

Exit **137** (128+9, SIGKILL) with reason **OOMKilled** = the container exceeded `limits.memory`. It asks for 150M but is capped at 100Mi. Raise the limit above the working set:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hungry
  namespace: crash3
spec:
  containers:
  - name: stress
    image: polinux/stress
    command: ["stress"]
    args: ["--vm","1","--vm-bytes","150M","--vm-hang","1"]
    resources:
      limits:
        memory: "200Mi"
      requests:
        memory: "150Mi"
```

```bash
k -n crash3 delete pod hungry --now
k -n crash3 apply -f hungry.yaml
k -n crash3 get pod hungry -w    # stays Running, RESTARTS 0
```

Why: it's a **resources** problem, not a health-check one — the cgroup OOM killer terminated the process for exceeding the memory limit, so probes/`initialDelaySeconds` are irrelevant; the fix is a limit that fits the workload.

## Solution 7 — multi-container logs with --previous

```bash
k -n multi logs twocon -c sidecar --previous > /opt/sidecar-prev.log
cat /opt/sidecar-prev.log      # contains SIDECAR-BOOTED-<epoch>
grep SIDECAR-BOOTED /opt/sidecar-prev.log
```

Dump both containers at once:

```bash
k -n multi logs twocon --all-containers=true
```

Why: the sidecar's *current* container may be mid-backoff, so `--previous` reads the last dead instance's logs where the boot line lives; `-c sidecar` is required because the pod is multi-container.

## Solution 8 — highest-CPU pod to a file

```bash
k top pods -n topns --sort-by=cpu --no-headers | head -1 | awk '{print $1}' > /opt/highest-cpu.txt
cat /opt/highest-cpu.txt        # -> burner
```

If `k top` says metrics aren't available yet, wait ~30–60s and retry (metrics-server needs a scrape window).

Why: `k top --sort-by=cpu` orders the table **descending** by CPU, so the top consumer (`burner`, running `md5sum /dev/zero`) is the **first** row; `--no-headers` + `head -1` + `awk '{print $1}'` extracts exactly the name. (Note: `kubectl get --sort-by` is ascending, but `kubectl top --sort-by` is descending — don't conflate them.)

## Solution 9 — node InternalIPs via jsonpath

```bash
k get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' > /opt/node-ips.txt
cat /opt/node-ips.txt

# just cka-worker's InternalIP:
k get node cka-worker -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}'
```

Why: the `[?(@.type=="InternalIP")]` filter selects the InternalIP element from each node's `addresses` array; `{range}…{end}` with a `{"\n"}` literal puts one IP per line.

## Solution 10 — all pod images across namespaces, sorted

```bash
k get pods -A -o custom-columns=IMAGE:.spec.containers[*].image --no-headers \
  | tr -s ' ' '\n' | tr ',' '\n' | sort -u > /opt/all-images.txt
cat /opt/all-images.txt
```

Equivalent with jsonpath:

```bash
k get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sort -u > /opt/all-images.txt
```

Why: `custom-columns` with `[*]` expands each pod's images (comma-joined); splitting on spaces/commas and `sort -u` yields the deduplicated, sorted list — no manual editing.

## Solution 11 — ephemeral debug into a distroless pod

```bash
# Attach an ephemeral busybox and curl the app from inside the pod's netns:
k -n dbg debug -it hello --image=busybox:1.36 -- wget -qO- 127.0.0.1:8080
# -> Hello, world! / Version: 1.0.0 / Hostname: hello

# Or drop into a shell and probe interactively:
k -n dbg debug -it hello --image=busybox:1.36 -- sh
#   / # wget -qO- 127.0.0.1:8080

# List the ephemeral container(s) now on the pod:
k -n dbg get pod hello -o jsonpath='{.spec.ephemeralContainers[*].name}{"\n"}'
```

Why: the distroless image has no shell, so `exec` can't help; `kubectl debug` injects an ephemeral busybox that shares the pod's network namespace, so `127.0.0.1:8080` reaches the app without restarting or modifying it.

## Solution 12 — node debug: read a file from the host

```bash
# Launch a debug pod on the node; host root is mounted at /host
k debug node/cka-control-plane -it --image=busybox:1.36 -- sh
#  / # grep PRETTY_NAME /host/etc/os-release
#         PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
#  / # ls /host/etc/kubernetes/manifests | wc -l
#         4     (etcd, kube-apiserver, kube-controller-manager, kube-scheduler)
#  / # exit
```

Then record the value you read (kind nodes are Debian):

```bash
echo 'Debian GNU/Linux 12 (bookworm)' > /opt/node-os.txt
cat /opt/node-os.txt
```

Clean up the debug pod afterwards: `k get pod | grep node-debugger` then `k delete pod <name>`.

Why: `kubectl debug node/` runs a pod in the node's host namespaces with the node filesystem at **`/host`**, so node files are read as `/host/etc/...` without SSH; the control-plane has 4 static pod manifests.

## Solution 13 — graceful termination with preStop

Patch the deployment's pod template with the hook and grace period:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fe
  namespace: grace
spec:
  replicas: 2
  selector:
    matchLabels: { app: fe }
  template:
    metadata:
      labels: { app: fe }
    spec:
      terminationGracePeriodSeconds: 30
      containers:
      - name: nginx
        image: nginx:1.27
        lifecycle:
          preStop:
            exec:
              command: ["/bin/sh","-c","sleep 10"]
```

```bash
k apply -f fe.yaml
k -n grace rollout status deploy/fe
k -n grace get pod -o jsonpath='{.items[0].spec.containers[0].lifecycle.preStop}{"\n"}'
POD=$(k -n grace get pod -o name | head -1)
k -n grace delete $POD &        # observe it in another pane:
k -n grace get pod -w           # the pod sits Terminating ~10s (preStop) before it goes away
```

Why: the grace period is the total budget for preStop + SIGTERM; the 10s `preStop` sleep runs before SIGTERM, giving endpoints time to drain, and the pod lingers `Terminating` for that sleep.

## Solution 14 — rollout, history, and undo to a revision

```bash
k -n roll set image deploy/api nginx=nginx:1.25
k -n roll annotate deploy/api kubernetes.io/change-cause="bump 1.25" --overwrite
k -n roll rollout status deploy/api

k -n roll set image deploy/api nginx=nginx:1.26
k -n roll annotate deploy/api kubernetes.io/change-cause="bump 1.26" --overwrite
k -n roll rollout status deploy/api

k -n roll rollout history deploy/api
# REVISION  CHANGE-CAUSE
# 1         init 1.24
# 2         bump 1.25
# 3         bump 1.26

k -n roll rollout undo deploy/api --to-revision=1
k -n roll rollout status deploy/api
k -n roll get deploy api -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# nginx:1.24
```

Note: `k create deployment api --image=nginx:1.24` names the container after the image base — `nginx` — which is why `set image` targets `nginx=...`. If unsure, check first: `k -n roll get deploy api -o jsonpath='{.spec.template.spec.containers[0].name}'`.

Why: each `set image` creates a new revision; `rollout undo --to-revision=1` rolls *forward* to a new revision whose template equals revision 1, restoring `nginx:1.24`.

## Solution 15 — full triage chain: stuck rollout, Ready 0/1

Diagnose the chain:

```bash
k -n stuck get pods
# old pods Running 1/1; new pod(s) Running 0/1  (not Ready)
k -n stuck rollout status deploy/shop     # hangs: "Waiting for rollout to finish..."
k -n stuck describe pod -l app=shop | sed -n '/Events/,$p'
# Warning  Unhealthy  Readiness probe failed: Get "http://POD_IP:8080/ready": connection refused
```

Root cause: the new template's readiness probe hits `/ready:8080`, but nginx serves `/` on `80`. With `maxUnavailable: 0`, the never-Ready new pod blocks the rollout from proceeding. Fix the probe:

```bash
k -n stuck patch deployment shop --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/"},
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":80}
]'
k -n stuck rollout status deploy/shop        # now completes
k -n stuck get pods                           # all 3 Running 1/1
```

Corrected readiness probe:

```yaml
        readinessProbe:
          httpGet:
            path: /
            port: 80
          periodSeconds: 5
```

Report the top-memory `shop` pod (metrics-server required):

```bash
k -n stuck top pods -l app=shop --sort-by=memory --no-headers | head -1 | awk '{print $1}'
```

Why: a failing **readiness** probe keeps new pods out of endpoints and, under `maxUnavailable: 0`, stalls the rollout — no container ever crashes, which is exactly why `logs` are unhelpful and `describe`/events (the `Unhealthy` readiness message) are the diagnosis.
