#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# BREAK 06 — SYMPTOM
#
#   A stateful pod "db" in namespace bf06 is stuck Pending, and its
#   PersistentVolumeClaim "data" never binds. The team says "we didn't
#   set anything special, storage always just worked on this cluster."
#
#   Your job: get the PVC Bound and the pod Running, using the cluster's
#   dynamic provisioner (do not hand-craft a PV).
#
#   Verify when done:  kubectl -n bf06 get pvc,pod   (Bound / Running)
#   Full walkthrough:  SOLUTIONS.md  (spoilers)
#
#   Do not read past this line if you want the drill.
# ============================================================================

CTX=kind-cka
BACKUP_DIR=/tmp/cka-breakfix
mkdir -p "$BACKUP_DIR"

kubectl --context "$CTX" get nodes >/dev/null

kubectl --context "$CTX" get storageclass standard -o yaml > "$BACKUP_DIR/standard-sc.bak.yaml"
kubectl --context "$CTX" delete storageclass standard

kubectl --context "$CTX" create namespace bf06
cat <<'EOF' | kubectl --context "$CTX" -n bf06 apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: db
spec:
  containers:
  - name: db
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: data
EOF

echo "[break-06] armed. Backup: $BACKUP_DIR/standard-sc.bak.yaml (do not peek unless stuck)"
