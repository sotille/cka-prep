# Week 09 — Troubleshooting Exercises

Lab: 3-node kind cluster `cka` (context `kind-cka`, nodes `cka-control-plane`, `cka-worker`, `cka-worker2`). Aliases assumed: `alias k=kubectl`, `export do="--dry-run=client -o yaml"`, `export now="--grace-period=0 --force"`. Each task has a **setup fence — run it first**, then solve without peeking. Where the real exam differs (kubeadm nodes with SSH + sudo instead of `docker exec`), a one-line exam-flavor note says so. Clean up after each task with the cleanup line in its solution. For deeper node/control-plane breakage practice, use `labs/breakfix/`.

---

## Task 1 — Pod won't schedule (warmup, 4 min)

Context: namespace `t01` exists with one pod.

```bash
kubectl create ns t01
kubectl -n t01 run heavy --image=nginx:1.27 --overrides='{"spec":{"containers":[{"name":"heavy","image":"nginx:1.27","resources":{"requests":{"cpu":"64","memory":"128Gi"}}}]}}'
```

A pod `heavy` in namespace `t01` is not starting. Find the cause and make the pod run with sensible resource requests (100m CPU, 128Mi memory). Do not change the image.

## Task 2 — Image pull failure (warmup, 3 min)

Context: namespace `t02`, one Deployment.

```bash
kubectl create ns t02
kubectl -n t02 create deployment web --image=ngnix:1.27 --replicas=2
```

The Deployment `web` in namespace `t02` has no available replicas. Fix it so 2/2 replicas become Ready.

## Task 3 — Save crash evidence (warmup, 3 min)

Context: namespace `t03`, one restarting pod.

```bash
kubectl create ns t03
kubectl -n t03 run flaky --image=busybox:1.36 --restart=Always -- sh -c 'echo "boot id $RANDOM"; echo "FATAL: config checksum mismatch" >&2; sleep 5; exit 1'
```

A pod `flaky` in namespace `t03` is restarting. Save the log output of the **previous** container instance to `/tmp/t03-prev.log` and the current restart count to `/tmp/t03-restarts.txt`. Do not fix the pod.

## Task 4 — CreateContainerConfigError (exam, 5 min)

Context: namespace `t04`, one Deployment referencing app config.

```bash
kubectl create ns t04
kubectl -n t04 create deployment api --image=nginx:1.27 --replicas=1
kubectl -n t04 patch deployment api --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/envFrom","value":[{"configMapRef":{"name":"api-config"}}]}]'
```

The Deployment `api` in namespace `t04` has 0 ready replicas. Diagnose and fix it **without removing any environment configuration** from the pod template. The application expects a key `DB_HOST` with value `postgres.t04.svc`.

## Task 5 — CrashLoopBackOff: missing env (exam, 6 min)

Context: namespace `t05`, one Deployment that crashes on boot.

```bash
kubectl create ns t05
kubectl -n t05 create deployment worker --image=busybox:1.36 --replicas=1 -- sh -c 'if [ -z "$QUEUE_URL" ]; then echo "FATAL: QUEUE_URL is not set" >&2; exit 1; fi; echo "worker up"; sleep 3600'
```

The Deployment `worker` in namespace `t05` is in CrashLoopBackOff. Find out from the container's own output why it crashes and fix the Deployment. Use `amqp://rabbit.t05.svc:5672` as the value the app needs.

## Task 6 — Restart storm: liveness probe (exam, 6 min)

Context: namespace `t06`, one Deployment restarting although the app works.

```bash
kubectl create ns t06
kubectl -n t06 create deployment front --image=nginx:1.27 --replicas=1
kubectl -n t06 patch deployment front --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/livenessProbe","value":{"httpGet":{"path":"/","port":8080},"initialDelaySeconds":5,"periodSeconds":5,"failureThreshold":2}}]'
```

Pods of Deployment `front` in namespace `t06` keep restarting even though nginx serves traffic normally on port 80. Stop the restarts without removing the liveness probe.

## Task 7 — Service with no endpoints (exam, 5 min)

Context: namespace `t07`, a Deployment and a Service that should front it.

```bash
kubectl create ns t07
kubectl -n t07 create deployment shop --image=nginx:1.27 --replicas=2
kubectl -n t07 create service clusterip shop --tcp=80:80
kubectl -n t07 patch svc shop -p '{"spec":{"selector":{"app":"shop-frontend"}}}'
```

The Service `shop` in namespace `t07` times out from inside the cluster. Fix the Service (do not modify the Deployment) and verify with an in-cluster HTTP request that it returns the nginx welcome page.

## Task 8 — Endpoints exist, connection refused (exam, 5 min)

Context: namespace `t08`, Deployment + Service, traffic refused.

```bash
kubectl create ns t08
kubectl -n t08 create deployment pay --image=nginx:1.27 --replicas=1
kubectl -n t08 create service clusterip pay --tcp=80:8080
```

Requests to Service `pay` in namespace `t08` on port 80 are refused, although the pod is Running and Ready. Fix the Service so `wget -qO- http://pay.t08:80` succeeds from a test pod.

## Task 9 — Ready 0/1: readiness probe (exam, 6 min)

Context: namespace `t09`, app pods never become Ready so the Service is dead.

```bash
kubectl create ns t09
kubectl -n t09 create deployment cart --image=nginx:1.27 --replicas=2
kubectl -n t09 expose deployment cart --port=80
kubectl -n t09 patch deployment cart --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/readinessProbe","value":{"httpGet":{"path":"/healthz","port":80},"periodSeconds":3}}]'
```

Service `cart` in namespace `t09` has no endpoints and pods show READY 0/1, but nginx answers on `/` just fine. Make the pods Ready and the Service serve traffic. The team insists on keeping a readiness probe.

## Task 10 — Pending: taints (exam, 7 min)

Context: namespace `t10`; the platform team has reserved both workers for team blue.

```bash
kubectl create ns t10
kubectl taint node cka-worker team=blue:NoSchedule
kubectl taint node cka-worker2 team=blue:NoSchedule
kubectl -n t10 run batch --image=busybox:1.36 --restart=Never -- sleep 3600
```

Pod `batch` in namespace `t10` is Pending. Make it run **without removing or changing any node taints** and without touching other workloads.

## Task 11 — Pending: unbound PVC (exam, 7 min)

Context: namespace `t11`, a pod with a data volume claim.

```bash
kubectl create ns t11
cat <<'EOF' | kubectl -n t11 apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: fast-ssd
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: db
spec:
  containers:
  - name: db
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: data
EOF
```

Pod `db` in namespace `t11` is Pending. Diagnose the chain pod → PVC → StorageClass and fix it using the cluster's existing dynamic provisioner. The claim must stay named `data` and keep its 1Gi request.

Exam-flavor: identical logic on the real exam; the default SC there may be different — always `k get sc` first.

## Task 12 — RBAC: forbidden (exam, 7 min)

Context: namespace `t12` with ServiceAccount `ci-bot`; a CI job using it reports errors.

```bash
kubectl create ns t12
kubectl -n t12 create serviceaccount ci-bot
```

The CI pipeline authenticating as ServiceAccount `ci-bot` in namespace `t12` fails with `pods is forbidden: User "system:serviceaccount:t12:ci-bot" cannot list resource "pods"`. Grant `ci-bot` permission to `get`, `list` and `watch` pods and pod logs **only in namespace `t12`**, and prove with `kubectl auth can-i` that (a) it can list pods in `t12` and (b) it cannot list pods in `default`.

## Task 13 — Node NotReady (hard, 8 min)

Context: whole cluster; a worker just dropped out of the cluster.

```bash
docker exec cka-worker2 systemctl stop kubelet
sleep 45
```

Node `cka-worker2` is NotReady. Diagnose from the node itself (service status + logs), bring it back to Ready, and make sure the failure would survive a node reboot (the responsible service must be enabled).

Exam-flavor: on the real exam this is `ssh node-name` + `sudo -i` instead of `docker exec -it cka-worker2 bash`.

## Task 14 — Cluster frozen: nothing schedules (hard, 10 min)

Context: control plane; users report every new pod hangs in Pending with no events.

```bash
docker exec cka-control-plane bash -c "cp /etc/kubernetes/manifests/kube-scheduler.yaml /root/ksched.yaml.bak && sed -i 's/--leader-elect=true/--leader-elect-mode=true/' /etc/kubernetes/manifests/kube-scheduler.yaml"
sleep 20
kubectl -n default run canary-t14 --image=nginx:1.27
```

The pod `canary-t14` in namespace `default` (and any other new pod) stays Pending with **no events**. Find the broken control-plane component, identify the exact bad configuration, and fix it so `canary-t14` gets scheduled. Use `crictl` on the control-plane node as part of your diagnosis.

Exam-flavor: on the real exam you SSH to the control-plane node; here `docker exec -it cka-control-plane bash`.

## Task 15 — Cluster DNS is down (hard, 10 min)

Context: cluster-wide; every pod fails name resolution.

```bash
kubectl -n kube-system get cm coredns -o yaml > /tmp/t15-coredns-backup.yaml
kubectl -n kube-system get cm coredns -o yaml | sed 's/forward \. \/etc\/resolv.conf/forwardx . \/etc\/resolv.conf/' | kubectl apply -f -
kubectl -n kube-system scale deployment coredns --replicas=0
sleep 5
kubectl -n kube-system scale deployment coredns --replicas=2
```

In-cluster DNS is completely broken: `nslookup kubernetes.default` fails from every pod. Restore cluster DNS to a working state and verify with a successful lookup of `kubernetes.default.svc.cluster.local` from a temporary pod. (Backup of the original ConfigMap is at `/tmp/t15-coredns-backup.yaml` — but try to repair it by reading the error first.)

---

# SOLUTIONS

## Task 1 — Pod won't schedule

```bash
k -n t01 describe pod heavy | tail -8
```

Shows `FailedScheduling ... 0/3 nodes are available: ... Insufficient cpu, ... Insufficient memory`. The pod requests 64 CPUs / 128Gi — no kind node has that. Bare pods can't be resized for scheduling fields; recreate:

```bash
k -n t01 get pod heavy -o yaml > /tmp/heavy.yaml
# edit /tmp/heavy.yaml: requests cpu "64"->"100m", memory "128Gi"->"128Mi"
k -n t01 delete pod heavy $now
k -n t01 apply -f /tmp/heavy.yaml
```

Or recreate cleanly:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: heavy
  namespace: t01
spec:
  containers:
  - name: heavy
    image: nginx:1.27
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
```

Why: describe's FailedScheduling event names the blocker verbatim; requests must fit node allocatable. Cleanup: `k delete ns t01`.

## Task 2 — Image pull failure

```bash
k -n t02 get pods    # ImagePullBackOff
k -n t02 describe pod -l app=web | tail -6   # "pull access denied ... ngnix"
k -n t02 set image deployment/web ngnix=nginx:1.27
k -n t02 get pods -w
```

Why: `ngnix` is a typo'd repo that doesn't exist; `k set image` fixes the template and triggers a rollout — faster than `edit`. (Container name is `ngnix` because `create deployment` derives it from the image.) Cleanup: `k delete ns t02`.

## Task 3 — Save crash evidence

```bash
k -n t03 logs flaky --previous > /tmp/t03-prev.log
k -n t03 get pod flaky -o jsonpath='{.status.containerStatuses[0].restartCount}' > /tmp/t03-restarts.txt
cat /tmp/t03-prev.log   # contains "FATAL: config checksum mismatch"
```

Why: `--previous` reads the terminated instance (the one that actually crashed); restartCount lives in containerStatuses. If `--previous` errors, the container hasn't restarted yet — wait one cycle. Cleanup: `k delete ns t03`.

## Task 4 — CreateContainerConfigError

```bash
k -n t04 get pods                       # STATUS CreateContainerConfigError
k -n t04 describe pod -l app=api | tail -6
# Event: "configmap \"api-config\" not found"
k -n t04 create configmap api-config --from-literal=DB_HOST=postgres.t04.svc
k -n t04 get pods -w                    # kubelet retries; pod goes Running
```

Why: `envFrom` references a ConfigMap that doesn't exist; the kubelet can't construct the container environment, so the container never starts. Creating the referenced object is the fix — kubelet retries automatically, no rollout needed. Cleanup: `k delete ns t04`.

## Task 5 — CrashLoopBackOff: missing env

```bash
k -n t05 get pods                            # CrashLoopBackOff, exit code 1
k -n t05 logs deploy/worker --previous       # "FATAL: QUEUE_URL is not set"
k -n t05 set env deployment/worker QUEUE_URL=amqp://rabbit.t05.svc:5672
k -n t05 get pods -w                         # new RS, pod Running, restarts stop
```

Why: exit code 1 = app-level failure → the container's own stderr (`logs --previous`) names the missing variable; `k set env` patches the template without an editor. Cleanup: `k delete ns t05`.

## Task 6 — Restart storm: liveness probe

```bash
k -n t06 describe pod -l app=front | grep -B2 -A6 Liveness
# Liveness: http-get http://:8080/ ... Events: "Liveness probe failed: ... connection refused"
# nginx listens on 80; probe hits 8080.
k -n t06 patch deployment front --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/port","value":80}]'
k -n t06 get pods -w    # restarts stop
```

Why: kubelet kills the container every time the probe fails `failureThreshold` times; the app was healthy — the probe was wrong. Exit code would show 137/143 with Events explaining the kill (Trap 6 in the masterclass). Cleanup: `k delete ns t06`.

## Task 7 — Service with no endpoints

```bash
k -n t07 get endpoints shop           # <none>
k -n t07 describe svc shop | grep Selector    # app=shop-frontend
k -n t07 get pods --show-labels               # pods carry app=shop
k -n t07 patch svc shop -p '{"spec":{"selector":{"app":"shop"}}}'
k -n t07 get endpoints shop           # two pod IPs
k run tmp --rm -it --image=busybox:1.36 --restart=Never -- wget -qO- --timeout=2 http://shop.t07.svc.cluster.local
```

Why: empty endpoints + Ready pods = selector mismatch; patching the Service (not the Deployment, per task constraints) realigns it. Cleanup: `k delete ns t07`.

## Task 8 — Endpoints exist, connection refused

```bash
k -n t08 get endpoints pay        # 10.244.x.x:8080  <- endpoints exist, port is wrong
k -n t08 get svc pay -o jsonpath='{.spec.ports[0].targetPort}'   # 8080
# nginx container listens on 80:
k -n t08 patch svc pay --type=json -p='[{"op":"replace","path":"/spec/ports/0/targetPort","value":80}]'
k run tmp --rm -it --image=busybox:1.36 --restart=Never -- wget -qO- --timeout=2 http://pay.t08:80
```

Why: endpoints get the Service's `targetPort` attached; if nothing listens there you get connection refused despite healthy pods — port mismatch, not selector (masterclass Playbook 3 branch 2). Cleanup: `k delete ns t08`.

## Task 9 — Ready 0/1: readiness probe

```bash
k -n t09 describe pod -l app=cart | grep -A6 Readiness
# "Readiness probe failed: HTTP probe failed with statuscode: 404" -> /healthz doesn't exist on stock nginx
k -n t09 patch deployment cart --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/"}]'
k -n t09 get endpoints cart     # populated once pods flip 1/1
```

Why: readiness gates endpoint membership — the selector was correct the whole time (Trap 7). Repointing the probe at a path that returns 200 keeps the probe (per constraint) and restores endpoints. Cleanup: `k delete ns t09`.

## Task 10 — Pending: taints

```bash
k -n t10 describe pod batch | tail -5
# "1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: },
#  2 node(s) had untolerated taint {team: blue}"
k -n t10 get pod batch -o yaml > /tmp/batch.yaml
k -n t10 delete pod batch $now
```

Add the toleration and recreate:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: batch
  namespace: t10
spec:
  tolerations:
  - key: team
    operator: Equal
    value: blue
    effect: NoSchedule
  containers:
  - name: batch
    image: busybox:1.36
    command: ["sleep", "3600"]
```

```bash
k apply -f /tmp/batch.yaml && k -n t10 get pod batch -o wide   # lands on a worker
```

Why: taints repel, tolerations permit — the constraint "don't touch taints" forces the toleration route; bare pods need recreation since tolerations are immutable. Cleanup: `k delete ns t10; k taint node cka-worker team-; k taint node cka-worker2 team-`.

## Task 11 — Pending: unbound PVC

```bash
k -n t11 describe pod db | tail -4     # "pod has unbound immediate PersistentVolumeClaims"
k -n t11 get pvc                       # data  Pending  ...  fast-ssd
k get sc                               # only "standard (default)" exists -> fast-ssd is bogus
```

`storageClassName` is immutable on a PVC → recreate the claim (pod must be recreated too, it holds the claim reference but will re-bind by name):

```bash
k -n t11 delete pod db $now
k -n t11 delete pvc data
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
  namespace: t11
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: standard
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: db
  namespace: t11
spec:
  containers:
  - name: db
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: data
```

Apply both documents with `k apply -f /tmp/t11-fixed.yaml`. kind's `standard` class uses `WaitForFirstConsumer`, so the PVC binds only when the pod schedules — `Pending` PVC before pod creation is normal, not a bug. Why: the chain is pod → PVC (Pending) → SC (nonexistent); fixing the lowest broken layer unblocks everything above. Cleanup: `k delete ns t11`.

## Task 12 — RBAC: forbidden

```bash
k -n t12 create role pod-reader --verb=get,list,watch --resource=pods,pods/log
k -n t12 create rolebinding ci-bot-pod-reader --role=pod-reader --serviceaccount=t12:ci-bot
k auth can-i list pods --as=system:serviceaccount:t12:ci-bot -n t12      # yes
k auth can-i list pods --as=system:serviceaccount:t12:ci-bot -n default  # no
```

Why: the error is a 403 (authn OK, authz denied) → RBAC, not credentials (Trap 10); a namespaced Role+RoleBinding scopes access to `t12` only, and `pods/log` is a distinct subresource that must be granted explicitly. Cleanup: `k delete ns t12`.

## Task 13 — Node NotReady

```bash
k get nodes                                   # cka-worker2 NotReady
k describe node cka-worker2 | grep -A8 Conditions
# Ready=Unknown, "Kubelet stopped posting node status"
docker exec -it cka-worker2 bash              # exam: ssh cka-worker2; sudo -i
  systemctl status kubelet                    # inactive (dead)
  journalctl -u kubelet --no-pager | tail -20 # clean shutdown, no crash -> just stopped
  systemctl enable --now kubelet
  systemctl status kubelet                    # active (running)
  exit
k get nodes -w                                # Ready within ~30s
```

Why: `Ready=Unknown` means the kubelet went silent (vs `False` = kubelet reporting a problem); status was `inactive`, not crash-looping, so no config surgery needed — start it, and `enable` satisfies the reboot-survival requirement (Trap 9). Cleanup: none (that was the fix).

## Task 14 — Cluster frozen: nothing schedules

```bash
k -n default describe pod canary-t14          # Pending, ZERO events -> scheduler never saw it
k -n kube-system get pods | grep scheduler    # kube-scheduler-cka-control-plane CrashLoopBackOff
docker exec -it cka-control-plane bash
  crictl ps -a | grep scheduler               # Exited, restart count climbing
  crictl logs $(crictl ps -a --name kube-scheduler -q | head -1) --tail 5
  # "Error: unknown flag: --leader-elect-mode"
  grep leader /etc/kubernetes/manifests/kube-scheduler.yaml
  sed -i 's/--leader-elect-mode=true/--leader-elect=true/' /etc/kubernetes/manifests/kube-scheduler.yaml
  watch crictl ps                             # scheduler container Running and staying up
  exit
k -n default get pod canary-t14 -o wide       # scheduled and Running
```

Why: Pending + no events is the scheduler-down signature (Trap 4); static pods are reconciled from disk, so the fix is `sed` on the manifest — `kubectl edit` on the mirror pod would do nothing (Trap 1). The crash log names the exact bad flag, no guessing. Cleanup: `k -n default delete pod canary-t14 $now; docker exec cka-control-plane rm -f /root/ksched.yaml.bak`.

## Task 15 — Cluster DNS is down

```bash
k run dnstest --rm -it --image=busybox:1.36 --restart=Never -- nslookup kubernetes.default   # fails
k -n kube-system get pods -l k8s-app=kube-dns       # CrashLoopBackOff
k -n kube-system logs -l k8s-app=kube-dns --tail=5
# "Error during parsing: Unknown directive 'forwardx'"
k -n kube-system edit cm coredns                    # forwardx -> forward
k -n kube-system rollout restart deployment coredns # CoreDNS won't reliably self-reload (Trap 11)
k -n kube-system get pods -l k8s-app=kube-dns -w    # 2/2 Running
k run dnstest --rm -it --image=busybox:1.36 --restart=Never -- nslookup kubernetes.default.svc.cluster.local  # resolves to 10.96.0.1
```

Fallback if the edit goes sideways: `k apply -f /tmp/t15-coredns-backup.yaml` then rollout restart. Why: the CoreDNS crash log names the corrupt directive — the ConfigMap is the root cause, the scale-down/up was a red herring that merely surfaced it (pods only re-read the Corefile on start). Cleanup: `rm -f /tmp/t15-coredns-backup.yaml`.
