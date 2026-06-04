#!/usr/bin/env bash
# Daily 15-minute kubectl drill template
# Goal: build keyboard reflexes. Run this every day, even on rest days.
#
# Usage:
#   ./drills/daily-template.sh
#
# Variations: change image/name/replicas to keep your brain engaged

set -e

NS="drill-$(date +%H%M%S)"
echo "▶ Creating namespace: $NS"
kubectl create ns "$NS"

echo "▶ Drill 1: create deployment from CLI"
kubectl -n "$NS" create deploy web --image=nginx --replicas=3

echo "▶ Drill 2: scale + rollout new image + verify"
kubectl -n "$NS" scale deploy web --replicas=5
kubectl -n "$NS" set image deploy/web nginx=nginx:1.25
kubectl -n "$NS" rollout status deploy/web --timeout=30s

echo "▶ Drill 3: expose as service"
kubectl -n "$NS" expose deploy web --port=80 --type=ClusterIP

echo "▶ Drill 4: dry-run pod yaml with env var"
kubectl -n "$NS" run debug --image=busybox --env="FOO=bar" --dry-run=client -o yaml -- sleep 3600

echo "▶ Drill 5: rollback"
kubectl -n "$NS" rollout undo deploy/web

echo "▶ Final state:"
kubectl -n "$NS" get all

echo
echo "✅ Drill complete. Cleaning up..."
kubectl delete ns "$NS"

echo
echo "⏱  Goal: complete all 5 drills in under 5 minutes (with no doc lookup)."
