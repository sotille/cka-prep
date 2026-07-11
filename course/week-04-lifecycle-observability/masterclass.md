# Week 04 Masterclass — Pod Lifecycle & Observability (feeds Troubleshooting 30% + Workloads & Scheduling 15%)

> 🧭 **Learning path:** [‹ week-03-scheduling](../week-03-scheduling/masterclass.md) · [Tier map](../LEARNING-PATH.md) · [week-05-cluster-maintenance ›](../week-05-cluster-maintenance/masterclass.md)


This module is the mechanical core of the exam's largest domain. Troubleshooting tasks are rarely exotic — they are a pod in `CrashLoopBackOff`, a deployment wedged mid-rollout, a liveness probe murdering a healthy app, or "find the pod using the most CPU and write its name to a file." Each one decomposes into the same three moves: read the state machine (status + events), read the evidence (logs + exit codes), extract the answer in the exact format asked. The kubelet-side internals below — probe execution, termination signalling, node log paths, `crictl`, `journalctl` — are what separate a 4-minute fix from a 20-minute flail. Everything here is drillable on the kind lab.

Version note: behaviour described is stable across recent Kubernetes releases; version-dependent details are flagged inline. Confirm the current exam version on the CNCF curriculum page (github.com/cncf/curriculum) before exam day.

---

## What the exam actually asks

| Topic | Domain | Weight | Typical task phrasing |
|---|---|---|---|
| Probes (liveness/readiness/startup) | Workloads & Scheduling + Troubleshooting | 15% / 30% | "Add a readiness probe…", "Pod X restarts constantly, fix it" |
| CrashLoopBackOff root cause | Troubleshooting | 30% | "Pod Y in ns Z is failing. Find the cause and fix it" |
| Logs (`-c`, `--previous`, selectors) | Troubleshooting | 30% | "Save the failed container's logs to /opt/out.txt" |
| Events as primary signal | Troubleshooting | 30% | Implicit in every debug task |
| `kubectl top` + metrics-server | Troubleshooting | 30% | "Write the name of the highest-CPU pod to a file" |
| `kubectl debug` (ephemeral / node / copy) | Troubleshooting | 30% | "Inspect the distroless pod", node-level checks |
| `crictl` / `journalctl` | Troubleshooting | 30% | Broken kubelet / control-plane (week 9 depth) |
| Termination & lifecycle hooks | Workloads & Scheduling | 15% | "Ensure graceful shutdown / add a preStop hook" |
| Rollouts (strategy, undo, restart) | Workloads & Scheduling | 15% | "Update the image, then roll back to the previous version" |
| Output engineering (jsonpath / columns / sort) | All domains | — | "List all pod images across namespaces, sorted" |

The unifying skill is **fast, structured triage**. Memorise the decision tree in the "Debugging methodology" section; the rest of this file is the depth behind each branch.

---

## Probes — the deep dive

A probe is a periodic health check the **kubelet** runs against a container. Three types, each wired to a different consequence. Confusing the consequences is the single most expensive probe mistake on the exam.

| Probe | Question it answers | Failure consequence | Runs when |
|---|---|---|---|
| **liveness** | "Is this container wedged and needs a kick?" | **Restart the container** (per `restartPolicy`) | For the whole container lifetime, after startup succeeds |
| **readiness** | "Should this container receive traffic right now?" | **Remove pod from Service endpoints** — no restart | For the whole container lifetime, after startup succeeds |
| **startup** | "Has this slow app finished booting yet?" | **Restart the container**, and *hold off* liveness/readiness | Only during startup; once it passes, it never runs again |

Key mental model: **liveness restarts, readiness gates traffic, startup buys time.** A failing readiness probe never restarts anything — it silently pulls the pod out of the `EndpointSlice` so the Service stops routing to it. A failing liveness probe kills and restarts the container. If you reach for liveness when you meant readiness, you convert a "temporarily not ready" pod into a restart loop.

### Handlers — the four ways to probe

All four are valid for liveness/readiness/startup. (Lifecycle *hooks* — `postStart`/`preStop` — support only `exec` and `httpGet`; `tcpSocket`/`grpc` are probe-only.)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: probe-handlers
spec:
  containers:
  - name: app
    image: nginx:1.27
    ports:
    - containerPort: 80
    # httpGet: kubelet does an HTTP GET; any 200-399 = success
    readinessProbe:
      httpGet:
        path: /healthz
        port: 80
        scheme: HTTP          # HTTP or HTTPS; HTTPS skips cert verification
        httpHeaders:
        - name: X-Probe
          value: kubelet
    # tcpSocket: success if the TCP connection opens
    livenessProbe:
      tcpSocket:
        port: 80
    # exec: runs inside the container; exit 0 = success (each call forks a process)
    startupProbe:
      exec:
        command:
        - cat
        - /tmp/ready
```

`grpc` (GA in v1.27; the `GRPCContainerProbe` feature gate) uses the standard gRPC health-checking protocol — the app must implement the `grpc.health.v1.Health` service:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: grpc-probe
spec:
  containers:
  - name: app
    image: registry.k8s.io/etcd:3.5.15-0
    livenessProbe:
      grpc:
        port: 2379
        # service field is optional; omit for the default gRPC health service
      initialDelaySeconds: 10
```

Handler mechanics that cost points:
- The kubelet probes the **pod IP from the node**, not through the Service/cluster network. A readiness probe cannot be "broken by the Service"; if it fails, the container is genuinely not answering on that port/path.
- `httpGet` success is any status **200–399**. A health endpoint returning 302 passes; one returning 404 fails. `scheme: HTTPS` makes the kubelet skip certificate verification — it just needs a TLS handshake and a 2xx/3xx.
- `exec` probes are the most expensive: every invocation forks a process inside the container. A tight `periodSeconds` with a heavy `exec` command adds real CPU load. Prefer `httpGet`/`tcpSocket` when the app exposes a port.
- `tcpSocket` only proves the port accepts a connection — not that the app behind it is healthy. It is the weakest liveness signal.

### Timing fields — every default worth knowing

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: probe-timing
spec:
  containers:
  - name: app
    image: nginx:1.27
    livenessProbe:
      httpGet:
        path: /healthz
        port: 8080
      initialDelaySeconds: 0    # default 0: delay before the FIRST probe
      periodSeconds: 10         # default 10, min 1: how often to probe
      timeoutSeconds: 1         # default 1, min 1: probe times out after this
      failureThreshold: 3       # default 3: consecutive fails before acting
      successThreshold: 1       # default 1: consecutive passes to be "healthy"
```

| Field | Default | Notes |
|---|---|---|
| `initialDelaySeconds` | 0 | Grace before the first probe. On liveness this is the naive (and dangerous) way to accommodate slow starts — use `startupProbe` instead. |
| `periodSeconds` | 10 | Interval between probes. Minimum 1. |
| `timeoutSeconds` | 1 | A probe that doesn't answer within this counts as a **failure**. The classic silent killer: a healthy-but-busy app that takes 1.2s to answer with the 1s default → intermittent liveness failures → restarts. |
| `failureThreshold` | 3 | Consecutive failures before the consequence fires. |
| `successThreshold` | 1 | Consecutive successes to flip back to healthy. **Must be 1** for liveness and startup; only readiness may set it higher. |

Two derived numbers to compute in your head:
- **Time to first restart from a dead liveness probe** ≈ `initialDelaySeconds + failureThreshold × periodSeconds` (roughly — the first probe fires at `initialDelaySeconds`, then every `periodSeconds`).
- **Total startup budget from a startup probe** = `failureThreshold × periodSeconds`. Want to allow a 5-minute boot with 10s polling? `failureThreshold: 30`, `periodSeconds: 10`.

### The classic trap: slow-start app + liveness probe, no startup probe

An app that needs 60s to load caches, with a naïve liveness probe (shown broken — do not copy):

```text
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  periodSeconds: 10
  failureThreshold: 3
  # initialDelaySeconds omitted -> 0
```

Timeline: liveness starts probing at t=0. The app isn't listening yet. Three failures (~30s) → kubelet restarts the container → app starts booting again from zero → probe fails again → restart. **Permanent `CrashLoopBackOff`, and the app never even finishes booting once.** Bumping `initialDelaySeconds` to 90 "works" but is fragile: it hard-codes a boot time you can't predict, and once the app is up you've delayed real failure detection by 90s.

The correct fix is a **startup probe**, which suspends liveness/readiness until boot completes, then hands over:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: slow-start-fixed
spec:
  containers:
  - name: app
    image: nginx:1.27
    ports:
    - containerPort: 80
    startupProbe:
      httpGet:
        path: /
        port: 80
      periodSeconds: 10
      failureThreshold: 30      # up to 300s of boot time allowed
    livenessProbe:              # only begins AFTER startup passes
      httpGet:
        path: /
        port: 80
      periodSeconds: 10
      failureThreshold: 3       # tight, fast failure detection once running
    readinessProbe:
      httpGet:
        path: /
        port: 80
      periodSeconds: 5
```

While the startup probe is running, liveness and readiness are **disabled**, so a slow boot can't trip them. The moment startup succeeds, it stops running forever and the tight liveness probe takes over. This is the pattern the exam wants when it says "the app takes a while to start and keeps restarting — fix it."

### Readiness gates traffic — the other half of the trap

Readiness failure ≠ restart. When a container's readiness probe fails, the endpoint controller removes that pod's IP from the Service's `EndpointSlice`. Effects:
- The Service stops load-balancing to it. The pod keeps running; nothing is killed.
- During a rolling update, a not-ready new pod **blocks the rollout from progressing** (it counts against availability) — this is why a bad readiness probe manifests as "the deployment is stuck at X/Y and `rollout status` never returns."
- `kubectl get pod` shows `READY 0/1` but `STATUS Running`. That combination — Running but not Ready — is the fingerprint of a readiness problem, distinct from `CrashLoopBackOff` (a liveness/exit problem).

Don't confuse the readiness *probe* with `spec.readinessGates` — a separate, rarely-tested feature letting external controllers inject custom pod conditions (e.g. a load balancer confirming registration) that also gate `Ready`. Awareness-level only.

### Probe-level termination grace (v1.25+)

A liveness/startup failure can carry its own `terminationGracePeriodSeconds`, overriding the pod's for the probe-triggered kill only — useful to kill a wedged container fast without shortening normal shutdown:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: probe-grace
spec:
  containers:
  - name: app
    image: nginx:1.27
    livenessProbe:
      httpGet:
        path: /healthz
        port: 8080
      failureThreshold: 3
      terminationGracePeriodSeconds: 5   # override just for a liveness-triggered kill
```

---

## Pod termination sequence & lifecycle hooks

Deleting a pod is not instantaneous, and the ordering matters for both graceful-shutdown tasks and "why is my app dropping connections" debugging.

### postStart — the startup hook

`postStart` fires **immediately after the container is created**, running concurrently with (no ordering guarantee against) the container's ENTRYPOINT. The container is held in `Waiting` (not `Started`) until `postStart` returns. If it exits non-zero or errors, the **container is killed and restarted**. No arguments are passed to the handler; it must be self-contained.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hooks-demo
spec:
  containers:
  - name: app
    image: nginx:1.27
    lifecycle:
      postStart:
        exec:
          command: ["/bin/sh", "-c", "echo booted > /usr/share/nginx/html/started"]
      preStop:
        exec:
          command: ["/bin/sh", "-c", "nginx -s quit; sleep 5"]
```

Because `postStart` races the entrypoint, it can run *before* your app is listening. Don't use it for anything that assumes the main process is up.

### The termination sequence, in order

When a pod is deleted (or evicted, or a rolling update retires it):

1. **Pod marked `Terminating`**, `deletionTimestamp` set. The grace-period clock (`terminationGracePeriodSeconds`, default **30s**) starts **now**.
2. **Endpoint removal begins, concurrently.** The endpoint controller removes the pod IP from `EndpointSlice`s. This is *asynchronous* and races everything below — for a few hundred ms the pod may still receive new connections while it is also being asked to shut down.
3. **`preStop` hook runs** (if defined) — to completion, *before* any signal is sent to the app.
4. **`SIGTERM` sent to PID 1** of each container, immediately after `preStop` returns.
5. **Wait** for the container to exit, up to the remaining grace period.
6. **`SIGKILL`** if the container is still alive when the grace period elapses (plus a small 2s buffer if `preStop` overran).

Critical detail: **the grace period is the total budget for `preStop` + `SIGTERM` handling combined**, counted from step 1 — not a fresh 30s after `preStop`. A `preStop` that sleeps 25s leaves the app only ~5s to handle `SIGTERM` before `SIGKILL`.

### terminationGracePeriodSeconds

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: grace-demo
spec:
  terminationGracePeriodSeconds: 60    # default 30
  containers:
  - name: app
    image: nginx:1.27
```

Override at delete time: `k delete pod grace-demo --grace-period=10`. Force-kill immediately: `k delete pod grace-demo --grace-period=0 --force` — this is exactly your `$now` alias, and it skips the graceful sequence entirely (SIGKILL now, and the API object is removed without waiting for the kubelet to confirm — use sparingly).

### The signal-forwarding trap

`SIGTERM` is delivered only to **PID 1** inside the container. If your entrypoint is `sh -c "myapp"`, then PID 1 is the shell, and most shells do **not** forward signals to child processes. Result: your app never sees `SIGTERM`, sits idle through the entire grace period, and is `SIGKILL`ed at the end. The forensic tell is the exit code:

- App shut down cleanly on `SIGTERM` → exit **143** (128 + 15).
- App was `SIGKILL`ed after ignoring `SIGTERM` → exit **137** (128 + 9), with the pod having taken the full grace period to die.

Fix: use the exec form (`ENTRYPOINT ["myapp"]`) so the app is PID 1, or run a lightweight init like `tini` that forwards signals.

### preStop as the endpoint-drain fix

Because endpoint removal (step 2) races `SIGTERM` (step 4), a proxy/webserver can receive a connection *after* it starts shutting down → dropped request during rollouts. The standard mitigation is a `preStop` that sleeps a few seconds, giving `EndpointSlice` propagation time to finish before the app stops accepting connections:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: prestop-drain
spec:
  terminationGracePeriodSeconds: 30
  containers:
  - name: web
    image: nginx:1.27
    lifecycle:
      preStop:
        exec:
          command: ["/bin/sh", "-c", "sleep 5"]
```

The app keeps serving during the sleep, endpoints drain, *then* `SIGTERM` arrives. Keep `terminationGracePeriodSeconds` above the sleep so real shutdown still fits.

---

## Exit codes & CrashLoopBackOff forensics

The exit code is the fastest root-cause signal in the box. Read it from `k describe pod` under `Last State`, or straight from the object:

```bash
k get pod POD -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'
k get pod POD -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
```

| Exit code | Meaning | What it usually is |
|---|---|---|
| **0** | Clean exit | A `restartPolicy: Always` container that legitimately finished (e.g. a one-shot process in the wrong workload type) |
| **1** | Generic application error | Uncaught exception, bad config, failed connection at boot — **read the logs** |
| **2** | Shell misuse / bad flags | Wrong CLI arguments to the entrypoint |
| **126** | Command found but not executable | Bad permissions / not a binary |
| **127** | Command not found | A **shell** ran a missing command (`sh -c 'typo'`). A *direct* exec of a missing binary instead surfaces as **128 / `reason: StartError`** (see next row) |
| **128** | Container failed to start (`StartError`) | Direct exec (no shell) of a nonexistent/non-executable binary — e.g. a typo'd `command:` with no shell wrapper. containerd reports `reason: StartError` and exit **128** (this is what a bare `k run ... -- sleeep` produces on kind and the real exam) |
| **137** | 128 + 9 (**SIGKILL**) | **OOMKilled** (check `reason: OOMKilled`), or `SIGKILL` after grace, or liveness kill |
| **139** | 128 + 11 (SIGSEGV) | Native crash / segfault |
| **143** | 128 + 15 (**SIGTERM**) | Graceful shutdown — usually *not* a bug, it's the normal stop signal |

The 137-vs-OOM distinction matters. **Both** OOMKilled and a grace-period `SIGKILL` show exit **137**, because both are delivered as signal 9. Disambiguate with `reason`:

```bash
k get pod POD -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
# OOMKilled  -> cgroup hit the memory limit; raise limits or fix the leak
# Error      -> generic SIGKILL after grace / liveness kill
```

An `OOMKilled` reason means the container exceeded its `resources.limits.memory` and the kernel's cgroup OOM killer terminated it. Fix is either raising the limit or fixing the workload — not touching probes.

### CrashLoopBackOff — what it actually is

`CrashLoopBackOff` is **not an error state** — it is the kubelet *waiting* before restarting a container that keeps exiting. The container ran, died, and the kubelet is backing off before trying again. The backoff is exponential:

`10s → 20s → 40s → 80s → 160s → 300s`, capped at **300s (5 min)**.

The counter resets after the container has run successfully for **10 minutes** (default). So a pod that crashes every 4 minutes will eventually sit at the 5-minute cap. (v1.30+ carried alpha work to reduce the max backoff; the 300s cap is the safe assumption for the exam.)

`CrashLoopBackOff` tells you the container **starts and then exits** — it is *not* an image-pull or scheduling problem. Contrast the states:

| STATUS | READY | Meaning | First move |
|---|---|---|---|
| `CrashLoopBackOff` | 0/1 | Container starts, exits, kubelet backing off | `k logs POD --previous` + exit code |
| `Running` | 0/1 | Container up but readiness failing | Check readiness probe / app health endpoint |
| `Error` | 0/1 | Container exited non-zero, restarting now | `k logs POD --previous` |
| `ImagePullBackOff` / `ErrImagePull` | 0/1 | Image can't be pulled | `k describe` events — bad name/tag/registry/secret |
| `CreateContainerConfigError` | 0/1 | Config ref missing | Missing ConfigMap/Secret in `envFrom`/`valueFrom` |
| `Pending` | 0/1 | Not scheduled or image pulling | `k describe` events — resources/taints/affinity |
| `OOMKilled` (in Last State) | varies | Memory limit hit | Raise `limits.memory` or fix leak |

The three canonical CrashLoop root causes the exam plants:
1. **Bad command / entrypoint** — `command:` points at a binary that doesn't exist (exit 127) or exits immediately. Logs show the error or are empty; `k describe` shows the command.
2. **Missing ConfigMap/Secret** — a referenced config object doesn't exist → `CreateContainerConfigError` (won't even start) or the app boots and dies reading empty config (exit 1). Events name the missing object.
3. **OOM limit too low** — container exceeds `limits.memory` → exit 137, `reason: OOMKilled`. Fix the limit.

---

## Logging — every flag, plus the node view

`kubectl logs` reads the container's stdout/stderr as captured by the CRI runtime. The flags are exam bread-and-butter:

```bash
k logs POD                          # single-container pod
k logs POD -c CONTAINER             # pick a container in a multi-container pod
k logs POD --all-containers=true    # all containers in the pod, interleaved
k logs POD --previous               # -p: the PREVIOUS (crashed) instance — vital for CrashLoop
k logs POD -f                       # follow (stream)
k logs POD --tail=50                # last 50 lines only
k logs POD --since=1h               # last hour; also --since-time='2026-07-10T10:00:00Z'
k logs POD --timestamps             # prepend RFC3339 timestamps
k logs -l app=web                   # by label selector (across pods)
k logs -l app=web --max-log-requests=10   # raise the concurrent-stream cap (default 5)
k logs deploy/web                   # a controller: logs from one of its pods
```

The two that win points:
- **`--previous` / `-p`** — for a `CrashLoopBackOff` pod, the *current* container may not exist yet (kubelet is backing off), so `k logs POD` returns nothing or errors. `--previous` reads the **last dead instance's** logs, which contain the actual crash reason. This is the single most important logging flag on the exam.
- **`-c CONTAINER`** — a multi-container pod refuses a bare `k logs` with `a container name must be specified`. Name the container. `--all-containers=true` dumps them all if you don't know which one.

If the task says "save the logs to a file," redirect: `k logs POD -c app --previous > /opt/out.txt`. Don't hand-copy from the terminal.

### The node-level view

Under the hood, the kubelet and CRI runtime write container stdout/stderr to files on the node. When the API path is broken (kubelet down, apiserver unreachable), this is where the logs still live:

```text
/var/log/pods/<namespace>_<pod-name>_<pod-uid>/<container>/0.log   # rotated: 0.log, 1.log, ...
/var/log/containers/<pod>_<namespace>_<container>-<id>.log          # symlinks INTO /var/log/pods
```

`/var/log/containers/*.log` are **symlinks** into `/var/log/pods/…`; log collectors (Fluent Bit, etc.) tail the former. On kind you reach them via the node container:

```bash
docker exec -it cka-control-plane bash
ls /var/log/containers/                       # find the file for your pod
cat /var/log/pods/NS_POD_UID/CONTAINER/0.log  # substitute the real dir name
```

On a kubeadm node it's `ssh NODE` then `sudo -i` first. This is the fallback when `kubectl logs` can't reach the container — e.g. the pod is a control-plane static pod and the apiserver itself is the thing that's down.

---

## Events — the primary signal

Events are the cluster's changelog and the **first thing to read** on any "it's broken" task — they name the cause (FailedScheduling, Failed pull, Unhealthy probe, BackOff, OOMKilling) in plain language. Events are namespaced objects with a default TTL of **1 hour** (apiserver `--event-ttl`), so old failures age out — read them promptly.

```bash
k get events --sort-by=.lastTimestamp                 # ALWAYS sort — default order is useless
k get events --sort-by=.metadata.creationTimestamp    # alternative sort key
k get events -A --sort-by=.lastTimestamp              # all namespaces
k get events --field-selector involvedObject.name=POD,involvedObject.kind=Pod
k get events --field-selector type=Warning            # only warnings — the interesting ones
```

The default `k get events` output is sorted by name, i.e. random for triage — **always `--sort-by=.lastTimestamp`** so the newest, most relevant events land at the bottom.

The newer dedicated command (`kubectl events`, stable ~v1.28) is purpose-built and sorts by time by default:

```bash
k events                              # this namespace, time-sorted, with a "LAST SEEN" column
k events --for pod/POD                # scoped to one object — cleaner than field-selectors
k events --for deploy/web --watch     # stream events for a deployment as they arrive
k events --types=Warning              # filter by type
```

But the fastest signal for a single misbehaving pod is buried in `k describe`:

```bash
k describe pod POD    # the Events: block at the bottom is the whole story, already scoped
```

For 90% of "pod won't start / won't schedule / keeps restarting" tasks, `k describe pod POD` and reading the `Events:` section *is* the diagnosis. Reach for cluster-wide `k get events --sort-by` when the failing object isn't obvious (e.g. a controller creating and destroying pods faster than you can name one).

---

## metrics-server & kubectl top

`kubectl top` reports live CPU/memory from the **metrics-server**, which scrapes the kubelet Summary API and serves the `metrics.k8s.io` aggregated API. Without metrics-server installed, `k top` returns `error: Metrics API not available`. It is **not** in a default kind cluster — you install it, and on kind you must add a flag.

### Installing metrics-server on kind

The kubelet serves metrics over TLS with a **self-signed serving certificate** that metrics-server won't trust by default → it fails readiness and `top` never works. The fix is `--kubelet-insecure-tls`:

```bash
# Install the upstream manifest (needs internet; do this during lab setup, not on the exam)
k apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Patch the deployment to skip kubelet cert verification (REQUIRED on kind)
k -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

k -n kube-system rollout status deploy/metrics-server
```

Give it ~30–60s to collect the first scrape (metrics have a resolution window; `top` says "metrics not available yet" until then). On the real exam metrics-server is normally already installed — you consume `top`, you don't install it.

### Reading top

```bash
k top nodes                          # CPU/mem per node, with % of allocatable
k top pods                           # this namespace
k top pods -A                        # all namespaces
k top pod POD --containers           # per-container breakdown within a pod
k top pods --sort-by=cpu             # sort by cpu (also: memory)
k top pods -A --sort-by=memory       # highest-memory pod cluster-wide
k top pods -l app=web                # by selector
```

The archetypal exam task — **"write the name of the pod consuming the most CPU to a file"** — is a one-liner. `--sort-by=cpu` orders the table by that column; grab the top consumer and extract just the name:

```bash
# Highest-CPU pod name in namespace `mon`, written to a file:
k top pods -n mon --sort-by=cpu --no-headers | head -1 | awk '{print $1}' > /opt/highest-cpu.txt
```

`--no-headers` drops the header row so `head -1` reliably grabs the first line. `k top --sort-by=cpu` sorts **descending**, so the biggest consumer is the **first** row — hence `head -1`. (Trap: `kubectl get --sort-by` is *ascending*, but `kubectl top --sort-by` is *descending* — don't carry the `get` habit over.) Verify the file contains exactly the pod name — a stray header or the CPU value in the file loses the point.

---

## kubectl debug — ephemeral containers, copies, and nodes

`kubectl debug` is the exam's answer to "the pod I need to inspect has no shell." Three modes.

### 1. Ephemeral container into a running pod (the distroless case)

A distroless/scratch image has no `sh`, no `cat`, no `ls` — `k exec` fails with `exec: "sh": executable file not found`. `kubectl debug` injects a **new ephemeral container** into the *existing, running* pod, sharing its namespaces, so you troubleshoot with a fat toolbox image without disturbing the app:

```bash
# Attach a busybox ephemeral container to the running pod:
k debug -it POD --image=busybox --target=app -- sh
```

- `--target=app` makes the ephemeral container **share the process namespace** of container `app`, so `ps`, `/proc`, and inspecting its processes work. Without `--target` you still share the network namespace (same pod IP, so `wget localhost:PORT` hits the app) but not the process view.
- The ephemeral container is added in place — the pod is **not** restarted, the app keeps running. Ephemeral containers are GA (v1.25+); no feature gate needed.
- You share the network namespace either way, so `wget -O- http://localhost:8080/` from the debug container tests the app's own endpoint locally — exactly how you confirm a readiness path is or isn't answering.

Inspect what got added:

```bash
k get pod POD -o jsonpath='{.spec.ephemeralContainers[*].name}{"\n"}'
```

### 2. Copy the pod with a changed image (--copy-to / --set-image)

When you need to change the image or command to debug (you can't mutate a running pod's image in place), `--copy-to` builds a **copy** of the pod you can freely modify, leaving the original untouched:

```bash
# Copy `myapp`, swap the app container's image for a debug build, drop into it:
k debug POD -it --copy-to=myapp-debug --set-image=app=busybox --container=app -- sh

# Or copy and add a debug container alongside the originals:
k debug POD --copy-to=myapp-debug --image=busybox --container=debugger -- sleep 1d
```

`--set-image=CONTAINER=IMAGE` (comma-separated for several) rewrites images in the copy; `*=IMAGE` sets them all. Handy when the original crashes on start and you want to boot the same spec with a shell (`--set-image` to busybox, `-- sleep 1d`) to poke at mounts/env. Delete the copy when done.

### 3. Node debugging (host access without SSH)

`kubectl debug node/NODE` launches a privileged pod in the node's **host namespaces**, with the node's root filesystem mounted at **`/host`** — reading node files or checking host processes without SSH access:

```bash
k debug node/cka-worker -it --image=busybox
# then, inside the debug pod:
ls /host/etc/kubernetes/manifests    # read node files under /host
cat /host/var/log/syslog
chroot /host                         # optional: operate as if on the node root
```

The node's filesystem is at `/host`; host PID and network namespaces are shared. This is how a "read `/etc/…` on node X" task is done when you weren't given SSH. The debug pod is a normal pod — `k delete pod` it (name shown on creation, `node-debugger-<node>-<rand>`) when finished, or it lingers.

---

## crictl — when the API server is unreachable

When the apiserver or kubelet is down, `kubectl` is useless — but the container runtime (containerd) is still running containers. `crictl` talks straight to the CRI socket, bypassing Kubernetes entirely. This is the week-9 toolset; know it cold.

Run it **on the node** (`ssh NODE; sudo -i`, or `docker exec -it cka-control-plane bash` on kind). It needs the runtime endpoint — set it once in config or pass `-r`:

```bash
# /etc/crictl.yaml — set this so you don't pass -r every time:
#   runtime-endpoint: unix:///run/containerd/containerd.sock
#   image-endpoint: unix:///run/containerd/containerd.sock

crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps   # or rely on /etc/crictl.yaml
```

Core commands (deliberately mirror `docker`):

```bash
crictl ps                 # running containers (crictl ps -a for all, incl. exited)
crictl pods               # pod sandboxes and their states
crictl images             # images on the node
crictl logs CONTAINER_ID  # logs for a container — works with the apiserver DOWN
crictl inspect CONTAINER_ID   # full JSON: mounts, env, state, exit code, cmd
crictl stopp / crictl rmp     # stop / remove a pod sandbox (surgical, when kubelet can't)
```

The canonical broken-control-plane flow: apiserver static pod won't come up, `kubectl` times out. On the control-plane node:

```bash
crictl ps -a | grep kube-apiserver           # is the container even being created / what state?
crictl logs $(crictl ps -a --name kube-apiserver -q | head -1)   # why did it exit
```

`crictl logs` reads the same `/var/log/pods` files `kubectl logs` would — but without needing the apiserver alive. `crictl inspect` gives you the exit code and the exact command/mounts, which is how you catch a typo'd `--flag` in a static pod manifest that makes the apiserver crash on boot.

---

## journalctl — kubelet & containerd logs

The kubelet and containerd run as **systemd services** (on kubeadm nodes and inside kind node containers). When a node is `NotReady` or pods won't start on it, the kubelet's own log is the source of truth — `kubectl` can't show you the kubelet's internal errors.

```bash
journalctl -u kubelet                    # all kubelet logs
journalctl -u kubelet -f                 # follow live
journalctl -u kubelet --since "10 min ago"
journalctl -u kubelet -n 100 --no-pager  # last 100 lines
journalctl -u kubelet -u containerd      # both units together, interleaved by time
journalctl -u kubelet -p err             # priority: errors and worse
```

On kind: `docker exec -it cka-worker bash` then `journalctl -u kubelet -e`. Typical finds: kubelet failing to reach the apiserver (cert/kubeconfig), CNI not ready, container runtime socket errors, cgroup driver mismatch, image pull failures. Pair with `systemctl status kubelet` (is it even running / did it crash-loop) and `systemctl restart kubelet` after a config fix. On kubeadm nodes the kubelet config lives at `/var/lib/kubelet/config.yaml` and its systemd drop-in at `/etc/systemd/system/kubelet.service.d/10-kubeadm.conf` — a `systemctl daemon-reload` is needed after editing units.

---

## Rollouts — strategy, surge/unavailable, and the rollout verbs

Deployments manage pod replacement through ReplicaSets. A **rollout** is triggered *only* by a change to the pod template (`spec.template`) — image, env, labels, resources. Changing `replicas` is a scale, **not** a rollout, and creates no new revision.

### Recreate vs RollingUpdate

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 4
  strategy:
    type: RollingUpdate      # default; the other option is Recreate
    rollingUpdate:
      maxSurge: 25%           # default 25%: extra pods ABOVE replicas during the roll
      maxUnavailable: 25%     # default 25%: pods that may be down BELOW replicas
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
```

| Strategy | Behaviour | Use when |
|---|---|---|
| **RollingUpdate** (default) | Incrementally replace old pods with new, bounded by `maxSurge`/`maxUnavailable`. Zero downtime if the app tolerates two versions running at once. | Almost always. |
| **Recreate** | Kill **all** old pods, *then* create new ones. Guaranteed downtime window. | When two versions can't coexist (e.g. an exclusive DB lock, incompatible schema). |

`maxSurge` and `maxUnavailable` (percentages round: surge up, unavailable down) control the rolling pace:
- `maxSurge: 25%` on 4 replicas → up to 5 pods exist momentarily.
- `maxUnavailable: 25%` on 4 replicas → at least 3 must stay available.
- **They can't both be 0** — that leaves no room to make progress. Set `maxUnavailable: 0` for strict "never below capacity" rollouts (relies on surge); set `maxSurge: 0` for "never above capacity" (relies on unavailability, slower).

A stuck rollout usually means new pods aren't going **Ready** (bad image, failing readiness probe, crash). The deployment respects `progressDeadlineSeconds` (default **600s**); past it, the `Progressing` condition flips to `False` with reason `ProgressDeadlineExceeded` — but the rollout doesn't auto-rollback, it just stops progressing. `revisionHistoryLimit` (default **10**) caps how many old ReplicaSets are retained for rollback.

### The rollout verbs

```bash
k set image deploy/web web=nginx:1.27.1        # trigger a rollout by changing the image
k rollout status deploy/web                    # block until complete (or the deadline) — great for verify
k rollout history deploy/web                   # list revisions and CHANGE-CAUSE
k rollout history deploy/web --revision=3      # full pod-template of a specific revision
k rollout undo deploy/web                      # roll back to the PREVIOUS revision
k rollout undo deploy/web --to-revision=2      # roll back to a SPECIFIC revision
k rollout restart deploy/web                   # restart all pods (new rollout, same template)
k rollout pause deploy/web                     # freeze rollouts (batch several edits into one)
k rollout resume deploy/web                    # unfreeze -> single rollout for all batched changes
```

Notes that save points:
- **`rollout undo` is a forward roll**, not time travel: it creates a *new* revision whose template equals the target's. Omitting `--to-revision` (or `--to-revision=0`) means "the previous one."
- **CHANGE-CAUSE** in `rollout history` comes from the `kubernetes.io/change-cause` annotation. The old `--record` flag is deprecated; set it explicitly so history is readable:
  ```bash
  k annotate deploy/web kubernetes.io/change-cause="upgrade to nginx 1.27.1" --overwrite
  ```
- **`rollout restart`** bumps a template annotation (`kubectl.kubernetes.io/restartedAt`), forcing a rolling replacement without any image/config change — the exam-legal way to make pods re-read a mounted ConfigMap/Secret or clear a wedged state.
- `k rollout status` returns non-zero on failure/timeout — use it as the verification step ("prove the rollout succeeded") rather than eyeballing `get pods`.

---

## Output engineering — jsonpath, custom-columns, sort-by, yq

Many exam tasks are pure data extraction into an exact format/file. The tool is `-o jsonpath` / `-o custom-columns` / `--sort-by`. Memorise these shapes.

### jsonpath

```bash
# All pod names in a namespace, space-separated:
k get pods -o jsonpath='{.items[*].metadata.name}'

# Node InternalIPs (classic task) — filter the addresses array by type:
k get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'

# One node's InternalIP:
k get node cka-worker -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}'

# range/end to build rows (name TAB image), all pods, all namespaces:
k get pods -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

# A specific field — container's exit code:
k get pod POD -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'
```

The `[?(@.type=="InternalIP")]` filter is the pattern the exam loves — pull one element out of a list by a field value. `{range .items[*]}…{end}` builds multi-column, multi-row output; add `{"\t"}` / `{"\n"}` literals for formatting.

### custom-columns

More readable than jsonpath for tabular pulls:

```bash
# Pod name + node + image as columns:
k get pods -A -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,IMAGE:.spec.containers[0].image

# All container images across all namespaces (one per line), deduped & sorted:
k get pods -A -o custom-columns=IMAGE:.spec.containers[*].image --no-headers | tr ',' '\n' | sort -u
```

Header is `COLNAME:jsonpath-without-braces`. `[*]` inside a column expands lists (comma-joined). `--no-headers` for clean file output.

### --sort-by and yq

```bash
# Pods sorted by restart count (find the flappiest pod):
k get pods -A --sort-by='.status.containerStatuses[0].restartCount'

# Pods sorted by creation time (newest last):
k get pods --sort-by=.metadata.creationTimestamp

# Events newest last:
k get events --sort-by=.lastTimestamp
```

`--sort-by` takes a **jsonpath** (with the leading dot, no braces). For anything `-o jsonpath` can't express, pipe `-o yaml` to `yq` (available on the exam desktop):

```bash
k get pods -A -o yaml | yq '.items[].metadata.name'
k get deploy web -o yaml | yq '.spec.template.spec.containers[].image'
```

Know `yq` exists and its basic path syntax; jsonpath/custom-columns handle nearly everything, but `yq` is the escape hatch for gnarly nested pulls under time pressure.

---

## Debugging methodology — the decision tree

Every troubleshooting task fits this flow. Run it top-down; stop when you find the cause.

1. **Look at STATUS + READY** — `k get pod POD -o wide`. The state (table in the CrashLoop section) tells you which branch you're in before you read anything else. `-o wide` gives you the node too (relevant for node-scoped issues).
2. **Read the events** — `k describe pod POD`, bottom `Events:` block. This names most causes outright: `FailedScheduling`, `Failed to pull image`, `Back-off restarting`, `Unhealthy` (probe), `OOMKilling`, `CreateContainerConfigError` (missing config).
3. **Read the logs** — `k logs POD -c C --previous`. For a crash, `--previous` is mandatory (current container may not exist). Empty logs + non-zero exit → look at the `command:`/exit code, not the app.
4. **Read the exit code + reason** — `.status.containerStatuses[0].lastState.terminated.{exitCode,reason}`. 137+OOMKilled, 127 bad command, 1 app error, 143 clean SIGTERM.
5. **Escalate to the node** — if the API path is broken (kubelet issues, control-plane static pods, node NotReady): `crictl ps/logs/inspect`, `journalctl -u kubelet`, `/var/log/pods`, `kubectl debug node/`.

Map symptom → likely cause fast:

| Symptom | Most likely | Confirm with |
|---|---|---|
| `Pending`, no node | Resources / taint / affinity / nodeSelector | `k describe pod` → `FailedScheduling` reason |
| `ImagePullBackOff` | Bad image name/tag, private registry, missing pull secret | `k describe pod` events |
| `CrashLoopBackOff` | App exits: bad cmd (127), missing config (1), OOM (137) | `k logs -p` + exit code/reason |
| `Running` but `0/1 Ready` | Readiness probe failing | `k describe` → `Unhealthy`; test the path via ephemeral container |
| Restart loop, healthy app | Liveness probe too aggressive / no startup probe | `k describe` → `Unhealthy` liveness; check probe timing |
| `CreateContainerConfigError` | Missing ConfigMap/Secret in env/volume | `k describe` events name the object |
| Node `NotReady` | kubelet / CNI / runtime down | `journalctl -u kubelet` on the node |

---

## Traps

Each: the wrong assumption, then the correction.

1. **"Liveness and readiness do the same thing."** No. Liveness **restarts** the container; readiness **removes it from Service endpoints** without restarting. Using liveness where you meant readiness turns "temporarily not ready" into a restart loop.
2. **"Just bump `initialDelaySeconds` for the slow app."** Fragile — it hard-codes an unpredictable boot time and delays real failure detection forever after. Use a **startupProbe**, which suspends liveness/readiness during boot and hands over cleanly.
3. **"`successThreshold: 2` on my liveness probe adds safety."** Invalid — `successThreshold` must be **1** for liveness and startup probes; only readiness may exceed 1. The pod is rejected.
4. **"`k logs POD` shows nothing, so there's no error."** For `CrashLoopBackOff`, the current container doesn't exist yet — use **`--previous`** to read the dead instance where the actual crash lives.
5. **"Multi-container pod, `k logs POD` will just work."** It errors with `a container name must be specified`. Use `-c CONTAINER` or `--all-containers=true`.
6. **"137 means OOM."** 137 is signal 9 (SIGKILL) — could be OOM **or** a grace-period kill **or** a liveness kill. Disambiguate with `lastState.terminated.reason` (`OOMKilled` vs `Error`).
7. **"143 is a crash."** 143 is SIGTERM (128+15) — the *normal* graceful stop signal. Usually not a bug; it's the pod being asked to shut down.
8. **"`k top` is broken."** If it returns `Metrics API not available`, **metrics-server isn't installed** (or hasn't scraped yet, or lacks `--kubelet-insecure-tls` on kind). It's not in a default kind cluster.
9. **"`k get events` shows me the latest problems."** Default sort is by name (effectively random). **Always `--sort-by=.lastTimestamp`**, or use `k events` which time-sorts by default. And events expire after ~1h — read them promptly.
10. **"`k exec` into the distroless pod to look around."** No shell exists → `exec` fails. Use **`k debug -it POD --image=busybox --target=CONTAINER -- sh`** (ephemeral container).
11. **"`kubectl debug node/N` gives me the node's `/`."** It mounts the node root at **`/host`**, not `/`. `cat /host/etc/kubernetes/...`, or `chroot /host` first.
12. **"CrashLoopBackOff is an error to clear."** It's the kubelet **waiting** (10s→…→300s cap) before the next restart. The container *is* starting and exiting — find *why it exits* (logs/exit code); the backoff is a symptom, not the disease.
13. **"preStop runs, *then* I get a fresh grace period for SIGTERM."** The grace period is the **total** budget for preStop **+** SIGTERM handling, counted from the start of termination. A long preStop eats the SIGTERM window.
14. **"My app ignores SIGTERM but it's fine, the code handles it."** If PID 1 is a shell (`sh -c`), it doesn't forward signals — the app never sees SIGTERM, waits the full grace, and gets SIGKILLed (exit 137). Use the exec form or an init like tini.
15. **"Scaling replicas creates a new rollout revision."** Only **pod-template** changes create revisions. Scaling is not a rollout; `rollout history` won't record it.
16. **"`rollout undo` restores an old ReplicaSet as-is."** It creates a **new** revision with the target's template. Forward-only history.
17. **"`maxSurge: 0` and `maxUnavailable: 0` for a careful rollout."** Both zero = no room to progress; the rollout deadlocks. Pick one to be non-zero.
18. **"The apiserver is down, so I can't see any logs."** `crictl logs` (on the node) reads the same `/var/log/pods` files without the apiserver. And `journalctl -u kubelet` shows the kubelet's own errors that `kubectl` never would.

---

## Speed patterns

| Task | Fastest exam-legal path |
|---|---|
| Add a probe to a running deployment | `k edit deploy/NAME` and paste the probe block under the container — or generate YAML with `$do`, add the probe, `k apply -f` |
| Diagnose any failing pod | `k describe pod POD` → read `Events:`; then `k logs POD -p` if it crashed |
| CrashLoop root cause | `k logs POD --previous` **and** `exitCode`/`reason` via jsonpath — do both in one glance |
| Highest-CPU pod → file | `k top pods -n NS --sort-by=cpu --no-headers \| head -1 \| awk '{print $1}' > FILE` (top's `--sort-by` is **descending**) |
| Highest-memory pod cluster-wide | `k top pods -A --sort-by=memory --no-headers \| head -1` |
| Inspect a distroless/shell-less pod | `k debug -it POD --image=busybox --target=app -- sh` |
| Read a file on a node (no SSH) | `k debug node/NODE -it --image=busybox` → `cat /host/PATH` |
| Node is NotReady | `journalctl -u kubelet -e` on the node (kind: `docker exec -it NODE bash`) |
| apiserver/kubelet down | `crictl ps -a` + `crictl logs ID` on the control-plane node |
| Roll back a bad deploy | `k rollout undo deploy/NAME` (add `--to-revision=N` for a specific one) |
| Reload a mounted ConfigMap/Secret | `k rollout restart deploy/NAME` |
| Verify a rollout finished | `k rollout status deploy/NAME` (non-zero exit = failed) |
| Node InternalIPs | `k get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'` |
| All images across namespaces | `k get pods -A -o custom-columns=I:.spec.containers[*].image --no-headers \| tr ',' '\n' \| sort -u` |
| Latest events | `k get events -A --sort-by=.lastTimestamp` (or `k events --for pod/POD`) |

---

## Docs map

Every path is under `kubernetes.io`. Practise finding these fast — you get in-browser docs on the exam.

| You need | kubernetes.io path |
|---|---|
| Probe fields + configuration | `/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/` |
| Probe API reference (all fields/defaults) | `/docs/reference/generated/kubernetes-api/` → Pod → `Probe` |
| Pod lifecycle, hooks, termination sequence | `/docs/concepts/workloads/pods/pod-lifecycle/` |
| Container lifecycle hooks (postStart/preStop) | `/docs/concepts/containers/container-lifecycle-hooks/` |
| Debug running pods (ephemeral, copy, node) | `/docs/tasks/debug/debug-application/debug-running-pod/` |
| kubectl debug reference | `/docs/reference/kubectl/generated/kubectl_debug/` |
| Logs & node log locations | `/docs/concepts/cluster-administration/logging/` |
| metrics-server / resource metrics pipeline | `/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/` |
| `kubectl top` reference | `/docs/reference/kubectl/generated/kubectl_top/` |
| Rolling updates / deployment strategy | `/docs/concepts/workloads/controllers/deployment/` |
| kubectl rollout reference | `/docs/reference/kubectl/generated/kubectl_rollout/` |
| jsonpath support | `/docs/reference/kubectl/jsonpath/` |
| crictl (troubleshooting with CRI) | `/docs/tasks/debug/debug-cluster/crictl/` |
| Troubleshooting a node / kubelet logs | `/docs/tasks/debug/debug-cluster/` |

---

## Checkpoint

Self-test under time. All runnable on the kind lab `cka`.

- Can you state, without hesitation, what happens when each of liveness / readiness / startup **fails**?
- Can you add a correct **startup + liveness + readiness** set to a slow-starting deployment in **3 minutes**, and explain why the startup probe prevents the restart loop?
- Can you diagnose a `CrashLoopBackOff` — state (bad command / missing config / OOM) with evidence — in **4 minutes**?
- Can you read a crashed container's logs and exit code, and say what `137` + `reason: OOMKilled` vs `137` + `Error` each mean?
- Can you write the name of the highest-CPU pod in a namespace to a file in **1 minute**?
- Can you attach an ephemeral debug container to a distroless pod and hit its health endpoint locally in **2 minutes**?
- Can you read a file from a node with `kubectl debug node/` (remembering `/host`) in **2 minutes**?
- Can you recite the termination sequence (Terminating → endpoints removed → preStop → SIGTERM → grace → SIGKILL) and say why the grace period covers preStop **and** SIGTERM?
- Can you explain RollingUpdate vs Recreate, and what `maxSurge`/`maxUnavailable` do, in **1 minute**?
- Can you roll a deployment forward, then `undo` to a specific revision, and verify with `rollout status`?
- Can you extract all node InternalIPs, and all pod images across namespaces sorted, with jsonpath/custom-columns from memory?
- Can you get container logs and the exit reason **with the apiserver down**, using `crictl` and `journalctl` on the node?
