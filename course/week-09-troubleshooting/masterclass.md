# Week 09 Masterclass — Troubleshooting (30% of the exam — the single largest domain, the exam-decider)

> 🧭 **Learning path:** [‹ week-08-networking](../week-08-networking/masterclass.md) · [Tier map](../LEARNING-PATH.md) · [week-10-final-prep ›](../week-10-final-prep/masterclass.md)


Troubleshooting is 30% of the CKA. It is also the domain that silently eats the other four: a "Storage" task that presents as a Pending pod, a "Networking" task that presents as empty endpoints, an "Architecture" task that presents as a dead apiserver. The exam does not label these tasks by domain. You are handed a symptom and a broken cluster, and the clock is running. Winning here is not knowledge, it is **method**: the same four questions and the same first-30-seconds command set applied to every symptom, so you never freeze staring at a Pending pod wondering where to start.

This masterclass is eight playbooks. Each has the same shape: **symptom → first-30-seconds commands → decision path (a text decision tree) → root causes ranked by how often they are the actual cause → fix patterns.** Memorize the shape, not just the content. On exam day you will not have time to think about *how* to troubleshoot; you will only have time to execute.

> **Lab note:** everything here runs on the 3-node kind cluster `cka` (context `kind-cka`, nodes `cka-control-plane` / `cka-worker` / `cka-worker2`). On kind, each node is a Docker container running systemd, so `docker exec cka-worker systemctl status kubelet` and `journalctl -u kubelet` work exactly as they would over SSH on a real kubeadm node. Where the real exam differs (you `ssh node01` and use `sudo`), a one-line **exam-flavor** note calls it out.

Assume these are set (course convention): `alias k=kubectl`, `export do="--dry-run=client -o yaml"`, `export now="--grace-period=0 --force"`.

## What the exam actually asks

| Symptom you are handed | Real domain(s) behind it | Playbook |
|---|---|---|
| "Pod X stays Pending — make it run" | Scheduling 15% / Storage 10% / Troubleshooting 30% | 1 |
| "Pod X keeps restarting / CrashLoopBackOff / ImagePullBackOff" | Workloads 15% / Troubleshooting 30% | 2 |
| "Pods are Running but the app is unreachable through its Service" | Networking 20% / Troubleshooting 30% | 3 |
| "Node nodeXX is NotReady — fix it" | Architecture 25% / Troubleshooting 30% | 4 |
| "kubectl returns nothing / apiserver is down / deployments don't scale" | Architecture 25% / Troubleshooting 30% | 5 |
| "Pods can't resolve service names / DNS is broken" | Networking 20% / Troubleshooting 30% | 6 |
| "This kubeconfig doesn't work / user gets Forbidden" | Cluster Architecture 25% / Troubleshooting 30% | 7 |
| "etcd is unhealthy / restore from a snapshot" | Architecture 25% / Troubleshooting 30% | 8 |

Not asked: reading Go stack traces from component source, writing a CNI plugin, deep BGP/Calico internals. The exam wants you to **localize the fault to a component, read that component's own logs, and apply a standard fix** — fast. Written against Kubernetes v1.31+ behavior; where something is version-dependent it is flagged inline. Confirm the live exam version on the CNCF curriculum page (github.com/cncf/curriculum) before your attempt.

---

## The universal first move

Before any playbook, every troubleshooting task answers four questions in order. Do not skip ahead; skipping is how you waste ten minutes fixing the wrong layer.

1. **Is the control plane answering me?** `k get nodes` returns instantly → apiserver + etcd are alive; go to the workload. It hangs or errors → you are in Playbook 5 first, everything else is downstream noise.
2. **What object is unhealthy, and what does its status say?** `k get <kind> <name> -n <ns> -o wide` — READY column, STATUS, RESTARTS, NODE, IP. The status string is a diagnosis, not decoration: `ImagePullBackOff`, `CreateContainerConfigError`, `ContainerCreating` stuck, `Pending`, `NotReady` each point at a specific layer.
3. **What do the events say?** `k describe <kind> <name> -n <ns>` — read the **Events** block at the bottom first. A large share of exam troubleshooting is solved by reading events. The scheduler, kubelet, and controllers narrate their failures here.
4. **What do the logs say?** For a workload: `k logs <pod> -n <ns>` and, when it has restarted, `k logs <pod> -n <ns> --previous`. For a cluster component that is a static pod: `k logs -n kube-system <static-pod>`; if the apiserver is dead, drop to `crictl logs`.

The commands you type reflexively, in every task:

```bash
k get pods -A -o wide                 # cluster-wide health at a glance; watch for non-Running
k get events -A --sort-by=.lastTimestamp | tail -30   # the events firehose, newest last
k describe <kind> <name> -n <ns>      # events + spec reality for one object
k get componentstatuses               # legacy but instant control-plane triage (deprecated, still works)
```

Speed reflex: never open an editor to *read* a status. `k get`/`k describe`/`k logs` beat any editor. Only edit once you have already localized the fault.

---

## Playbook 1 — Pod Pending (it will not schedule)

**Symptom:** `STATUS: Pending`, `NODE: <none>`. The pod object exists but no kubelet has been told to run it, because the scheduler has not bound it to a node — or cannot.

**First 30 seconds:**

```bash
k get pod webapp -n prod -o wide                 # confirm Pending, NODE <none>
k describe pod webapp -n prod | tail -20         # Events: "FailedScheduling ..." is the whole answer
k get nodes                                       # are nodes Ready at all?
k describe node cka-worker | grep -A6 -iE 'taint|allocatable|pressure'
```

The `FailedScheduling` event from the scheduler literally names the reason: `Insufficient cpu`, `Insufficient memory`, `node(s) had untolerated taint {...}`, `node(s) didn't match Pod's node affinity/selector`, `pod has unbound immediate PersistentVolumeClaims`, `0/3 nodes are available`.

**Decision path:**

```text
describe pod -> Events block
|
+-- No events at all, ever  --------------------> scheduler itself is down -> go to Playbook 5
|
+-- "Insufficient cpu/memory" --------------------> requests exceed free Allocatable
|      fix: lower requests, or free/scale nodes, or remove other pods
|
+-- "untolerated taint {key: value}" -------------> node tainted (control-plane NoSchedule, or custom)
|      fix: add matching toleration, or target a schedulable node, or (rarely) remove the taint
|
+-- "didn't match node affinity/selector" --------> nodeSelector/affinity has no matching node
|      fix: correct the label selector, or label a node to match
|
+-- "unbound ... PersistentVolumeClaims" ---------> PVC not Bound -> jump to the PVC sub-tree below
|
+-- "0/3 nodes available: node(s) had ... " ------> combination; read every clause, each is one node's reason
```

PVC sub-tree (Pending because storage will not bind):

```text
k get pvc -n <ns>   ->  STATUS Pending
|
+-- describe pvc: "no persistent volumes available ... no storage class" -> no (default) StorageClass
+-- "waiting for first consumer" + WaitForFirstConsumer -> NORMAL: PVC binds only once a pod schedules
+-- provisioner name wrong / provisioner pod down -> check the CSI/provisioner pod in kube-system
```

**Root causes, ranked:**

1. **Insufficient resources** — requests too high for remaining Allocatable. Most common in scale-up tasks.
2. **Taints without tolerations** — classic on control-plane nodes (`node-role.kubernetes.io/control-plane:NoSchedule`) and after `kubectl cordon`/pressure taints.
3. **PVC won't bind** — missing/renamed StorageClass, or genuinely `WaitForFirstConsumer` (not a bug).
4. **nodeSelector / nodeAffinity mismatch** — a label typo, or the target label was never applied to any node.
5. **Scheduler down** — no events *ever*; the pod is invisible to scheduling. This is Playbook 5.

**Fix patterns:**

```bash
# Scheduler's own words for every node it rejected:
k get events -n prod --field-selector reason=FailedScheduling

# Taint: tolerate it on the pod, or (if a leftover) remove it from the node
k taint nodes cka-worker dedicated=team-a:NoSchedule-      # trailing minus removes a taint

# Resources: shrink the request so it fits
k set resources deploy webapp -n prod --requests=cpu=100m,memory=128Mi

# Node label to satisfy a selector
k label node cka-worker disktype=ssd
```

**Trap:** `Pending` with `NODE` already set is **not** a scheduling problem — the scheduler already bound it; the kubelet is stuck (image pull, volume mount). Read events, not scheduler capacity. And a pod stuck `ContainerCreating` is *not* Pending — it is scheduled and the kubelet is failing to start it (CNI, volume, secret) — that is Playbook 2/4 territory.

---

## Playbook 2 — Pod crashing / CrashLoopBackOff / image errors

**Symptom:** high `RESTARTS`, `STATUS: CrashLoopBackOff`, `Error`, `ImagePullBackOff`, `ErrImagePull`, `CreateContainerConfigError`, or `RunContainerError`.

**First 30 seconds:**

```bash
k get pod api -n prod -o wide                       # RESTARTS count, STATUS string
k describe pod api -n prod                           # Events + Last State + Exit Code + Reason
k logs api -n prod                                   # current attempt
k logs api -n prod --previous                        # the attempt that CRASHED (this is the gold)
```

`--previous` is the single most important flag in this playbook. A CrashLooping container's *current* logs are usually empty (it just restarted); the logs that explain the crash belong to the **previous** dead container. For multi-container pods add `-c <container>`.

**Decision path — split by the STATUS string first, because they mean different failure layers:**

```text
STATUS string
|
+-- ImagePullBackOff / ErrImagePull -----------> kubelet cannot GET the image (never even started)
|      describe -> Events: "failed to pull ... not found / unauthorized / no such host"
|      causes: image typo | wrong tag | private registry, no imagePullSecret | air-gapped node
|
+-- CreateContainerConfigError ----------------> a referenced ConfigMap/Secret key does not exist
|      describe -> "couldn't find key X" / "secret Y not found"
|      causes: envFrom/valueFrom points at a missing CM/Secret or missing key
|
+-- RunContainerError / CreateContainerError --> command/mount problem at container start
|      causes: bad command/args, missing mount, readonly fs, wrong securityContext
|
+-- CrashLoopBackOff / Error (Exit Code N) ----> container STARTED then died -> read logs --previous
       Exit 0   : process finished (a job/one-shot mislabeled as long-running) -> not really a bug
       Exit 1   : generic app error -> logs --previous tell you what
       Exit 137 : SIGKILL -> OOMKilled (Reason: OOMKilled) or liveness probe killed it
       Exit 139 : SIGSEGV -> app segfault
       Exit 143 : SIGTERM -> killed during shutdown (often liveness/eviction)
```

Then the probe overlay — probes turn a *healthy* app into a restart loop:

```text
Events show "Liveness probe failed" / "Readiness probe failed"
|
+-- Liveness failing  -> kubelet keeps KILLING and restarting a working container
|      cause: probe path/port/scheme wrong, or initialDelaySeconds too short (app not up yet)
+-- Readiness failing -> container runs but never enters Ready -> pulled OUT of Service endpoints
       cause: same probe misconfig; app is fine, Service just looks "dead" (this is also Playbook 3)
```

**Root causes, ranked:**

1. **Image name/tag wrong or unpullable** — `ImagePullBackOff`. Fastest fix in the whole exam if you spot it.
2. **Missing ConfigMap/Secret reference** — `CreateContainerConfigError`; the pod never runs until the key exists.
3. **App misconfiguration** — bad env var, missing file, wrong DB host → Exit 1, read `--previous`.
4. **OOMKilled** — Exit 137, `Reason: OOMKilled`; memory limit too low or a leak. Raise the limit or fix the app.
5. **Probe misconfiguration** — a healthy container killed by a wrong liveness probe, or drained by a wrong readiness probe.

**Fix patterns:**

```bash
# Image typo -> just set the right image, deployment rolls itself
k set image deploy/api api=nginx:1.27 -n prod

# Confirm the missing reference the kubelet is complaining about
k get pod api -n prod -o jsonpath='{.spec.containers[*].envFrom}{"\n"}'
k get configmap,secret -n prod

# OOM: raise the limit
k set resources deploy/api -n prod --limits=memory=256Mi

# Probe wrong: edit the probe (path/port/initialDelaySeconds)
k edit deploy/api -n prod     # fix livenessProbe.httpGet.port / .path / initialDelaySeconds

# Private registry: attach an imagePullSecret
k create secret docker-registry regcred --docker-server=registry.internal \
  --docker-username=svc --docker-password=REDACTED -n prod
k patch sa default -n prod -p '{"imagePullSecrets":[{"name":"regcred"}]}'
```

**Trap:** `RESTARTS: 0` with `STATUS: Completed` is not broken — it is a Job/one-shot that ran to completion. And a pod that is `Running` but `0/1` READY is *not* crashing — it is failing readiness (Playbook 3). Match the fix to the exact column.

---

## Playbook 3 — Pod Running but the app is unreachable

**Symptom:** pods are `Running` and `1/1 READY`, but a client (test pod, curl, or the exam checker) cannot reach the app through its Service.

**First 30 seconds:**

```bash
k get pod -n prod -o wide -l app=web                 # are the pods actually READY (not just Running)?
k get svc web -n prod -o wide                          # type, CLUSTER-IP, PORT(S), SELECTOR
k get endpointslices -n prod -l kubernetes.io/service-name=web   # ADDRESSES: empty == the bug
k describe svc web -n prod | grep -i endpoints        # fastest endpoints check
```

The single decisive question: **does the Service have endpoints?** No endpoints → the Service selector does not match ready pods → nothing else matters. Endpoints present but unreachable → it is a port, policy, or node-path problem.

**Decision path:**

```text
k describe svc -> Endpoints:
|
+-- Endpoints: <none>  ---------------------------------> selector/label mismatch OR pods not Ready
|      check 1: do svc.spec.selector labels == pod labels?  (typo like app=web vs app=web-frontend)
|      check 2: are pods READY? a failing readinessProbe removes them from endpoints
|      fix: correct the selector, or fix the readiness probe / the app
|
+-- Endpoints present (IP:port list) -------------------> selector is fine; test each layer inward
       test A (app itself):  wget POD_IP:targetPort     -> fails? app/port problem, back to Playbook 2
       test B (service):     wget CLUSTERIP:port         -> fails but A works? port/targetPort mismatch
       test C (dns):         wget svc.ns.svc:port         -> fails but B works? DNS problem -> Playbook 6
       test D (policy):      any NetworkPolicy in ns?    -> a default-deny with no matching allow
```

Run those inward tests from a throwaway pod:

```bash
k run tmp --rm -it --image=busybox:1.36 --restart=Never -- sh
# inside, substitute real values from the describe output:
#   wget -qO- --timeout=2 http://10.244.1.7:80          # A: is the app alive at all?
#   wget -qO- --timeout=2 http://10.96.12.34:80          # B: does the Service DNAT reach it?
#   wget -qO- --timeout=2 http://web.prod.svc:80         # C: does DNS + Service work end to end?
```

**Root causes, ranked:**

1. **Selector/label mismatch** — Service `spec.selector` does not equal the pods' labels. `Endpoints: <none>`. The #1 "app unreachable" cause on the exam.
2. **port vs targetPort mismatch** — Service `port` is what clients hit; `targetPort` must equal the container's listening port. Wrong `targetPort` → connection refused with healthy endpoints.
3. **Readiness probe failing** — pods `Running` but `0/1`, silently pulled out of endpoints. Looks like a dead Service; is actually a probe/app bug.
4. **NetworkPolicy default-deny** — a `default-deny` policy with no matching allow rule blocks the traffic; endpoints look perfect.
5. **DNS** — name won't resolve but ClusterIP works → Playbook 6, not a Service bug.

**Fix patterns:**

```bash
# See the actual pod labels vs the service selector, side by side
k get pods -n prod --show-labels
k get svc web -n prod -o jsonpath='{.spec.selector}{"\n"}'

# Fix a wrong selector
k patch svc web -n prod -p '{"spec":{"selector":{"app":"web"}}}'

# Fix targetPort
k patch svc web -n prod --type=json -p='[{"op":"replace","path":"/spec/ports/0/targetPort","value":80}]'

# Prove/deny a NetworkPolicy is the cause
k get netpol -n prod
k describe netpol default-deny -n prod
```

**Trap:** `Endpoints: <none>` on a **headless** Service (`clusterIP: None`) is normal if it is meant for a specific StatefulSet. And endpoints populated but the exam checker still fails often means the client is in another namespace and needs the FQDN `web.prod.svc.cluster.local`, or a NetworkPolicy blocks cross-namespace traffic. Always test from where the *checker* sits.

---

## Playbook 4 — Node NotReady

**Symptom:** `k get nodes` shows a node `NotReady`. Pods on it go to `Terminating`/`Unknown`; new pods scheduled there stick in `ContainerCreating`.

**First 30 seconds (from the API):**

```bash
k get nodes -o wide                                        # which node, and its kubelet/runtime versions
k describe node cka-worker | grep -A15 Conditions          # Ready=False + the REAL reason string
k get pods -A -o wide --field-selector spec.nodeName=cka-worker
```

Then get **onto the node** — this is where the answer lives. On kind: `docker exec -it cka-worker bash`. Exam-flavor: `ssh cka-worker` then `sudo -i`.

```bash
docker exec cka-worker systemctl status kubelet            # is the kubelet even running?
docker exec cka-worker journalctl -u kubelet -n 40 --no-pager   # its own error log
docker exec cka-worker systemctl status containerd         # is the runtime up?
```

**Decision path:**

```text
describe node -> Conditions.Ready reason
|
+-- "kubelet stopped posting node status" / Unknown -> kubelet not running or can't reach API
|     on node: systemctl status kubelet
|       dead/inactive -> systemctl start kubelet ; enable it to survive reboot
|       active but failing -> journalctl -u kubelet -> read the fatal line:
|         * "failed to load Kubelet config file /var/lib/kubelet/config.yaml" -> bad/edited config
|         * "open /var/lib/kubelet/pki/... certificate ... expired" -> kubelet client cert expired
|         * "failed to run Kubelet: ... cgroup" -> cgroup driver mismatch vs containerd
|
+-- "container runtime network not ready: cni ... uninitialized" -> CNI config/plugin missing
|     on node: ls /etc/cni/net.d   (empty?)  ;  ls /opt/cni/bin
|       fix: restore the CNI config (or reinstall the CNI DaemonSet), restart containerd + kubelet
|
+-- "container runtime is down" / "failed to get container runtime status" -> containerd dead
|     on node: systemctl status containerd -> start it -> kubelet recovers
|
+-- MemoryPressure/DiskPressure/PIDPressure = True -> node resource-starved -> node tainted, evicting
      on node: df -h ; check /var full -> free space (logs, images: crictl rmi --prune)
```

**Root causes, ranked:**

1. **kubelet stopped** — crashed, `systemctl stop`ped, or disabled. `systemctl start kubelet` (+`enable`). The most common single break.
2. **kubelet misconfigured** — someone edited `/var/lib/kubelet/config.yaml` (bad YAML, wrong `cgroupDriver`, wrong `staticPodPath`) or `/var/lib/kubelet/kubeconfig`; kubelet won't start until it's valid.
3. **CNI missing** — `/etc/cni/net.d` empty or `/opt/cni/bin` gone → runtime network never initializes → node NotReady, pods ContainerCreating. (Emphasized post-Feb-2025: CNI awareness.)
4. **containerd down** — runtime not answering the kubelet's CRI calls.
5. **Resource pressure** — disk/memory full → pressure taints → evictions and NotReady.

**Fix patterns:**

```bash
# kubelet down (must survive reboot -> enable)
docker exec cka-worker systemctl enable --now kubelet

# kubelet config broken: read the exact parse error, then fix the file
docker exec cka-worker journalctl -u kubelet -n 20 --no-pager
docker exec cka-worker vi /var/lib/kubelet/config.yaml       # fix, then:
docker exec cka-worker systemctl restart kubelet

# CNI config gone: put it back, bounce the runtime and kubelet
docker exec cka-worker ls -la /etc/cni/net.d
docker exec cka-worker systemctl restart containerd kubelet

# Verify recovery (allow ~30-60s for status to post)
k get nodes -w
```

**Exam-flavor:** on kubeadm nodes the kubelet is a host systemd unit; use `sudo systemctl`. `/var/lib/kubelet/config.yaml` is the live config, `/etc/kubernetes/kubelet.conf` is the kubeconfig it uses to talk to the API. A NotReady node that comes back after `systemctl start kubelet` almost always needs `enable` too, because the task usually says "survive a reboot."

---

## Playbook 5 — Control plane down

**Symptom:** `kubectl` hangs or returns `The connection to the server ... was refused`, or subtler: pods stay `Pending` forever (scheduler dead) / Deployments never create ReplicaSets (controller-manager dead) / everything is read-only-stale (etcd dead).

kubeadm control-plane components run as **static pods**: the kubelet on the control-plane node watches `/etc/kubernetes/manifests/` and runs whatever `*.yaml` it finds there. A single bad flag in one of those files makes that component crash-loop. Because the kubelet manages them directly, you cannot `kubectl edit` them — you edit the file on disk and the kubelet reconciles within seconds.

**First 30 seconds — when kubectl is dead, use crictl (talks straight to containerd, no apiserver needed):**

```bash
# from the control-plane node:
docker exec cka-control-plane crictl ps -a | grep -E 'kube-apiserver|etcd|scheduler|controller'
docker exec cka-control-plane crictl logs <container-id>        # the crash reason (paste the real id)
docker exec cka-control-plane ls /etc/kubernetes/manifests/     # the four static pod manifests
docker exec cka-control-plane journalctl -u kubelet -n 30 --no-pager   # kubelet's view of static pods
```

`crictl` may need the runtime endpoint if `/etc/crictl.yaml` is not set: `crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a`. On kind it is preconfigured.

**Decision path:**

```text
kubectl works?
|
+-- NO (connection refused / timeout) -----------> apiserver or etcd is down
|     crictl ps -a: is kube-apiserver present and NOT restarting?
|       apiserver absent/looping -> crictl logs <apiserver>:
|          "unknown flag --xxx" / "invalid value" -> typo in kube-apiserver.yaml manifest -> fix file
|          "connection refused ... 2379" -> etcd is down -> fix etcd first (apiserver depends on it)
|       etcd absent/looping -> crictl logs <etcd>: bad flag, wrong data-dir, or cert path -> fix manifest
|     after fixing the file: kubelet re-creates the pod in ~15-30s; watch crictl ps
|
+-- YES, but symptoms are indirect ---------------> scheduler or controller-manager is down
      pods stuck Pending, describe shows NO events         -> kube-scheduler crash-looping
      Deployments don't create pods / nodes not GC'd / SA  -> kube-controller-manager crash-looping
      k get pods -n kube-system | grep -E 'scheduler|controller'   -> CrashLoopBackOff / not there
      k logs -n kube-system kube-scheduler-cka-control-plane        -> the bad flag / cert / kubeconfig
```

**Root causes, ranked:**

1. **Typo in a static pod manifest** — a bad flag (`--leader-elect-and-hope=true`), wrong indentation, wrong `--etcd-servers`, wrong image tag. The kubelet dutifully runs the broken spec; the component crash-loops. Overwhelmingly the exam's control-plane break.
2. **etcd down / wrong data-dir / cert path** — apiserver can't start ("connection refused to 2379"); fix etcd first, apiserver recovers on its own.
3. **Certificate/kubeconfig problem** — a component's client cert expired or its `/etc/kubernetes/*.conf` points at the wrong CA/server.
4. **Manifest moved/deleted** — someone `mv`'d `kube-scheduler.yaml` out of the manifests dir → the component simply vanishes (not crash-looping, just *gone*).
5. **Port/host binding conflict** — rare; `--secure-port` collision.

**Fix patterns:**

```bash
# Localize which static pod is broken and why (kubectl-independent):
docker exec cka-control-plane crictl ps -a | grep -E 'apiserver|etcd|sched|controller'
docker exec cka-control-plane crictl logs --tail=25 <container-id>

# Fix the manifest on disk; the kubelet reconciles automatically (no restart command needed)
docker exec cka-control-plane vi /etc/kubernetes/manifests/kube-scheduler.yaml

# Force a clean re-read if it seems stuck: move it out and back
docker exec cka-control-plane sh -c 'mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/ && sleep 20 && mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/'

# Once apiserver is back, confirm health:
k get --raw='/readyz?verbose'
```

**Trap:** you cannot `kubectl edit` a static pod — editing the mirror pod does nothing; edit the file in `/etc/kubernetes/manifests/`. And do not `crictl rm` the apiserver container hoping it restarts "clean" — the kubelet recreates it from the same (still-broken) manifest. Fix the *manifest*, not the container. Also: after fixing, give the kubelet 15-30s; impatience makes people "fix" a second thing that was never broken.

---

## Playbook 6 — DNS failures

**Symptom:** pods can reach Services by ClusterIP but not by name; `nslookup kubernetes.default` from a pod times out or `NXDOMAIN`; apps that dial `db.prod.svc` error with "no such host."

Cluster DNS is CoreDNS: a Deployment (`coredns`, 2 replicas) in `kube-system`, fronted by a Service named `kube-dns` (historical name) at a fixed ClusterIP (usually `.10` in the service CIDR). Every pod's `/etc/resolv.conf` points `nameserver` at that ClusterIP, injected by the kubelet.

**First 30 seconds:**

```bash
k -n kube-system get pods -l k8s-app=kube-dns -o wide     # are CoreDNS pods Running and READY? (0 replicas?)
k -n kube-system get deploy coredns                        # READY 0/0 means someone scaled it down
k -n kube-system get svc kube-dns                          # ClusterIP present? endpoints?
k -n kube-system logs -l k8s-app=kube-dns --tail=30        # CrashLoop? "plugin/... unknown directive"?
```

Then test resolution from a throwaway pod (ground truth):

```bash
k run dnstest --rm -it --image=busybox:1.36 --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local
```

**Decision path:**

```text
CoreDNS pods
|
+-- 0 replicas (deploy scaled to 0) -----------> k -n kube-system scale deploy coredns --replicas=2
|
+-- CrashLoopBackOff ---------------------------> corrupt Corefile ConfigMap
|     logs: "Corefile:N - Error ... unknown directive 'forwrad'" -> typo in the coredns ConfigMap
|     fix: k -n kube-system edit configmap coredns  (fix the directive) -> pods self-heal
|
+-- Running & Ready, but resolution still fails
|     check kube-dns Service has the right ClusterIP + endpoints (the CoreDNS pod IPs)
|     check a pod's /etc/resolv.conf nameserver == kube-dns ClusterIP
|     check no NetworkPolicy in kube-system blocks port 53 UDP/TCP
|
+-- resolves cluster names but not external -----> forward plugin / upstream (/etc/resolv.conf) issue
```

**Root causes, ranked:**

1. **CoreDNS scaled to 0** — deploy `coredns` at `0/0`; nothing serves DNS. `scale --replicas=2`.
2. **Corrupt Corefile ConfigMap** — a typo (`forwrad`), a bad `errors`/`ready` directive → CoreDNS crash-loops. Fix the `coredns` ConfigMap; the pods reload.
3. **kube-dns Service broken** — wrong ClusterIP, deleted, or empty endpoints (its selector must match CoreDNS pod labels `k8s-app=kube-dns`).
4. **resolv.conf / ndots** — pod `dnsPolicy` wrong, or upstream `forward . /etc/resolv.conf` loops. Less common on the exam.
5. **NetworkPolicy blocking 53** — a default-deny in `kube-system` or the app namespace eating DNS.

**Fix patterns:**

```bash
# The two most common CKA DNS fixes, back to back:
k -n kube-system scale deploy coredns --replicas=2
k -n kube-system edit configmap coredns          # fix the Corefile directive (e.g. forwrad -> forward)

# CoreDNS reloads the ConfigMap on its own (reload plugin); to force, roll it:
k -n kube-system rollout restart deploy coredns

# Verify kube-dns has endpoints (CoreDNS pod IPs)
k -n kube-system get endpoints kube-dns
```

**Trap:** the Service is named `kube-dns`, not `coredns` — the Deployment is `coredns`, the Service is `kube-dns`. Grepping for the wrong one wastes time. And CoreDNS pods `Running` with `nslookup` still failing usually means the **Service/endpoints** layer, not CoreDNS itself — test resolution against a CoreDNS pod IP directly to bisect pod-vs-service.

---

## Playbook 7 — kubeconfig / auth failures

**Symptom:** `kubectl` errors before it can even do work: `connection refused`, `x509: certificate signed by unknown authority`, `Unauthorized (401)`, or it *works* but a specific action returns `Forbidden (403)`.

A kubeconfig is three linked parts: **clusters** (server URL + CA to trust), **users** (client credentials — cert/key, token, or exec), and **contexts** (which user + cluster + namespace is current). A failure is almost always a mismatch in one of those three.

**First 30 seconds:**

```bash
k config current-context                         # which context is even active?
k config view --minify                            # the resolved cluster/user/namespace for it (redacted)
k config view --minify --raw | grep -E 'server:|certificate-authority|client-certificate'  # real values
k get nodes -v=7 2>&1 | head -20                  # verbose shows the exact HTTP/TLS failure
```

**Decision path — classify the error string, it names the layer:**

```text
error string
|
+-- "connection refused" / "no route to host" / timeout -> TRANSPORT: wrong server host or port
|     fix: correct clusters[].cluster.server (right host, right port, https)
|
+-- "x509: certificate signed by unknown authority" ----> wrong/missing CA
|     fix: point certificate-authority(-data) at the cluster's real CA
|
+-- "x509: certificate has expired or is not yet valid" -> client cert expired (or clock skew)
|     fix: renew the user cert (kubeadm certs renew, or re-issue via CSR); check date on node
|
+-- "Unauthorized" (401) ------------------------------> AUTHN failed: bad/expired token or cert-CA mismatch
|     the API does not know WHO you are -> credentials are wrong
|
+-- "Forbidden" (403) ---------------------------------> AUTHN ok, AUTHZ failed: RBAC denies this verb
      the API knows who you are, but you lack the (Cluster)Role/binding for this action -> RBAC
```

The 401-vs-403 split is the exam's favorite trick and the fastest triage you own:

- **401 Unauthorized** = "I don't know who you are." Fix the *credential* (cert, key, token, CA).
- **403 Forbidden** = "I know who you are, you're not allowed." Fix *RBAC* (Role/RoleBinding/ClusterRoleBinding). `k auth can-i <verb> <resource> --as=<user> -n <ns>` confirms it in one line.

**Root causes, ranked:**

1. **Wrong server host/port** — copied config pointing at the wrong endpoint → connection refused. Fix `server:`.
2. **Wrong or unreachable CA** — `certificate-authority:` points at a path that doesn't exist on this host (e.g., a container-internal path), or embedded `-data` is for a different cluster → x509 unknown authority. Prefer embedded `certificate-authority-data` from a known-good config.
3. **Expired client cert** — user cert past `notAfter` → x509 expired / 401.
4. **RBAC too narrow** — 403 Forbidden on a specific verb/resource/namespace. Bind the right Role.
5. **Wrong context/namespace** — everything's fine but you're pointed at the wrong cluster or namespace.

**Fix patterns:**

```bash
# Repair a broken kubeconfig FILE in place (do not clobber ~/.kube/config)
KCFG=/tmp/ops.kubeconfig
kubectl --kubeconfig "$KCFG" config view --raw            # inspect what's wrong
# kind publishes the API on a RANDOM host port, so derive the real server — never hard-code 6443:
REAL_SERVER=$(kubectl config view --raw -o jsonpath='{.clusters[?(@.name=="kind-cka")].cluster.server}')
kubectl --kubeconfig "$KCFG" config set-cluster kind-cka --server="$REAL_SERVER"
kubectl --kubeconfig "$KCFG" config set-cluster kind-cka \
  --certificate-authority=/path/to/ca.crt --embed-certs=true

# Diagnose 401 vs 403 without guessing
k auth can-i --list --as=dev -n prod            # what CAN this user do?
k auth can-i create deployments --as=dev -n prod

# Renew expired control-plane/client certs (kubeadm nodes)
kubeadm certs check-expiration
kubeadm certs renew all       # then restart control-plane static pods
```

**Trap:** `certificate-authority: /etc/kubernetes/pki/ca.crt` in a handed-over kubeconfig looks authoritative but that path only exists on the control-plane node — on your workstation it's a missing file, giving a load error, not an x509 error. Swap it for embedded `certificate-authority-data`. And never "fix" a 403 by editing credentials or a 401 by editing RBAC — you'll burn time on the wrong layer. The error string already told you which.

---

## Playbook 8 — etcd & data issues (awareness)

**Symptom:** apiserver reports etcd unreachable; cluster state is stale or lost; the task explicitly says "back up etcd" or "restore the cluster from this snapshot." etcd is the single source of truth — every object lives there. If etcd is gone, the cluster's memory is gone.

**Health & first look:**

```bash
# etcd is a DISTROLESS static pod; etcdctl is NOT on the kind node host, so exec INTO the etcd pod
# (docker exec cka-control-plane etcdctl ... returns "etcdctl: not found"). ETCDCTL_API defaults to 3.
kubectl -n kube-system exec etcd-cka-control-plane -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health
```

The certs live in `/etc/kubernetes/pki/etcd/`. The three flags `--cacert/--cert/--key` are non-negotiable — etcd is mutually-TLS-authenticated; without them you get a connection error that looks like etcd is down when it is fine.

**Backup (snapshot):**

```bash
kubectl -n kube-system exec etcd-cka-control-plane -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd-backup.db
```

**Restore (the exam pattern):** restore the snapshot to a *new* data directory, then repoint etcd's static pod at it.

```text
1. etcdutl snapshot restore /backup/snap.db --data-dir /var/lib/etcd-restore
   (etcd >=3.6: restore/status live in etcdutl, not etcdctl; etcd 3.5 still accepts
    `etcdctl snapshot restore` with a deprecation warning. `snapshot save` stays in etcdctl.)
2. edit /etc/kubernetes/manifests/etcd.yaml:
     - change the hostPath volume for etcd data from /var/lib/etcd to /var/lib/etcd-restore
       (OR restore INTO /var/lib/etcd after stopping etcd and moving the old dir aside)
3. the kubelet restarts etcd from the new data-dir; apiserver reconnects
4. verify: k get nodes ; k get pods -A   (state matches the snapshot's point in time)
```

**Root causes / notes, ranked:**

1. **Restore requested** — the headline etcd task. Get the snapshot, `snapshot restore` to a new dir, repoint `etcd.yaml`, verify. Practice the exact flags cold.
2. **etcd static pod broken** — bad flag / wrong `--data-dir` / cert path → apiserver can't reach 2379 → this is Playbook 5, fix the manifest.
3. **Disk full on the control-plane** — etcd goes read-only (`mvcc: database space exceeded`); free space / compact.
4. **Wrong certs in the etcdctl call** — not a cluster bug, a *your-command* bug; use the `/etc/kubernetes/pki/etcd/` certs.

**Trap:** `snapshot restore` does **not** touch the running etcd; it writes a new data dir on disk. Nothing changes until you repoint etcd's manifest at that dir and the kubelet restarts the pod. Also `ETCDCTL_API=3` must be set (default on current etcd, but set it explicitly on the exam to be safe), and `snapshot save` needs a *running* etcd while `snapshot restore` is offline.

---

## Monitoring & health surfaces

Three families of "what is actually happening right now" commands. Reach for them before you start editing anything.

**Resource pressure — `kubectl top` (needs metrics-server; on kind it may be absent, that's expected):**

```bash
k top nodes                          # CPU/memory per node — find the saturated one
k top pods -A --sort-by=memory       # the memory hog behind an OOMKill or eviction
k top pods -n prod --containers      # per-container within a pod
```

**Events firehose — the cluster narrating its own failures in time order:**

```bash
k get events -A --sort-by=.lastTimestamp | tail -40      # everything, newest last
k get events -n prod --field-selector type=Warning        # just the warnings
k get events -n prod --field-selector involvedObject.name=api   # one object's story
k get events -A -w                                         # live tail while you reproduce
```

**Component health — the API's own readiness probes (the fastest control-plane triage that exists):**

```bash
k get --raw='/readyz?verbose'        # every apiserver readiness check, line by line (etcd, informers, ...)
k get --raw='/livez?verbose'         # liveness variant
k get --raw='/healthz'               # legacy single-line ok/not-ok
k get --raw='/readyz/etcd'           # a single check by name
```

`/readyz?verbose` prints one `[+]check ok` line per subsystem and a final `readyz check failed` if any failed — it tells you *which* dependency (etcd, an admission webhook, an informer) is dragging the apiserver down, without leaving kubectl. Scheduler and controller-manager expose their own `/healthz` on `127.0.0.1:10259` and `:10257` respectively (query from the control-plane node with `curl -k https://127.0.0.1:10259/healthz`).

Legacy but instant when you just need a yes/no on the trio:

```bash
k get componentstatuses            # scheduler/controller-manager/etcd Healthy? (deprecated, still answers)
```

---

## Traps

Each trap is a specific wrong assumption that costs points, and its correction.

- **Wrong:** "Pending means the scheduler can't fit it." **Right:** Pending with `NODE` already assigned means the *kubelet* is stuck (image/volume/secret). Read events, not scheduler capacity.
- **Wrong:** "The current logs will show why it crashed." **Right:** a CrashLooping pod's current logs are from the fresh restart; the crash is in `logs --previous`. Without `--previous` you're reading an empty or misleading log.
- **Wrong:** "Running == healthy." **Right:** `Running` with `0/1 READY` fails readiness and is pulled from Service endpoints — the app looks dead through its Service while the pod looks fine.
- **Wrong:** "I'll `kubectl edit` the apiserver to fix its flag." **Right:** control-plane components are static pods; `kubectl edit` on the mirror pod does nothing. Edit the file in `/etc/kubernetes/manifests/` on the node.
- **Wrong:** "`Endpoints: <none>` means the pods are down." **Right:** it usually means the Service selector doesn't match the pod labels, or the pods are unready. The pods can be perfectly healthy.
- **Wrong:** "403 Forbidden = bad credentials." **Right:** 403 = authenticated but not authorized → fix RBAC. 401 = not authenticated → fix the credential. Never cross the streams.
- **Wrong:** "The DNS Deployment is called `kube-dns`." **Right:** the Deployment is `coredns`; the Service is `kube-dns`. Scale/log the Deployment, verify endpoints on the Service.
- **Wrong:** "kubelet `start` fixes the NotReady node for good." **Right:** if the task says "survive a reboot," you also need `systemctl enable`. A start without enable regresses on the next boot.
- **Wrong:** "`snapshot restore` brings the cluster back immediately." **Right:** it only writes a new data dir; you must repoint etcd's manifest at it and let the kubelet restart the pod.
- **Wrong:** "`crictl rm` the crashing static-pod container to reset it." **Right:** the kubelet recreates it from the same broken manifest. Fix the manifest; the container is a symptom.
- **Wrong:** "A missing CNI is an apiserver problem because pods say ContainerCreating." **Right:** ContainerCreating + `cni ... uninitialized` in node/kubelet logs is a *node-local* CNI fault. Fix `/etc/cni/net.d` and the runtime on that node.

---

## Speed patterns

The fastest exam-legal way to do each recurring troubleshooting move.

| Need | Fastest command |
|---|---|
| Cluster-wide "what's broken" | `k get pods -A -o wide \| grep -vE 'Running\|Completed'` |
| One pod's full story | `k describe pod <p> -n <ns>` (read Events bottom-up) |
| Why it crashed | `k logs <p> -n <ns> --previous` (add `-c <ctr>` for multi-container) |
| Why it won't schedule | `k get events -n <ns> --field-selector reason=FailedScheduling` |
| Service dead? | `k describe svc <s> -n <ns> \| grep -i endpoints` |
| Node broken — get on it | `docker exec -it <node> bash` (exam: `ssh node01 && sudo -i`) |
| kubelet's own errors | `journalctl -u kubelet -n 40 --no-pager` |
| kubectl is dead, inspect containers | `crictl ps -a` then `crictl logs <id>` |
| Static pod broke the control plane | edit `/etc/kubernetes/manifests/<comp>.yaml`, wait ~20s |
| apiserver readiness detail | `k get --raw='/readyz?verbose'` |
| Force a static pod re-read | `mv <manifest> /tmp/ && sleep 20 && mv /tmp/<manifest> back` |
| 401 vs 403 | `k auth can-i <verb> <res> --as=<user> -n <ns>` |
| Throwaway test client | `k run tmp --rm -it --image=busybox:1.36 --restart=Never -- sh` |
| Delete a wedged pod now | `k delete pod <p> -n <ns> $now` (i.e. `--grace-period=0 --force`) |
| Watch recovery | `k get nodes -w` / `k get pods -n <ns> -w` |

Two meta-patterns worth the muscle memory:

- **`k get events -A --sort-by=.lastTimestamp | tail -40`** first, on almost every task. It surfaces the failing component and its reason before you've even named the object.
- **Bisect inward, never outward.** App (POD_IP) → Service (ClusterIP) → DNS (name). Test the innermost layer first; the first layer that fails is your fault domain. Fixing outer layers on an inner-layer bug is the #1 time sink.

---

## Docs map

Everything below is reachable in-browser during the exam from `kubernetes.io/docs`. Know the *path*, not the URL — rehearsed navigation beats search.

| What you need | Exact docs path |
|---|---|
| Debug Pods (Pending, CrashLoop, describe) | Tasks → Monitor, Log, and Debug → Debug Pods |
| Debug Running Pods (exec, ephemeral containers) | Tasks → Monitor, Log, and Debug → Debug Running Pods |
| Debug Services (endpoints, selectors) | Tasks → Monitor, Log, and Debug → Debug Services |
| Debug DNS resolution | Tasks → Monitor, Log, and Debug → Debugging DNS Resolution |
| Debug cluster / node problems | Tasks → Monitor, Log, and Debug → Troubleshoot Clusters |
| Static Pods (control-plane manifests) | Tasks → Configure Pods and Containers → Create static Pods |
| kubelet config file reference | Reference → Config APIs → kubelet configuration (v1beta1) |
| etcd backup & restore | Tasks → Administer a Cluster → Operating etcd / Backing up an etcd cluster |
| Certificates & kubeconfig | Tasks → Administer a Cluster → Certificate management with kubeadm; Reference → kubeconfig |
| RBAC (401/403) | Reference → Access Authn Authz → RBAC; Using RBAC Authorization |
| Resource metrics (top) | Tasks → Monitor, Log, and Debug → Resource metrics pipeline |
| Node conditions / pressure | Reference → Nodes → Node Status |
| kubectl cheat sheet (jsonpath, field-selectors) | Reference → kubectl → kubectl Cheat Sheet |

---

## Checkpoint

Self-test with time targets. If you can't hit these cold, drill the matching `labs/breakfix` script until you can.

- Can you, in **2 minutes**, take a Pending pod and name the exact reason (resources / taint / affinity / PVC) from events alone?
- Can you, in **3 minutes**, diagnose a CrashLoopBackOff to a specific cause using `describe` + `logs --previous` and apply the fix?
- Can you, in **3 minutes**, decide whether an unreachable app is a selector, port, readiness, or DNS problem by bisecting POD_IP → ClusterIP → name?
- Can you, in **5 minutes**, bring a NotReady node back to Ready from the node itself (kubelet down, config broken, or CNI missing) *and* make the fix survive a reboot?
- Can you, in **5 minutes**, restore a crashed control plane by finding the bad static-pod manifest with `crictl` and correcting the file — with `kubectl` dead the whole time?
- Can you, in **3 minutes**, restore cluster DNS when CoreDNS is scaled to 0 *and* its ConfigMap is corrupt?
- Can you, in **2 minutes**, classify an auth failure as 401 vs 403 and fix the correct layer (credential vs RBAC)?
- Can you, in **5 minutes**, take an etcd snapshot and restore it to a new data-dir, repointing the static pod?
- Can you, in **30 seconds**, read `/readyz?verbose` and name which apiserver dependency is failing?

Pass mark on the real exam is 66%. Troubleshooting is 30% of it. If you own these nine, you have already banked the domain that decides pass/fail — and you'll clear the networking, storage, and architecture tasks that arrive wearing troubleshooting clothes.
