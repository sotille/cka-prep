#!/usr/bin/env bash
# labs/setup/lib.sh — shared helpers for the lab automation scripts.
# Source this; do not execute directly.

CKA_CTX="${CKA_CTX:-kind-cka}"
CKA_CLUSTER="${CKA_CLUSTER:-cka}"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_dim=$'\033[2m'; c_rst=$'\033[0m'

log()  { printf '%s>>>%s %s\n' "$c_dim" "$c_rst" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s  !%s %s\n' "$c_ylw" "$c_rst" "$*" >&2; }
die()  { printf '%sFATAL:%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found on PATH"; }

require_docker() {
  need docker
  docker info >/dev/null 2>&1 || die "docker daemon not running — start Docker Desktop"
}

require_cluster() {
  need kubectl
  kubectl config get-contexts "$CKA_CTX" >/dev/null 2>&1 \
    || die "kubectl context '$CKA_CTX' not found — run labs/setup/bootstrap-cluster.sh"
  kubectl --context "$CKA_CTX" get nodes >/dev/null 2>&1 \
    || die "cluster unreachable via context '$CKA_CTX' — is the kind cluster '$CKA_CLUSTER' up?"
}

# Guard against operating on the wrong cluster. Refuse any non-kind context.
assert_kind_context() {
  case "$(kubectl config current-context 2>/dev/null)" in
    kind-*) : ;;
    *) die "current context is not a kind cluster — refusing to touch it. Run: kubectl config use-context $CKA_CTX" ;;
  esac
}

# wait_rollout <ns> <deploy> [timeout]
wait_rollout() {
  kubectl --context "$CKA_CTX" -n "$1" rollout status deploy/"$2" --timeout="${3:-120s}"
}
