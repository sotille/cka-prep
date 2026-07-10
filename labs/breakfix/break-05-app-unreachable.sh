#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# BREAK 05 — SYMPTOM
#
#   The app team deployed "web" (Deployment + Service) in namespace bf05.
#   It has never worked: from inside the cluster,
#     wget -qO- http://web.bf05   -> times out
#
#   Your job: make the Service return the app's page from an in-cluster
#   test pod. The final image must be nginx:1.27. There may be more than
#   one thing wrong.
#
#   Verify when done:
#     kubectl run tmp --rm -it --image=busybox:1.36 --restart=Never -- \
#       wget -qO- --timeout=2 http://web.bf05
#   Full walkthrough:  SOLUTIONS.md  (spoilers)
#
#   Do not read past this line if you want the drill.
# ============================================================================

CTX=kind-cka

kubectl --context "$CTX" get nodes >/dev/null

kubectl --context "$CTX" create namespace bf05
kubectl --context "$CTX" -n bf05 create deployment web --image=nginx:1.99.99-broken --replicas=2
kubectl --context "$CTX" -n bf05 create service clusterip web --tcp=80:80
kubectl --context "$CTX" -n bf05 patch service web -p '{"spec":{"selector":{"app":"web-frontend"}}}'

echo "[break-05] armed. Start with: kubectl -n bf05 get all"
