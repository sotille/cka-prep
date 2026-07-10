#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# BREAK 04 — SYMPTOM
#
#   Cluster DNS is completely dead. From any pod:
#     nslookup kubernetes.default        -> fails / times out
#   Deployments that talk to Services by name are all erroring.
#
#   Your job: restore working cluster DNS. There may be more than one
#   thing wrong — keep digging until nslookup succeeds.
#
#   Verify when done:
#     kubectl run dnstest --rm -it --image=busybox:1.36 --restart=Never -- \
#       nslookup kubernetes.default.svc.cluster.local
#   Full walkthrough:  SOLUTIONS.md  (spoilers)
#
#   Do not read past this line if you want the drill.
# ============================================================================

CTX=kind-cka
BACKUP_DIR=/tmp/cka-breakfix
mkdir -p "$BACKUP_DIR"

kubectl --context "$CTX" get nodes >/dev/null

kubectl --context "$CTX" -n kube-system get configmap coredns -o yaml > "$BACKUP_DIR/coredns-cm.bak.yaml"

kubectl --context "$CTX" -n kube-system get configmap coredns -o yaml \
  | sed 's/forward \. \/etc\/resolv\.conf/forwrad . \/etc\/resolv.conf/' \
  | kubectl --context "$CTX" apply -f -

kubectl --context "$CTX" -n kube-system scale deployment coredns --replicas=0

echo "[break-04] armed. Backup of the original state: $BACKUP_DIR/coredns-cm.bak.yaml (do not peek unless stuck)"
