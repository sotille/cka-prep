#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# BREAK 02 — SYMPTOM
#
#   Within a minute or two, node cka-worker goes NotReady. Unlike break-01,
#   the kubelet service on the node is up and running — yet the node still
#   refuses to become Ready, and new pods assigned to it never start.
#
#   Your job: read what the node itself says is wrong and repair it.
#
#   Verify when done:  kubectl get nodes   (all Ready)
#   Full walkthrough:  SOLUTIONS.md  (spoilers)
#
#   Do not read past this line if you want the drill.
# ============================================================================

CTX=kind-cka

kubectl --context "$CTX" get nodes >/dev/null
docker inspect cka-worker >/dev/null

docker exec cka-worker bash -c 'mkdir -p /root/.bf02-cni-backup && mv /etc/cni/net.d/* /root/.bf02-cni-backup/'
docker exec cka-worker systemctl restart containerd

echo "[break-02] armed. Wait ~90s, then run: kubectl get nodes && kubectl describe node cka-worker | grep -A8 Conditions"
