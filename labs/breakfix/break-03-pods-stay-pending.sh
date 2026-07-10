#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# BREAK 03 — SYMPTOM
#
#   Every newly created pod hangs in Pending forever. `kubectl describe`
#   on such a pod shows NO events at all. A canary pod named bf03-canary
#   has been created in namespace default so you can see it immediately.
#
#   Your job: find the broken cluster component, identify the exact
#   misconfiguration, and fix it so bf03-canary runs.
#
#   Verify when done:  kubectl get pod bf03-canary -o wide   (Running, on a node)
#   Full walkthrough:  SOLUTIONS.md  (spoilers)
#
#   Do not read past this line if you want the drill.
# ============================================================================

CTX=kind-cka

kubectl --context "$CTX" get nodes >/dev/null
docker inspect cka-control-plane >/dev/null

docker exec cka-control-plane grep -q -- '--leader-elect=true' /etc/kubernetes/manifests/kube-scheduler.yaml
docker exec cka-control-plane cp /etc/kubernetes/manifests/kube-scheduler.yaml /root/kube-scheduler.yaml.bf03.bak
docker exec cka-control-plane sed -i 's/--leader-elect=true/--leader-elect-and-hope=true/' /etc/kubernetes/manifests/kube-scheduler.yaml

sleep 20
kubectl --context "$CTX" run bf03-canary --image=nginx:1.27 --restart=Never

echo "[break-03] armed. Run: kubectl get pod bf03-canary ; kubectl describe pod bf03-canary | tail -5"
