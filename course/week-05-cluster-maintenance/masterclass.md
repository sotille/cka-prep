# Week 05 Masterclass — Cluster Maintenance: kubeadm Lifecycle, Upgrades, and etcd (Cluster Architecture, Installation & Configuration — 25%)

This module is the single highest-ROI week of the course. The Cluster Architecture domain is 25% of the exam, and its heavy hitters — etcd backup/restore, kubeadm upgrade, node drain — are near-guaranteed tasks worth multiple points each. They are also the tasks where candidates burn the most time, because they involve SSH to nodes, `sudo`, static pod manifests, and long commands that punish improvisation. Everything here is drillable to muscle memory.

## What the exam actually asks

| Exam task pattern | Domain | Weight contribution |
|---|---|---|
| "Take a snapshot of etcd and save it to /srv/backup/etcd.db" | Cluster Architecture (25%) | High — appears in almost every exam |
| "Restore the cluster state from the snapshot at /srv/backup/etcd.db" | Cluster Architecture (25%) | High — often paired with the snapshot task |
| "Upgrade the control plane node to version X.Y.Z" (kubeadm) | Cluster Architecture (25%) | High — multi-step, high point value |
| "Drain node X for maintenance / make node X unschedulable" | Cluster Architecture (25%) + Troubleshooting (30%) | Medium |
| "Generate a join command / join a new worker node" | Cluster Architecture (25%) | Medium |
| Broken control-plane component (static pod manifest sabotage) | Troubleshooting (30%) | High — week 9 territory, but the mechanics live here |
| Certificate expiry inspection / renewal | Cluster Architecture (25%) | Low-medium |
| HA topology awareness (stacked vs external etcd) | Cluster Architecture (25%) | Conceptual — informs troubleshooting speed |

The exam is post-Feb-2025 curriculum; check the current outline at the CNCF curriculum page before exam day. Weights above are current as of that revision.

---

## kubeadm init anatomy — what actually happens

`kubeadm init` is a phase pipeline. Knowing the phases means you know where every artifact on a control-plane node came from — which is exactly what troubleshooting tasks test. Run `kubeadm init phase --help` to see the list; the execution order is:

1. **preflight** — checks: swap off, required ports free (6443, 2379-2380, 10250, 10257, 10259), container runtime socket reachable, `br_netfilter` loaded, `ip_forward=1`, minimum CPU/RAM. Failures here are errors; `--ignore-preflight-errors=...` overrides (kind uses this internally).
2. **certs** — generates the entire PKI under `/etc/kubernetes/pki`:
   - `ca.crt/ca.key` — cluster CA (signs apiserver serving cert, kubelet client certs, all kubeconfig client certs). 10-year validity.
   - `apiserver.crt` — serving cert; SANs include node IP, `--apiserver-advertise-address`, `--control-plane-endpoint`, `kubernetes.default.svc`, and the first IP of the service CIDR.
   - `apiserver-kubelet-client.crt` — apiserver's client cert for talking to kubelets.
   - `front-proxy-ca.crt` + `front-proxy-client.crt` — aggregation layer (extension API servers).
   - `etcd/ca.crt`, `etcd/server.crt`, `etcd/peer.crt`, `etcd/healthcheck-client.crt`, `apiserver-etcd-client.crt` — separate etcd CA and everything TLS between apiserver and etcd.
   - `sa.key/sa.pub` — the ServiceAccount token signing keypair. **Not a cert.** Lose this and every SA token in the cluster is invalid after restart.
3. **kubeconfig** — writes `/etc/kubernetes/admin.conf`, `super-admin.conf` (v1.29+), `kubelet.conf`, `controller-manager.conf`, `scheduler.conf`. Each embeds a client cert signed by the CA; the CN/O of that cert is the identity RBAC sees (`admin.conf` → `kubeadm:cluster-admins` group since 1.29, previously `system:masters`).
4. **kubelet-start** — writes kubelet config, starts kubelet, which begins watching `/etc/kubernetes/manifests` (the `staticPodPath`).
5. **control-plane** — writes static pod manifests for `kube-apiserver.yaml`, `kube-controller-manager.yaml`, `kube-scheduler.yaml` into `/etc/kubernetes/manifests`. Kubelet starts them — no scheduler, no API server involved. This bootstraps the chicken-and-egg problem.
6. **etcd** — writes `etcd.yaml` static pod manifest (unless external etcd is configured). Data dir `/var/lib/etcd`.
7. **upload-config** — stores `ClusterConfiguration` in the `kubeadm-config` ConfigMap and kubelet config in `kubelet-config` ConfigMap (kube-system). This is what `kubeadm upgrade` reads later.
8. **upload-certs** — (only with `--upload-certs`) encrypts control-plane certs into the `kubeadm-certs` Secret with a generated key. TTL 2 hours.
9. **mark-control-plane** — labels the node `node-role.kubernetes.io/control-plane=` and taints it `node-role.kubernetes.io/control-plane:NoSchedule`.
10. **bootstrap-token** — creates a bootstrap token (Secret `bootstrap-token-<id>` in kube-system), sets up RBAC so the `system:bootstrappers` group can submit CSRs, and publishes `cluster-info` ConfigMap in kube-public.
11. **kubelet-finalize** — flips kubelet to its own rotated client cert.
12. **addon** — installs **kube-proxy** (DaemonSet) and **CoreDNS** (Deployment). These are the only workloads kubeadm installs; CNI is *your* problem.

Key flags to know cold:

| Flag | What it does | Why it matters |
|---|---|---|
| `--pod-network-cidr` | Recorded in cluster config; controller-manager allocates per-node podCIDRs from it (`--allocate-node-cidrs`) | Must match the CNI's expectation (Flannel defaults to `10.244.0.0/16`). Wrong value = pods can't route |
| `--apiserver-advertise-address` | IP the apiserver advertises and etcd peers on | On multi-NIC VMs (Vagrant/multipass) the default route interface is often wrong — set explicitly |
| `--control-plane-endpoint` | Stable DNS/VIP written into certs and kubeconfigs | **Required up front for HA.** You cannot cleanly convert a single-CP cluster to HA later without it |
| `--upload-certs` | Runs the upload-certs phase | Enables control-plane joins without manual cert copying |

Any phase can be re-run standalone: `kubeadm init phase certs apiserver`, `kubeadm init phase addon coredns`, etc. This is how you regenerate a single broken artifact without re-initializing.

## Joining nodes

**Worker join.** The joining node needs three things: the API endpoint, a bootstrap token, and the CA public key hash (so the node can trust the cluster it's joining — mutual authentication):

```bash
# On a control plane node — generates a fresh token AND prints the full command:
kubeadm token create --print-join-command
# -> kubeadm join 172.18.0.2:6443 --token abcdef.0123456789abcdef \
#      --discovery-token-ca-cert-hash sha256:e2a4...

kubeadm token list                      # see existing tokens + TTL
kubeadm token create --ttl 2h           # custom TTL; default 24h; 0 = never expires (don't)
```

The hash can be recomputed by hand if a task demands it:

```bash
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
  | openssl rsa -pubin -outform der 2>/dev/null \
  | openssl dgst -sha256 -hex | sed 's/^.* //'
```

What `kubeadm join` does on the worker: discovery (validates the cluster CA against the hash), TLS bootstrap (authenticates to the apiserver *as the bootstrap token* — group `system:bootstrappers` — submits a CSR, which the controller-manager auto-approves and signs), writes `kubelet.conf`, starts kubelet. Tokens are stored as Secrets in kube-system, so token expiry = Secret TTL expiry; an expired token gives `couldn't validate the identity of the API Server` or unauthorized errors on join.

**Control-plane join** adds two requirements — the shared certs and etcd membership:

```bash
# On an existing control plane: re-upload certs (the kubeadm-certs Secret expires after 2h)
kubeadm init phase upload-certs --upload-certs
# -> prints a certificate key, e.g. 9aad...

# On the new control-plane node:
kubeadm join 172.18.0.100:6443 --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:e2a4aa0000000000000000000000000000000000000000000000000000000000 \
  --control-plane --certificate-key 9aad000000000000000000000000000000000000000000000000000000000000
```

The `--certificate-key` decrypts the `kubeadm-certs` Secret so the new node gets `ca.key`, `sa.key`, etcd CA, etc. The join then adds a new etcd member (stacked topology), writes control-plane static pods, and runs mark-control-plane. Without `--control-plane-endpoint` having been set at init, this join has no stable endpoint to target — hence the "decide HA at init time" rule.

---

## THE UPGRADE RUNBOOK — kubeadm on Debian/Ubuntu

This is the sequence to recite in the shower. Rules first, commands second.

**Rules:**
- **One minor version at a time.** 1.32 → 1.33 → 1.34. Never skip.
- **Control plane before workers.** All control-plane nodes, then workers one by one.
- **kubeadm first on every node.** The new kubeadm drives the upgrade of everything else.
- **pkgs.k8s.io repos are per-minor.** The apt repo you have configured only contains packages for ONE minor version. Upgrading a minor means editing the repo definition first. (The legacy `apt.kubernetes.io` repo is dead — and its `-00` package suffix went with it; current packages look like `1.33.2-1.1`.)
- Packages should be on `apt-mark hold`; unhold → install → re-hold.

### First control-plane node

```bash
# 0. See what's configured and what's running
kubectl get nodes                                  # kubelet versions per node
kubeadm version -o short

# 1. Point apt at the NEW minor's repo (pkgs.k8s.io is per-minor!)
sudo sed -i 's|v1.32|v1.33|' /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update

# 2. Upgrade kubeadm — kubeadm first, always
sudo apt-mark unhold kubeadm
sudo apt-get install -y kubeadm='1.33.2-1.1'
sudo apt-mark hold kubeadm
kubeadm version -o short                           # verify it took

# 3. Plan, then apply
sudo kubeadm upgrade plan                          # shows current/target versions, cert expiry, manual steps
sudo kubeadm upgrade apply v1.33.2                 # type 'y'; takes a few minutes

# 4. Drain the node (from a machine with kubectl access)
kubectl drain cp1 --ignore-daemonsets

# 5. Upgrade kubelet + kubectl
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet='1.33.2-1.1' kubectl='1.33.2-1.1'
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# 6. Uncordon
kubectl uncordon cp1
kubectl get nodes                                  # node now reports v1.33.2
```

### Additional control-plane nodes

Same, except step 3 is **`sudo kubeadm upgrade node`** — NOT `upgrade apply`, and no `upgrade plan` needed. `upgrade apply` bumps the cluster-wide config and addons exactly once; `upgrade node` reads that already-upgraded config and just rewrites the local static pod manifests.

### Each worker node (one at a time)

```bash
# From kubectl:
kubectl drain w1 --ignore-daemonsets

# On the worker (SSH):
sudo sed -i 's|v1.32|v1.33|' /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-mark unhold kubeadm
sudo apt-get install -y kubeadm='1.33.2-1.1'
sudo apt-mark hold kubeadm
sudo kubeadm upgrade node                          # upgrades local kubelet config only, fast
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet='1.33.2-1.1' kubectl='1.33.2-1.1'
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# From kubectl:
kubectl uncordon w1
```

### What `kubeadm upgrade apply` actually does

Preflight → pulls new control-plane images → **renews all certificates** (unless `--certificate-renewal=false`) → writes new static pod manifests one component at a time, waiting for each to come healthy, with automatic rollback from `/etc/kubernetes/tmp` backups on failure → upgrades CoreDNS and kube-proxy addons → updates the `kubeadm-config` and `kubelet-config` ConfigMaps. Note the implication: **a regularly upgraded cluster never hits cert expiry**, because every upgrade renews certs.

After `upgrade apply`, `kubectl get nodes` still shows the OLD version for that node — that column is the **kubelet** version, which you haven't touched yet. Don't panic; finish steps 4-6.

### Version-skew policy

The rules (verify the current policy at kubernetes.io/releases/version-skew-policy/ — the kubelet window widened in v1.28):

| Component | Allowed skew vs kube-apiserver |
|---|---|
| kubelet | Up to **3 minors older** (v1.28+; was 2), **never newer** |
| kube-controller-manager, kube-scheduler, cloud-controller-manager | Up to 1 minor older, never newer |
| kubectl | ±1 minor |
| kube-proxy | Up to 3 minors older, never newer |
| kube-apiserver (HA, during upgrade) | Instances may skew 1 minor from each other |

This is *why* the ordering is control plane first: upgrading a kubelet past its apiserver is the only sequence that violates skew. It's also why workers can lag several minors behind in an emergency — you can upgrade the control plane two cycles without touching workers, but never the reverse.

---

## Node maintenance: cordon, drain, uncordon

- `kubectl cordon NODE` — sets `spec.unschedulable=true`. Nothing is evicted; new pods just won't schedule there.
- `kubectl drain NODE` — cordon + **evict** every pod. Uses the Eviction API, which **respects PodDisruptionBudgets** — this is the mechanism, and the failure mode: a PDB with no headroom makes drain block forever, retrying evictions.
- `kubectl uncordon NODE` — clears the flag. Pods do NOT move back automatically; the scheduler only considers the node for *future* scheduling decisions.

Flags you will need:

| Flag | When |
|---|---|
| `--ignore-daemonsets` | Always on real clusters. DaemonSet pods can't be drained meaningfully (the DS controller ignores `unschedulable` and would recreate them); drain refuses to proceed without this flag if DS pods exist |
| `--delete-emptydir-data` | Required if any pod uses `emptyDir` (data is lost on eviction, so drain wants explicit consent) |
| `--force` | Required for "naked" pods (no controller owner). **These pods are deleted and never come back** |
| `--disable-eviction` | Bypasses PDBs by using direct delete instead of eviction. Last resort; on the exam only if the task explicitly says so |
| `--grace-period`, `--timeout` | Tuning; `--timeout=60s` stops drain from hanging silently |

Static (mirror) pods are skipped by drain automatically — they aren't API-managed, so eviction is meaningless for them; only removing the manifest file stops them.

---

## etcd — role, quorum, static pod

etcd is the only stateful component of the control plane: a strongly consistent, Raft-replicated key-value store. **Every API object lives in etcd and nowhere else.** The apiserver is the only client; controllers and kubelets see state exclusively through the apiserver's watch cache.

**Quorum.** Raft requires a majority — `floor(n/2)+1` — to commit writes and elect a leader:

| Members | Quorum | Tolerated failures |
|---|---|---|
| 1 | 1 | 0 |
| 2 | 2 | **0** (worse than 1: same tolerance, double failure probability) |
| 3 | 2 | 1 |
| 5 | 3 | 2 |

Even member counts add nothing — always run odd. Losing quorum makes etcd read-only-at-best: apiserver requests fail, controllers stall, but **already-running workloads keep running** (kubelets keep containers alive without the control plane; they just can't reconcile changes).

**The static pod.** On kubeadm clusters, etcd runs from `/etc/kubernetes/manifests/etcd.yaml`. Every flag you need for `etcdctl` is in that file — never memorize cert paths, grep for them:

```bash
grep -E 'data-dir|cert-file|key-file|trusted-ca|listen-client' /etc/kubernetes/manifests/etcd.yaml
```

Flags to be able to read:

| Flag | Meaning |
|---|---|
| `--data-dir=/var/lib/etcd` | The bbolt DB + WAL. Mapped in via hostPath — **this is what you repoint on restore** |
| `--listen-client-urls=https://127.0.0.1:2379,https://NODE_IP:2379` | Where clients (apiserver, etcdctl) connect |
| `--advertise-client-urls` | What it tells peers/clients to use |
| `--cert-file` / `--key-file` | Server cert presented to clients |
| `--trusted-ca-file` + `--client-cert-auth=true` | Client certs are required and verified against the etcd CA — hence etcdctl's three cert flags |
| `--peer-*` variants | Same TLS story for member-to-member traffic (port 2380) |
| `--initial-cluster` | name=peerURL map; matters when restoring multi-member clusters |
| `--snapshot-count` | Internal Raft snapshotting — unrelated to your backups |

## etcd BACKUP

Memorize this block; it is the exam pattern verbatim. Run on (or against) the etcd node:

```bash
ETCDCTL_API=3 etcdctl snapshot save /srv/backup/etcd.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

Notes that save you points:
- `ETCDCTL_API=3` is the default in etcdctl ≥3.4, so it's redundant on modern clusters — but harmless. Type it; it costs one second and defends against an old binary.
- `--endpoints=https://127.0.0.1:2379` — the **local** member. A snapshot is taken from one member; don't point at a load balancer.
- Which cert pair? Any client cert the etcd CA trusts. `server.crt/server.key` works (kubeadm issues it with client auth usage); `healthcheck-client.crt` also works; `/etc/kubernetes/pki/apiserver-etcd-client.crt` works from the apiserver's cert set. Missing/wrong certs give the classic `context deadline exceeded`.
- **Verify** with etcdutl (the offline tool; `etcdctl snapshot status` is deprecated):

```bash
etcdutl snapshot status /srv/backup/etcd.db -w table
# +----------+----------+------------+------------+
# |   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
```

A snapshot with a plausible revision count (a kubeadm cluster has thousands of keys) is your proof of success — check it, then move on.

## etcd RESTORE

Restore is offline: it unpacks the snapshot into a **fresh data directory**, then you point etcd at it.

```bash
# 1. Restore into a NEW directory (must not exist / must be empty)
etcdutl snapshot restore /srv/backup/etcd.db --data-dir=/var/lib/etcd-restore
# Legacy form, still accepted on many exam images:
# ETCDCTL_API=3 etcdctl snapshot restore /srv/backup/etcd.db --data-dir=/var/lib/etcd-restore
```

```bash
# 2. Repoint the static pod's hostPath at the new dir
vi /etc/kubernetes/manifests/etcd.yaml
```

Change the data volume (only the hostPath — the container's `--data-dir` and mountPath stay `/var/lib/etcd`):

```yaml
volumes:
- hostPath:
    path: /var/lib/etcd-restore    # was /var/lib/etcd
    type: DirectoryOrCreate
  name: etcd-data
```

```bash
# 3. Kubelet notices the manifest change and recreates the pod. Watch it:
watch crictl ps
# etcd container restarts; kube-apiserver follows once etcd answers
kubectl get pods -A     # may error for ~30-60s, then reflects the snapshot-time state
```

Why a new directory: `snapshot restore` refuses a non-empty target, and you want the old data dir intact as a rollback path. The restore also rewrites member metadata (new member/cluster IDs) — fine for the single-member case the exam gives you; multi-member restores require per-member `--initial-cluster`/`--name` flags (awareness only).

**Post-restore hygiene:** kube-scheduler and kube-controller-manager hold watch caches from the pre-restore world. If the cluster behaves oddly after restore, bounce them: `mv` their manifests out of `/etc/kubernetes/manifests`, wait for the containers to stop, `mv` back.

### Why you back up etcd — and what is NOT in it

In etcd: every API object. Deployments, Services, ConfigMaps, **Secrets** (base64, or encrypted only if EncryptionConfiguration is set up), RBAC, CRDs and CRs, Helm release records (they're Secrets), Events, Leases.

NOT in etcd — an etcd snapshot is *not* a cluster backup:

| Missing from the snapshot | Lives where |
|---|---|
| PKI certificates and keys | `/etc/kubernetes/pki` on control-plane nodes |
| Static pod manifests | `/etc/kubernetes/manifests` per node |
| kubeconfigs (`admin.conf`, etc.) | `/etc/kubernetes` |
| kubelet config, systemd units | Node filesystem |
| CNI config | `/etc/cni/net.d` per node |
| Container images and runtime state | Node containerd store |
| **Application data on PersistentVolumes** | The storage backend — etcd holds only the PV *objects* |

Corollary: restoring etcd resurrects the *desired state* as of snapshot time; kubelets and controllers then reconcile the real world to match — pods created after the snapshot get orphaned and killed, pods deleted after it come back.

The poor man's supplementary backup — worth knowing because the exam has asked for it: `kubectl get all,cm,secret -n NS -o yaml > backup.yaml`.

---

## Certificate management

```bash
kubeadm certs check-expiration
# CERTIFICATE                EXPIRES        RESIDUAL TIME   CA            EXTERNALLY MANAGED
# admin.conf                 ...            364d            ca            no
# apiserver                  ...            364d            ca            no
# etcd-server                ...            364d            etcd-ca       no
# ...
# CA                         EXPIRES        RESIDUAL TIME
# ca                         ...            9y
```

Leaf certs get 1 year, CAs get 10. Renewal:

```bash
kubeadm certs renew all            # or a single one: kubeadm certs renew apiserver
```

Two things people forget:
1. **Renewal does not reload anything.** The control-plane components serve the old cert from memory until restarted. Restart the static pods: `mv /etc/kubernetes/manifests/*.yaml /tmp/ && sleep 20 && mv /tmp/*.yaml /etc/kubernetes/manifests/` (or per-file, safer).
2. `renew all` renews the kubeconfig-embedded certs too (`admin.conf`, `controller-manager.conf`, `scheduler.conf`) but **not the CAs**, and not any cert marked externally managed.

And the earlier point bears repeating: `kubeadm upgrade apply` renews all certs as a side effect, which is why well-maintained clusters never see expiry.

Manual inspection when kubeadm isn't an option:

```bash
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -enddate -subject
```

## HA topologies — stacked vs external etcd

**Stacked** (kubeadm default): each control-plane node runs its own etcd member as a static pod; apiserver talks to its local member. 3 control-plane nodes = 3 etcd members.
- Pro: fewer machines, simpler, what `kubeadm join --control-plane` gives you.
- Con: coupled failure domains — losing a control-plane node loses an etcd member *and* an apiserver simultaneously. Minimum 3 nodes for any real fault tolerance.

**External etcd**: a separate 3+ node etcd cluster; every apiserver is configured (ClusterConfiguration `etcd.external.endpoints`) to talk to it.
- Pro: decoupled failure domains; control-plane nodes become nearly stateless.
- Con: double the machines (minimum 3 + 3), you manage etcd's lifecycle yourself.

Both require `--control-plane-endpoint` (a load balancer VIP or DNS name in front of the apiservers) at init time. For the exam this is awareness-level: know the two diagrams, the quorum math, and that stacked is what kubeadm builds by default.

---

## Practicing on kind — what works, what doesn't

Your lab is the 3-node kind cluster `cka` (`cka-control-plane`, `cka-worker`, `cka-worker2`). kind nodes are containers, but they run real kubeadm-bootstrapped kubelets, real static pods, and real etcd. Node access is `docker exec -it cka-control-plane bash` instead of SSH.

**Works on kind (drill these here):**
- etcd snapshot save/restore — fully. etcdctl and etcdutl live inside the etcd pod's image, and `/var/lib/etcd` plus `/etc/kubernetes/pki/etcd` are hostPath-mounted, so you can exec into the pod for the snapshot and into the node for the manifest edit. The exercises walk the exact sequence.
- drain/cordon/uncordon, PDB-blocked drains.
- Static pod manipulation on any node.
- `kubeadm token create --print-join-command`, `kubeadm certs check-expiration` — kind control-plane nodes have the kubeadm binary.

**Does NOT work on kind:** `kubeadm upgrade`. Node images have Kubernetes baked in as fixed binaries — there's no apt-managed kubelet to upgrade, no per-minor repo dance. Do not waste time trying. Instead:

1. **killercoda.com** → Killer Shell CKA scenarios → "Cluster Upgrade" (also the plain Ubuntu playground for building from scratch). Free, disposable, real kubeadm on Ubuntu. Run the upgrade scenario until the runbook is reflexive.
2. **Two-VM multipass cluster** — the closest thing to the real exam environment you can run locally:

```bash
# Host (macOS): 2 Ubuntu VMs
brew install --cask multipass
multipass launch --name cp --cpus 2 --memory 2G --disk 12G 24.04
multipass launch --name w1 --cpus 2 --memory 2G --disk 12G 24.04
```

On **both** VMs (`multipass shell cp` / `w1`) — install runtime + Kubernetes packages pinned one minor behind current, so you have something to upgrade:

```bash
# runtime + prereqs
sudo apt-get update && sudo apt-get install -y containerd apt-transport-https ca-certificates curl gpg
echo 'br_netfilter' | sudo tee /etc/modules-load.d/k8s.conf && sudo modprobe br_netfilter
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/k8s.conf && sudo sysctl --system
sudo mkdir -p /etc/containerd
containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' | sudo tee /etc/containerd/config.toml >/dev/null
sudo systemctl restart containerd

# Kubernetes packages from pkgs.k8s.io, OLD minor (adjust versions to current-1)
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

Then on `cp`: `sudo kubeadm init --pod-network-cidr=10.244.0.0/16`, install Flannel, join `w1` with the printed command — and run the full upgrade runbook to the next minor, for real. One evening of this is worth ten readings of the docs.

---

## Traps

Each one: the wrong assumption, then the correction.

1. **"apt has the new version, the repo is fine."** pkgs.k8s.io repos are *per minor*. Your `kubernetes.list` pinned at `v1.32` will never offer 1.33 packages — `apt-get install kubeadm='1.33.2-1.1'` fails with "version not found". Edit the repo file first, then `apt-get update`.
2. **"Package versions end in `-00`."** That was the dead legacy repo. Current format is like `1.33.2-1.1`. Don't guess — `apt-cache madison kubeadm` lists what's actually available.
3. **"Run `kubeadm upgrade apply` on every control-plane node."** Only the first. The rest (and all workers) run `kubeadm upgrade node`. Running `apply` twice mostly works but wastes minutes re-upgrading addons; running `node` on the first CP silently skips the cluster-wide upgrade.
4. **"Upgrade kubelet first, it's the visible version."** kubelet must never be newer than the apiserver. kubeadm-then-control-plane-then-kubelet, and control-plane nodes before workers. Reversing the order violates skew and can wedge the node.
5. **"`kubectl get nodes` still shows the old version — the upgrade failed."** That column is the kubelet version. After `kubeadm upgrade apply` it *should* still show old until you upgrade kubelet and restart it.
6. **"I can jump 1.31 → 1.33."** One minor at a time. `kubeadm upgrade plan` will refuse anyway; don't burn time trying.
7. **"etcdctl works without cert flags, it's localhost."** kubeadm etcd requires client certs (`--client-cert-auth=true`). No/wrong certs = `context deadline exceeded` (not a clean auth error, which is what makes it confusing). Grep the manifest for the paths; don't type them from memory.
8. **"Restore into the existing /var/lib/etcd."** `snapshot restore` refuses a non-empty dir. Restore into a new dir and repoint the manifest's hostPath — this also preserves the old dir as rollback.
9. **"After editing the manifest I should change `--data-dir` too."** Change only the hostPath `path:`. The container still mounts it at `/var/lib/etcd`, so `--data-dir` and the mountPath stay untouched. Changing all three inconsistently is the classic self-inflicted outage.
10. **"I'll `kubectl edit` the etcd pod."** Static pods can't be edited through the API — the mirror pod is read-only and any change bounces. The file in `/etc/kubernetes/manifests` is the only source of truth.
11. **"Drain is stuck, add `--force`."** `--force` handles *unmanaged* pods (and deletes them irrecoverably). A PDB-blocked drain is a different failure: read the error, then either scale the app up, adjust the PDB, or — only if the task says so — `--disable-eviction`.
12. **"Drain done, maintenance done."** Forgetting `kubectl uncordon` leaves the node `SchedulingDisabled` and silently costs the points. Make drain/uncordon a paired reflex.
13. **"The join token from yesterday's notes still works."** Default TTL 24h. Regenerate with `kubeadm token create --print-join-command` — never reuse.
14. **"`kubeadm certs renew all` fixed the expired certs."** Not until the control-plane pods restart — they hold the old certs in memory. Move the manifests out and back, then verify with `check-expiration`.
15. **"An etcd snapshot backs up the cluster."** It backs up API objects only. PKI, static manifests, kubeconfigs, CNI config, and PV *data* are all outside etcd. Conversely, restoring resurrects deleted objects and kills post-snapshot ones — controllers reconcile hard.
16. **"2 control-plane nodes are more resilient than 1."** For etcd, 2 members tolerate zero failures with doubled failure probability. HA starts at 3.

## Speed patterns

| Task | Fastest exam-legal path |
|---|---|
| etcd flags recon | `grep -E 'data-dir\|cert\|trusted\|listen-client' /etc/kubernetes/manifests/etcd.yaml` |
| etcd snapshot | Recite the memorized 5-line block; only the save path and cert paths ever change. Verify: `etcdutl snapshot status FILE -w table` |
| etcd restore | `etcdutl snapshot restore FILE --data-dir=NEW` → `vi` manifest → change ONE line (hostPath `path:`) → `watch crictl ps` |
| Upgrade commands | Don't type from memory — open kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/, copy each block, substitute the version. It's the single highest-value docs page of the exam |
| Drain | `k drain NODE --ignore-daemonsets --delete-emptydir-data` — add `--force` only when it complains about unmanaged pods |
| Join command | `kubeadm token create --print-join-command` — one command, never assemble by hand |
| Cert expiry | `kubeadm certs check-expiration` — the openssl route is backup only |
| Restart a control-plane component | `mv /etc/kubernetes/manifests/X.yaml /tmp/` → wait for `crictl ps` to drop it → `mv` back |
| Confirm which node you must be on | `k get pods -n kube-system -o wide \| grep etcd` — etcd tasks run on the node hosting the member |
| Node shell on the exam | `ssh NODE` then immediately `sudo -i`; on kind: `docker exec -it NODE bash` |

## Docs map

| You need | kubernetes.io path |
|---|---|
| Upgrade runbook (copy-paste source) | `/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/` |
| etcd backup + restore commands | `/docs/tasks/administer-cluster/configure-upgrade-etcd/` |
| Drain semantics, PDB interaction | `/docs/tasks/administer-cluster/safely-drain-node/` |
| kubeadm init phases + flags | `/docs/reference/setup-tools/kubeadm/kubeadm-init/` |
| kubeadm join / discovery mechanics | `/docs/reference/setup-tools/kubeadm/kubeadm-join/` |
| kubeadm token commands | `/docs/reference/setup-tools/kubeadm/kubeadm-token/` |
| Certificate management with kubeadm | `/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/` |
| Version skew policy | `/releases/version-skew-policy/` |
| HA topology diagrams (stacked/external) | `/docs/setup/production-environment/tools/kubeadm/ha-topology/` |
| Creating HA clusters with kubeadm | `/docs/setup/production-environment/tools/kubeadm/high-availability/` |
| Static pods | `/docs/tasks/configure-pod-container/static-pod/` |
| PodDisruptionBudgets | `/docs/tasks/run-application/configure-pdb/` |

## Checkpoint

Self-test under time. All on the kind lab unless noted.

- Can you take and verify an etcd snapshot in **2 minutes** (from a cold prompt, including finding the cert paths)?
- Can you complete a full etcd restore — snapshot to repointed manifest to healthy cluster — in **5 minutes**?
- Can you write the complete control-plane upgrade command sequence (repo edit through uncordon) on paper, correctly ordered, in **3 minutes**?
- Can you state the `kubeadm upgrade apply` vs `upgrade node` split without hesitation?
- Can you drain a node hosting DaemonSet pods and an emptyDir pod, first try with the right flags, in **1 minute**?
- Can you diagnose and unblock a PDB-stuck drain in **4 minutes**?
- Can you produce a valid worker join command in **30 seconds**?
- Can you list three things an etcd snapshot does NOT contain, instantly?
- Can you check cert expiry and name the renewal command plus the post-renewal step in **1 minute**?
- Can you recite the quorum sizes for 1/2/3/5-member etcd and say why 2 is worse than it looks?
