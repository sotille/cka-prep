# Week 02 Exercises — Workloads & Configuration

Lab: 3-node kind cluster `cka` (`kubectl config use-context kind-cka`), aliases assumed: `alias k=kubectl`, `export do="--dry-run=client -o yaml"`, `export now="--grace-period=0 --force"`. Task 14 needs `helm` on your workstation (`brew install helm`). Each task states its namespace; setup fences create anything that must pre-exist. Cleanup at the end deletes per-task namespaces. On the real exam every task starts with a printed `kubectl config use-context ...` line — run it first, always; that reflex is part of what you are drilling here.

---

## Tasks

### 1. Deployment lifecycle basics (warmup, 4 min)

Context: nothing pre-exists.

Create namespace `apps`. In it, create a deployment `web` with image `nginx:1.27` and 3 replicas. Then scale it to 5 replicas, update the image to `nginx:1.29`, and record the change-cause "bump to 1.29" so it appears in the rollout history. Show the history.

### 2. Roll back to a pinned revision (exam, 6 min)

Context: namespace `rollback-lab` with deployment `api` that has been through several image changes.

Setup:

```bash
k create ns rollback-lab
k -n rollback-lab create deployment api --image=nginx:1.25 --replicas=3
k -n rollback-lab rollout status deploy/api
k -n rollback-lab set image deploy/api nginx=nginx:1.26
k -n rollback-lab rollout status deploy/api
k -n rollback-lab set image deploy/api nginx=nginx:1.27
k -n rollback-lab rollout status deploy/api
```

Roll deployment `api` back to the revision that used image `nginx:1.25`. Do not guess the revision number — verify which revision carries that image before rolling back, and verify the running image afterwards.

### 3. Diagnose and fix a stuck rollout (exam, 7 min)

Context: namespace `broken-lab` with deployment `payments` whose latest rollout is not progressing.

Setup:

```bash
k create ns broken-lab
k -n broken-lab create deployment payments --image=nginx:1.27 --replicas=3
k -n broken-lab rollout status deploy/payments
k -n broken-lab patch deploy payments -p '{"spec":{"progressDeadlineSeconds":60}}'
k -n broken-lab set image deploy/payments nginx=nginx:1.99-nonexistent
```

The `payments` deployment is failing to roll out. Identify the deployment condition that proves the rollout is stuck, find the root cause, and restore the deployment to a fully available state without editing the pod template by hand.

### 4. Rollout strategy tuning (exam, 6 min)

Context: deployment `web` in namespace `apps` from task 1.

First configure `web` so that during updates at most 1 extra pod may be created and no pod may become unavailable, then trigger a rollout to `nginx:1.29.1` and confirm availability never dropped below 5. Afterwards, change the deployment strategy to `Recreate` and observe the difference during a rollout to `nginx:1.29.2`.

### 5. DaemonSet covering every node (exam, 6 min)

Context: nothing pre-exists; the kind cluster has 1 control-plane and 2 worker nodes; the control-plane node carries the `node-role.kubernetes.io/control-plane:NoSchedule` taint.

Create namespace `monitoring`. In it, create a DaemonSet `node-agent` using image `busybox:1.36` running `sleep infinity`, with a RollingUpdate strategy allowing at most 1 pod unavailable during updates. The DaemonSet must run on **all 3 nodes**, including the control plane. Verify DESIRED=CURRENT=READY=3.

Exam-flavor note: identical on real kubeadm clusters — the control-plane toleration is the point of the task.

### 6. StatefulSet with stable storage (exam, 8 min)

Context: nothing pre-exists; kind ships a default StorageClass `standard` (dynamic provisioning, WaitForFirstConsumer).

Create namespace `data`. In it create: a headless service `db-hl` on port 6379 selecting `app: db`; a StatefulSet `db` with 3 replicas, image `redis:7`, container port 6379, mounting a volume claim template named `data` (100Mi, ReadWriteOnce, default StorageClass) at `/data`, using `db-hl` as its service. Verify the pods come up in order with stable names, that 3 PVCs exist, then scale to 1 and confirm the PVCs of the removed pods still exist.

### 7. Canary a StatefulSet update with partition (hard, 7 min)

Context: StatefulSet `db` from task 6, scaled back to 3 replicas (`k -n data scale sts db --replicas=3` and wait for ready).

Update the StatefulSet image to `redis:7.4` such that **only pod `db-2`** receives the new image. Verify `db-0`/`db-1` still run `redis:7` while `db-2` runs `redis:7.4`. Then complete the rollout to all pods using only the update strategy (no pod deletions).

### 8. Parallel Job with constraints (exam, 6 min)

Context: nothing pre-exists.

Create namespace `batch-lab`. In it create a Job `crunch` that: requires 6 successful completions, runs at most 2 pods in parallel, retries at most 2 times, is killed if it runs longer than 120 seconds total, cleans itself up 300 seconds after finishing, and uses a pod that must **not** be restarted in place on failure (failed pods must remain inspectable). Each pod runs `busybox:1.36` executing `echo done from $HOSTNAME && sleep 3`. Verify 6 completions.

### 9. CronJob with concurrency control + manual trigger (exam, 6 min)

Context: namespace `batch-lab` from task 8.

Create a CronJob `backup` that runs every 5 minutes, never allows overlapping runs, skips a run if it cannot start within 100 seconds of its scheduled time, keeps 2 successful and 1 failed job in history, with pod `busybox:1.36` running `echo backing up && sleep 5` and restartPolicy `OnFailure`. Then: suspend the CronJob, and trigger one manual run from it while suspended. Verify the manual Job completes.

### 10. ConfigMap + Secret, three consumption modes (exam, 8 min)

Context: nothing pre-exists.

Create namespace `config-lab`. Create ConfigMap `app-config` with keys `APP_MODE=production` and `APP_COLOR=blue`, and Secret `app-secret` with keys `DB_USER=admin` and `DB_PASS=S3cret!`. Then create pod `consumer` (image `busybox:1.36`, command `sleep 3600`) that consumes them three ways simultaneously:

1. env var `MODE` from ConfigMap key `APP_MODE` (single key);
2. **all** keys of `app-secret` as env vars via envFrom;
3. the whole ConfigMap mounted as a volume at `/etc/app-config`.

Verify from inside the pod: `MODE`, `DB_USER`/`DB_PASS` in the environment, and two files under `/etc/app-config`.

### 11. The subPath rotation trap (hard, 8 min)

Context: namespace `subpath-lab` with a running pod that prints its config file every 10 seconds.

Setup:

```bash
k create ns subpath-lab
k -n subpath-lab create cm feature-flags --from-literal=flags.conf='beta=false'
k -n subpath-lab apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: flag-reader
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "while true; do cat /etc/app/flags.conf; sleep 10; done"]
    volumeMounts:
    - name: flags
      mountPath: /etc/app/flags.conf
      subPath: flags.conf
  volumes:
  - name: flags
    configMap:
      name: feature-flags
EOF
```

The application team updated `feature-flags` to `beta=true` two hours ago, but `flag-reader` still logs `beta=false`. Reproduce the update, prove the pod never sees it (wait >2 minutes), explain the root cause in one sentence, and fix the pod so that **future** ConfigMap updates propagate without pod restarts. Verify with one more update.

### 12. Quota-blocked deployment (hard, 8 min)

Context: namespace `constrained` with a ResourceQuota and a deployment stuck at 0/2 replicas.

Setup:

```bash
k create ns constrained
k -n constrained apply -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute-quota
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
    pods: "10"
EOF
k -n constrained create deployment blocked --image=nginx:1.27 --replicas=2
```

Deployment `blocked` shows READY 0/2 but no pods exist and no pods are Pending. Find the evidence explaining why no pods are being created, then fix the deployment (requests cpu=100m/memory=128Mi, limits cpu=200m/memory=256Mi) so both replicas run. Finally, show the quota's current usage.

### 13. HPA with kubectl autoscale + behavior tuning (exam, 6 min)

Context: nothing pre-exists. metrics-server is NOT installed on kind by default — install note in the solution (on the real exam it is already running).

Create namespace `scale-lab` with deployment `web` (image `nginx:1.27`, 2 replicas) with requests cpu=100m/memory=64Mi and limits cpu=200m/memory=128Mi. Create an HPA for `web` scaling between 2 and 6 replicas targeting 70% average CPU utilization, using the imperative command. Then modify the HPA so scale-down uses a 60-second stabilization window. Verify the HPA reports a real utilization value (not `<unknown>`).

### 14. Helm release lifecycle (exam, 8 min)

Context: needs internet access to a public chart repo; a fully offline alternative is included in the solution.

Add the `podinfo` chart repository (`https://stefanprodan.github.io/podinfo`), update repo indexes, and find the chart. Install release `web` of chart `podinfo/podinfo` into namespace `helm-lab` (create it via helm) with `replicaCount=1`. Then upgrade the release to `replicaCount=2`. Inspect the release history, roll back to revision 1, and prove: (a) the history now shows 3 revisions, (b) the user-supplied values are back to `replicaCount=1`, (c) the deployment has 1 replica. Finally uninstall the release.

Exam-flavor note: the exam preinstalls helm on the terminal host and typically points you at a specific repo URL and chart version — `--version` pinning works exactly as shown here.

### 15. Kustomize base + overlay (exam, 8 min)

Context: nothing pre-exists in the cluster; you will create files under `~/kustomize-lab`.

Build a kustomize layout `~/kustomize-lab/{base,overlays/prod}` where the base defines a deployment `web` (image `nginx:1.27`, 2 replicas, envFrom a generated ConfigMap `web-config` with `LOG_LEVEL=info`) and a service `web` on port 80. The prod overlay must: target namespace `kustomize-lab`, prefix all names with `prod-`, retag the image to `nginx:1.29`, and patch replicas to 3. Render with `kubectl kustomize` and review, create the namespace, apply with `kubectl apply -k`, and verify: names are prefixed, the generated ConfigMap has a hash suffix and the deployment references the hashed name, image tag is 1.29, replicas 3.

### 16. Init container gate + SecurityContext (exam, 8 min)

Context: namespace `bootstrap`, empty.

Create namespace `bootstrap`. Create a pod `app` (image `busybox:1.36`, command `sleep 3600`) that: (a) has an init container `wait-for-db` (same image) that blocks until the DNS name `db.bootstrap.svc.cluster.local` resolves; (b) runs its main container as UID 1000, group 3000, with `runAsNonRoot: true`, fsGroup 2000, no privilege escalation, and all capabilities dropped. Create the pod first and confirm it stays in `Init:0/1`. Then create a deployment `db` (image `nginx:1.27`) and expose it as a ClusterIP service `db` on port 80, and confirm the pod proceeds to Running. Verify the UID/GID from inside the container.

---

## SOLUTIONS

### 1. Deployment lifecycle basics

```bash
k create ns apps
k -n apps create deployment web --image=nginx:1.27 --replicas=3
k -n apps scale deploy web --replicas=5
k -n apps set image deploy/web nginx=nginx:1.29
k -n apps annotate deploy web kubernetes.io/change-cause="bump to 1.29"
k -n apps rollout status deploy/web
k -n apps rollout history deploy/web
```

Why: scaling does not create a revision (history shows 2 entries, not 3); the change-cause annotation is copied to the newest ReplicaSet, which is what `rollout history` prints. Container name is `nginx` because `create deployment` names it after the image basename.

### 2. Roll back to a pinned revision

```bash
k -n rollback-lab rollout history deploy/api
# inspect each revision's template until you find nginx:1.25:
k -n rollback-lab rollout history deploy/api --revision=1
# -> Image: nginx:1.25
k -n rollback-lab rollout undo deploy/api --to-revision=1
k -n rollback-lab rollout status deploy/api
k -n rollback-lab get deploy api -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# nginx:1.25
k -n rollback-lab rollout history deploy/api
```

Why: revision numbers are not stable — the undo consumes revision 1 and re-creates it as revision 4; inspecting with `--revision=N` before pinning is the safe pattern.

### 3. Diagnose and fix a stuck rollout

```bash
k -n broken-lab rollout status deploy/payments
# error: deployment "payments" exceeded its progress deadline
k -n broken-lab get deploy payments
# READY 3/3, UP-TO-DATE 1, AVAILABLE 3 — with replicas=3 the defaults give maxUnavailable=0/maxSurge=1,
# so all old pods keep serving and the deployment looks healthy; the stuck new RS pod is the only clue
k -n broken-lab describe deploy payments | grep -A5 Conditions
# Progressing  False  ProgressDeadlineExceeded
k -n broken-lab get pods
# newest pod: ImagePullBackOff
k -n broken-lab describe pod -l app=payments | grep -A3 Events | tail -5
# Failed to pull image "nginx:1.99-nonexistent": not found
k -n broken-lab rollout undo deploy/payments
k -n broken-lab rollout status deploy/payments
k -n broken-lab get deploy payments   # 3/3 available
```

Why: `progressDeadlineSeconds` only sets `Progressing=False` — nothing rolls back automatically; `rollout undo` restores the last working template, which is "fixing without editing the template by hand".

### 4. Rollout strategy tuning

```bash
k -n apps patch deploy web -p '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":1,"maxUnavailable":0}}}}'
k -n apps set image deploy/web nginx=nginx:1.29.1
k -n apps get pods -w    # never fewer than 5 Ready; a 6th pod surges in each step
k -n apps rollout status deploy/web
# convert to Recreate — plain patch of type fails while rollingUpdate params exist:
k -n apps patch deploy web -p '{"spec":{"strategy":{"$retainKeys":["type"],"type":"Recreate"}}}'
k -n apps set image deploy/web nginx=nginx:1.29.2
k -n apps get pods -w    # all 5 terminate together, THEN 5 new ones start (downtime)
```

Why: `maxUnavailable: 0` forces surge-first replacement (zero downtime); `$retainKeys` drops the leftover `rollingUpdate` block that otherwise fails validation when switching to Recreate.

### 5. DaemonSet covering every node

Scaffold from a deployment, then convert:

```bash
k create ns monitoring
k -n monitoring create deploy node-agent --image=busybox:1.36 $do -- sleep infinity > ds.yaml
# edit ds.yaml: kind -> DaemonSet, delete replicas/strategy, add updateStrategy + toleration
```

Final manifest:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-agent
  namespace: monitoring
  labels:
    app: node-agent
spec:
  selector:
    matchLabels:
      app: node-agent
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app: node-agent
    spec:
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      containers:
      - name: node-agent
        image: busybox:1.36
        command: ["sleep", "infinity"]
```

```bash
k apply -f ds.yaml
k -n monitoring get ds node-agent          # DESIRED 3 CURRENT 3 READY 3
k -n monitoring get pods -o wide           # one pod per node incl. cka-control-plane
```

Why: without the control-plane toleration DESIRED is 2 — the DaemonSet controller counts only schedulable-for-this-pod nodes.

### 6. StatefulSet with stable storage

```yaml
apiVersion: v1
kind: Service
metadata:
  name: db-hl
  namespace: data
spec:
  clusterIP: None
  selector:
    app: db
  ports:
  - name: redis
    port: 6379
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: db
  namespace: data
spec:
  serviceName: db-hl
  replicas: 3
  selector:
    matchLabels:
      app: db
  template:
    metadata:
      labels:
        app: db
    spec:
      containers:
      - name: redis
        image: redis:7
        ports:
        - name: redis
          containerPort: 6379
        volumeMounts:
        - name: data
          mountPath: /data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 100Mi
```

```bash
k create ns data
k apply -f sts.yaml
k -n data get pods -w                      # db-0 Ready, then db-1, then db-2 (OrderedReady)
k -n data get pvc                          # data-db-0, data-db-1, data-db-2 Bound
k -n data scale sts db --replicas=1
k -n data get pods                         # only db-0
k -n data get pvc                          # STILL 3 PVCs — retained by design
```

Why: `serviceName` must reference the headless service for per-pod DNS (`db-0.db-hl.data.svc.cluster.local`); PVCs from volumeClaimTemplates deliberately survive scale-down so data returns when the ordinal comes back. Don't type this from scratch on the exam — copy the StatefulSet example from /docs/concepts/workloads/controllers/statefulset/ and edit.

### 7. Canary a StatefulSet update with partition

```bash
k -n data scale sts db --replicas=3 && k -n data rollout status sts/db
k -n data patch sts db -p '{"spec":{"updateStrategy":{"type":"RollingUpdate","rollingUpdate":{"partition":2}}}}'
k -n data set image sts/db redis=redis:7.4
k -n data rollout status sts/db            # completes: only ordinal >=2 updates
k -n data get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
# db-0  redis:7
# db-1  redis:7
# db-2  redis:7.4
# finish the rollout:
k -n data patch sts db -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":0}}}}'
k -n data rollout status sts/db
k -n data get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
# all redis:7.4
```

Why: partition=N updates only ordinals >= N, highest first — a built-in canary; dropping partition to 0 rolls the rest (2→1→0 order, no manual deletes).

### 8. Parallel Job with constraints

```bash
k create ns batch-lab
k -n batch-lab create job crunch --image=busybox:1.36 $do -- sh -c 'echo done from $HOSTNAME && sleep 3' > job.yaml
# edit: add the five spec fields; restartPolicy Never is already the create-job default
```

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: crunch
  namespace: batch-lab
spec:
  completions: 6
  parallelism: 2
  backoffLimit: 2
  activeDeadlineSeconds: 120
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: crunch
        image: busybox:1.36
        command: ["sh", "-c", "echo done from $HOSTNAME && sleep 3"]
```

```bash
k apply -f job.yaml
k -n batch-lab get pods -w        # never more than 2 Running at once
k -n batch-lab get job crunch     # COMPLETIONS 6/6
k -n batch-lab logs -l job-name=crunch --tail=-1
```

Why: `restartPolicy: Never` keeps failed pods around for `k logs` (OnFailure restarts in place and deletes evidence at the limit); `activeDeadlineSeconds` caps the whole Job's wall-clock, overriding backoffLimit; the TTL controller garbage-collects Job+pods 300s after finish.

### 9. CronJob with concurrency control + manual trigger

```bash
k -n batch-lab create cronjob backup --image=busybox:1.36 --schedule='*/5 * * * *' $do -- sh -c 'echo backing up && sleep 5' > cj.yaml
```

Edited result:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup
  namespace: batch-lab
spec:
  schedule: "*/5 * * * *"
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 100
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: backup
            image: busybox:1.36
            command: ["sh", "-c", "echo backing up && sleep 5"]
```

```bash
k apply -f cj.yaml
k -n batch-lab patch cronjob backup -p '{"spec":{"suspend":true}}'
k -n batch-lab create job backup-manual --from=cronjob/backup
k -n batch-lab get jobs -w        # backup-manual Completions 1/1
k -n batch-lab logs -l job-name=backup-manual
```

Why: `Forbid` skips a scheduled run while one is still active; `--from=cronjob/` copies the jobTemplate and works even while suspended (suspend only stops the *scheduler*, not manual creation).

### 10. ConfigMap + Secret, three consumption modes

```bash
k create ns config-lab
k -n config-lab create cm app-config --from-literal=APP_MODE=production --from-literal=APP_COLOR=blue
k -n config-lab create secret generic app-secret --from-literal=DB_USER=admin --from-literal=DB_PASS='S3cret!'
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: consumer
  namespace: config-lab
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sleep", "3600"]
    env:
    - name: MODE
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: APP_MODE
    envFrom:
    - secretRef:
        name: app-secret
    volumeMounts:
    - name: cfg
      mountPath: /etc/app-config
  volumes:
  - name: cfg
    configMap:
      name: app-config
```

```bash
k apply -f consumer.yaml
k -n config-lab exec consumer -- sh -c 'echo MODE=$MODE; echo DB_USER=$DB_USER; echo DB_PASS=$DB_PASS; ls /etc/app-config'
# MODE=production / DB_USER=admin / DB_PASS=S3cret! / APP_COLOR APP_MODE
```

Why: one pod exercising `valueFrom` (single key), `envFrom` (all keys, names become env var names), and a volume (one file per key). Remember: the two env modes never see updates; the volume does.

### 11. The subPath rotation trap

```bash
# reproduce the update (imperative replace pattern):
k -n subpath-lab create cm feature-flags --from-literal=flags.conf='beta=true' $do | k replace -f -
k -n subpath-lab logs flag-reader --tail=3 -f
# wait >2 min: still beta=false — the update NEVER lands
```

Root cause (one sentence): a `subPath` mount bind-mounts the resolved file directly and bypasses the kubelet's atomic-symlink update mechanism, so the container keeps the content from pod start forever.

Fix — mount the directory, not the file (pods are immutable in volumes/mounts, so recreate):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: flag-reader
  namespace: subpath-lab
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "while true; do cat /etc/app/flags.conf; sleep 10; done"]
    volumeMounts:
    - name: flags
      mountPath: /etc/app
  volumes:
  - name: flags
    configMap:
      name: feature-flags
```

```bash
k -n subpath-lab delete pod flag-reader $now
k -n subpath-lab apply -f flag-reader.yaml
k -n subpath-lab create cm feature-flags --from-literal=flags.conf='beta=canary' $do | k replace -f -
k -n subpath-lab logs flag-reader -f
# within ~1-2 min the output flips to beta=canary
```

Why: directory-mounted ConfigMaps are symlink-swapped by the kubelet on its sync loop, so updates propagate (worst case about kubelet sync period + cache delay); subPath is only for injecting a file into a directory whose other content must survive.

### 12. Quota-blocked deployment

```bash
k -n constrained get deploy blocked        # READY 0/2
k -n constrained get pods                  # No resources found — not even Pending
k -n constrained describe rs -l app=blocked | grep -A4 Events
# Warning  FailedCreate ... forbidden: failed quota: compute-quota:
#   must specify limits.cpu for: nginx; limits.memory for: nginx; requests.cpu ...
k -n constrained get events --sort-by=.lastTimestamp | tail -5   # same evidence
# fix:
k -n constrained set resources deploy blocked \
  --requests=cpu=100m,memory=128Mi --limits=cpu=200m,memory=256Mi
k -n constrained rollout status deploy/blocked
k -n constrained get pods                  # 2/2 Running
k -n constrained describe quota compute-quota
# requests.cpu 200m/1, requests.memory 256Mi/1Gi, limits.cpu 400m/2, ...
```

Why: a quota on `requests.*`/`limits.*` makes those fields mandatory at admission; the ReplicaSet's create calls are rejected, so there are no pods and no pod events — the evidence lives on the ReplicaSet. (Alternative fix: a LimitRange with `default`/`defaultRequest` injects values namespace-wide.)

### 13. HPA with kubectl autoscale + behavior tuning

metrics-server for kind (one-time; kubelets use self-signed certs, hence the flag):

```bash
k apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
k -n kube-system patch deploy metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
k -n kube-system rollout status deploy/metrics-server
k top nodes    # works when ready (can take ~1 min)
```

Task:

```bash
k create ns scale-lab
k -n scale-lab create deployment web --image=nginx:1.27 --replicas=2
k -n scale-lab set resources deploy web --requests=cpu=100m,memory=64Mi --limits=cpu=200m,memory=128Mi
k -n scale-lab autoscale deployment web --min=2 --max=6 --cpu-percent=70
k -n scale-lab patch hpa web --type=merge \
  -p '{"spec":{"behavior":{"scaleDown":{"stabilizationWindowSeconds":60}}}}'
k -n scale-lab get hpa web -w
# TARGETS shows cpu: 0%/70% (a number, not <unknown>) within ~1 min
k -n scale-lab get hpa web -o yaml | grep -A3 scaleDown
```

Why: `k autoscale` is the fastest exam-legal HPA path; behavior fields only exist in autoscaling/v2 and are reachable via patch/edit. `<unknown>` means metrics-server missing or no CPU requests on the target — this deployment has both prerequisites satisfied.

### 14. Helm release lifecycle

Online path (podinfo is a small, reliable public chart):

```bash
helm repo add podinfo https://stefanprodan.github.io/podinfo
helm repo update
helm search repo podinfo --versions | head -3

helm install web podinfo/podinfo -n helm-lab --create-namespace --set replicaCount=1
helm list -n helm-lab                             # STATUS deployed, REVISION 1
helm upgrade web podinfo/podinfo -n helm-lab --set replicaCount=2
k -n helm-lab get deploy                          # 2/2

helm history web -n helm-lab                      # rev 1 install, rev 2 upgrade
helm rollback web 1 -n helm-lab
helm history web -n helm-lab                      # rev 3 "Rollback to 1"  (a)
helm get values web -n helm-lab                   # replicaCount: 1        (b)
k -n helm-lab get deploy web-podinfo              # 1/1                    (c)
helm get manifest web -n helm-lab | head          # exactly what is applied
helm uninstall web -n helm-lab
```

Offline alternative (no internet — behavior identical):

```bash
helm create mychart                                # scaffolds an nginx chart
helm install web ./mychart -n helm-lab --create-namespace --set replicaCount=1
helm upgrade web ./mychart -n helm-lab --set replicaCount=2
helm history web -n helm-lab
helm rollback web 1 -n helm-lab && helm get values web -n helm-lab
helm uninstall web -n helm-lab
```

Why: rollback creates a new revision rather than rewinding history (audit trail), and `helm get values` is the ground truth for what the release currently runs with — remember a later bare `helm upgrade` would reset to chart defaults unless you re-pass values or use `--reuse-values`. (Bitnami charts are the classic tutorial target; their image registry moved in 2025, so this course uses podinfo — the commands are identical.)

### 15. Kustomize base + overlay

```bash
mkdir -p ~/kustomize-lab/base ~/kustomize-lab/overlays/prod
```

`~/kustomize-lab/base/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 2
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
        envFrom:
        - configMapRef:
            name: web-config
```

`~/kustomize-lab/base/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 80
```

`~/kustomize-lab/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
configMapGenerator:
  - name: web-config
    literals:
      - LOG_LEVEL=info
```

`~/kustomize-lab/overlays/prod/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: kustomize-lab
namePrefix: prod-
resources:
  - ../../base
images:
  - name: nginx
    newTag: "1.29"
patches:
  - patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: web
      spec:
        replicas: 3
```

```bash
k kustomize ~/kustomize-lab/overlays/prod    # review: prod-web, nginx:1.29, replicas 3,
                                             # envFrom -> prod-web-config-<hash>
k create ns kustomize-lab
k apply -k ~/kustomize-lab/overlays/prod
k -n kustomize-lab get deploy,svc,cm
# deployment.apps/prod-web 3/3, service/prod-web, configmap/prod-web-config-<hash>
k -n kustomize-lab get deploy prod-web -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# nginx:1.29
```

Why: the generator appends a content hash and rewrites the deployment's `configMapRef` automatically — change `LOG_LEVEL` and re-apply and you get a new CM name plus an automatic rolling restart; patches identify their target by kind+name *before* prefixing, which is why the patch says `web`, not `prod-web`. Note `namespace:` in kustomization does not create the namespace — hence `k create ns` first.

### 16. Init container gate + SecurityContext

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app
  namespace: bootstrap
spec:
  securityContext:
    runAsUser: 1000
    runAsGroup: 3000
    runAsNonRoot: true
    fsGroup: 2000
  initContainers:
  - name: wait-for-db
    image: busybox:1.36
    command: ["sh", "-c", "until nslookup db.bootstrap.svc.cluster.local; do echo waiting for db; sleep 2; done"]
  containers:
  - name: app
    image: busybox:1.36
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
```

```bash
k create ns bootstrap
k apply -f app.yaml
k -n bootstrap get pod app             # Init:0/1 — blocked, as required
k -n bootstrap logs app -c wait-for-db --tail=3   # "waiting for db" loop
# create the dependency:
k -n bootstrap create deployment db --image=nginx:1.27
k -n bootstrap expose deployment db --port=80
k -n bootstrap get pod app -w          # Init:0/1 -> PodInitializing -> Running (within ~2s of DNS existing)
k -n bootstrap exec app -- id
# uid=1000 gid=3000 groups=2000,3000
```

Why: init containers run to completion before app containers start, so a DNS-poll loop is the standard dependency gate; the pod-level securityContext (runAsUser/runAsGroup/runAsNonRoot/fsGroup) applies to all containers while capabilities/allowPrivilegeEscalation are container-level only. Note `runAsNonRoot` applies to the init container too — busybox's `nslookup` works fine as UID 1000.

---

Cleanup:

```bash
k delete ns apps rollback-lab broken-lab monitoring data batch-lab config-lab \
  subpath-lab constrained scale-lab helm-lab kustomize-lab bootstrap --ignore-not-found
rm -rf ~/kustomize-lab
```
