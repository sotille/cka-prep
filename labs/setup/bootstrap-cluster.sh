#!/usr/bin/env bash
# bootstrap-cluster.sh — create the 3-node kind cluster 'cka' if it does not exist.
# Idempotent: re-running when the cluster is already up just verifies health.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

require_docker
need kind

if kind get clusters 2>/dev/null | grep -qx "$CKA_CLUSTER"; then
  ok "kind cluster '$CKA_CLUSTER' already exists"
else
  log "Creating kind cluster '$CKA_CLUSTER' from kind-config.yaml"
  kind create cluster --name "$CKA_CLUSTER" --config "$REPO/kind-config.yaml" --wait 120s
  ok "cluster created"
fi

kubectl config use-context "$CKA_CTX" >/dev/null
log "Nodes:"
kubectl get nodes -o wide

not_ready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{print $1}')"
if [ -n "$not_ready" ]; then
  warn "these nodes are not Ready yet: $not_ready (give them a minute)"
else
  ok "all nodes Ready — context is '$CKA_CTX'"
fi
echo
log "Next: labs/setup/install-addons.sh  (metrics-server, ingress-nginx, Gateway API CRDs)"
