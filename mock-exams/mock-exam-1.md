# CKA Mock Exam 1 — Full Run (exam-level minus)

A complete 16-task exam covering all five domains at the official weight distribution,
tuned slightly below real-exam difficulty. Goal: finish under time, score above 66%,
and calibrate where your minutes go.

## Rules — read once, then start the clock

1. **Run the setup script first**: `bash mock-exams/mock-exam-1-setup.sh`.
   **Do not read the script** — it contains every broken resource and therefore every answer.
   Re-running it resets the entire exam state, **including your own work**.
2. **2 hours, strict.** Start a timer the moment setup finishes.
3. Allowed references: `kubernetes.io/docs`, `kubernetes.io/blog`, `helm.sh/docs`. Nothing else — no notes, no chat, no search engine.
4. Weights sum to 100. **Pass mark: 66.** Partial credit exists (see solutions rubric).
5. Grading is on **final cluster/file state**. Solve tasks in any order; a 60-second triage pass first is a good habit.
6. Query answers go to **exact file paths under `/tmp/exam/`**. Files are graded literally; a missing or misnamed file scores zero for that part.
7. Course conventions are assumed active: `alias k=kubectl`, `export do="--dry-run=client -o yaml"`, `export now="--grace-period=0 --force"`.
8. Lab-to-exam mapping: this runs on the 3-node kind cluster `cka` (context `kind-cka`; nodes `cka-control-plane`, `cka-worker`, `cka-worker2`). Where the real exam says `ssh node01`, the lab equivalent is `docker exec -it <node-name> bash`. On the real exam every task begins with a `kubectl config use-context ...` line — run `kubectl config use-context kind-cka` now and build the reflex.
9. One lab caveat: kind's default CNI (kindnet) does **not enforce** NetworkPolicy. The policy task is graded on the object spec, exactly as you would write it on an enforcing CNI.

When the timer ends: stop, then self-grade with `mock-exam-1-solutions.md`.

---

## Task 1 — 6% — Least-privilege for a CI bot

Context: namespace `cicd` exists and is empty.

Create a ServiceAccount `deploy-bot` in namespace `cicd`. Create a Role `deployment-manager` in `cicd` granting exactly these permissions and nothing more: `get`, `list`, `watch`, `update`, `patch` on Deployments (API group `apps`). Bind the Role to the ServiceAccount with a RoleBinding named `deploy-bot-binding`.

Then check with `kubectl auth can-i` whether the ServiceAccount can `update` Deployments in `cicd`, and write the command's output (`yes` or `no`) to `/tmp/exam/task1-cani.txt`.

## Task 2 — 6% — Deployment won't come up

Context: namespace `apex` contains a Deployment `web-frontend` that should run 3 replicas; 0 are ready.

Diagnose and fix the Deployment so all 3 replicas become Ready. Do not delete and recreate the Deployment.

## Task 3 — 7% — Node not ready

Context: whole cluster.

One of the cluster nodes is `NotReady`. Identify it, find the root cause, and fix it so the node returns to `Ready`. The fix must survive a node reboot.

*Exam flavor: on the real exam you would `ssh node01` and use `sudo`; here use `docker exec -it <node-name> bash` (or one-shot `docker exec <node-name> <command>`).*

## Task 4 — 6% — Expose an app on a fixed node port

Context: namespace `netz` contains a running Deployment `echo-server` whose pods listen on port 8080.

Create a Service `echo-svc` in namespace `netz` of type NodePort that selects the `echo-server` pods: service port `8080`, targetPort `8080`, nodePort `30080`.

Write the Service's ClusterIP to `/tmp/exam/task4-clusterip.txt`.

## Task 5 — 8% — Deployment rollout controls

Context: namespace `apps` exists; nothing pre-exists for this task.

Create a Deployment `api-gateway` in namespace `apps`:

- image `nginx:1.27`, container named `nginx`, 2 replicas
- resource requests: cpu `100m`, memory `128Mi`; resource limit: memory `256Mi`
- rolling update strategy: at most 1 extra pod during updates (`maxSurge: 1`) and zero unavailable pods (`maxUnavailable: 0`)

Once it is fully available: update the image to `nginx:1.28` and let the rollout complete, then scale to 4 replicas.

Write the output of `kubectl rollout history` for this Deployment to `/tmp/exam/task5-history.txt`.

## Task 6 — 6% — Pods failing to start

Context: namespace `commerce` contains a Deployment `orders-api` (1 replica, 0 ready) and a Secret `orders-secret`.

The `orders-api` pod never starts. Find the cause and fix the Deployment so the pod becomes Ready. **Do not modify the Secret.**

## Task 7 — 7% — etcd snapshot

Context: etcd runs as a static pod on the control plane. Client endpoint: `https://127.0.0.1:2379`; certificates under `/etc/kubernetes/pki/etcd/`.

Create a snapshot of the etcd database and store it **on your host machine** at `/tmp/exam/task7-snapshot.db`. Then write the snapshot status (hash, revision, total keys, size — table format) to `/tmp/exam/task7-status.txt`.

*Exam flavor: on the real exam you `ssh` to the control-plane node where `etcdctl`/`etcdutl` are installed on the host and save directly to a host path. On kind, run the tools inside the etcd pod (or `docker exec` into `cka-control-plane`) and copy the snapshot out with `docker cp`.*

## Task 8 — 5% — Static provisioning

Context: a PersistentVolume `pv-manual-1g` (1Gi, RWO, storageClassName `manual`) pre-exists. Namespace `data` exists.

Create a PersistentVolumeClaim `data-claim` in namespace `data` requesting `500Mi` with storageClassName `manual`, access mode ReadWriteOnce, so that it binds to the existing PV. Then create a Pod `data-pod` in `data` (image `nginx:1.27-alpine`) that mounts the claim at `/usr/share/nginx/html`.

End state: PVC `Bound`, Pod `Running`.

## Task 9 — 7% — Lock down the database

Context: namespace `secure-apps` contains pods `db` (label `role=db`), `api` (label `role=api`) and `client` (label `role=client`).

Create a NetworkPolicy `db-allow-api` in namespace `secure-apps` so that only pods labeled `role=api` may connect to pods labeled `role=db`, and only on TCP port 5432. All other ingress to the `db` pods must be denied. Do not restrict traffic to any other pods in the namespace.

*(Graded on the policy spec — see rule 9.)*

## Task 10 — 7% — Run a pod on the control plane

Context: namespace `apps`.

Create a Pod `cp-agent` in namespace `apps` (image `busybox:1.36`, command `sleep 86400`) that runs on the control-plane node. Use a **toleration** for the control-plane taint plus a **node selector** on the control-plane role label. Do not set `spec.nodeName`.

End state: pod `Running` on `cka-control-plane`.

## Task 11 — 6% — Service without endpoints

Context: namespace `commerce` contains a Deployment `catalog-api` (2 replicas, all Running) and a Service `catalog-svc` (port 80). The app team reports DNS resolves but every connection to the service fails.

Fix the **Service** (do not modify the Deployment) so traffic reaches the pods. Then, from a temporary pod, request `http://catalog-svc.commerce/hostname` and write the response body to `/tmp/exam/task11-response.txt`.

## Task 12 — 6% — Kustomize prod overlay

Context: a Kustomize base exists at `/tmp/exam/task12/base` (a Deployment `nginx-web` and a Service `nginx-web`). Namespace `prod-apps` exists.

Without modifying the base, create an overlay at `/tmp/exam/task12/overlays/prod` that:

- places all resources in namespace `prod-apps`
- prefixes all resource names with `prod-`
- sets the Deployment's replicas to 3

Deploy the overlay with `kubectl apply -k`. End state: Deployment `prod-nginx-web` in `prod-apps` with 3 ready replicas, plus Service `prod-nginx-web`.

## Task 13 — 5% — Dynamic provisioning

Context: the cluster has a default StorageClass backed by a dynamic provisioner. Namespace `data` exists.

Write the **name** of the default StorageClass to `/tmp/exam/task13-sc.txt`. Then create a PersistentVolumeClaim `logs-pvc` in namespace `data` (200Mi, ReadWriteOnce) using the default StorageClass, and a Pod `logs-writer` in `data` (image `busybox:1.36`, command `sleep 86400`) mounting the claim at `/var/log/app`.

End state: PVC `Bound`, Pod `Running`.

## Task 14 — 5% — Extract error logs

Context: namespace `commerce` contains a Pod `payment-processor` that has been logging since setup.

Write all of the pod's log lines containing `level=ERROR` — and only those lines — to `/tmp/exam/task14-errors.txt`.

## Task 15 — 7% — Gateway API routing

Context: the Gateway API CRDs and a GatewayClass `exam-gc` are installed. Namespace `netz`. The backend is the Service `echo-svc` from Task 4 (your route is valid and gradable even if that Service does not exist).

Create a Gateway `web-gw` in namespace `netz`: gatewayClassName `exam-gc`, a single listener named `http`, protocol HTTP, port 80, allowing routes only from the same namespace.

Create an HTTPRoute `echo-route` in namespace `netz` attached to `web-gw` that routes requests for hostname `echo.example.com`, path prefix `/`, to the backend Service `echo-svc` on port 8080.

*(No gateway controller is installed in the lab, so the objects will not be programmed — grading is on the spec.)*

## Task 16 — 6% — Custom resources

Context: a CustomResourceDefinition in the API group `ops.example.com` is installed. Namespace `ops` exists.

Write the full name of that CRD to `/tmp/exam/task16-crd.txt`. Then create an instance of it named `nightly` in namespace `ops` with this spec: `source` = `/var/lib/app-data`, `schedule` = `0 2 * * *` (string), `retainDays` = `14` (integer). Use `kubectl explain` or the CRD schema to discover the structure.

---

**Time's up?** Put the keyboard down. Grade yourself with `mock-exam-1-solutions.md` — rubric points map 1:1 to the weights above.
