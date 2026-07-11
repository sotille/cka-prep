#!/usr/bin/env bash
# install-addons.sh — install the cluster addons the exercises and mocks reference,
# so lab time goes to practicing, not plumbing. Idempotent.
#
# Usage:
#   labs/setup/install-addons.sh                 # install all
#   labs/setup/install-addons.sh metrics ingress # install a subset
# Addons: metrics | ingress | gateway   (default: all three)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

require_cluster
kubectl config use-context "$CKA_CTX" >/dev/null
assert_kind_context
need curl

WANT="${*:-metrics ingress gateway}"
want() { case " $WANT " in *" $1 "*) return 0;; *) return 1;; esac; }

GATEWAY_VER="v1.2.1"
INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml"
METRICS_MANIFEST="https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
GATEWAY_MANIFEST="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_VER}/standard-install.yaml"

if want metrics; then
  log "metrics-server (kind needs --kubelet-insecure-tls)"
  if kubectl apply -f "$METRICS_MANIFEST" >/dev/null 2>&1; then
    # kind's kubelet serving cert is self-signed → metrics-server must skip TLS verify
    kubectl -n kube-system patch deploy metrics-server --type=json \
      -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' >/dev/null 2>&1 || true
    kubectl -n kube-system rollout status deploy/metrics-server --timeout=120s >/dev/null 2>&1 \
      && ok "metrics-server ready — try: kubectl top nodes" \
      || warn "metrics-server applied but not Ready yet (give it a minute, then 'kubectl top nodes')"
  else
    warn "could not fetch metrics-server manifest (offline?)"
  fi
fi

if want ingress; then
  log "ingress-nginx (kind provider manifest)"
  if kubectl apply -f "$INGRESS_MANIFEST" >/dev/null 2>&1; then
    kubectl -n ingress-nginx wait --for=condition=Available deploy/ingress-nginx-controller --timeout=150s >/dev/null 2>&1 \
      && ok "ingress-nginx ready — ingressClassName: nginx" \
      || warn "ingress-nginx applied; controller still coming up"
  else
    warn "could not fetch ingress-nginx manifest (offline?)"
  fi
fi

if want gateway; then
  log "Gateway API CRDs ($GATEWAY_VER, standard channel)"
  if kubectl apply -f "$GATEWAY_MANIFEST" >/dev/null 2>&1; then
    ok "Gateway API CRDs installed — kind: Gateway / HTTPRoute (gateway.networking.k8s.io/v1)"
    warn "note: no Gateway *controller* is installed — objects won't be Programmed, which is fine for CKA spec practice"
  else
    warn "could not fetch Gateway API CRDs (offline?)"
  fi
fi

echo
ok "addons done. For NetworkPolicy enforcement (kindnet does NOT enforce it) use labs/setup/calico-netpol-cluster.sh"
