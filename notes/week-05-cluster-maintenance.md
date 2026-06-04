# Week 5 (Jul 6–12) — Cluster Maintenance ⭐ HIGH VALUE

**Goal:** Master etcd backup/restore + cluster upgrade. **THIS WEEK PAYS THE EXAM.**

**Time budget:** 20h (heavy week)

---

## Critical Topics (etcd + upgrade are top-scoring exam tasks)

- [ ] OS upgrades + node draining (`kubectl drain`, `cordon`, `uncordon`)
- [ ] Cluster upgrade with kubeadm (control plane + worker nodes)
- [ ] **etcd backup with etcdctl snapshot save**
- [ ] **etcd restore with etcdctl snapshot restore**
- [ ] Backup/restore other resources (yaml from kubectl get)
- [ ] Cluster version skew rules

## etcd — Memorize This Pattern

```bash
# Backup
ETCDCTL_API=3 etcdctl snapshot save /backup/etcd.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Restore (writes to a new data dir)
ETCDCTL_API=3 etcdctl snapshot restore /backup/etcd.db \
  --data-dir=/var/lib/etcd-restored

# Then: update /etc/kubernetes/manifests/etcd.yaml to point hostPath at the new data-dir
# Static pod will restart with restored data.
```

## kubeadm Upgrade Pattern

```bash
# On control plane node:
apt-get update && apt-get install -y kubeadm=1.30.0-00
kubeadm upgrade plan
kubeadm upgrade apply v1.30.0
apt-get install -y kubelet=1.30.0-00 kubectl=1.30.0-00
systemctl daemon-reload && systemctl restart kubelet

# On each worker:
kubectl drain <node> --ignore-daemonsets
# (SSH to worker)
apt-get install -y kubeadm=1.30.0-00
kubeadm upgrade node
apt-get install -y kubelet=1.30.0-00
systemctl daemon-reload && systemctl restart kubelet
# (Back to control plane)
kubectl uncordon <node>
```

## Hands-On Labs (do EACH lab 3 times this week)

- [ ] Drain a worker, run upgrade on it
- [ ] etcd snapshot → break cluster → restore from snapshot
- [ ] Backup all resources in namespace via `kubectl get -o yaml > backup.yaml`

## Week 5 Checkpoint

- [ ] Perform etcd backup in < 2 min
- [ ] Perform etcd restore in < 5 min
- [ ] Recite the upgrade sequence from memory

## Insights

<!-- Add as you go — especially "gotchas" in etcd restore -->
