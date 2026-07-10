# Week 4 Exercises — Lifecycle & Observability

Lab: kind cluster `cka` (context `kind-cka`), aliases `k=kubectl`, `$do`, `$now` assumed. Run once before starting:

```bash
k create ns w4
mkdir -p /tmp/w4
```

Answer files go to `/tmp/w4/` on your machine; on the real exam the task names a path like `/opt/answer.txt` on the exam terminal — the redirect pattern is identical. Tasks 7 depends on task 6 (metrics-server); everything else is independent. Each task with pre-existing/broken resources has a **Setup** fence — run it, then solve without looking at it (it is the answer key's inverse).

---

## Task 1 — Basic probe pair (warmup, 4 min)

Context: namespace `w4`, nothing pre-exists.

Create a pod `web-probed` in `w4` with image `nginx:1.27` that has:
- a readinessProbe: HTTP GET `/` on port 80, every 5 seconds
- a livenessProbe: TCP socket check on port 80, every 10 seconds

## Task 2 — Probe set for a slow-starting app (exam, 7 min)

Setup:

```bash
k -n w4 apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: slowapp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: slowapp
  template:
    metadata:
      labels:
        app: slowapp
    spec:
      containers:
      - name: app
        image: busybox:1.36
        command: ["sh","-c","mkdir -p /www && echo ok > /www/index.html && sleep 45 && exec httpd -f -p 8080 -h /www"]
        ports:
        - containerPort: 8080
EOF
```

Context: deployment `slowapp` in `w4` serves HTTP on port 8080 but takes up to 60 seconds worst-case to start listening.

Configure probes on the `app` container so that all three hold:
1. the container is never restarted during a boot of up to 90 seconds,
2. it receives no Service traffic until it actually serves HTTP,
3. once booted, a deadlock is detected and the container restarted within ~30 seconds.

Verify: the pod reaches `1/1 Running` with `RESTARTS 0`.

## Task 3 — Fix a restart-looping pod (exam, 6 min)

Setup:

```bash
k -n w4 apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payments-api
  template:
    metadata:
      labels:
        app: payments-api
    spec:
      containers:
      - name: api
        image: nginx:1.27
        livenessProbe:
          httpGet:
            path: /healthz
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5
          failureThreshold: 2
        readinessProbe:
          httpGet:
            path: /
            port: 80
EOF
```

Context: namespace `w4`. The pod of deployment `payments-api` shows a climbing restart count even though the application itself is healthy.

Find the root cause using events, fix the deployment so restarts stop, and keep liveness protection in place. Do not remove the readiness probe.

## Task 4 — Node InternalIPs via jsonpath (warmup, 3 min)

Context: any cluster state.

Write the InternalIP addresses of all nodes in the cluster to `/tmp/w4/node-ips.txt` using a single kubectl command (no manual copying).

## Task 5 — All images cluster-wide, sorted (exam, 4 min)

Context: any cluster state.

Write every unique container image currently specified by pods across **all namespaces** to `/tmp/w4/images.txt`, one per line, sorted alphabetically, no duplicates.

## Task 6 — Install metrics-server on kind (warmup, 5 min)

Context: fresh kind cluster; `k top node` currently fails with `Metrics API not available`.

Install metrics-server and make it work against kind's self-signed kubelet certificates. Verify `k top node` returns numbers for all 3 nodes.

Exam flavor: on the real exam metrics-server is preinstalled — this install is lab-only, but the `kubectl top` skills built on it are graded.

## Task 7 — Highest-CPU pod to a file (exam, 5 min)

Setup (requires task 6 done; wait ~60s after applying before solving):

```bash
k -n w4 apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cpu-burn
spec:
  containers:
  - name: burn
    image: busybox:1.36
    command: ["sh","-c","while :; do :; done"]
    resources:
      limits:
        cpu: 300m
---
apiVersion: v1
kind: Pod
metadata:
  name: idle-1
spec:
  containers:
  - name: idle
    image: busybox:1.36
    command: ["sleep","86400"]
---
apiVersion: v1
kind: Pod
metadata:
  name: idle-2
spec:
  containers:
  - name: idle
    image: busybox:1.36
    command: ["sleep","86400"]
EOF
```

Context: namespace `w4` contains several running pods.

Write the **name only** of the pod consuming the most CPU in namespace `w4` to `/tmp/w4/high-cpu.txt`. Delete pod `cpu-burn` when done (it burns its full CPU limit until deleted).

## Task 8 — Debug a distroless pod with an ephemeral container (exam, 5 min)

Setup:

```bash
k -n w4 apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: secretive
spec:
  containers:
  - name: app
    image: registry.k8s.io/pause:3.9
EOF
```

Context: pod `secretive` in `w4` runs an image with no shell and no binaries — `kubectl exec` is impossible (prove it to yourself first).

Using an ephemeral debug container (`busybox:1.36`) that shares the `app` container's process namespace, record the command line of the `app` container's PID 1 into `/tmp/w4/pid1.txt`.

## Task 9 — Read a file from a node without SSH (exam, 6 min)

Setup:

```bash
docker exec cka-worker sh -c 'mkdir -p /opt && echo "flag-1337" > /opt/cka-flag.txt'
```

Context: a file `/opt/cka-flag.txt` exists on the host filesystem of node `cka-worker`.

Using **only kubectl** (no `docker exec`, no SSH), read that file and save its contents to `/tmp/w4/flag.txt`. Delete the pod your method leaves behind.

Exam flavor: on the real exam you would `ssh <node>` + `sudo cat`; `kubectl debug node/` is the fallback when SSH is not offered, and exactly what kind forces you to practice.

## Task 10 — Previous logs of the right container (exam, 4 min)

Setup:

```bash
k -n w4 apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: duo
spec:
  containers:
  - name: app
    image: nginx:1.27
  - name: worker
    image: busybox:1.36
    command: ["sh","-c","echo worker starting; echo 'FATAL: cannot reach queue at queue.w4.svc:5672' >&2; sleep 5; exit 1"]
EOF
```

Context: multi-container pod `duo` in `w4`; one of its containers keeps restarting.

Identify which container is restarting and save the complete log output of its **previous** (terminated) instance to `/tmp/w4/worker-prev.log`.

## Task 11 — CrashLoopBackOff: bad command (hard, 6 min)

Setup:

```bash
k -n w4 apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders
spec:
  replicas: 1
  selector:
    matchLabels:
      app: orders
  template:
    metadata:
      labels:
        app: orders
    spec:
      containers:
      - name: orders
        image: busybox:1.36
        command: ["/bin/shh","-c","while true; do echo processing; sleep 10; done"]
EOF
```

Context: the pod of deployment `orders` in `w4` is failing and `kubectl logs` returns nothing.

Find the root cause. Save the exact runtime error message (from the pod's status, single kubectl command) to `/tmp/w4/orders-error.txt`, then fix the deployment so the pod runs.

## Task 12 — Pod stuck, no restarts, no backoff (hard, 5 min)

Setup:

```bash
k -n w4 apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: billing
spec:
  containers:
  - name: billing
    image: nginx:1.27
    envFrom:
    - configMapRef:
        name: billing-config
EOF
```

Context: pod `billing` in `w4` never starts; its status is not `CrashLoopBackOff` and restart count stays 0.

Diagnose and fix it **without deleting or recreating the pod**. The pod must reach `Running` on its own after your fix.

## Task 13 — OOM forensics (hard, 6 min)

Setup:

```bash
k -n w4 apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: memhog
spec:
  containers:
  - name: memhog
    image: busybox:1.36
    command: ["sh","-c","sleep 5; tail /dev/zero"]
    resources:
      requests:
        memory: 16Mi
      limits:
        memory: 32Mi
EOF
```

Context: pod `memhog` in `w4` restarts repeatedly. Wait for at least one restart before solving.

Determine why the container is being terminated. Using a **single kubectl command** (jsonpath, no describe+copy-paste), write the termination reason and exit code to `/tmp/w4/memhog.txt` in exactly the format `REASON:EXITCODE` (e.g. `SomeReason:42`).

## Task 14 — Graceful termination with preStop (exam, 5 min)

Setup:

```bash
k -n w4 create deploy web-term --image=nginx:1.27 --replicas=1
```

Context: deployment `web-term` in `w4`, container name `nginx`.

Configure the deployment so that on pod termination:
- the container sleeps 10 seconds **before** nginx receives SIGTERM (connection-drain window),
- the total grace budget is 40 seconds.

Verify that deleting the pod takes at least 10 seconds.

## Task 15 — Event engineering (warmup, 3 min)

Setup:

```bash
k -n w4 run badimage --image=nginx:1.99-does-not-exist
```

Context: namespace `w4` contains at least one failing pod.

1. Write all `Warning` events in `w4`, sorted by last timestamp, to `/tmp/w4/warnings.txt`.
2. Show the time-sorted warning events for pod `badimage` only, without grep.

## Task 16 — Restart champion cluster-wide (exam, 4 min)

Context: after the tasks above, several pods in the cluster have restarted.

Write the pod with the **highest restart count across all namespaces** to `/tmp/w4/champion.txt` in the format `namespace/name`, using kubectl sorting (no manual scanning of the list).

Cleanup when the whole set is done:

```bash
k delete ns w4
docker exec cka-worker rm -f /opt/cka-flag.txt
```

---

# SOLUTIONS

## Solution 1 — Basic probe pair

Generate the skeleton, then add probes (probes have no imperative flag — YAML edit is mandatory):

```bash
k -n w4 run web-probed --image=nginx:1.27 $do > /tmp/w4/t1.yaml
vim /tmp/w4/t1.yaml
k apply -f /tmp/w4/t1.yaml
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web-probed
  namespace: w4
  labels:
    run: web-probed
spec:
  containers:
  - name: web-probed
    image: nginx:1.27
    readinessProbe:
      httpGet:
        path: /
        port: 80
      periodSeconds: 5
    livenessProbe:
      tcpSocket:
        port: 80
      periodSeconds: 10
```

Why: readiness gates Service traffic (needs a real HTTP check), liveness only needs "is something listening" — tcpSocket is the cheapest correct answer.

## Solution 2 — Probe set for a slow-starting app

`k -n w4 edit deploy slowapp` and give the container all three probes:

```yaml
containers:
- name: app
  image: busybox:1.36
  command: ["sh","-c","mkdir -p /www && echo ok > /www/index.html && sleep 45 && exec httpd -f -p 8080 -h /www"]
  ports:
  - containerPort: 8080
  startupProbe:
    httpGet:
      path: /
      port: 8080
    periodSeconds: 5
    failureThreshold: 18
  readinessProbe:
    httpGet:
      path: /
      port: 8080
    periodSeconds: 5
  livenessProbe:
    httpGet:
      path: /
      port: 8080
    periodSeconds: 10
    failureThreshold: 3
```

```bash
k -n w4 get po -l app=slowapp -w    # ~45-50s to 1/1, RESTARTS stays 0
```

Why: startup budget = failureThreshold × periodSeconds = 18 × 5 = 90s (requirement 1) and suppresses the other probes during boot; readiness gates traffic (requirement 2); liveness detects deadlock within 3 × 10 = 30s once startup has succeeded (requirement 3). Cranking `initialDelaySeconds` instead would satisfy 1 but delay deadlock detection after every restart — wrong answer.

## Solution 3 — Fix a restart-looping pod

```bash
k -n w4 describe po -l app=payments-api | grep -A8 Events
# Warning  Unhealthy  Liveness probe failed: HTTP probe failed with statuscode: 404
# Warning  Killing    Container api failed liveness probe, will be restarted
```

nginx has no `/healthz` route → 404 → outside 200–399 → liveness kill every ~10s (2 failures × 5s). The app is fine; the probe endpoint is wrong. Point liveness at a path that exists:

```bash
k -n w4 edit deploy payments-api
```

```yaml
livenessProbe:
  httpGet:
    path: /
    port: 80
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 2
```

```bash
k -n w4 get po -l app=payments-api    # new pod, restarts stay 0
```

Why: the `Unhealthy` event carries the HTTP status code — 404 (bad path) vs `connection refused` (bad port) vs timeout (slow app) each point to a different fix; here only the path is wrong.

## Solution 4 — Node InternalIPs via jsonpath

```bash
k get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' > /tmp/w4/node-ips.txt
cat /tmp/w4/node-ips.txt
```

One per line, if the task demands it:

```bash
k get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' > /tmp/w4/node-ips.txt
```

Why: `addresses` is a list of typed entries — the `[?(@.type=="InternalIP")]` filter is the only way to select by type; always `cat` the file to verify before moving on.

## Solution 5 — All images cluster-wide, sorted

```bash
k get po -A -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n' | sort -u > /tmp/w4/images.txt
cat /tmp/w4/images.txt
```

Why: jsonpath flattens to space-separated on one line; `tr` splits, `sort -u` handles both "sorted" and "unique" in one pass.

## Solution 6 — Install metrics-server on kind

```bash
k apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
k -n kube-system patch deploy metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
k -n kube-system rollout status deploy/metrics-server
k top node
```

Why: kind kubelets serve self-signed certs; without `--kubelet-insecure-tls` metrics-server fails TLS verification against each kubelet's `/metrics/resource` endpoint and its pod never becomes Ready.

## Solution 7 — Highest-CPU pod to a file

```bash
k top pod -n w4 --sort-by=cpu --no-headers | head -1 | awk '{print $1}' > /tmp/w4/high-cpu.txt
cat /tmp/w4/high-cpu.txt        # expect: cpu-burn
k -n w4 delete po cpu-burn $now
```

Why: `top --sort-by=cpu` sorts **descending** (unlike `get --sort-by`), so `head -1` is the top consumer; `--no-headers` keeps the header row out of the answer file. If you get `metrics not available yet`, the pods are younger than one scrape cycle — wait a minute.

## Solution 8 — Ephemeral container into distroless

```bash
k -n w4 exec secretive -- sh
# error: exec: "sh": executable file not found in $PATH  ← the cue for kubectl debug

# interactive exploration:
k -n w4 debug -it secretive --image=busybox:1.36 --target=app -- sh
# inside: tr '\0' ' ' < /proc/1/cmdline ; exit

# one-shot capture to the answer file (-i attaches stdout, no TTY garbage):
k -n w4 debug -i secretive --image=busybox:1.36 --target=app -- sh -c 'tr "\0" " " < /proc/1/cmdline' > /tmp/w4/pid1.txt
cat /tmp/w4/pid1.txt            # expect: /pause
```

Why: `--target=app` joins the app container's PID namespace, making its PID 1 visible at `/proc/1/`; cmdline is NUL-separated, hence the `tr`. Ephemeral containers persist in the pod spec until the pod dies — that's expected, not a mess to clean.

## Solution 9 — Read a node file without SSH

```bash
k debug node/cka-worker --image=busybox:1.36 -- cat /host/opt/cka-flag.txt
# kubectl prints the created pod name: node-debugger-cka-worker-<5 chars>

P=$(k get po -o name | grep node-debugger | head -1)
k logs "$P" > /tmp/w4/flag.txt
cat /tmp/w4/flag.txt            # expect: flag-1337
k delete "$P" $now
```

Interactive variant: `k debug node/cka-worker -it --image=busybox:1.36 -- chroot /host bash` — full shell on the node, then copy the value out by hand.

Why: the node debug pod mounts the node's root filesystem at `/host`, so any host path is readable at `/host/<path>`; running the command non-interactively and harvesting it with `kubectl logs` avoids TTY carriage-return pollution in the answer file. Always delete the leftover `node-debugger-*` pod.

## Solution 10 — Previous logs of the right container

```bash
k -n w4 describe po duo | grep -B2 -A6 'Restart Count'
# or: k -n w4 get po duo -o jsonpath='{range .status.containerStatuses[*]}{.name}{"="}{.restartCount}{"\n"}{end}'
# worker has restarts > 0; app has 0

k -n w4 logs duo -c worker --previous > /tmp/w4/worker-prev.log
cat /tmp/w4/worker-prev.log     # both stdout and stderr lines are there
```

Why: in a multi-container pod `-c` is mandatory, and the crash evidence lives in the **previous** instance — the current instance may only show the first boot line. Both stdout and stderr end up in the same CRI log stream.

## Solution 11 — CrashLoopBackOff: bad command

```bash
k -n w4 get po -l app=orders
# STATUS cycles StartError/RunContainerError → CrashLoopBackOff, logs empty

k -n w4 describe po -l app=orders | grep -A6 'Last State'
#   Exit Code: 128 ← runtime failed BEFORE the entrypoint ran; that's why logs are empty

POD=$(k -n w4 get po -l app=orders -o name | head -1)
k -n w4 get "$POD" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.message}' > /tmp/w4/orders-error.txt
cat /tmp/w4/orders-error.txt
# ... exec: "/bin/shh": stat /bin/shh: no such file or directory ...

k -n w4 edit deploy orders     # fix command to /bin/sh
k -n w4 get po -l app=orders   # new pod Running
```

Why: exit 128 + empty logs = the container never executed, so the evidence is in `status.containerStatuses[].lastState.terminated.message` (runtime error), not in logs; the fix is a one-character command typo in the deployment template.

## Solution 12 — Stuck pod, no backoff

```bash
k -n w4 get po billing
# STATUS: CreateContainerConfigError — not a crash class; restartCount stays 0

k -n w4 describe po billing | tail -5
# Warning  Failed  ... configmap "billing-config" not found

k -n w4 create configmap billing-config --from-literal=CURRENCY=EUR
k -n w4 get po billing -w      # goes Running within seconds, untouched
```

Why: `CreateContainerConfigError` means the kubelet cannot even assemble the container config (missing ConfigMap/Secret referenced in env) — there is no crash, no backoff, and the kubelet retries forever, so creating the missing object heals the pod in place.

## Solution 13 — OOM forensics

```bash
k -n w4 get po memhog          # RESTARTS climbing, STATUS OOMKilled/CrashLoopBackOff

k -n w4 get po memhog -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}:{.status.containerStatuses[0].lastState.terminated.exitCode}' > /tmp/w4/memhog.txt
cat /tmp/w4/memhog.txt         # expect: OOMKilled:137
```

Why: 137 = 128+9 = SIGKILL, but only `reason: OOMKilled` proves the kernel OOM killer fired on the cgroup limit (vs grace-period SIGKILL, which shows reason `Error`); `tail /dev/zero` grows past 32Mi within seconds, and the `sleep 5` in the command keeps the loop observable. Real-life fix would be a realistic memory limit or fixing the leak — the exam usually only asks for the diagnosis in an exact format.

## Solution 14 — Graceful termination with preStop

`k -n w4 edit deploy web-term` — pod template spec:

```yaml
spec:
  terminationGracePeriodSeconds: 40
  containers:
  - name: nginx
    image: nginx:1.27
    lifecycle:
      preStop:
        exec:
          command: ["sh","-c","sleep 10"]
```

```bash
k -n w4 rollout status deploy/web-term
time k -n w4 delete po -l app=web-term
# real ~10-11s: 10s preStop, then SIGTERM, nginx exits fast
```

Why: the kubelet runs preStop to completion **before** sending SIGTERM, and both consume the same 40s grace budget — a drain window that leaves the app 30s to shut down after the hook. If `time` reports ~0s you forgot that `delete` returned early because you used `$now` — don't force-delete when measuring.

## Solution 15 — Event engineering

```bash
k -n w4 get events --field-selector type=Warning --sort-by=.lastTimestamp > /tmp/w4/warnings.txt
cat /tmp/w4/warnings.txt

k -n w4 events --for pod/badimage --types=Warning
```

Why: `get events` is arbitrarily ordered and needs `--sort-by=.lastTimestamp` plus a field selector for the type; the newer `k events` subcommand sorts by time on its own and `--for` scopes to one object without grep.

## Solution 16 — Restart champion cluster-wide

```bash
k get po -A --sort-by='.status.containerStatuses[0].restartCount' --no-headers | tail -1 | awk '{print $1"/"$2}' > /tmp/w4/champion.txt
cat /tmp/w4/champion.txt       # e.g. w4/memhog
```

Why: `get --sort-by` sorts **ascending**, so the champion is the last line (`tail -1` — opposite of the `top --sort-by` pattern in task 7); the path indexes the first container, which is fine for single-container pods (the standard exam case). `awk` assembles the exact `namespace/name` format — always `cat` to verify format before moving on.
