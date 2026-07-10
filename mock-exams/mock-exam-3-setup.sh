#!/usr/bin/env bash
# CKA Mock Exam 3 - environment setup (KILLER-LEVEL, deliberately harder than the real exam).
# DO NOT READ THIS FILE BEFORE THE EXAM. It contains every injected fault (spoilers).
#
# Requires: running kind cluster "cka" (nodes cka-control-plane, cka-worker, cka-worker2),
# kubectl context kind-cka, docker, helm, network access (Gateway API CRDs are pulled from GitHub).
# Touches ONLY the kind cluster and /tmp/exam3. Idempotent-ish: safe to re-run - it first
# un-breaks anything a previous run broke, lets the cluster settle, then re-injects the faults.
#
# Central design: Task 1 breaks kube-controller-manager. While it is down, NOTHING that a
# controller drives will progress cluster-wide (no ReplicaSets/pods, no endpoints, no PVC
# binding, no node-lifecycle transitions). That is intentional - it gates most other tasks.

set -euo pipefail

CTX=kind-cka
CP=cka-control-plane
W1=cka-worker
W2=cka-worker2
GW_VERSION=v1.2.1
GW_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GW_VERSION}/standard-install.yaml"

echo ">>> Prerequisites"
command -v docker >/dev/null 2>&1 || { echo "FATAL: docker not found on PATH" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "FATAL: docker daemon not running" >&2; exit 1; }
docker inspect "$CP" >/dev/null 2>&1 || { echo "FATAL: node container $CP not found - is kind cluster 'cka' up?" >&2; exit 1; }
kubectl config use-context "$CTX" >/dev/null 2>&1 || { echo "FATAL: kubectl context $CTX not found" >&2; exit 1; }
kubectl get nodes >/dev/null || { echo "FATAL: cluster unreachable via context $CTX" >&2; exit 1; }
command -v helm >/dev/null 2>&1 || echo "WARN: helm not found on PATH - Task 12 requires it (brew install helm)" >&2

echo ">>> Workspace /tmp/exam3"
rm -rf /tmp/exam3
mkdir -p /tmp/exam3
mkdir -p /tmp/exam3/charts/webshop/templates
mkdir -p /tmp/exam3/kustomize/base

# ---------------------------------------------------------------------------
# Known-good and known-broken CoreDNS Corefiles, written as merge-patch files.
# (Task 13 breaks internal DNS by pointing the kubernetes plugin at a bogus zone.)
# ---------------------------------------------------------------------------
cat > /tmp/exam3/coredns-good.yaml <<'EOF'
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30 {
           disable success cluster.local
           disable denial cluster.local
        }
        loop
        reload
        loadbalance
    }
EOF
cat > /tmp/exam3/coredns-broken.yaml <<'EOF'
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.broken in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30 {
           disable success cluster.local
           disable denial cluster.local
        }
        loop
        reload
        loadbalance
    }
EOF

echo ">>> Un-breaking anything a previous run left broken (idempotency)"
# Task 1: restore kube-controller-manager static pod command.
docker exec "$CP" sed -i 's|- kube-controller-managerX$|- kube-controller-manager|' \
  /etc/kubernetes/manifests/kube-controller-manager.yaml 2>/dev/null || true
# Task 10: restore worker2 kubelet extra-args and bring the kubelet back.
docker exec "$W2" sh -c 'printf "KUBELET_EXTRA_ARGS=--runtime-cgroups=/system.slice/containerd.service\n" > /etc/default/kubelet' 2>/dev/null || true
docker exec "$W2" systemctl daemon-reload 2>/dev/null || true
docker exec "$W2" systemctl restart kubelet 2>/dev/null || true
# Task 13: restore a healthy Corefile.
kubectl -n kube-system patch cm coredns --type merge --patch-file /tmp/exam3/coredns-good.yaml >/dev/null 2>&1 || true
kubectl -n kube-system rollout restart deploy coredns >/dev/null 2>&1 || true
echo "    waiting up to 90s for control plane + nodes to settle"
kubectl -n kube-system rollout status deploy coredns --timeout=90s >/dev/null 2>&1 || true
for i in $(seq 1 18); do
  ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -c '^Ready$' || true)
  [ "${ready:-0}" -ge 3 ] && break
  sleep 5
done

echo ">>> Namespaces"
for ns in apex citadel mesh vault orbit fortress bazaar batchjobs sentry helmwork; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

echo ">>> Task 3 fixtures (Gateway API CRDs + web-v1 / web-v2 backends)"
if kubectl apply -f "$GW_URL" >/dev/null 2>&1; then
  echo "    Gateway API CRDs ${GW_VERSION} installed"
else
  echo "    WARN: could not fetch Gateway API CRDs (offline?). Task 3 will not be solvable." >&2
fi
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-v1
  namespace: mesh
  labels:
    app: web-v1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web-v1
  template:
    metadata:
      labels:
        app: web-v1
    spec:
      containers:
      - name: web
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-v2
  namespace: mesh
  labels:
    app: web-v2
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web-v2
  template:
    metadata:
      labels:
        app: web-v2
    spec:
      containers:
      - name: web
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web-v1
  namespace: mesh
spec:
  selector:
    app: web-v1
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web-v2
  namespace: mesh
spec:
  selector:
    app: web-v2
  ports:
  - port: 80
    targetPort: 80
EOF

echo ">>> Task 4 fixtures (WaitForFirstConsumer SC + local PV reserved to a ghost claim + Pending PVC)"
docker exec "$W1" mkdir -p /opt/pv-fast
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-fast
provisioner: kubernetes.io/no-provisioner
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-fast
spec:
  capacity:
    storage: 1Gi
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-fast
  claimRef:
    namespace: vault
    name: ghost-claim
  local:
    path: /opt/pv-fast
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - cka-worker
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-fast
  namespace: vault
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: local-fast
  resources:
    requests:
      storage: 1Gi
EOF

echo ">>> Task 5 fixtures (two independent faults: bad image + wrong secretKeyRef key)"
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: telemetry-token
  namespace: orbit
type: Opaque
stringData:
  token: s3cr3t-telemetry-value
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: telemetry
  namespace: orbit
  labels:
    app: telemetry
spec:
  replicas: 2
  selector:
    matchLabels:
      app: telemetry
  template:
    metadata:
      labels:
        app: telemetry
    spec:
      containers:
      - name: web
        image: nginx:1.99-alpine
        ports:
        - containerPort: 80
        env:
        - name: TELEMETRY_TOKEN
          valueFrom:
            secretKeyRef:
              name: telemetry-token
              key: auth-token
EOF

echo ">>> Task 7 fixtures (ledger + restrictive PDB)"
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ledger
  namespace: fortress
  labels:
    app: ledger
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ledger
  template:
    metadata:
      labels:
        app: ledger
    spec:
      containers:
      - name: web
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ledger-pdb
  namespace: fortress
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: ledger
EOF

echo ">>> Task 8 fixtures (api + frontend + misconfigured Service + default-deny NetworkPolicy)"
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: bazaar
  labels:
    app: api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
      - name: web
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: bazaar
  labels:
    role: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      role: frontend
  template:
    metadata:
      labels:
        role: frontend
    spec:
      containers:
      - name: client
        image: busybox:1.36
        command: ["sh", "-c", "sleep 43200"]
---
apiVersion: v1
kind: Service
metadata:
  name: api-svc
  namespace: bazaar
spec:
  selector:
    app: api-broken
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: bazaar
spec:
  podSelector: {}
  policyTypes:
  - Ingress
EOF

echo ">>> Task 12 fixtures (local Helm chart + two releases; one release can never run)"
cat > /tmp/exam3/charts/webshop/Chart.yaml <<'EOF'
apiVersion: v2
name: webshop
description: Minimal web chart for CKA mock exam 3
type: application
version: 0.1.0
appVersion: "1.0"
EOF
cat > /tmp/exam3/charts/webshop/values.yaml <<'EOF'
replicaCount: 1
image:
  repository: nginx
  tag: 1.26-alpine
EOF
cat > /tmp/exam3/charts/webshop/templates/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-webshop
  labels:
    app: {{ .Release.Name }}-webshop
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}-webshop
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}-webshop
    spec:
      containers:
      - name: web
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        ports:
        - containerPort: 80
EOF
if command -v helm >/dev/null 2>&1; then
  helm uninstall web -n helmwork >/dev/null 2>&1 || true
  helm uninstall broken -n helmwork >/dev/null 2>&1 || true
  helm install web /tmp/exam3/charts/webshop -n helmwork >/dev/null 2>&1 || \
    echo "    WARN: helm install web failed" >&2
  helm install broken /tmp/exam3/charts/webshop -n helmwork --set image.tag=9.99-broken >/dev/null 2>&1 || \
    echo "    WARN: helm install broken failed" >&2
fi

echo ">>> Task 15 fixtures (kustomize base)"
cat > /tmp/exam3/kustomize/base/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: notify
spec:
  replicas: 1
  selector:
    matchLabels:
      app: notify
  template:
    metadata:
      labels:
        app: notify
    spec:
      containers:
      - name: web
        image: nginx:1.25-alpine
        ports:
        - containerPort: 80
EOF
cat > /tmp/exam3/kustomize/base/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- deployment.yaml
EOF

echo ">>> Waiting for baseline pods to schedule (best-effort; some fixtures are meant to stay broken)"
for ns in mesh fortress bazaar helmwork; do
  kubectl -n "$ns" wait --for=condition=PodScheduled pod --all --timeout=90s >/dev/null 2>&1 || true
done
sleep 5

echo ">>> Injecting fault: cluster DNS (Task 13) - kubernetes plugin points at a bogus zone"
kubectl -n kube-system patch cm coredns --type merge --patch-file /tmp/exam3/coredns-broken.yaml >/dev/null
kubectl -n kube-system rollout restart deploy coredns >/dev/null
kubectl -n kube-system rollout status deploy coredns --timeout=90s >/dev/null 2>&1 || true

echo ">>> Injecting fault: control-plane component down (Task 1) - kube-controller-manager"
docker exec "$CP" sed -i 's|- kube-controller-manager$|- kube-controller-managerX|' \
  /etc/kubernetes/manifests/kube-controller-manager.yaml
sleep 8

echo ">>> Task 1 fixture (canary Deployment created AFTER the break - it gets no ReplicaSet)"
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: canary
  namespace: apex
  labels:
    app: canary
spec:
  replicas: 1
  selector:
    matchLabels:
      app: canary
  template:
    metadata:
      labels:
        app: canary
    spec:
      containers:
      - name: web
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
EOF

echo ">>> Injecting fault: worker node kubelet crash-loop (Task 10) - bad --fail-swap-on value"
docker exec "$W2" sh -c 'printf "KUBELET_EXTRA_ARGS=--runtime-cgroups=/system.slice/containerd.service --fail-swap-on=maybe\n" > /etc/default/kubelet'
docker exec "$W2" systemctl daemon-reload
docker exec "$W2" systemctl restart kubelet 2>/dev/null || true

echo ""
echo "=========================================================="
echo " Environment ready. This paper is KILLER-LEVEL."
echo " Start your 120-minute timer NOW."
echo " Exam paper:        mock-exams/mock-exam-3.md"
echo " Answers directory: /tmp/exam3"
echo ""
echo " Triage first: a control-plane component is down (Task 1),"
echo " cluster DNS is broken (Task 13), and a node is broken"
echo " (Task 10). Most other tasks depend on Task 1 - fix it early."
echo "=========================================================="
