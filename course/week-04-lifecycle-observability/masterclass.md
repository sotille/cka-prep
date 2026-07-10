# Week 4 — Pod Lifecycle & Observability (feeds Troubleshooting 30% + Workloads & Scheduling 15%)

This module is the mechanical core of the exam's biggest domain. Troubleshooting questions are rarely exotic — they are a pod in `CrashLoopBackOff`, a deployment stuck mid-rollout, a probe that kills a healthy app, or "find the pod using the most CPU and write its name to a file." Every one of those decomposes into: read the state machine (status + events), read the evidence (logs + exit codes), and extract the answer in the exact output format requested. The kubelet-side details below (probe execution, termination signals, node log paths, crictl) are what separate a 5-minute fix from a 20-minute flail.

Version note: behavior described here is stable across recent Kubernetes releases; where a detail is version-dependent it is flagged inline. Check the current exam version on the CNCF curriculum page (github.com/cncf/curriculum) before exam day.

---

## What the exam actually asks

| Topic | Domain | Weight | Typical task phrasing |
|---|---|---|---|
| Probes (liveness/readiness/startup) | Workloads & Scheduling / Troubleshooting | 15% / 30% | "Add a readiness probe...", "Pod X restarts constantly, fix it" |
| CrashLoopBackOff root cause | Troubleshooting | 30% | "Pod Y in namespace Z is failing. Find the cause and fix it" |
| Logs (`-c`, `--previous`, selectors) | Troubleshooting | 30% | "Save the logs of the failed container to /opt/logs.txt" |
| Events | Troubleshooting | 30% | Implicit in every debugging task |
| `kubectl top` + metrics-server | Troubleshooting | 30% | "Write the name of the pod consuming most CPU to a file" |
| `kubectl debug` (ephemeral, node) | Troubleshooting | 30% | "Inspect the distroless pod...", node-level checks |
| crictl / journalctl | Troubleshooting | 30% | Broken kubelet/control-plane tasks (week 9 depth) |
| Rollouts (strategy, undo) | Workloads & Scheduling | 15% | "Update the image, then roll back to the previous version" |
| jsonpath / custom-columns / --sort-by | All domains | — | Any "write X to file Y" task |

---

## Probes: the kubelet's health state machine

Probes are executed **by the kubelet on the node where the pod runs** — not by the control plane. `httpGet` and `tcpSocket` are issued from the kubelet process against the pod IP; `exec` spawns a process inside the container via the CRI; `grpc` (GA v1.27) calls the standard gRPC health-checking service. This matters for debugging: a probe can fail because of node-local conditions (kubelet → pod networking) even when the app answers fine from elsewhere.

### The three probes and their consequences

| Probe | On failure (after `failureThreshold` consecutive fails) | Affects traffic? | Restarts container? |
|---|---|---|---|
| **startupProbe** | Container killed and restarted (restartPolicy). While it has not yet succeeded, **liveness and readiness are suppressed** | no | yes |
| **livenessProbe** | Container killed and restarted | not directly | yes |
| **readinessProbe** | Container marked NotReady → pod removed from Service EndpointSlices | **yes — this is the only probe that gates traffic** | **no, never** |

Burn these into memory:

- **Readiness never restarts anything.** A pod failing readiness sits at `Running` `0/1` forever. If you expect a restart to "fix" it, you misdiagnosed.
- **Liveness never touches traffic directly.** A container can be live (not deadlocked) but not ready (warming cache). They answer different questions: "should I restart this?" vs "should I route to this?"
- **Startup is a mute button.** While a startupProbe is defined and hasn't succeeded, the other two probes do not run at all. Once it succeeds once, it never runs again for that container instance.
- Pod `Ready` condition = all containers ready **and** all `readinessGates` conditions true. `readinessGates` are pod-spec entries that let external controllers (e.g. cloud LB controllers) veto readiness — know they exist, you won't configure them on the exam.

### Handlers

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
    httpHeaders:
    - name: X-Probe
      value: kubelet
```

- `httpGet`: success = HTTP status **200–399**. Scheme `HTTPS` skips certificate verification. Redirects are followed.
- `tcpSocket`: success = TCP connection opens. Cheapest; proves only that something is listening.
- `exec`: success = exit code 0. Spawns a process per probe tick — measurable overhead at scale. **Fails unconditionally on distroless images** (no shell, often no binary to run) — a classic misconfiguration.
- `grpc`: `grpc: {port: 9090}` — requires the app to implement grpc.health.v1. No TLS support.

### Timing fields (defaults in parentheses)

| Field | Default | Meaning |
|---|---|---|
| `initialDelaySeconds` | 0 | Wait before first probe |
| `periodSeconds` | 10 | Interval between probes |
| `timeoutSeconds` | **1** | Per-probe timeout — the most under-set field in production |
| `failureThreshold` | 3 | Consecutive failures before acting |
| `successThreshold` | 1 | Consecutive successes to be considered passing — **must be 1 for liveness and startup** (API rejects otherwise); only readiness may use >1 |

Liveness/startup probes may also carry their own `terminationGracePeriodSeconds` (GA v1.28) so a probe-kill can use a shorter grace than a normal delete.

### The classic trap: slow starter + liveness = restart loop

App takes 60s to boot. Liveness probe: defaults (first check ~10s, dead after ~30s). Sequence: container starts → probe fails 3× → kubelet kills it → restart → boots slowly again → killed again. The pod shows `Running` with a climbing `RESTARTS` count and events alternating `Unhealthy` / `Killing`. The restarts are subject to the same exponential backoff as crashes, so it eventually looks like `CrashLoopBackOff` even though the app never crashed once.

**Wrong fix:** crank `initialDelaySeconds` to 300. It "works" but every legitimate restart now waits 5 minutes before liveness protection starts, and you guessed a number.

**Right fix:** a startupProbe with a generous budget:

```yaml
startupProbe:
  httpGet:
    path: /healthz
    port: 8080
  periodSeconds: 5
  failureThreshold: 24        # 24 x 5s = up to 120s to start
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  periodSeconds: 10
  failureThreshold: 3         # tight again once started
```

Startup budget = `failureThreshold × periodSeconds`. Say that formula out loud when you size one.

Probes on a **bare pod cannot be edited in place** (pod spec is immutable except image and a few fields). Fastest legal path: `k get po X -o yaml > p.yaml`, edit, `k replace --force -f p.yaml`. On a Deployment, just edit the template — new ReplicaSet, rolling replacement.

---

## Lifecycle hooks and the termination sequence

### postStart

Runs immediately after the container is created, **in parallel with the ENTRYPOINT — no ordering guarantee**. The container is not marked `Running` until postStart completes; if postStart fails, the container is killed and restartPolicy applies. Do not use it to "wait for the app" — it can fire before the app's first instruction.

### Termination, step by step

1. Delete request → API server sets `metadata.deletionTimestamp` and the grace-period countdown starts (`spec.terminationGracePeriodSeconds`, default **30**). Pod shows `Terminating`.
2. **In parallel**, the endpoints controller marks the pod terminating in EndpointSlices and kube-proxy on every node starts removing it from Service rules. This is asynchronous — traffic can still arrive for a few seconds after SIGTERM. This race is why the `preStop: sleep` pattern exists.
3. Kubelet runs the **preStop hook** (if defined) and waits for it. preStop time **counts against** the grace period — it does not extend it.
4. Kubelet sends **SIGTERM** to PID 1 of every container (after preStop finishes).
5. Grace period expires → **SIGKILL** to anything still alive → exit code 137.
6. API object removed once containers are dead (and finalizers cleared).

The load-balancer-drain pattern:

```yaml
lifecycle:
  preStop:
    exec:
      command: ["sh", "-c", "sleep 5"]
```

Five seconds for kube-proxy everywhere to converge before the app even sees SIGTERM.

**PID 1 trap:** `command: ["sh", "-c", "myapp"]` makes the shell PID 1. `sh` does not forward SIGTERM to children. Result: app never sees the signal, sits through the full grace period, dies by SIGKILL, exit 137, every deploy takes 30s longer than it should. Fix: `exec myapp` in the shell line, or drop the shell wrapper.

`k delete pod X $now` (`--grace-period=0 --force`) deletes the **API object** immediately without waiting for kubelet confirmation — the container may briefly keep running on the node. Fine for exam cleanup; dangerous for StatefulSets in real life (two instances of the same identity).

---

## Exit-code forensics and CrashLoopBackOff mechanics

Where the evidence lives:

```bash
k describe po X                 # Last State: Terminated → Reason, Exit Code
k get po X -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'
```

| Exit code | Meaning | Typical cause |
|---|---|---|
| 0 | clean exit | command finished — **still crashloops under restartPolicy: Always** |
| 1 | app error | unhandled exception, bad config value — read the logs |
| 2 | shell misuse | syntax error in `sh -c` line |
| 126 | not executable | permissions, or exec format error |
| 127 | command not found | typo in command/args resolved by a shell |
| 128+N | killed by signal N | see below |
| 137 | 128+9 = **SIGKILL** | OOMKilled, grace-period expiry, liveness kill after SIGTERM ignored |
| 139 | 128+11 = SIGSEGV | native crash |
| 143 | 128+15 = **SIGTERM** | app received TERM and exited — normal shutdown path |

**137 is not automatically OOM.** Check `lastState.terminated.reason`: `OOMKilled` means the cgroup memory limit was hit (kernel OOM killer); plain `Error` with 137 usually means SIGKILL after an ignored SIGTERM (grace-period expiry or liveness kill on a PID-1 shell).

Distinguish these waiting states — they have different root-cause classes:

| Status column | What actually happened |
|---|---|
| `CrashLoopBackOff` | Container started, then exited (any code, including 0); kubelet is waiting out the backoff before restarting |
| `Error` / `StartError` (exit 128) | Runtime could not exec the entrypoint at all — "executable file not found in $PATH" lives in `lastState.terminated.message` |
| `CreateContainerConfigError` | Kubelet can't build the container config — missing ConfigMap/Secret referenced in `env`; **no restarts, no backoff** — kubelet retries until you create the missing object |
| `ImagePullBackOff` / `ErrImagePull` | Registry-side: typo in image, missing tag, auth |
| `OOMKilled` (in Last State) | Memory limit hit |

Backoff curve: restart delay starts at 10s and doubles per crash — 10, 20, 40, 80, 160 — **capped at 300s (5 min)**, and resets after the container runs 10 minutes without dying. So a crashlooping pod restarts at most every 5 minutes; don't sit watching it — read `--previous` logs instead of waiting for the next attempt. (Recent releases shrink the initial delay behind a feature gate; the 10s→5m curve is the documented default.)

Triage order for any crashing pod — this sequence solves ~90% of CrashLoopBackOff exam tasks in under 3 minutes:

```bash
k describe po X          # 1. Last State: exit code + reason + message, and Events
k logs X --previous      # 2. what the dying instance said
k get po X -o yaml       # 3. command, env refs, resources, probes — compare with evidence
```

---

## Logs: every layer

### kubectl logs — the flags that matter

```bash
k logs mypod                          # single-container pod
k logs mypod -c sidecar               # named container (mandatory if >1 container)
k logs mypod --all-containers=true    # everything in the pod
k logs mypod --previous               # the PREVIOUS instance (crashed one) — alias -p
k logs mypod -f --tail=20             # follow, starting from last 20 lines
k logs mypod --since=10m              # time-bounded
k logs mypod --timestamps             # prefix each line with RFC3339 time
k logs -l app=web --prefix --tail=5   # by selector, pod name prefixed
k logs deploy/web                     # ONE pod of the deployment, not all
```

- `--previous` errors with "previous terminated container not found" if the container never restarted — that error is itself information.
- With `-l` selectors, kubectl streams at most `--max-log-requests` pods concurrently (default 5); more pods than that with `-f` fails.
- `k logs deploy/web` picks a single pod. For all pods, use the label selector.

### Node-level view

The kubelet doesn't invent logs; it reads files the container runtime writes:

```text
/var/log/containers/<pod>_<ns>_<container>-<cid>.log   # symlink layer (flat, greppable)
        -> /var/log/pods/<ns>_<pod>_<uid>/<container>/0.log   # actual file, one per restart (0.log, 1.log ...)
```

`kubectl logs` = kubelet serving these files over its API. If the API server is down, the files are still there — read them directly on the node (via SSH on the exam, `docker exec -it cka-worker bash` on kind, or `k debug node/`). Log rotation is kubelet-managed (`containerLogMaxSize`, default 10Mi). Format is CRI: `timestamp stream tag message` per line.

Caveat when reading via `k debug node/X` (host at `/host`): the symlinks in `/host/var/log/containers` point to **absolute** paths like `/var/log/pods/...` which don't resolve inside the debug container — read `/host/var/log/pods/...` directly, or `chroot /host`.

---

## Events: the primary signal

`describe` shows an object's recent events at the bottom — that is always step 1. For everything else:

```bash
k get events --sort-by=.lastTimestamp                     # get events is NOT time-sorted by default
k get events -A --field-selector type=Warning
k get events --field-selector involvedObject.name=mypod
k events --for pod/mypod --types=Warning                  # newer subcommand: time-sorted by default
k events -A --watch
```

Facts that cost points when unknown:

- `k get events` default ordering is arbitrary. Untrained people scroll the wrong end. Always `--sort-by=.lastTimestamp` (the `k events` subcommand sorts correctly by itself).
- Events are **namespaced** — scheduling failures for a pod in `frontend` are in `frontend`, not `default`.
- Events have a **TTL of 1 hour** by default (`kube-apiserver --event-ttl`). "No events" means nothing happened *recently*, not nothing happened.
- The high-value reasons: `FailedScheduling`, `Unhealthy` (probe fail), `Killing`, `BackOff`, `Failed` (image pull), `FailedMount`, `OOMKilling` (node event).

---

## metrics-server and kubectl top

`kubectl top` reads the Metrics API (`metrics.k8s.io`), served by **metrics-server**, which scrapes each kubelet's `/metrics/resource` endpoint every ~15s. No metrics-server → `error: Metrics API not available`. On the exam it is preinstalled; on kind it is not, and the kubelet serves self-signed certs, so:

```bash
k apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
k -n kube-system patch deploy metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
k -n kube-system rollout status deploy/metrics-server
```

Usage:

```bash
k top node
k top pod -A
k top pod -n prod --sort-by=cpu          # sort-by takes only cpu|memory (not jsonpath)
k top pod -n prod --containers           # per-container breakdown
k top pod -n prod --sort-by=cpu --no-headers | head -1
```

Values are short-window averages (roughly the last scrape interval) in millicores and Mi. Fresh pods return "metrics not available yet" for up to a minute — deploy first, answer other questions, come back. The classic exam task — "write the name of the pod with the highest CPU to /opt/answer.txt" — is the `--sort-by=cpu --no-headers | head -1 | awk '{print $1}'` pattern; see Speed patterns.

---

## kubectl debug: three distinct modes

| Mode | Command shape | What it creates | Use when |
|---|---|---|---|
| Ephemeral container | `k debug -it pod/X --image=busybox:1.36 --target=app` | Extra container injected into the **running** pod | Distroless/no-shell images; must inspect live state |
| Pod copy | `k debug pod/X -it --copy-to=X-debug --set-image=app=busybox:1.36 -- sh` | A **new, unmanaged** pod cloned from X | Need to change image/command to experiment; original must stay untouched |
| Node | `k debug node/N -it --image=busybox:1.36` | Privileged-ish pod on node N with host filesystem at **/host** | No SSH at hand; read node files, check processes |

Ephemeral containers:

- `kubectl exec` on a distroless image fails with `exec: "sh": executable file not found` — that error is your cue to reach for `debug`.
- `--target=CONTAINER` shares the target's **PID namespace**: from the ephemeral busybox you can `ps`, read `/proc/1/cmdline`, inspect `/proc/<pid>/root/` (the target's filesystem via procfs).
- Ephemeral containers cannot be removed or restarted once added — they live until the pod dies. They have no ports, no probes, no resource guarantees.

Pod copies (`--copy-to`):

- Flags that matter: `--set-image=container=image` (same syntax as `kubectl set image`, `*` for all), `--share-processes`, `--container/-c`, `--same-node`.
- Probes are stripped from the copy by default (`--keep-liveness`, `--keep-readiness`, `--keep-startup` to retain) — deliberately, so a crashlooping pod's copy stays alive long enough to inspect.
- **The copy is not managed by any controller.** Fixing the copy fixes nothing; it is a lab bench. Apply the real fix to the Deployment, then delete the copy.

Node debugging:

- The debug pod gets `hostNetwork`, `hostPID`, `hostIPC` and the node root mounted at `/host`. Not fully privileged by default — add `--profile=sysadmin` (v1.27+) when you need privileged operations.
- `chroot /host` gives you an effectively-SSH shell (kind nodes have bash).
- It leaves a `node-debugger-<node>-<hash>` pod behind — **delete it** when done; on the exam, leftover junk in `default` can confuse later tasks.
- Exam flavor: real exam nodes are reachable with `ssh <node>` + `sudo -i`; `k debug node/` is the fallback when SSH is not offered. On kind: `docker exec -it cka-worker bash` is the equivalent.

---

## Below the API: crictl and journalctl

When the API server (or kubelet) is down, kubectl is blind. The container runtime is not. On any node:

```bash
crictl ps                      # running containers
crictl ps -a                   # including exited — where crashed control-plane pods hide
crictl pods                    # pod sandboxes
crictl logs <container-id>
crictl inspect <container-id>  # full runtime config, mounts, state
crictl images
crictl exec -it <container-id> sh
```

crictl needs to know the runtime socket — configured in `/etc/crictl.yaml`:

```yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
```

or per-command: `crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps`. Exam nodes have this preconfigured. The canonical week-9 move: kube-apiserver static pod is down → `kubectl` dead → SSH to control plane → `crictl ps -a | grep apiserver` → `crictl logs <id>` → find the manifest typo.

For the daemons themselves (kubelet, containerd are systemd services, not containers):

```bash
journalctl -u kubelet --since "15 min ago" --no-pager | tail -50
journalctl -u kubelet -f
journalctl -u containerd --no-pager | grep -i error
```

On kind, nodes run systemd inside the Docker containers, so `docker exec -it cka-worker journalctl -u kubelet` works as-is.

---

## Output engineering: jsonpath, custom-columns, sort-by

Half of Troubleshooting scoring is *extracting the answer into the exact file requested*. Fumbling here costs more time than the diagnosis.

### jsonpath

```bash
# All node InternalIPs (the canonical exam task)
k get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'

# One field
k get po web -o jsonpath='{.status.podIP}'

# range/end for line-per-item output
k get po -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.podIP}{"\n"}{end}'

# All images across all namespaces, deduplicated
k get po -A -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n' | sort -u
```

Rules: single-quote the whole expression (the exam shell is bash; `$`, `*`, `"` inside must not hit the shell); literal text goes in `{"..."}`; filters are `[?(@.field=="value")]`; field names are case-sensitive and match the JSON, not the column headers. When you don't know the path: `k get po web -o json | less` and walk it, or `k explain po.status.containerStatuses --recursive`.

### custom-columns

```bash
k get po -A -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,NODE:.spec.nodeName,IMAGE:.spec.containers[0].image'
```

Same path syntax minus `{}`. Better than jsonpath when the task wants a readable multi-field listing. `--no-headers` to strip the header row when writing to a file.

### --sort-by

```bash
k get po -A --sort-by='.status.containerStatuses[0].restartCount'   # restart champions at the bottom
k get events --sort-by=.lastTimestamp
k get po --sort-by=.metadata.creationTimestamp
```

`kubectl get --sort-by` takes any jsonpath; `kubectl top --sort-by` takes only `cpu` or `memory`.

### yq/jq awareness

`k get deploy web -o yaml | yq '.spec.template.spec.containers[0]'` is pleasant — but do not build exam muscle memory on yq/jq being installed. jsonpath and custom-columns are always there. `-o yaml > f.yaml && vim f.yaml` is the universal fallback.

---

## Rollouts: strategy, math, undo

(From the week-4 notes; overlaps week 2 — here from the failure-mode angle.)

```yaml
spec:
  replicas: 10
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%          # extra pods allowed ABOVE replicas — rounds UP
      maxUnavailable: 25%    # pods allowed missing BELOW replicas — rounds DOWN
```

For replicas=10: maxSurge 25% → ceil(2.5)=3 → up to 13 pods; maxUnavailable 25% → floor(2.5)=2 → at least 8 **Ready**. Both zero is invalid. `Recreate` kills all pods before creating new ones — needed for RWO volumes and apps that can't run two versions; it is downtime by design.

**"Ready" is the readiness probe.** A rollout with a broken readiness probe on the new image stalls at exactly `maxUnavailable`: the new pods never become Ready, so the old ones can't be scaled down. After `progressDeadlineSeconds` (default 600) the Deployment gets condition `Progressing=False`, reason `ProgressDeadlineExceeded` — but **nothing rolls back automatically**. "Deployment stuck, fix it" on the exam = check `k describe deploy` conditions, check new-RS pod events/probes, then fix or undo.

```bash
k rollout status deploy/web                 # blocks until done or deadline
k rollout history deploy/web
k rollout history deploy/web --revision=2   # full template of that revision
k rollout undo deploy/web                   # back to previous
k rollout undo deploy/web --to-revision=2   # to a specific one
k rollout restart deploy/web                # rolling replacement, same spec (stamps restartedAt annotation)
k rollout pause deploy/web && k rollout resume deploy/web
```

Mechanics worth knowing: each template change creates a new ReplicaSet; revision number lives in the RS annotation `deployment.kubernetes.io/revision`; history depth is `revisionHistoryLimit` (default 10); `CHANGE-CAUSE` column is the `kubernetes.io/change-cause` annotation — set it with `k annotate deploy web kubernetes.io/change-cause="image to 1.28"` if a task asks for a recorded cause. **`undo` does not go "back" in numbering** — undoing to revision 2 re-creates its template as a new highest revision (2 disappears from the middle of the list and reappears at the top). DaemonSets and StatefulSets support the same `rollout` verbs.

---

## App-level triage methodology (the drill chain)

The week-4 drill — pod won't start → service can't reach it → DNS won't resolve — is one layered methodology. Fix layer N before touching N+1:

| Layer | Question | Commands | Common causes |
|---|---|---|---|
| 1. Pod scheduled? | `Pending`? | `k describe po` → Events | `FailedScheduling`: insufficient resources, taints, nodeSelector |
| 2. Container starts? | `ImagePullBackOff`/`CreateContainerConfigError`/`StartError`? | `k describe po`, `k get po -o yaml` | image typo, missing CM/Secret, bad command |
| 3. Container stays up? | `CrashLoopBackOff`, restarts>0? | `k logs -p`, exit code + reason | app error, OOM, liveness kill |
| 4. Container ready? | `Running 0/1`? | `k describe po` → Unhealthy events | readiness probe wrong port/path, dependency down |
| 5. Service routes? | endpoints empty? | `k get endpointslices -l kubernetes.io/service-name=X`, `k describe svc X` | selector≠labels, targetPort≠containerPort, pods not Ready (layer 4!) |
| 6. DNS resolves? | name lookup fails? | `k run tmp --rm -it --image=busybox:1.36 --restart=Never -- nslookup web.prod.svc.cluster.local` | CoreDNS pods down, wrong FQDN, netpol |

Layers 5–6 get full depth in weeks 8–9; the point here is the discipline: **status → events → logs → spec**, one layer at a time, never guess-edit YAML before you have evidence.

---

## Traps

Each: the wrong assumption, then the correction.

1. **"initialDelaySeconds handles slow starts."** Boot time varies; one guessed number either restarts healthy apps or delays real protection. Use a startupProbe with `failureThreshold × periodSeconds` as budget.
2. **"The readiness probe failed, so the pod will restart and recover."** Readiness never restarts. `Running 0/1` will sit there until *you* fix the cause.
3. **"Probe timeouts are generous by default."** `timeoutSeconds: 1`. A healthy-but-slow `/healthz` (1.2s under load) fails probes and gets killed by liveness. If a pod dies under load only, check timeout first.
4. **"Exit 137 = OOM."** Only if `reason: OOMKilled`. Otherwise it's a SIGKILL after ignored SIGTERM — grace-period expiry or liveness kill, often the PID-1 shell trap.
5. **"CrashLoopBackOff means the app is crashing with an error."** It also happens on **exit 0**: a container whose command completes (a one-shot script in a Deployment) restarts forever under `restartPolicy: Always`. Check the exit code before hunting bugs.
6. **"kubectl get events shows newest last."** Default order is arbitrary. `--sort-by=.lastTimestamp`, or use `k events` which sorts by default.
7. **"No events on the pod = nothing to see."** Events expire after 1h. Use logs/status; or reproduce (delete pod, watch fresh events).
8. **"kubectl logs shows the crash."** The *current* instance's log may be one boot line. The crash evidence is in `--previous`. If `--previous` errors, the container never restarted — different problem class.
9. **"kubectl logs deploy/web aggregates all pods."** One pod, silently. Use `-l app=web --prefix`.
10. **"I'll exec in and look around."** Distroless: no `sh`. `k debug -it pod/X --image=busybox:1.36 --target=<container>` is the move, and `--target` is what gives you their processes.
11. **"I fixed it in the debug copy."** `--copy-to` pods are unmanaged clones. The Deployment is still broken. Fix the real object; delete the copy (and the `node-debugger-*` pods).
12. **"successThreshold: 3 makes liveness more careful."** Invalid — must be 1 for liveness and startup; the API server rejects the manifest. Only readiness accepts >1.
13. **"preStop buys extra time."** preStop runs *inside* the grace period. `preStop sleep 25` + default grace 30 leaves the app 5s between SIGTERM and SIGKILL. Raise `terminationGracePeriodSeconds` to fit hook + shutdown.
14. **"A shell wrapper in command: is harmless."** `sh -c` as PID 1 swallows SIGTERM → app never shuts down cleanly → 137 every time. Use `exec` in the shell line.
15. **"kubectl top just works."** Requires metrics-server. On kind it also needs `--kubelet-insecure-tls`. And new pods need ~a minute before metrics exist.
16. **"undo restores the old revision number."** The target template is re-created as a **new** top revision. Verify with `k rollout history` after undo — don't assume.
17. **"I can kubectl edit a pod's probe."** Pod probes are immutable. `k get po -o yaml > f.yaml` → edit → `k replace --force -f f.yaml` (deletes and recreates in one command). On Deployments, edit the template.

---

## Speed patterns

Fastest exam-legal path for each common task:

**Probe YAML.** Never type probes from memory: docs search "liveness" → *Configure Liveness, Readiness and Startup Probes* → copy block, adjust port/path. Local alternative: `k explain po.spec.containers.livenessProbe --recursive` for field names.

**Edit a bare pod (probes, command, resources):**

```bash
k get po broken -o yaml > p.yaml
vim p.yaml
k replace --force -f p.yaml     # delete+recreate, one command
```

**Crashloop triage (run as one burst):**

```bash
k describe po X | grep -A10 'Last State'
k logs X -p --tail=30
k get po X -o yaml | grep -A6 -E 'command|resources|configMap'
```

**Highest-CPU pod to a file:**

```bash
k top pod -n NS --sort-by=cpu --no-headers | head -1 | awk '{print $1}' > /opt/answer.txt
cat /opt/answer.txt             # ALWAYS verify the file
```

**Node InternalIPs to a file:**

```bash
k get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' > /opt/ips.txt
```

**Events for one object, time-ordered:**

```bash
k events --for pod/X            # or: k get events --sort-by=.lastTimestamp | grep X
```

**Distroless inspection:**

```bash
k debug -it pod/X --image=busybox:1.36 --target=app -- sh
# inside: ps ; cat /proc/1/cmdline ; ls /proc/1/root/etc
```

**Node file check without SSH:**

```bash
k debug node/N -it --image=busybox:1.36 -- chroot /host bash
# ... work ...
k get po | grep node-debugger    # then delete it
```

**Stuck rollout:**

```bash
k rollout status deploy/web     # confirm stuck
k describe deploy web | grep -A5 Conditions
k rollout undo deploy/web && k rollout status deploy/web
```

**Restart champions across the cluster:**

```bash
k get po -A --sort-by='.status.containerStatuses[0].restartCount' | tail -5
```

**Logs of a previous crash to a file (exact-format tasks):**

```bash
k logs X -c app --previous > /opt/crash.log
```

---

## Docs map

| You need | kubernetes.io path |
|---|---|
| Probe YAML (all three, all handlers) | /docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/ |
| Pod lifecycle, termination sequence, container states | /docs/concepts/workloads/pods/pod-lifecycle/ |
| postStart/preStop hooks | /docs/concepts/containers/container-lifecycle-hooks/ |
| Hook YAML example | /docs/tasks/configure-pod-container/attach-handler-lifecycle-event/ |
| Ephemeral containers, pod copies | /docs/tasks/debug/debug-application/debug-running-pod/ |
| `kubectl debug node/` | /docs/tasks/debug/debug-cluster/kubectl-node-debug/ |
| crictl usage + output mapping | /docs/tasks/debug/debug-cluster/crictl/ |
| metrics-server / Metrics API | /docs/tasks/debug/debug-cluster/resource-metrics-pipeline/ |
| Node log paths, logging architecture | /docs/concepts/cluster-administration/logging/ |
| jsonpath syntax + examples | /docs/reference/kubectl/jsonpath/ |
| kubectl one-liners (sort-by, custom-columns) | /docs/reference/kubectl/quick-reference/ |
| Deployment strategy, rollback, progressDeadline | /docs/concepts/workloads/controllers/deployment/ |
| Generic pod debugging flowchart | /docs/tasks/debug/debug-application/debug-pods/ |

---

## Checkpoint

Self-test — all on the kind lab, clock running:

- Can you write a correct startupProbe + livenessProbe pair for an app with a stated 60s worst-case boot, from memory, in 3 minutes?
- Can you take a pod in CrashLoopBackOff and name the root cause (bad command vs missing ConfigMap vs OOM vs liveness kill) with evidence in 4 minutes?
- Can you explain, without notes, why a failing readiness probe empties a Service and why no restart will ever happen?
- Can you get the previous-instance logs of the correct container in a 3-container pod into a file in 90 seconds?
- Can you write all node InternalIPs to a file with jsonpath in 2 minutes without opening the docs?
- Can you find the highest-memory pod cluster-wide and write its name+namespace to a file in 2 minutes?
- Can you get a shell "into" a distroless pod and read its PID 1 command line in 3 minutes?
- Can you read a file from a worker node's filesystem using only kubectl (no SSH) in 3 minutes, and clean up after?
- Can you recite the termination sequence (deletionTimestamp → endpoints removal ‖ preStop → SIGTERM → grace → SIGKILL) and place exit codes 143 and 137 on it?
- Can you unstick a Deployment whose new image has a broken readiness probe — diagnose and roll back — in 5 minutes?
- Can you find which containers crashed on a node using only crictl (API server "down") in 4 minutes?
