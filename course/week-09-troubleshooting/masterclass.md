# Week 09 — Troubleshooting Masterclass (Troubleshooting 30% — the single biggest domain, the exam-decider)

Troubleshooting is worth roughly a third of your score — expect 5–7 of the 15–20 tasks to be "something is broken, fix it". Unlike authoring tasks, these have unbounded time sinks: a candidate without playbooks burns 15 minutes staring at a dead API server. Every playbook below has the same shape: **symptom → first-30-seconds commands → decision path → root causes ranked by frequency → fix patterns**. Drill them until the decision paths run without conscious thought; on exam day you should be typing before you finish reading the task.

Written against Kubernetes v1.31+ behavior. Where something is version-dependent it is flagged inline. Check the current exam version on the CNCF curriculum page (github.com/cncf/curriculum) before your attempt.

Conventions: `alias k=kubectl`, `export do="--dry-run=client -o yaml"`, `export now="--grace-period=0 --force"`.

---

## What the exam actually asks

| Curriculum bullet (Troubleshooting, 30%) | Typical task phrasing | Playbook |
|---|---|---|
| Troubleshoot clusters and nodes | "Node X is NotReady. Fix it and make the fix persistent." | 4 |
| Troubleshoot cluster components | "The API server / scheduler on cluster2 is not working." | 5, 8 |
| Monitor cluster and application resource usage | "Find the pod using the most CPU in namespace X, write its name to /opt/answer.txt" | Monitoring |
| Manage and evaluate container output streams | "Save the logs of the failing container to /opt/logs.txt" | 2 |
| Troubleshoot services and networking | "Service X does not serve traffic / DNS resolution fails" | 3, 6 |

The other domains leak into this one constantly: a Storage task about a Pending PVC is playbook 1; a Cluster Architecture task about RBAC gone wrong is playbook 7; a Networking task where the Gateway routes nowhere starts at playbook 3. The 30% number understates how much of the exam is really diagnosis.

**The universal law:** `k describe` on the failing object plus `k get events` answers roughly 70% of troubleshooting tasks by themselves. Kubernetes tells you what is wrong; the skill is knowing which object to ask and reading the answer literally.

---

## The universal first minute

Before any playbook, the same four commands, every single broken-cluster task:

```bash
kubectl config use-context kind-cka          # the task names a context; skipping this = silent zero
k get nodes                                  # NotReady anywhere? that recolors everything else
k get pods -A | grep -vE 'Running|Completed' # the not-fine list
k get events -A --sort-by=.lastTimestamp | tail -20
```

Then place the failure on the pod lifecycle chain and jump to the playbook that owns that arrow:

```text
manifest accepted -> scheduled -> image pulled -> container started -> Ready -> reachable
      |                 |             |                  |               |         |
   (apply         (Pending:        (ErrImagePull:   (CrashLoop:      (probe:   (Service/DNS/
    rejected:      playbook 1)      playbook 2)      playbook 2)   playbook 2)  netpol: 3, 6)
    quota/RBAC/
    validation)
```

If the API server itself does not answer, none of this works — that is playbook 5, and it has its own toolbox (`crictl`, journal, static manifests).

---

## Playbook 1 — Pod Pending

**Symptom:** pod stuck `Pending`; `-o wide` shows no node assigned.

**First 30 seconds:**

```bash
k -n NS get pod PODNAME -o wide                 # NODE column empty? never scheduled
k -n NS describe pod PODNAME | tail -15         # the FailedScheduling event IS the answer
k get nodes -o wide                             # capacity/readiness context
```

**Decision path:**

```text
Pod Pending
├── describe shows a FailedScheduling event → read it literally
│   ├── "Insufficient cpu" / "Insufficient memory"
│   │     → sum of requests doesn't fit any node
│   │       → lower requests, or free capacity, or (if task allows) add tolerated node
│   ├── "node(s) had untolerated taint {...}"
│   │     → k describe node X | grep -i taint → add toleration OR remove taint
│   ├── "didn't match Pod's node affinity/selector"
│   │     → k get nodes --show-labels → fix nodeSelector/affinity or label the node
│   ├── "unbound immediate PersistentVolumeClaims" / "persistentvolumeclaim not found"
│   │     → k get pvc: no matching PV? no StorageClass? WaitForFirstConsumer is NORMAL-pending
│   └── "didn't satisfy existing pods anti-affinity" / "exceed max volume count" → read literally
├── describe shows NO events at all
│   └── scheduler is not running → playbook 5 (kube-scheduler static pod)
└── pod HAS a node (nodeName set) but not Running
    └── it is not a scheduling problem: ContainerCreating/Init → playbook 2 or node/CNI → playbook 4
```

**Root causes ranked by frequency (exam):**

1. Resource requests exceed node allocatable (often a comedy request like `cpu: "64"`).
2. Untolerated taint (control-plane taint, or a `NoSchedule` taint planted on the target node).
3. `nodeSelector`/affinity referencing a label no node carries (typo'd hostname, missing `disktype=ssd`).
4. PVC unbound: no default StorageClass, wrong `storageClassName`, no matching PV.
5. Scheduler dead — Pending pods with zero events, cluster-wide.
6. ResourceQuota — but note: quota rejects at admission, so the *pod never exists*; look at the ReplicaSet's events (`k describe rs`) for `exceeded quota`.

**Fix patterns:**

```bash
# requests too big — pod spec resources are immutable: dump, edit, replace
k -n NS get pod PODNAME -o yaml > /tmp/p.yaml   # edit requests down
k replace --force -f /tmp/p.yaml                # --force = delete+recreate

# taint in the way (when the task lets you touch the node)
k taint node cka-worker key-                    # trailing '-' removes the taint

# or tolerate it instead (edit the controller, not the pod, when it's a Deployment)
k -n NS edit deploy DEPLOY                      # add .spec.template.spec.tolerations

# label to satisfy a selector
k label node cka-worker disktype=ssd
```

`WaitForFirstConsumer` trap: a PVC Pending with event "waiting for first consumer" is *healthy* — it binds when a pod uses it. Do not "fix" it.

---

## Playbook 2 — Pod crashing, image errors, config errors

**Symptom:** `CrashLoopBackOff`, `ErrImagePull`/`ImagePullBackOff`, `CreateContainerConfigError`, `StartError`, endless restarts, or `Completed` cycling.

**First 30 seconds:**

```bash
k -n NS get pod PODNAME                          # the STATUS string routes you
k -n NS describe pod PODNAME | tail -20          # events + last state + exit code
k -n NS logs PODNAME --previous --tail=30        # the CRASHED attempt, not the current one
```

**The STATUS string is a router.** Learn the table cold:

| STATUS | What it means | Where to look |
|---|---|---|
| `ErrImagePull` → `ImagePullBackOff` | registry/name/tag wrong, private registry auth, network | `describe`: "manifest unknown", "pull access denied" |
| `InvalidImageName` | malformed image reference (uppercase, stray space) | fix the string |
| `CreateContainerConfigError` | env var references a **missing ConfigMap/Secret (or key)** | `describe`: "configmap \"x\" not found" |
| `ContainerCreating` (stuck) | **volume**-mounted ConfigMap/Secret missing, PVC unbound, or CNI sandbox failure | `describe`: `FailedMount` / `FailedCreatePodSandBox` |
| `StartError` / `RunContainerError` | entrypoint binary not found / not executable | `describe` last state: exit code 128, "executable file not found" |
| `CrashLoopBackOff` | process started, then exited nonzero | `logs --previous`, exit code |
| `OOMKilled` (reason on last state) | memory limit hit | raise limit or fix the app |
| `Completed` + restarts climbing | command finishes; `restartPolicy: Always` restarts it | long-running command, or it should be a Job |

Missing-reference nuance that costs points: a ConfigMap consumed as **env** fails with `CreateContainerConfigError`; the same ConfigMap consumed as a **volume** leaves the pod stuck `ContainerCreating` with `FailedMount` events. Different symptom, same root cause.

**Exit codes** (read from `describe` or jsonpath — `lastState`, not `state`):

```bash
k -n NS get pod PODNAME -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}'
```

| Code | Meaning | Typical cause |
|---|---|---|
| 0 | clean exit | command finished — restart loop under `Always` |
| 1 | generic app error | bad config value, unreachable dependency, exception |
| 2 | shell misuse | broken shell one-liner |
| 126 | cannot execute | permissions, mounted script not `+x` |
| 127 | command not found | typo in `command:`/`args:`, wrong PATH |
| 128 | container never exec'd | entrypoint path wrong ("no such file or directory") |
| 137 | 128+9, SIGKILL | **OOMKilled — or liveness-probe kill escalation, or node eviction. Check the reason field and events before writing "OOM".** |
| 139 | 128+11, SIGSEGV | binary crash |
| 143 | 128+15, SIGTERM | graceful termination (rollout, liveness kill, drain) |

**Probes decide two different fates:**

- **Liveness** fail → container restarted (SIGTERM, then SIGKILL). Symptom: restarts climbing, events say `Liveness probe failed`.
- **Readiness** fail → pod removed from Service endpoints, **never restarted**. Symptom: pod `Running` but `0/1 READY`, Service has no endpoints. This is playbook 3's most common root cause.
- **Startup** probe gates both until it succeeds. Failure budget = `failureThreshold × periodSeconds` — a slow app with `failureThreshold: 3, periodSeconds: 5` gets 15 s to boot before liveness starts killing it in a loop.

Backoff mechanics: crash restarts back off 10 s → 20 s → 40 s … capped at 5 m, reset after 10 m of stable running. Image pulls back off similarly. This is why a fixed pod can still sit in `CrashLoopBackOff` for a few minutes — force it with `k delete pod` (controller recreates immediately) instead of waiting out the backoff.

**Root causes ranked by frequency (exam):**

1. Wrong image tag/name → `ImagePullBackOff` (fix: `k set image`).
2. Missing ConfigMap/Secret or key referenced by env/volume.
3. Bad `command:`/`args:` (typo'd binary, wrong flag) → 127/128 or app usage error in logs.
4. Liveness/readiness probe pointing at wrong port/path.
5. OOMKilled — limit set lower than actual footprint.
6. App-level config (crashes with a clear message in `logs --previous` — read it, the message names the missing env var or unreachable host).

**Fix patterns:**

```bash
k -n NS set image deploy/DEPLOY CONTAINER=nginx:1.27       # image typo — fastest legal fix
k -n NS create configmap app-config --from-literal=DB_HOST=db   # recreate what's missing
k -n NS edit deploy DEPLOY                                 # command/probe/limits — rollout applies it
k -n NS logs deploy/DEPLOY --all-containers --prefix --tail=30  # multi-container triage
```

For a bare pod (no controller), `edit` is rejected for most spec fields: dump to file, fix, `k replace --force -f`.

---

## Playbook 3 — Pod Running but app unreachable

**Symptom:** pods `Running` and `READY`, but `curl http://svc` times out or refuses; "users report the app is down".

**First 30 seconds:**

```bash
k -n NS get svc SVCNAME -o wide                  # selector, ports, type, clusterIP
k -n NS get endpoints SVCNAME                    # THE central clue: empty or populated?
k -n NS get pods -o wide --show-labels           # labels vs selector; READY column; pod IPs
```

(EndpointSlices are the real API — `k -n NS get endpointslices -l kubernetes.io/service-name=SVCNAME` — but `get endpoints` remains the fastest read.)

**Decision path:**

```text
Service unreachable
├── Endpoints EMPTY
│   ├── selector matches no pod labels        → fix svc selector or pod labels
│   │     k get pods -l 'KEY=VALUE' -n NS     ← paste the selector; zero rows = mismatch
│   ├── pods exist but 0/1 READY              → readiness probe failing → playbook 2
│   └── pods don't exist at all               → playbook 1/2 first
├── Endpoints POPULATED but ClusterIP times out
│   ├── curl the POD IP directly from a test pod
│   │     ├── pod IP works, ClusterIP doesn't → kube-proxy broken (see below) or NetworkPolicy
│   │     └── pod IP also fails               → app not listening on that port / netpol
│   ├── targetPort ≠ port the container actually listens on   → fix targetPort
│   │     (named targetPort must match the container port's NAME, not its number)
│   └── NetworkPolicy: k get netpol -A        → a default-deny in the namespace? add an allow policy
└── ClusterIP works, DNS name doesn't        → playbook 6
```

**Root causes ranked by frequency (exam):**

1. Service selector doesn't match pod labels (`app: web` vs `app: web-frontend`).
2. `targetPort` wrong (svc says 8080, container listens on 80) or named port mismatch.
3. Pods not Ready — readiness probe misconfigured → empty endpoints.
4. NetworkPolicy default-deny with no allow rule (exam plants these quietly).
5. kube-proxy not running on the node (DaemonSet broken) — old Services keep working via stale iptables rules; **new** Services are never programmed. That asymmetry is the fingerprint.
6. Wrong port tested (`port` is the Service's port; `nodePort` is the node's; `targetPort` is the container's).

**Fix patterns:**

```bash
k -n NS patch svc SVCNAME -p '{"spec":{"selector":{"app":"web"}}}'
k -n NS patch svc SVCNAME --type=json \
  -p='[{"op":"replace","path":"/spec/ports/0/targetPort","value":80}]'
k run tmp --rm -it --image=busybox:1.36 --restart=Never -- \
  wget -qO- --timeout=2 http://SVCNAME.NS      # in-cluster reachability test, one line
```

Minimal allow policy against a default-deny (adjust labels/ports):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-client-to-web
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: client
    ports:
    - protocol: TCP
      port: 80
```

---

## Playbook 4 — Node NotReady

**Symptom:** `k get nodes` shows `NotReady`; pods on the node stuck `Terminating`/`Unknown`, new pods avoid it.

**First 30 seconds:**

```bash
k get nodes
k describe node NODENAME | grep -A10 Conditions   # Ready False vs Unknown — different diseases
# then get ON the node:
ssh NODENAME && sudo -i                            # exam
docker exec -it cka-worker bash                    # kind lab equivalent
systemctl status kubelet
journalctl -u kubelet --no-pager | tail -50
```

**`Ready=Unknown` vs `Ready=False` is the first fork and most candidates never look:**

- **Unknown** — the kubelet stopped posting status entirely (controller-manager marks it after `node-monitor-grace-period`, default 40 s). Kubelet dead, node off, or network to API server severed.
- **False** — the kubelet is alive and *telling you what's wrong* in the condition message. Read it; it usually names the CNI or the runtime.

**Decision path:**

```text
Node NotReady
├── Ready=Unknown → kubelet not reporting
│   └── on the node: systemctl status kubelet
│       ├── inactive (dead)      → systemctl enable --now kubelet   (enable = survives reboot)
│       ├── activating/auto-restart loop → journalctl -u kubelet | tail -50, match the error:
│       │   ├── "failed to load kubelet config file"      → /var/lib/kubelet/config.yaml missing/mangled
│       │   ├── "unable to load client CA file" / x509    → cert paths in config, or expired kubelet cert
│       │   │       → openssl x509 -noout -enddate -in /var/lib/kubelet/pki/kubelet-client-current.pem
│       │   ├── "dial tcp ...:6443: connect: connection refused" → API server down (playbook 5)
│       │   │       or wrong server: in /etc/kubernetes/kubelet.conf
│       │   ├── "failed to run Kubelet: ... containerd.sock" → systemctl status containerd
│       │   └── "running with swap on is not supported"   → swapoff -a (failSwapOn default true;
│       │                                                    v1.28+ NodeSwap can allow it — read the config)
│       └── kubelet active, node still Unknown → network path node→apiserver
├── Ready=False → read the message in Conditions
│   ├── "container runtime network not ready: ... cni plugin not initialized"
│   │       → ls /etc/cni/net.d/        (empty or broken conflist = your answer)
│   │       → CNI DaemonSet running on this node? k -n kube-system get pods -o wide | grep NODENAME
│   └── runtime unhealthy → systemctl restart containerd; crictl info
└── MemoryPressure / DiskPressure = True (node may still show Ready)
        → df -h /  ; crictl rmi --prune  ; clear /var/log offenders
        → kubelet evicts pods and taints the node until pressure clears
```

**Root causes ranked by frequency (exam):**

1. kubelet stopped (and usually also disabled — restart alone won't survive reboot; the task text often says "make sure it stays fixed": `enable --now`).
2. kubelet config broken — wrong path/typo in `/var/lib/kubelet/config.yaml` or the systemd drop-in (`/etc/systemd/system/kubelet.service.d/10-kubeadm.conf`): `systemctl daemon-reload && systemctl restart kubelet` after fixing.
3. CNI config missing/broken in `/etc/cni/net.d/` — node Ready=False, new pods stuck `ContainerCreating` with `FailedCreatePodSandBox`.
4. containerd stopped.
5. Expired kubelet client cert (rotation failed) — x509 errors in the journal.
6. Disk pressure / disk full.

**Fix patterns:**

```bash
systemctl enable --now kubelet            # fix + persistence in one move
systemctl daemon-reload && systemctl restart kubelet   # after editing unit/drop-in
systemctl restart containerd
grep staticPodPath /var/lib/kubelet/config.yaml        # while you're in there: know your paths
```

Key file map (kubeadm-style nodes, which is what the exam gives you):

| File | Role |
|---|---|
| `/var/lib/kubelet/config.yaml` | KubeletConfiguration (staticPodPath, clusterDNS, auth) |
| `/etc/kubernetes/kubelet.conf` | kubelet's kubeconfig → API server URL, client cert reference |
| `/var/lib/kubelet/kubeadm-flags.env` | extra kubelet flags injected by kubeadm |
| `/var/lib/kubelet/pki/kubelet-client-current.pem` | rotating client cert (symlink) |
| `/etc/cni/net.d/` | CNI config the runtime loads |
| `/opt/cni/bin/` | CNI plugin binaries |

---

## Playbook 5 — Control plane down

**Symptom:** `kubectl` errors (`connection refused`, TLS errors, timeouts) — or kubectl works but the cluster is "frozen": new pods never schedule, Deployments never reconcile.

This playbook has a prerequisite mental model: on kubeadm clusters the control plane runs as **static pods** — the kubelet on the control-plane node reads `/etc/kubernetes/manifests/*.yaml` (fsnotify, applies within seconds) and runs them directly. The API-server "pods" you see in `kube-system` are read-only **mirror pods**. Consequences:

- Deleting the mirror pod with kubectl does nothing durable — kubelet recreates it from the file.
- One bad flag in a manifest = the container exits instantly and kubelet restarts it in a crash loop.
- A YAML **syntax** error in a manifest = kubelet cannot parse it, so the pod silently *vanishes* — no container, no mirror pod, nothing in `crictl ps -a`. The only witness is the kubelet journal.

**First 30 seconds (kubectl is dead — use the runtime directly):**

```bash
ssh CONTROLPLANE && sudo -i          # exam        | docker exec -it cka-control-plane bash  # kind
crictl ps -a | grep -E 'kube-apiserver|etcd'       # -a: SHOW EXITED containers
crictl logs --tail 30 CONTAINER_ID                 # the crash reason, verbatim
journalctl -u kubelet --no-pager | tail -30        # manifest parse errors live here
ls /etc/kubernetes/manifests/
```

If `crictl` complains about the endpoint: `crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a`. Container logs also sit on disk at `/var/log/pods/kube-system_<pod>_<uid>/<container>/*.log` and `/var/log/containers/`.

**Decision path:**

```text
kubectl: "connection refused"
├── crictl ps -a → apiserver container Exited/restarting
│   └── crictl logs <id>
│       ├── "Error: unknown flag: --X"            → typo'd flag name in kube-apiserver.yaml
│       ├── "invalid argument ... --X"            → flag value typo
│       ├── open /etc/kubernetes/pki/...: no such file → wrong cert path (flag or hostPath volume)
│       └── "dial tcp 127.0.0.1:2379: connect: connection refused"
│             → etcd is the patient: crictl ps -a | grep etcd → crictl logs
│               ├── etcd flag/datadir/cert typo in etcd.yaml
│               └── disk full → df -h; etcd refuses to start or goes read-only (playbook 8)
├── crictl ps -a → NO apiserver container at all
│   ├── journalctl -u kubelet | grep -iE 'manifest|apiserver'
│   │     → "could not process manifest" / YAML parse error → fix the file
│   ├── manifest file missing/renamed             → restore into /etc/kubernetes/manifests/
│   └── kubelet itself dead on the CP node        → playbook 4 on this node first
└── apiserver Running & healthy but kubectl still fails → wrong kubeconfig/port/CA → playbook 7

kubectl WORKS but the cluster is frozen
├── new pods Pending, describe shows NO events    → kube-scheduler dead
└── Deployment exists, no ReplicaSet / RS exists, no pods; scale does nothing
                                                  → kube-controller-manager dead
    Check either via:
      k -n kube-system get pods                   # mirror pod missing or CrashLoopBackOff
      k -n kube-system get lease                  # renewTime stale = component not renewing
      crictl ps -a on the CP node + crictl logs   # exact flag error
```

**Root causes ranked by frequency (exam):**

1. Deliberately typo'd flag in a static pod manifest (scheduler and apiserver are the usual victims).
2. Wrong file path in a manifest — cert path, `--etcd-servers` port, hostPath volume.
3. Manifest moved out of / missing from `/etc/kubernetes/manifests/`.
4. etcd down (own manifest broken, or disk).
5. kubelet on the control-plane node stopped (everything static disappears at once).

**Fix patterns:**

```bash
vi /etc/kubernetes/manifests/kube-scheduler.yaml   # fix the flag; kubelet reloads in seconds
# force a sluggish restart: move OUT of the dir, wait for the pod to die, move back
mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/ && sleep 3 && mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
watch crictl ps                                    # confirm it stays up before touching kubectl
```

Never park a backup copy **inside** `/etc/kubernetes/manifests/` — kubelet runs everything in that directory, backup included. Use `/root` or `/tmp`.

etcd health check (paths per `/etc/kubernetes/manifests/etcd.yaml`):

```bash
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health
```

---

## Playbook 6 — DNS failures

**Symptom:** apps error with "no such host"; `nslookup kubernetes.default` fails from pods; Services work by ClusterIP but not by name.

**First 30 seconds:**

```bash
k -n kube-system get deploy coredns                       # replicas? available?
k -n kube-system get pods -l k8s-app=kube-dns             # Running? CrashLoopBackOff?
k -n kube-system get svc kube-dns                         # ClusterIP (10.96.0.10 on this lab)
k run dnstest --rm -it --image=busybox:1.36 --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local
```

**How it's wired** (so the decision path makes sense): every `ClusterFirst` pod gets `/etc/resolv.conf` pointing at the `kube-dns` Service ClusterIP (the kubelet writes it from `clusterDNS` in `/var/lib/kubelet/config.yaml`), with search domains `<ns>.svc.cluster.local svc.cluster.local cluster.local` and `ndots:5`. That Service selects the CoreDNS pods; CoreDNS answers cluster zones from the API and forwards the rest per its Corefile (`forward . /etc/resolv.conf`). Break any link — pods, deployment scale, ConfigMap, Service, kube-proxy path, NetworkPolicy on port 53 — and "DNS is down".

**Decision path:**

```text
nslookup fails from a test pod
├── coredns pods not Running
│   ├── 0 replicas                → k -n kube-system scale deploy coredns --replicas=2
│   └── CrashLoopBackOff          → k -n kube-system logs -l k8s-app=kube-dns --previous
│         └── "Corefile:N - Error during parsing: ..." → fix cm coredns → rollout restart
├── pods Running → k -n kube-system get svc kube-dns   exists? ClusterIP = nameserver in pod resolv.conf?
│   └── k -n kube-system get endpoints kube-dns        empty = selector/readiness problem
├── endpoints fine → query a CoreDNS POD IP directly:
│   nslookup kubernetes.default POD_IP
│   ├── works → path pod→Service broken: kube-proxy (playbook 3) or NetworkPolicy blocking 53/UDP+TCP
│   └── fails → CoreDNS config or its upstream
├── only EXTERNAL names fail      → forward block / node /etc/resolv.conf upstream
└── one pod affected, rest fine   → that pod's dnsPolicy (hostNetwork needs ClusterFirstWithHostNet)
                                     or its node's kubelet clusterDNS
```

**Root causes ranked by frequency (exam):**

1. Corefile in the `coredns` ConfigMap corrupted → pods crash on (re)start with a parse error.
2. CoreDNS scaled to 0 or its pods evicted/pending.
3. `kube-dns` Service deleted or selector mangled → empty endpoints.
4. NetworkPolicy blocking UDP/TCP 53 egress from app namespaces.
5. Wrong `clusterDNS` in kubelet config on one node (single-node symptom).

**Fix patterns:**

```bash
k -n kube-system edit configmap coredns          # fix the Corefile
k -n kube-system rollout restart deploy coredns  # deterministic reload
```

Two timing traps: (1) CoreDNS ships the `reload` plugin — a *corrupted* ConfigMap does **not** kill running pods (they keep the last good config and log the error); it only bites when a pod restarts. So "DNS broke an hour after the change" is a restart, not the edit. (2) After you fix the ConfigMap, kubelet propagates ConfigMap volumes on a sync delay (up to ~1 min) and reload checks every ~30 s — `rollout restart` skips the wait.

---

## Playbook 7 — kubeconfig and auth failures

**Symptom:** kubectl refuses to talk, or talks and gets told no. **The error string names the broken layer** — this playbook is a lookup table plus surgery.

**First 30 seconds:**

```bash
kubectl config current-context
kubectl config view --minify                      # server URL, CA, user for THIS context
kubectl auth whoami                               # v1.28+: who does the server think you are
```

**Decision path — match the error text:**

| Error contains | Layer | Diagnosis / fix |
|---|---|---|
| `connection refused` | TCP | wrong `server:` port, or API server down (playbook 5). Compare with a working kubeconfig; `ss -tlnp \| grep 6443` on the CP node |
| `no such host` / timeout | DNS/route | wrong hostname/IP in `server:` |
| `x509: certificate signed by unknown authority` | server TLS | wrong CA in `certificate-authority(-data)`, or `server:` points at a different cluster |
| `unable to read certificate-authority ... no such file` | file path | kubeconfig references a CA file that isn't there — re-embed data or fix the path |
| `x509: certificate has expired or is not yet valid` | client cert | expired user/component cert → `kubeadm certs check-expiration`, `kubeadm certs renew <name>` |
| `Unauthorized` (401) | authentication | bad/expired token, client cert not signed by the cluster CA — who you are failed |
| `error: You must be logged in` | authentication | same family as 401 |
| `Forbidden` (403) | authorization | authn succeeded; RBAC says no — grant or use the right account |

**401 vs 403 is a classic point-loser:** 401 means the server doesn't know who you are (fix credentials); 403 means it knows exactly who you are and you lack RBAC (fix Role/RoleBinding). They are different subsystems — do not debug RBAC on a 401.

**RBAC surgery kit:**

```bash
k auth can-i list pods -n NS --as=system:serviceaccount:NS:SA     # simulate before and after
k auth can-i --list -n NS --as=system:serviceaccount:NS:SA        # full capability dump
k -n NS create role pod-reader --verb=get,list,watch --resource=pods
k -n NS create rolebinding pod-reader-b --role=pod-reader --serviceaccount=NS:SA
```

Cert inspection when kubeconfig embeds data:

```bash
k config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -subject -enddate
```

Subject `CN` = username, `O` = groups — that is how RBAC sees a cert user.

**Root causes ranked by frequency (exam):**

1. Wrong port/server in a provided kubeconfig ("this config doesn't work, fix it").
2. 403 tasks: ServiceAccount lacking a Role/RoleBinding you must author.
3. Wrong/missing CA (path or data) in a copied kubeconfig.
4. Expired certs (`kubeadm certs check-expiration` scenario).
5. Using the wrong context entirely — self-inflicted.

---

## Playbook 8 — etcd and data-layer issues (awareness level)

The exam rarely asks you to *repair* etcd beyond restore-from-snapshot (week 05 owns that drill), but etcd failures masquerade as API-server failures and you must recognize the costume.

**Symptoms and signatures:**

| Symptom | Signature |
|---|---|
| API server crash-looping | apiserver logs: `dial tcp 127.0.0.1:2379: connect: connection refused` — etcd is down, apiserver is the messenger |
| kubectl slow / timeouts, writes fail | etcd disk latency or quota; etcd logs mention `apply entries took too long` |
| Writes rejected: `etcdserver: mvcc: database space exceeded` | quota hit → `etcdctl alarm list` shows NOSPACE → compact + defrag + `alarm disarm` |
| etcd container exiting | its own manifest broken (`/etc/kubernetes/manifests/etcd.yaml`: data-dir, cert paths, `--listen-client-urls`), or disk full (`df -h /var/lib/etcd`) |

**First checks:** `crictl ps -a | grep etcd`, `crictl logs <id>`, `df -h`, then the `etcdctl endpoint health` command from playbook 5. If data is truly gone or corrupt: snapshot restore (`etcdctl snapshot restore --data-dir=/var/lib/etcd-new`, repoint the manifest's hostPath) — full procedure in week 05.

One prevention habit worth points elsewhere: before touching control-plane manifests, `cp` them to `/root/` — that is your own instant "snapshot".

---

## Monitoring — top, events, component health

**`kubectl top`** needs metrics-server (exam clusters have it; kind does not by default):

```bash
k top nodes
k top pods -A --sort-by=memory                   # --sort-by cpu|memory
k top pods -n NS --containers                    # per-container breakdown
# kind lab only — install metrics-server:
k apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
k -n kube-system patch deploy metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

"Find the top consumer and write its name to a file" is a free-points task — practice the exact flags. `Metrics API not available` means metrics-server is absent/broken, not that the cluster is sick.

**Events firehose** — events are the cluster's own diagnosis, 1-hour TTL by default:

```bash
k get events -A --sort-by=.lastTimestamp | tail -30
k get events -A --field-selector type=Warning
k events -n NS --for pod/PODNAME --types=Warning     # scoped view, modern subcommand
k get events -A -w                                   # live tail while you reproduce
```

**Component health endpoints:**

```bash
k get --raw='/readyz?verbose'      # apiserver readiness, per-check: [+]etcd ok, [+]poststarthook/... ok
k get --raw='/livez?verbose'       # liveness variant; /healthz is deprecated
k -n kube-system get lease         # scheduler/controller-manager alive? stale renewTime = dead
```

`readyz` includes the etcd check — the fastest proof that "apiserver up, etcd down". On a node, scheduler and controller-manager also answer locally: `curl -k https://localhost:10259/healthz` (scheduler) and `:10257` (controller-manager). `kubectl get componentstatuses` is deprecated and unreliable — use leases and the raw endpoints instead.

---

## Traps

Each trap: the wrong assumption, then the correction.

1. **"I deleted the broken kube-scheduler pod and it came back broken."** It's a mirror of a static pod; the API copy is a shadow. Edit `/etc/kubernetes/manifests/kube-scheduler.yaml` on the node.
2. **"I'll back the manifest up right here."** A copy left in `/etc/kubernetes/manifests/` is *executed* — kubelet runs every manifest in the dir. Back up to `/root` or `/tmp`.
3. **"Logs are empty, the container logs nothing."** You read the *current* (freshly restarted) attempt. `k logs POD --previous` shows the attempt that crashed.
4. **"Exit 137 = OOMKilled."** 137 is any SIGKILL: OOM, liveness-kill escalation, eviction. Check `lastState.terminated.reason` and events before writing "OOM" — the fix differs completely.
5. **"Readiness probe fails, so it'll restart soon."** Readiness never restarts anything; it only pulls the pod from endpoints. Only liveness restarts. Misdiagnosing this wastes a rollout.
6. **"Endpoints empty ⇒ selector wrong."** Equally often the selector is fine and pods are simply not Ready (probe failing) — check the READY column before rewriting the Service.
7. **"Traffic still flows, so kube-proxy must be fine."** Existing iptables rules survive kube-proxy's death; only *new* Services break. "Old svc works, new svc dead" ⇒ kube-proxy.
8. **"I fixed the CoreDNS ConfigMap; why is DNS still broken?"** ConfigMap propagation (~1 min) plus reload interval (~30 s). `rollout restart` and stop waiting. Inverse trap: corrupting the Corefile doesn't break *running* pods (reload keeps last-good) — it detonates on the next pod restart.
9. **"NotReady ⇒ restart kubelet."** Ready=**False** means kubelet is alive and telling you the cause (usually CNI/runtime) in the condition message; restarting kubelet is noise. Ready=**Unknown** is the kubelet-down case.
10. **"Pod Pending ⇒ resources or taints."** Zero events on describe means it never met the scheduler — the scheduler itself is down. Ten minutes of taint-hunting won't fix a dead scheduler.
11. **"401 vs 403, whatever."** 401 = authn (credentials), 403 = authz (RBAC). Debugging RBAC on a 401 is unfixable by design.
12. **"The static pod vanished — someone deleted it."** A YAML syntax error makes kubelet skip the manifest silently: no container, no mirror pod, nothing in `crictl ps -a`. Only `journalctl -u kubelet` testifies.
13. **"Quota exceeded — but describe shows nothing."** Admission rejected the pod, so there's no pod to describe. The complaint lives in the ReplicaSet: `k describe rs`.
14. **"Fixed the deployment, pod still CrashLoopBackOff."** You're waiting out restart backoff (up to 5 m). `k delete pod` — the controller recreates instantly with a clean backoff.
15. **"I fixed the node but forgot persistence."** Tasks say "ensure it survives reboot": that's `systemctl enable --now`, not just `start`. Graders check enablement.
16. **"I ssh'd to the node and kept working."** Run `exit` (twice: sudo shell, then ssh) before the next task — kubectl on a worker node either fails or, worse, talks to the wrong cluster with a stale kubeconfig.

---

## Speed patterns

The exam-legal fastest route for each recurring move (docs allowed, but you shouldn't need them for these):

```bash
# 0. Every task, no exceptions
kubectl config use-context NAME

# 1. Cluster-wide triage in three lines
k get nodes ; k get pods -A | grep -vE 'Running|Completed'
k get events -A --sort-by=.lastTimestamp | tail -20

# 2. Broken-pod inner loop (describe tail → previous logs → exit code)
k -n NS describe pod POD | tail -20
k -n NS logs POD --previous --tail=30
k -n NS get pod POD -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}'

# 3. Service chain in four commands (svc → ep → labels → live test)
k -n NS get svc SVC -o wide ; k -n NS get ep SVC
k -n NS get pods --show-labels
k run tmp --rm -it --image=busybox:1.36 --restart=Never -- wget -qO- --timeout=2 http://SVC.NS

# 4. Node ritual (exam nodes: ssh + sudo; kind: docker exec)
ssh NODE ; sudo -i
systemctl is-active kubelet containerd
journalctl -u kubelet --no-pager | tail -50
systemctl enable --now kubelet ; exit ; exit

# 5. Control-plane ritual when kubectl is dead
crictl ps -a | grep -E 'apiserver|etcd|scheduler|controller'
crictl logs --tail 30 CONTAINER_ID
journalctl -u kubelet --no-pager | grep -i manifest | tail
vi /etc/kubernetes/manifests/BROKEN.yaml

# 6. Force a static pod restart (kubelet slow to notice an edit)
mv /etc/kubernetes/manifests/X.yaml /tmp/ && sleep 3 && mv /tmp/X.yaml /etc/kubernetes/manifests/

# 7. DNS proof in one line
k run dnstest --rm -it --image=busybox:1.36 --restart=Never -- nslookup kubernetes.default.svc.cluster.local

# 8. RBAC verify-first, verify-after
k auth can-i VERB RESOURCE -n NS --as=system:serviceaccount:NS:SA

# 9. Answer-file tasks — never hand-copy
k top pods -n NS --sort-by=cpu | head -2 | tail -1 | awk '{print $1}' > /opt/answer.txt

# 10. Immutable pod field? Don't fight edit:
k -n NS get pod POD -o yaml > /tmp/p.yaml && vi /tmp/p.yaml && k replace --force -f /tmp/p.yaml
```

Time discipline: troubleshooting tasks are the heaviest in the exam — budget ~8 minutes, flag anything that exceeds 10 and move on (PSI's interface has a flag button; use it). A dead control plane you can't crack in 10 minutes is worth fewer points than three Service fixes you skipped for it. On the PSI remote desktop, copy/paste is Ctrl+Shift+C / Ctrl+Shift+V in the terminal — practice it in killer.sh so it's muscle memory, not friction.

---

## Docs map

What you'll actually open mid-exam (kubernetes.io unless noted). Bookmarks aren't allowed; the search box plus these paths are your index.

| You need | Path |
|---|---|
| Pod debugging flowchart (Pending/Crash/ImagePull) | /docs/tasks/debug/debug-application/debug-pods/ |
| `kubectl debug`, ephemeral containers, node debug | /docs/tasks/debug/debug-application/debug-running-pod/ |
| Service debugging checklist (endpoints, ports) | /docs/tasks/debug/debug-application/debug-service/ |
| DNS debugging (dnsutils pod, CoreDNS logs) | /docs/tasks/administer-cluster/dns-debugging-resolution/ |
| Node/cluster-level debugging | /docs/tasks/debug/debug-cluster/ |
| crictl usage + docker-CLI mapping | /docs/tasks/debug/debug-cluster/crictl/ |
| Resource metrics / `kubectl top` pipeline | /docs/tasks/debug/debug-cluster/resource-metrics-pipeline/ |
| kubeadm troubleshooting (certs, kubelet, ports) | /docs/setup/production-environment/tools/kubeadm/troubleshooting-kubeadm/ |
| Cert expiry / renewal (`kubeadm certs`) | /docs/tasks/administer-cluster/kubeadm/kubeadm-certs/ |
| Static pods | /docs/tasks/configure-pod-container/static-pod/ |
| Kubelet config file options | /docs/tasks/administer-cluster/kubelet-config-file/ |
| Probe syntax (liveness/readiness/startup) | /docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/ |
| NetworkPolicy recipes | /docs/concepts/services-networking/network-policies/ |
| RBAC (Role/Binding matrices) | /docs/reference/access-authn-authz/rbac/ |
| API health endpoints (readyz/livez) | /docs/reference/using-api/health-checks/ |
| etcd backup/restore | /docs/tasks/administer-cluster/configure-upgrade-etcd/ |

---

## Checkpoint

Run these against the kind lab (use `labs/breakfix/` to arm real breakage). Honest timing, no peeking:

- Can you triage "something is broken somewhere" to the owning playbook in **2 minutes** using only the universal-first-minute commands?
- Can you take a Pending pod to Running (taint or resources) in **4 minutes**, including the immutable-field replace dance?
- Can you diagnose a CrashLoopBackOff to its exact cause (probe vs config ref vs command vs OOM) in **5 minutes**, citing the exit code?
- Can you fix an empty-endpoints Service (selector or targetPort) and prove it with an in-cluster wget in **5 minutes**?
- Can you bring a NotReady node (kubelet stopped + disabled) back, persistently, in **5 minutes** — and state whether it was Ready=Unknown or Ready=False before you touched it?
- Can you recover a dead API server (typo'd manifest flag) using only crictl + journal + vi in **10 minutes**?
- Can you spot "scheduler down" from a Pending pod with no events in **1 minute**?
- Can you restore cluster DNS (crashlooping CoreDNS with a corrupt Corefile) in **7 minutes**?
- Can you repair a broken kubeconfig (wrong port + bad CA reference) in **6 minutes**?
- Can you classify 401 vs 403 instantly and fix the 403 with an imperative Role+RoleBinding in **4 minutes**?
- Can you name the top-CPU pod in a namespace into a file in **90 seconds**?
- Can you check apiserver readiness including its etcd check with one command in **30 seconds**?

Anything over target: re-run the matching playbook and the matching break script until it isn't.
