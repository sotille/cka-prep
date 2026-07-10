#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# BREAK 08 — SYMPTOM
#
#   A teammate handed you their kubeconfig:
#     /tmp/cka-breakfix/ops-user.kubeconfig
#   Nothing works with it:
#     kubectl --kubeconfig /tmp/cka-breakfix/ops-user.kubeconfig get nodes
#   errors out. There is more than one problem in the file.
#
#   Your job: repair the FILE (do not just switch to your own config)
#   until the command above lists the nodes. Do not modify ~/.kube/config.
#
#   Verify when done:
#     kubectl --kubeconfig /tmp/cka-breakfix/ops-user.kubeconfig get nodes
#   Full walkthrough:  SOLUTIONS.md  (spoilers)
#
#   Do not read past this line if you want the drill.
# ============================================================================

CTX=kind-cka
BACKUP_DIR=/tmp/cka-breakfix
mkdir -p "$BACKUP_DIR"

kubectl --context "$CTX" get nodes >/dev/null

TARGET="$BACKUP_DIR/ops-user.kubeconfig"

kubectl config view --minify --flatten --context "$CTX" \
  | sed -E 's#^( *)certificate-authority-data: .*#\1certificate-authority: /etc/kubernetes/pki/ca.crt#' \
  | sed -E 's#^( *)server: .*#\1server: https://127.0.0.1:6444#' \
  > "$TARGET"

echo "[break-08] armed. Debug with: kubectl --kubeconfig $TARGET get nodes"
