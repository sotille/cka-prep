#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# BREAK 07 — SYMPTOM
#
#   Strange one: Services that already existed keep working, but every
#   Service created from now on is unreachable — endpoints look fine,
#   yet connections to the ClusterIP time out. Something cluster-wide
#   that programs Service traffic is no longer running where it should.
#
#   Your job: find the missing cluster component and restore it.
#
#   Verify when done:
#     kubectl -n default run bf07-web --image=nginx:1.27 && \
#     kubectl -n default expose pod bf07-web --port=80 --name=bf07-svc && \
#     kubectl run tmp --rm -it --image=busybox:1.36 --restart=Never -- \
#       wget -qO- --timeout=2 http://bf07-svc.default
#   Full walkthrough:  SOLUTIONS.md  (spoilers)
#
#   Do not read past this line if you want the drill.
# ============================================================================

CTX=kind-cka

kubectl --context "$CTX" get nodes >/dev/null

kubectl --context "$CTX" -n kube-system patch daemonset kube-proxy --type=merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/os":"linux-v2"}}}}}'

echo "[break-07] armed. Give it ~30s, then try the verify sequence in the header."
