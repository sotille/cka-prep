#!/usr/bin/env bash
# CKA Mock Exam 2 - environment setup.
# DO NOT READ THIS FILE BEFORE THE EXAM. It contains the injected faults (spoilers).
#
# Requires: running kind cluster "cka" (nodes cka-control-plane, cka-worker, cka-worker2),
# kubectl context kind-cka, docker, network access (Gateway API CRDs are pulled from GitHub).
# Touches ONLY the kind cluster and /tmp/exam2. Idempotent-ish: safe to re-run, re-injects faults.

set -euo pipefail

CTX=kind-cka
CP=cka-control-plane
W1=cka-worker
W2=cka-worker2

echo ">>> Prerequisites"
command -v docker >/dev/null 2>&1 || { echo "FATAL: docker not found on PATH" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "FATAL: docker daemon not running" >&2; exit 1; }
docker inspect "$CP" >/dev/null 2>&1 || { echo "FATAL: node container $CP not found - is kind cluster 'cka' up?" >&2; exit 1; }
kubectl config use-context "$CTX" >/dev/null 2>&1 || { echo "FATAL: kubectl context $CTX not found" >&2; exit 1; }
kubectl get nodes >/dev/null || { echo "FATAL: cluster unreachable via context $CTX" >&2; exit 1; }
command -v helm >/dev/null 2>&1 || echo "WARN: helm not found on PATH - Task 12 requires it (brew install helm)" >&2

# If a previous run stopped kubelet on worker2, bring it back so setup pods can settle.
docker exec "$W2" systemctl start kubelet >/dev/null 2>&1 || true
# If a previous run broke the scheduler, restore it for the same reason.
docker exec "$CP" sed -i 's|- kube-schedulerX$|- kube-scheduler|' /etc/kubernetes/manifests/kube-scheduler.yaml || true
sleep 5

echo ">>> Workspace /tmp/exam2"
mkdir -p /tmp/exam2/ana
mkdir -p /tmp/exam2/kustomize/base
mkdir -p /tmp/exam2/charts/webapp/templates

echo ">>> Namespaces"
for ns in troubled commerce fintech secure-api web-frontend gateway-ns storage-task ci dev-ana recovery; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

echo ">>> Task 2 fixtures (broken deployment)"
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders-api
  namespace: troubled
  labels:
    app: orders-api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: orders-api
  template:
    metadata:
      labels:
        app: orders-api
    spec:
      nodeSelector:
        kubernetes.io/hostname: cka-worker
      containers:
      - name: web
        image: nginx:1.99-alpine
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 2
          periodSeconds: 5
EOF

echo ">>> Task 4 fixtures (deployment + misconfigured service)"
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog
  namespace: commerce
  labels:
    app: catalog
spec:
  replicas: 1
  selector:
    matchLabels:
      app: catalog
  template:
    metadata:
      labels:
        app: catalog
    spec:
      nodeSelector:
        kubernetes.io/hostname: cka-worker
      containers:
      - name: web
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: catalog-svc
  namespace: commerce
spec:
  selector:
    app: catalogue
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
EOF

echo ">>> Task 3 / Task 10 fixtures (fintech workloads, preexisting PriorityClass)"
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: fintech
  labels:
    app: checkout
spec:
  replicas: 1
  selector:
    matchLabels:
      app: checkout
  template:
    metadata:
      labels:
        app: checkout
    spec:
      nodeSelector:
        kubernetes.io/hostname: cka-worker
      containers:
      - name: web
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 100m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
  namespace: fintech
  labels:
    app: payments
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payments
  template:
    metadata:
      labels:
        app: payments
    spec:
      nodeSelector:
        kubernetes.io/hostname: cka-worker
      containers:
      - name: web
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: preexisting-high
value: 500000
globalDefault: false
description: Preexisting user-defined priority class (Task 10 reference point).
EOF

echo ">>> Task 6 fixtures (secure-api pods)"
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: secure-api
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
      nodeSelector:
        kubernetes.io/hostname: cka-worker
      containers:
      - name: web
        image: nginx:1.27-alpine
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: db
  namespace: secure-api
  labels:
    app: db
spec:
  replicas: 1
  selector:
    matchLabels:
      app: db
  template:
    metadata:
      labels:
        app: db
    spec:
      nodeSelector:
        kubernetes.io/hostname: cka-worker
      containers:
      - name: db
        image: nginx:1.27-alpine
        ports:
        - containerPort: 5432
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: client
  namespace: secure-api
  labels:
    app: client
spec:
  replicas: 1
  selector:
    matchLabels:
      app: client
  template:
    metadata:
      labels:
        app: client
    spec:
      nodeSelector:
        kubernetes.io/hostname: cka-worker
      containers:
      - name: web
        image: nginx:1.27-alpine
EOF

echo ">>> Task 13 fixtures (frontend deployment)"
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: web-frontend
  labels:
    app: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      nodeSelector:
        kubernetes.io/hostname: cka-worker
      containers:
      - name: web
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
EOF

echo ">>> Task 9 fixtures (Gateway API CRDs, GatewayClass, backends)"
GW_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml"
if kubectl apply -f "$GW_URL" >/dev/null 2>&1; then
  echo "    Gateway API CRDs installed"
else
  echo "    WARN: could not fetch Gateway API CRDs (offline?). Task 9 will not be solvable." >&2
fi
if kubectl get crd gatewayclasses.gateway.networking.k8s.io >/dev/null 2>&1; then
  kubectl apply -f - <<'EOF' >/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cka-gwc
spec:
  controllerName: example.com/cka-gateway-controller
EOF
fi
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
  namespace: gateway-ns
  labels:
    app: shop
spec:
  replicas: 1
  selector:
    matchLabels:
      app: shop
  template:
    metadata:
      labels:
        app: shop
    spec:
      nodeSelector:
        kubernetes.io/hostname: cka-worker
      containers:
      - name: web
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cart
  namespace: gateway-ns
  labels:
    app: cart
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cart
  template:
    metadata:
      labels:
        app: cart
    spec:
      nodeSelector:
        kubernetes.io/hostname: cka-worker
      containers:
      - name: web
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: shop
  namespace: gateway-ns
spec:
  selector:
    app: shop
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: cart
  namespace: gateway-ns
spec:
  selector:
    app: cart
  ports:
  - port: 8080
    targetPort: 80
EOF

echo ">>> Task 14 fixtures (static PV)"
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-archive
spec:
  capacity:
    storage: 2Gi
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: archive
  hostPath:
    path: /var/archive
    type: DirectoryOrCreate
EOF

echo ">>> Task 7 fixtures (ServiceAccount)"
kubectl -n ci create serviceaccount deploy-bot --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo ">>> Task 5 fixtures (kustomize base)"
cat > /tmp/exam2/kustomize/base/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: web
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
EOF
cat > /tmp/exam2/kustomize/base/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- deployment.yaml
EOF

echo ">>> Task 12 fixtures (local Helm chart)"
cat > /tmp/exam2/charts/webapp/Chart.yaml <<'EOF'
apiVersion: v2
name: webapp
description: Minimal web chart for CKA mock exam 2
type: application
version: 0.1.0
appVersion: "1.0"
EOF
cat > /tmp/exam2/charts/webapp/values.yaml <<'EOF'
replicaCount: 1
image:
  repository: nginx
  tag: 1.26-alpine
EOF
cat > /tmp/exam2/charts/webapp/templates/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-webapp
  labels:
    app: {{ .Release.Name }}-webapp
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}-webapp
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}-webapp
    spec:
      containers:
      - name: web
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        ports:
        - containerPort: 80
EOF

echo ">>> Waiting for baseline pods to be scheduled"
for ns in troubled commerce fintech secure-api web-frontend gateway-ns; do
  kubectl -n "$ns" wait --for=condition=PodScheduled pod --all --timeout=90s >/dev/null 2>&1 || true
done

echo ">>> Injecting fault: control plane component (Task 16)"
docker exec "$CP" sed -i 's|- kube-scheduler$|- kube-schedulerX|' /etc/kubernetes/manifests/kube-scheduler.yaml
sleep 8

echo ">>> Task 16 fixtures (workload affected by the fault)"
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: stuck-app
  namespace: recovery
  labels:
    app: stuck-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: stuck-app
  template:
    metadata:
      labels:
        app: stuck-app
    spec:
      containers:
      - name: web
        image: nginx:1.27-alpine
EOF

echo ">>> Injecting fault: node (Task 7)"
docker exec "$W2" systemctl stop kubelet

echo ""
echo "=========================================================="
echo " Environment ready. Start your 120-minute timer NOW."
echo " Exam paper: mock-exams/mock-exam-2.md"
echo " Answers directory: /tmp/exam2"
echo "=========================================================="
