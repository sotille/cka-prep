#!/usr/bin/env bash
# calico-netpol-cluster.sh — spin up a SECOND kind cluster that actually ENFORCES
# NetworkPolicy, so you can test that your policies really block traffic (kindnet,
# used by the main 'cka' cluster, does not enforce NetworkPolicy).
#
# Creates cluster 'cka-netpol' (context kind-cka-netpol) with the default CNI disabled
# and Calico installed. Your main 'cka' cluster is untouched.
#
# Usage:
#   labs/setup/calico-netpol-cluster.sh          # create + install Calico
#   labs/setup/calico-netpol-cluster.sh delete   # tear it down
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

require_docker
need kind
need kubectl

NP_CLUSTER="cka-netpol"
NP_CTX="kind-cka-netpol"
CALICO_VER="v3.28.2"
CALICO_MANIFEST="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VER}/manifests/calico.yaml"

if [ "${1:-}" = "delete" ]; then
  log "Deleting cluster '$NP_CLUSTER'"
  kind delete cluster --name "$NP_CLUSTER"
  ok "deleted"
  exit 0
fi

if kind get clusters 2>/dev/null | grep -qx "$NP_CLUSTER"; then
  ok "cluster '$NP_CLUSTER' already exists"
else
  log "Creating kind cluster '$NP_CLUSTER' with default CNI disabled"
  # Calico's default pod CIDR is 192.168.0.0/16; align kind to it.
  kind create cluster --name "$NP_CLUSTER" --wait 60s --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cka-netpol
nodes:
  - role: control-plane
  - role: worker
networking:
  disableDefaultCNI: true
  podSubnet: "192.168.0.0/16"
EOF
  ok "cluster created (nodes will be NotReady until Calico is installed — expected)"
fi

kubectl config use-context "$NP_CTX" >/dev/null
log "Installing Calico $CALICO_VER"
kubectl apply -f "$CALICO_MANIFEST" >/dev/null || die "could not fetch Calico manifest (offline?)"

log "Waiting for Calico + nodes to become Ready (up to 3 min)"
kubectl -n kube-system rollout status ds/calico-node --timeout=180s >/dev/null 2>&1 || warn "calico-node still rolling out"
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null 2>&1 || warn "nodes still settling"

kubectl get nodes
echo
ok "NetworkPolicy-enforcing cluster ready. Switch to it with:"
echo "     kubectl config use-context $NP_CTX"
warn "switch back to your main cluster with: kubectl config use-context $CKA_CTX"
echo
log "Smoke test idea: deny-all + a single allow, then curl from an allowed vs denied pod — the denied one should now actually time out."
