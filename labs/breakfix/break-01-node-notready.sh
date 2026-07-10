#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# BREAK 01 — SYMPTOM
#
#   About a minute after running this script, `kubectl get nodes` shows
#   node cka-worker2 as NotReady. Workloads on it stop being managed.
#
#   Your job: diagnose from the node itself and bring it back to Ready.
#   The fix must survive a node reboot.
#
#   Verify when done:  kubectl get nodes   (all Ready)
#   Full walkthrough:  SOLUTIONS.md  (spoilers)
#
#   Do not read past this line if you want the drill.
# ============================================================================

CTX=kind-cka

kubectl --context "$CTX" get nodes >/dev/null
docker inspect cka-worker2 >/dev/null

docker exec cka-worker2 systemctl stop kubelet
docker exec cka-worker2 systemctl disable kubelet >/dev/null 2>&1

echo "[break-01] armed. Wait ~60s, then run: kubectl get nodes"
