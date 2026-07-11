#!/usr/bin/env bash
# reset-cluster.sh — fast reset between labs. Deletes all lab-created namespaces and
# cluster-scoped practice objects, and repairs the common node-level faults the
# break-fix labs and mocks inject (stopped kubelet, moved CNI config). Leaves the
# cluster itself and all kube-system components intact.
#
# Use this to get back to a clean slate WITHOUT recreating the cluster (~5s vs ~2min).
# For a nuke-and-repave, delete the cluster: kind delete cluster --name cka
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

require_cluster
kubectl config use-context "$CKA_CTX" >/dev/null
assert_kind_context

PROTECTED='default|kube-system|kube-public|kube-node-lease|local-path-storage'

log "Deleting lab namespaces (everything except system namespaces)"
mapfile -t NSS < <(kubectl get ns -o name | sed 's|namespace/||' | grep -Ev "^($PROTECTED)$" || true)
if [ "${#NSS[@]}" -gt 0 ]; then
  kubectl delete ns "${NSS[@]}" --wait=false >/dev/null 2>&1 || true
  ok "requested deletion of: ${NSS[*]}"
else
  ok "no lab namespaces present"
fi

log "Cleaning practice objects in default namespace"
kubectl -n default delete pods,svc,deploy,rs,cm,secret -l '!kubernetes.io/managed-by' --field-selector 'metadata.name!=kubernetes' >/dev/null 2>&1 || true
kubectl -n default delete pod --all --grace-period=0 --force >/dev/null 2>&1 || true

log "Cleaning cluster-scoped practice objects (PVs, custom SCs, netpol-related CRDs left in place)"
kubectl delete pv --all --wait=false >/dev/null 2>&1 || true
# Custom StorageClasses (keep the default 'standard' that ships with kind)
for sc in $(kubectl get sc -o name 2>/dev/null | sed 's|storageclass.storage.k8s.io/||'); do
  [ "$sc" = "standard" ] && continue
  kubectl delete sc "$sc" >/dev/null 2>&1 || true
done
# Restore 'standard' as the (only) default in case a mock switched it
kubectl patch sc standard -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' >/dev/null 2>&1 || true

log "Repairing node-level faults (kubelet / CNI) injected by break-fix labs & mocks"
for node in cka-control-plane cka-worker cka-worker2; do
  docker inspect "$node" >/dev/null 2>&1 || continue
  docker exec "$node" systemctl enable --now kubelet >/dev/null 2>&1 || true
  # restore CNI config if a lab moved it aside
  docker exec "$node" sh -c '[ -f /etc/cni/net.d/10-kindnet.conflist.disabled ] && mv /etc/cni/net.d/10-kindnet.conflist.disabled /etc/cni/net.d/10-kindnet.conflist' >/dev/null 2>&1 || true
done

log "Waiting for nodes to settle"
kubectl wait --for=condition=Ready nodes --all --timeout=120s >/dev/null 2>&1 || warn "some nodes still settling"

ok "reset complete"
kubectl get nodes
