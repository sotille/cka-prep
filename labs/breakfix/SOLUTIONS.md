# breakfix — SOLUTIONS

Full diagnosis + fix + restore for every `break-NN-*.sh` in this directory. **Spoilers.** Run a break script, fight it blind against the symptom in its header, and only open this file when you are stuck or want to check your diagnosis narrative against the intended one.

All scripts operate only on the kind cluster `cka` (context `kind-cka`, nodes `cka-control-plane` / `cka-worker` / `cka-worker2`, reachable with `docker exec`). Conventions: `alias k=kubectl`, `export now="--grace-period=0 --force"`. Shared backups land in `/tmp/cka-breakfix/` on the host or in per-node paths noted below.

Exam-flavor: on a real kubeadm cluster you reach nodes with `ssh <node>` + `sudo -i` instead of `docker exec <node>`; every node-side command below is otherwise identical.

---

## break-01 — node NotReady (kubelet stopped)

**Symptom recap:** ~60s after arming, `k get nodes` shows `cka-worker2 NotReady`; workloads on it stop being managed. Fix must survive a reboot.

**Diagnosis walkthrough:**

```bash
k get nodes
# NAME                STATUS     ROLES           AGE   VERSION
# cka-worker2         NotReady   <none>          ...   v1.3x.x

k describe node cka-worker2 | grep -A6 Conditions
# Ready   False   ... KubeletNotReady? -> reason: "kubelet stopped posting node status"

docker exec cka-worker2 systemctl is-active kubelet
# inactive
docker exec cka-worker2 systemctl status kubelet | head -5
# Active: inactive (dead)  (and "disabled" in the vendor preset line)
```

The node manager (kubelet) is not running, so it stopped sending heartbeats; after the grace period the node flips to NotReady.

**Root cause:** the kubelet service was stopped *and disabled* on `cka-worker2`.

**Fix:**

```bash
docker exec cka-worker2 systemctl enable --now kubelet   # start now AND enable at boot
k get nodes -w                                            # cka-worker2 -> Ready in ~30-60s
```

`enable --now` covers both requirements: it starts the kubelet immediately and marks it to start on the next boot (survives a reboot). A plain `systemctl start kubelet` would regress on reboot because the break also disabled it.

**Restore / cleanup:** the fix *is* the restore — the node is healthy and the kubelet is enabled. Nothing else to undo.

---

## break-02 — node NotReady, kubelet is up (CNI config removed)

**Symptom recap:** `cka-worker` goes NotReady, but unlike break-01 its kubelet is running; new pods assigned to it never start.

**Diagnosis walkthrough:**

```bash
k get nodes
# cka-worker   NotReady   ...

k describe node cka-worker | grep -A8 Conditions
# Ready   False   ... reason: "container runtime network not ready:
#   NetworkReady=false reason:NetworkPluginNotReady
#   message:Network plugin returns error: cni plugin not initialized"

docker exec cka-worker systemctl is-active kubelet
# active   <- kubelet is fine, so this is NOT break-01

docker exec cka-worker ls -la /etc/cni/net.d
# empty (the CNI config files were moved away)
docker exec cka-worker ls /opt/cni/bin
# binaries still present -> config is missing, not the plugins
```

The kubelet is healthy but the container runtime cannot initialize pod networking because there is no CNI configuration in `/etc/cni/net.d`. That single condition holds the node NotReady.

**Root cause:** the CNI config in `/etc/cni/net.d/` was moved to `/root/.bf02-cni-backup/` and containerd restarted, so the runtime reports `cni plugin not initialized`.

**Fix (either path works):**

```bash
# Path A — restore the config files directly, then bounce runtime + kubelet:
docker exec cka-worker bash -c 'mv /root/.bf02-cni-backup/* /etc/cni/net.d/'
docker exec cka-worker systemctl restart containerd kubelet

# Path B — let the CNI DaemonSet regenerate its config by rescheduling its pod on the node:
k -n kube-system delete pod -l app=kindnet --field-selector spec.nodeName=cka-worker
# kindnet re-writes /etc/cni/net.d/10-kindnet.conflist on start

k get nodes -w   # cka-worker -> Ready
```

Path B is the "CNI awareness" lesson: the network plugin ships its config via a DaemonSet, so bouncing that pod re-lays the config even if you never find where the files went.

**Restore / cleanup:** after recovery, `docker exec cka-worker rm -rf /root/.bf02-cni-backup` (only if you used Path B and the backup is now redundant). If you used Path A the backup dir is already empty.

---

## break-03 — every new pod stays Pending (kube-scheduler manifest typo)

**Symptom recap:** every newly created pod hangs in `Pending` with **no events**. A canary `bf03-canary` in `default` shows it immediately.

**Diagnosis walkthrough:** `kubectl` still works (only the scheduler is down), so use it.

```bash
k get pod bf03-canary -o wide
# STATUS Pending, NODE <none>
k describe pod bf03-canary | tail -5
# Events:  <none>          <- no FailedScheduling at all -> scheduler isn't running

k -n kube-system get pods | grep scheduler
# kube-scheduler-cka-control-plane   0/1   CrashLoopBackOff

k -n kube-system logs kube-scheduler-cka-control-plane --previous | tail -5
# unknown flag: --leader-elect-and-hope
# (if the container is between restarts, use crictl on the node:)
docker exec cka-control-plane crictl ps -a | grep scheduler
docker exec cka-control-plane crictl logs <scheduler-container-id> | tail -5
```

Pending with an empty Events block is the fingerprint of a dead scheduler: nothing is even attempting to bind the pod. The log names the bad flag.

**Root cause:** in `/etc/kubernetes/manifests/kube-scheduler.yaml`, `--leader-elect=true` was corrupted to `--leader-elect-and-hope=true`. The kubelet runs the manifest, the binary rejects the unknown flag, the static pod crash-loops.

**Fix:**

```bash
# correct the flag in place; the kubelet reconciles the static pod automatically
docker exec cka-control-plane sed -i \
  's/--leader-elect-and-hope=true/--leader-elect=true/' \
  /etc/kubernetes/manifests/kube-scheduler.yaml
# or restore the backup the script saved:
# docker exec cka-control-plane cp /root/kube-scheduler.yaml.bf03.bak /etc/kubernetes/manifests/kube-scheduler.yaml

sleep 20
k -n kube-system get pods | grep scheduler      # Running 1/1
k get pod bf03-canary -o wide                   # now scheduled and Running
```

You cannot `kubectl edit` a static pod — edit the file on disk; the kubelet re-creates the pod within ~15-30s.

**Restore / cleanup:**

```bash
docker exec cka-control-plane rm -f /root/kube-scheduler.yaml.bf03.bak
k delete pod bf03-canary $now
```

---

## break-04 — cluster DNS completely dead (CoreDNS scaled to 0 + corrupt Corefile)

**Symptom recap:** `nslookup kubernetes.default` fails from every pod; there is more than one fault.

**Diagnosis walkthrough:**

```bash
k -n kube-system get deploy coredns
# READY 0/0                 <- fault #1: scaled to zero

k -n kube-system scale deploy coredns --replicas=2
k -n kube-system get pods -l k8s-app=kube-dns
# CrashLoopBackOff          <- fault #2 surfaces once pods exist

k -n kube-system logs -l k8s-app=kube-dns --previous | grep -i error
# Corefile:N - Error during parsing: Unknown directive 'forwrad'
```

Two independent faults: nothing was serving DNS (zero replicas), and even with replicas the Corefile has a typo that makes CoreDNS refuse to start.

**Root cause:** the `coredns` ConfigMap had `forward . /etc/resolv.conf` mangled to `forwrad . /etc/resolv.conf`, and the `coredns` Deployment was scaled to 0.

**Fix:**

```bash
# fault #1 already fixed above (scale to 2); now fix the Corefile:
k -n kube-system edit configmap coredns          # change 'forwrad' back to 'forward'
# or restore from the script's backup:
# k apply -f /tmp/cka-breakfix/coredns-cm.bak.yaml

k -n kube-system rollout restart deploy coredns   # guarantee a clean re-parse
k run dnstest --rm -it --image=busybox:1.36 --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local   # resolves
```

**Restore / cleanup:**

```bash
k apply -f /tmp/cka-breakfix/coredns-cm.bak.yaml   # if you edited by hand, this guarantees pristine state
k -n kube-system scale deploy coredns --replicas=2
rm -f /tmp/cka-breakfix/coredns-cm.bak.yaml
```

---

## break-05 — app never reachable (bad image + wrong Service selector)

**Symptom recap:** in namespace `bf05`, `wget http://web.bf05` from inside the cluster times out; it has never worked. Final image must be `nginx:1.27`. More than one fault.

**Diagnosis walkthrough:**

```bash
k -n bf05 get all
# deploy web 0/2, pods ImagePullBackOff, svc web ClusterIP ...

k -n bf05 describe pod -l app=web | grep -A2 Events
# Failed to pull image "nginx:1.99.99-broken": ... not found      <- fault #1

k -n bf05 describe svc web | grep -i endpoints
# Endpoints: <none>                                               <- fault #2
k -n bf05 get svc web -o jsonpath='{.spec.selector}{"\n"}'
# {"app":"web-frontend"}
k -n bf05 get pods --show-labels
# ... app=web                                                     <- selector != pod labels
```

Two faults stacked: the pods cannot pull their image (so nothing runs), *and* the Service selector (`app=web-frontend`) does not match the pods' label (`app=web`), so even healthy pods would have no endpoints.

**Root cause:** Deployment created with the nonexistent image `nginx:1.99.99-broken`; Service patched to select `app=web-frontend` which no pod carries.

**Fix:**

```bash
k -n bf05 set image deployment/web web=nginx:1.27           # fix the image
k -n bf05 patch service web -p '{"spec":{"selector":{"app":"web"}}}'   # fix the selector
k -n bf05 rollout status deployment/web
k -n bf05 describe svc web | grep -i endpoints              # now populated
k run tmp --rm -it --image=busybox:1.36 --restart=Never -- \
  wget -qO- --timeout=2 http://web.bf05                     # nginx welcome page
```

**Restore / cleanup:** `k delete namespace bf05`.

---

## break-06 — PVC never binds (default StorageClass deleted)

**Symptom recap:** pod `db` in `bf06` is `Pending` and its PVC `data` never binds. "Storage always just worked on this cluster." Must use the dynamic provisioner (no hand-crafted PV).

**Diagnosis walkthrough:**

```bash
k -n bf06 get pvc,pod
# pvc/data   Pending
# pod/db     Pending

k -n bf06 describe pvc data | tail -5
# ... no persistent volumes available for this claim and no storage class is set
#     (or) storageclass.storage.k8s.io "standard" not found

k get storageclass
# No resources found            <- the default class is gone
```

The claim was created without a `storageClassName`, relying on the cluster's default StorageClass to provision. That default (`standard`, the kind local-path provisioner) has been deleted, so nothing provisions a PV.

**Root cause:** the default StorageClass `standard` was deleted; the PVC has no class to bind against.

**Fix:**

```bash
k apply -f /tmp/cka-breakfix/standard-sc.bak.yaml   # recreates 'standard' WITH the is-default annotation
k get storageclass                                  # standard (default) present again
k -n bf06 get pvc data -w                           # Bound (retroactive default assignment, k8s >=1.28)
k -n bf06 get pod db                                # Running
```

On Kubernetes v1.28+ the PV controller retroactively assigns the restored default class to the still-unset PVC and it binds. If it does not bind within a minute (older behavior), recreate the claim so admission stamps the default class:

```bash
k -n bf06 delete pod db --wait=false
k -n bf06 delete pvc data
k apply -n bf06 -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
EOF
# then recreate the db pod (same spec as the setup) so it consumes the now-bound claim
```

**Restore / cleanup:**

```bash
k apply -f /tmp/cka-breakfix/standard-sc.bak.yaml   # ensure default class exists
k delete namespace bf06
rm -f /tmp/cka-breakfix/standard-sc.bak.yaml
```

---

## break-07 — only NEW Services are dead (kube-proxy DaemonSet unschedulable)

**Symptom recap:** pre-existing Services keep working, but every Service created from now on is unreachable — endpoints look fine, yet connecting to the ClusterIP times out. Something cluster-wide that programs Service traffic is not running where it should.

**Diagnosis walkthrough:**

```bash
k -n kube-system get daemonset kube-proxy
# DESIRED 0   CURRENT 0   READY 0        <- kube-proxy runs on NO node

k -n kube-system get pods -l k8s-app=kube-proxy -o wide
# (none)

k -n kube-system get daemonset kube-proxy -o jsonpath='{.spec.template.spec.nodeSelector}{"\n"}'
# {"kubernetes.io/os":"linux-v2"}         <- no node has this label

k get nodes -o jsonpath='{.items[*].metadata.labels.kubernetes\.io/os}{"\n"}'
# linux linux linux                       <- real label value is "linux"
```

kube-proxy is the component that turns Services into DNAT rules on each node. Existing rules persist in the datapath, so old Services still answer, but with kube-proxy scheduled on zero nodes, no *new* Service ever gets programmed — matching the "old works, new dead" symptom exactly.

**Root cause:** the `kube-proxy` DaemonSet's `nodeSelector` was set to `kubernetes.io/os: linux-v2`, a label no node carries, so the DaemonSet schedules nowhere.

**Fix:**

```bash
k -n kube-system patch daemonset kube-proxy --type=merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/os":"linux"}}}}}'
k -n kube-system rollout status daemonset kube-proxy      # DESIRED 3, READY 3

# verify a brand-new Service now works:
k -n default run bf07-web --image=nginx:1.27
k -n default expose pod bf07-web --port=80 --name=bf07-svc
k run tmp --rm -it --image=busybox:1.36 --restart=Never -- \
  wget -qO- --timeout=2 http://bf07-svc.default
```

**Restore / cleanup:**

```bash
k -n default delete svc bf07-svc --ignore-not-found
k -n default delete pod bf07-web --ignore-not-found $now
```

---

## break-08 — handed-over kubeconfig refuses everything (bad CA path + wrong port)

**Symptom recap:** `/tmp/cka-breakfix/ops-user.kubeconfig` errors on every command; there is more than one problem. Repair the **file** (do not switch to your own config, do not touch `~/.kube/config`).

**Diagnosis walkthrough:**

```bash
KCFG=/tmp/cka-breakfix/ops-user.kubeconfig
kubectl --kubeconfig "$KCFG" get nodes
# error: ... unable to read certificate-authority /etc/kubernetes/pki/ca.crt:
#        open /etc/kubernetes/pki/ca.crt: no such file or directory     <- fault #1

kubectl --kubeconfig "$KCFG" config view --raw | grep -E 'server:|certificate-authority'
# certificate-authority: /etc/kubernetes/pki/ca.crt   (a path that only exists INSIDE the control-plane)
# server: https://127.0.0.1:6444                      <- fault #2, wrong port
```

Two faults: the `certificate-authority` points at a file that exists only inside the control-plane container, not on this host (a load error, not an x509 error — that already tells you it is a *file path* problem); and the `server` port is wrong. Fix the CA first, and the next error (`connection refused`) reveals the port fault.

**Root cause:** the copied kubeconfig replaced the embedded `certificate-authority-data` with a container-internal path `/etc/kubernetes/pki/ca.crt`, and changed the server to `https://127.0.0.1:6444` (the real kind API port is different).

**Fix:** read the correct values from your working config and write them into the file.

```bash
KCFG=/tmp/cka-breakfix/ops-user.kubeconfig

# 1) the real server URL for kind-cka
REAL_SERVER=$(kubectl config view --raw \
  -o jsonpath='{.clusters[?(@.name=="kind-cka")].cluster.server}')
kubectl --kubeconfig "$KCFG" config set-cluster kind-cka --server="$REAL_SERVER"

# 2) the real CA, embedded (so no external file path is needed)
kubectl config view --raw \
  -o jsonpath='{.clusters[?(@.name=="kind-cka")].cluster.certificate-authority-data}' \
  | base64 -d > /tmp/cka-breakfix/ca.crt
kubectl --kubeconfig "$KCFG" config set-cluster kind-cka \
  --certificate-authority=/tmp/cka-breakfix/ca.crt --embed-certs=true

# 3) verify against the repaired FILE
kubectl --kubeconfig "$KCFG" get nodes            # lists all three nodes
```

`--embed-certs=true` inlines the CA as `certificate-authority-data`, so the file is portable and no longer depends on a path that does not exist on this host.

**Restore / cleanup:** nothing on the cluster was changed. Remove the drill files: `rm -f /tmp/cka-breakfix/ops-user.kubeconfig /tmp/cka-breakfix/ca.crt`.

---

## Reset everything

If you armed several breaks and want a clean slate:

```bash
# nodes
docker exec cka-worker2 systemctl enable --now kubelet
docker exec cka-worker bash -c 'mv /root/.bf02-cni-backup/* /etc/cni/net.d/ 2>/dev/null || true; systemctl restart containerd kubelet'
# control plane
docker exec cka-control-plane sh -c '[ -f /root/kube-scheduler.yaml.bf03.bak ] && cp /root/kube-scheduler.yaml.bf03.bak /etc/kubernetes/manifests/kube-scheduler.yaml || true'
# DNS
k apply -f /tmp/cka-breakfix/coredns-cm.bak.yaml 2>/dev/null || true
k -n kube-system scale deploy coredns --replicas=2
# storage
k apply -f /tmp/cka-breakfix/standard-sc.bak.yaml 2>/dev/null || true
# kube-proxy
k -n kube-system patch daemonset kube-proxy --type=merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/os":"linux"}}}}}'
# drill namespaces / files
k delete ns bf05 bf06 --ignore-not-found
k delete pod bf03-canary bf07-web -n default --ignore-not-found $now
k -n default delete svc bf07-svc --ignore-not-found
rm -f /tmp/cka-breakfix/*.bak.yaml /tmp/cka-breakfix/ops-user.kubeconfig /tmp/cka-breakfix/ca.crt

k get nodes && k get pods -A | grep -vE 'Running|Completed'   # should be clean
```
