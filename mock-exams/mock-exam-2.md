# CKA Mock Exam 2 — True Exam Level

## Rules

| Rule | Value |
|---|---|
| Duration | 120 minutes, hard stop |
| Tasks | 16, weights sum to 100% |
| Pass mark | 66% |
| Cluster | kind cluster `cka`, kubectl context `kind-cka` |
| Allowed docs | kubernetes.io/docs, kubernetes.io/blog, helm.sh/docs — one browser tab |
| Answer files | Exactly at the paths given, under `/tmp/exam2/` (pre-created by setup) |

Before starting, run the setup **without reading it** (it contains the faults):

```bash
bash mock-exams/mock-exam-2-setup.sh
```

Assumed shell environment (course conventions):

```bash
alias k=kubectl
export do="--dry-run=client -o yaml"
export now="--grace-period=0 --force"
```

Node access: this lab substitutes `docker exec -it <node-name> bash` for the real exam's `ssh <node>` + `sudo -i`. Node names: `cka-control-plane`, `cka-worker`, `cka-worker2`.

**Warning, read once:** this exam contains cluster-level faults. If pods you create in *any* task sit in `Pending` with **no events at all**, that is a symptom of one of the troubleshooting tasks — hunt it down and fix it before continuing. Skim all 16 tasks in the first 5 minutes, exactly as you should on the real exam.

Domain weights mirror the live exam: Troubleshooting 30, Cluster Architecture 25, Services & Networking 20, Workloads & Scheduling 15, Storage 10. Verify the current curriculum version on the CNCF curriculum page before exam day.

---

## Task 1 — Certificate-based user access (6%)

Use context `kind-cka`. Namespace `dev-ana` exists. Directory `/tmp/exam2/ana/` exists.

A new developer `ana` needs read access to pods in namespace `dev-ana`.

- Generate a 2048-bit RSA private key at `/tmp/exam2/ana/ana.key` and a CSR at `/tmp/exam2/ana/ana.csr` with Common Name `ana`.
- Create a `CertificateSigningRequest` object named `ana`, signed by the built-in signer for API-server client certificates, valid for 24 hours.
- Approve it and save the issued certificate to `/tmp/exam2/ana/ana.crt`.
- Create a Role `pod-reader` in `dev-ana` allowing `get`, `list`, `watch` on pods, and a RoleBinding `ana-pod-reader` granting it to the user `ana`.
- Verify that `ana` can list pods in `dev-ana` and prove it (kubeconfig context or `kubectl auth can-i`).

*Exam flavor: identical on the real exam; on the Linux exam terminal use `base64 -w 0`, on macOS plain `base64` plus `tr -d '\n'`.*

## Task 2 — Deployment not becoming Ready (8%)

Use context `kind-cka`. Namespace `troubled` pre-exists with Deployment `orders-api` (3 replicas).

`orders-api` was deployed an hour ago and still has 0 ready replicas. The application is plain nginx serving HTTP on port 80; the intended image line is `nginx:1.27-alpine`.

- Find **all** faults and fix the Deployment in place (do not delete/recreate it).
- Finish state: `3/3` replicas Ready.

## Task 3 — HorizontalPodAutoscaler (8%)

Use context `kind-cka`. Namespace `fintech` pre-exists with Deployment `checkout` (CPU requests already set).

Create an HPA named `checkout-hpa` in `fintech`:

- Targets Deployment `checkout`.
- Min 2 replicas, max 8.
- Scales on average CPU utilization of 65%.
- Scale-down must wait for a stabilization window of 300 seconds.
- Use API version `autoscaling/v2`.

*Lab note: this kind cluster has no metrics-server, so current metrics will read `<unknown>`; the object itself is what is graded. On the real exam metrics work.*

## Task 4 — Service serves no traffic (7%)

Use context `kind-cka`. Namespace `commerce` pre-exists with Deployment `catalog` (nginx on port 80) and Service `catalog-svc`.

`catalog-svc` returns connection failures. **Do not modify the Deployment.**

- Fix the Service so it serves the catalog pods on port 80.
- From a temporary pod, fetch `http://catalog-svc` and save the full HTTP response body to `/tmp/exam2/04-curl.txt`.

## Task 5 — Kustomize overlay (5%)

Use context `kind-cka`. A kustomize base exists at `/tmp/exam2/kustomize/base` (Deployment `web`, 1 replica).

Create an overlay at `/tmp/exam2/kustomize/overlays/prod` that, without editing the base:

- Deploys into namespace `prod-web` (create the namespace).
- Prefixes all resource names with `prod-`.
- Sets `web` replicas to 3.
- Adds label `env: prod` to all resources.

Apply the overlay with kubectl's built-in kustomize and save the rendered manifests to `/tmp/exam2/05-rendered.yaml`.

## Task 6 — NetworkPolicy for the database (7%)

Use context `kind-cka`. Namespace `secure-api` pre-exists with pods labeled `app=api`, `app=db`, `app=client`.

Create a NetworkPolicy `db-allow-api` in `secure-api`:

- Applies to pods labeled `app=db`.
- Allows ingress **only** from pods labeled `app=api` in the same namespace, **only** on TCP 5432.
- All other ingress to the db pods must be denied. Egress must remain unrestricted.

*Lab note: kind's default CNI (kindnet) does not enforce NetworkPolicy — the object is graded on correctness. The real exam clusters run a CNI that enforces it.*

## Task 7 — Node NotReady (8%)

Use context `kind-cka`.

Node `cka-worker2` is `NotReady`. Bring it back to `Ready` and make the fix survive a node reboot.

*Exam flavor: on the real exam this is `ssh <node>`, `sudo -i`, `systemctl`/`journalctl`. Here: `docker exec -it cka-worker2 bash` (you are already root).*

## Task 8 — Dynamic provisioning (5%)

Use context `kind-cka`. Namespace `storage-task` pre-exists. The cluster ships the `rancher.io/local-path` provisioner.

- Create a StorageClass `fast-local`: provisioner `rancher.io/local-path`, reclaim policy `Delete`, volume binding mode `WaitForFirstConsumer`.
- Create a PVC `data-pvc` in `storage-task`: 1Gi, `ReadWriteOnce`, using `fast-local`.
- Create a Pod `data-pod` in `storage-task` (image `busybox:1.36`, command keeping it running) mounting the claim at `/data`.
- Finish state: PVC `Bound`, pod `Running`.

## Task 9 — Gateway API route (7%)

Use context `kind-cka`. Namespace `gateway-ns` pre-exists with Services `shop` (port 80) and `cart` (port 8080). A GatewayClass `cka-gwc` exists.

- Create a Gateway `web-gw` in `gateway-ns`: class `cka-gwc`, one HTTP listener named `http` on port 80 for hostname `shop.example.com`, accepting routes from the same namespace only.
- Create an HTTPRoute `shop-route` in `gateway-ns` attached to `web-gw` for hostname `shop.example.com`: requests with path prefix `/cart` go to Service `cart` port 8080; all other requests go to Service `shop` port 80.

*Lab note: no gateway controller is installed, so the Gateway will not report `Programmed` — object spec is what is graded. Real-exam clusters have the CRDs pre-installed, as here.*

## Task 10 — PriorityClass (7%)

Use context `kind-cka`. Namespace `fintech` pre-exists with Deployment `payments`.

- Create a PriorityClass `critical-services` with a value exactly **one less** than the highest value among existing **user-defined** PriorityClasses (ignore `system-node-critical` and `system-cluster-critical`). It must not be the cluster default.
- Assign it to the `payments` Deployment and wait until the rollout completes.

## Task 11 — Certificate expiry (4%)

Use context `kind-cka`.

Determine when the kube-apiserver **serving certificate** of the control plane expires. Write the expiry date to `/tmp/exam2/11-expiry.txt` exactly as printed by `openssl x509 -noout -enddate` (the part after `notAfter=` is acceptable too).

*Exam flavor: on a kubeadm exam node you would `ssh` in and run `kubeadm certs check-expiration` or openssl against `/etc/kubernetes/pki/apiserver.crt`; here use `docker exec` on `cka-control-plane`.*

## Task 12 — Helm release lifecycle (5%)

Use context `kind-cka`. A local chart exists at `/tmp/exam2/charts/webapp` (default image tag `1.26-alpine`).

- Install release `web` from that chart into namespace `web` (create the namespace during install), overriding `replicaCount` to 3.
- Upgrade the release to image tag `1.27-alpine`, keeping the replica override.
- Save the release history to `/tmp/exam2/12-history.txt` (must show 2 revisions).

## Task 13 — NodePort Service and DNS (6%)

Use context `kind-cka`. Namespace `web-frontend` pre-exists with Deployment `frontend` (nginx on port 80).

- Expose `frontend` with a Service `frontend-svc` of type NodePort: port 80, targetPort 80, nodePort **30080**.
- Write the fully qualified cluster DNS name of the Service to `/tmp/exam2/13-fqdn.txt`.
- Prove DNS resolution of that FQDN from a pod (any throwaway pod is fine).

*Lab note: the nodePort is reachable from the kind node network, not from your macOS host (no extraPortMappings). Verify from a node or a pod.*

## Task 14 — Bind a pre-provisioned PV (5%)

Use context `kind-cka`. A PersistentVolume `pv-archive` pre-exists (2Gi, storageClassName `archive`). Namespace `storage-task` exists.

- Create a PVC `archive-pvc` in `storage-task` that binds `pv-archive` (match its class, mode and full capacity).
- Create a Pod `archive-pod` in `storage-task` (image `busybox:1.36`, long-running) mounting the claim at `/mnt/archive`, and write any file into that mount.
- Finish state: PV and PVC `Bound`, pod `Running`.

## Task 15 — RBAC for a ServiceAccount (5%)

Use context `kind-cka`. Namespace `ci` pre-exists with ServiceAccount `deploy-bot`.

- Grant `deploy-bot` the ability to `create`, `get`, `list`, `update`, `patch` Deployments — in namespace `ci` only. Use a Role `deploy-manager` and a RoleBinding `deploy-bot-binding`.
- It must **not** be able to delete Deployments or read Secrets.
- Verify both the allow and the deny with `kubectl auth can-i`.

## Task 16 — Pods stuck Pending cluster-wide (7%)

Use context `kind-cka`. Namespace `recovery` pre-exists with Deployment `stuck-app`.

`stuck-app` has been `Pending` since it was created, and its pods show **no scheduling events at all**. Newly created pods anywhere in the cluster show the same symptom.

- Find the root cause in the control plane and fix it permanently.
- Write the absolute path (on the control-plane node) of the file you fixed to `/tmp/exam2/16-cause.txt`.
- Finish state: `stuck-app` is `Running`.

*Exam flavor: on the real exam this is `ssh` to the control-plane node + `sudo -i`; here `docker exec -it cka-control-plane bash`.*

---

Stop at 120 minutes. Grade yourself with `mock-exams/mock-exam-2-solutions.md` — apply the partial-credit rubrics honestly, then compare against the 66% pass line.
