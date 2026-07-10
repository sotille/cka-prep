#!/usr/bin/env bash
# CKA Mock Exam 1 - environment setup (exam-level-minus, confidence run).
# DO NOT READ THIS FILE BEFORE THE EXAM. It seeds every broken resource and thus every answer.
#
# Requires: running kind cluster "cka" (nodes cka-control-plane, cka-worker, cka-worker2),
# kubectl context kind-cka, docker, and network access (Gateway API CRDs + agnhost/nginx images
# are pulled from the internet on first run).
# Touches ONLY the kind cluster and /tmp/exam. Idempotent-ish: safe to re-run, re-injects faults.

set -euo pipefail

CTX=kind-cka
CP=cka-control-plane
W1=cka-worker
W2=cka-worker2

AGN=registry.k8s.io/e2e-test-images/agnhost:2.53

echo ">>> Prerequisites"
command -v docker >/dev/null 2>&1 || { echo "FATAL: docker not found on PATH" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "FATAL: docker daemon not running" >&2; exit 1; }
docker inspect "$CP" >/dev/null 2>&1 || { echo "FATAL: node container $CP not found - is kind cluster 'cka' up?" >&2; exit 1; }
kubectl config use-context "$CTX" >/dev/null 2>&1 || { echo "FATAL: kubectl context $CTX not found" >&2; exit 1; }
kubectl get nodes >/dev/null || { echo "FATAL: cluster unreachable via context $CTX" >&2; exit 1; }

# If a previous run left worker2's kubelet disabled/stopped (Task 3 fault), restore it so
# baseline pods settle before we re-inject the fault at the end.
docker exec "$W2" systemctl enable --now kubelet >/dev/null 2>&1 || true
sleep 3

echo ">>> Workspace /tmp/exam"
rm -rf /tmp/exam
mkdir -p /tmp/exam
mkdir -p /tmp/exam/task12/base

echo ">>> Namespaces"
for ns in cicd apex netz apps commerce secure-apps data prod-apps ops; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

echo ">>> Task 2 fixtures (broken Deployment: bad image tag)"
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-frontend
  namespace: apex
  labels:
    app: web-frontend
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web-frontend
  template:
    metadata:
      labels:
        app: web-frontend
    spec:
      nodeSelector:
        kubernetes.io/hostname: cka-worker
      containers:
      - name: nginx
        image: nginx:1.99-alpine
        ports:
        - containerPort: 80
EOF

echo ">>> Task 4 fixtures (echo-server Deployment on 8080)"
kubectl apply -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-server
  namespace: netz
  labels:
    app: echo-server
spec:
  replicas: 2
  selector:
    matchLabels:
      app: echo-server
  template:
    metadata:
      labels:
        app: echo-server
    spec:
      nodeSelector:
        kubernetes.io/hostname: cka-worker
      containers:
      - name: echo
        image: ${AGN}
        args: ["netexec", "--http-port=8080"]
        ports:
        - containerPort: 8080
EOF

echo ">>> Task 6 fixtures (Secret + Deployment referencing a wrong secret key)"
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: orders-secret
  namespace: commerce
type: Opaque
stringData:
  db-password: s3cr3t-pw
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders-api
  namespace: commerce
  labels:
    app: orders-api
spec:
  replicas: 1
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
      - name: orders
        image: nginx:1.27
        env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: orders-secret
              key: db-pass
        ports:
        - containerPort: 80
EOF

echo ">>> Task 8 fixtures (static PersistentVolume)"
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-manual-1g
spec:
  capacity:
    storage: 1Gi
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  hostPath:
    path: /mnt/pv-manual-1g
    type: DirectoryOrCreate
EOF

echo ">>> Task 9 fixtures (db / api / client pods in secure-apps)"
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: db
  namespace: secure-apps
  labels:
    role: db
spec:
  replicas: 1
  selector:
    matchLabels:
      role: db
  template:
    metadata:
      labels:
        role: db
    spec:
      nodeSelector:
        kubernetes.io/hostname: cka-worker
      containers:
      - name: db
        image: nginx:1.27
        ports:
        - containerPort: 5432
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: secure-apps
  labels:
    role: api
spec:
  replicas: 1
  selector:
    matchLabels:
      role: api
  template:
    metadata:
      labels:
        role: api
    spec:
      nodeSelector:
        kubernetes.io/hostname: cka-worker
      containers:
      - name: api
        image: nginx:1.27
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: client
  namespace: secure-apps
  labels:
    role: client
spec:
  replicas: 1
  selector:
    matchLabels:
      role: client
  template:
    metadata:
      labels:
        role: client
    spec:
      nodeSelector:
        kubernetes.io/hostname: cka-worker
      containers:
      - name: client
        image: nginx:1.27
EOF

echo ">>> Task 11 fixtures (catalog-api + Service with a wrong selector)"
kubectl apply -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog-api
  namespace: commerce
  labels:
    app: catalog-api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: catalog-api
  template:
    metadata:
      labels:
        app: catalog-api
    spec:
      nodeSelector:
        kubernetes.io/hostname: cka-worker
      containers:
      - name: catalog
        image: ${AGN}
        args: ["netexec", "--http-port=8080"]
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: catalog-svc
  namespace: commerce
spec:
  selector:
    app: catalog
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
EOF

echo ">>> Task 14 fixtures (payment-processor emitting mixed-level logs)"
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: payment-processor
  namespace: commerce
  labels:
    app: payment-processor
spec:
  nodeSelector:
    kubernetes.io/hostname: cka-worker
  containers:
  - name: app
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      echo "$(date) level=INFO  payment-processor starting"
      echo "$(date) level=ERROR failed to connect to fraud-service: connection refused"
      echo "$(date) level=WARN  retrying fraud-service handshake"
      echo "$(date) level=ERROR payment gateway returned 503 Service Unavailable"
      echo "$(date) level=INFO  reconnected to fraud-service"
      i=0
      while true; do
        i=$((i+1))
        if [ $((i % 5)) -eq 0 ]; then
          echo "$(date) level=ERROR settlement batch $i rejected: duplicate id"
        elif [ $((i % 3)) -eq 0 ]; then
          echo "$(date) level=WARN  slow response from ledger ($i)"
        else
          echo "$(date) level=INFO  processed transaction $i"
        fi
        sleep 3
      done
EOF

echo ">>> Task 12 fixtures (kustomize base)"
cat > /tmp/exam/task12/base/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-web
  template:
    metadata:
      labels:
        app: nginx-web
    spec:
      containers:
      - name: nginx
        image: nginx:1.27
        ports:
        - containerPort: 80
EOF
cat > /tmp/exam/task12/base/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: nginx-web
spec:
  selector:
    app: nginx-web
  ports:
  - port: 80
    targetPort: 80
EOF
cat > /tmp/exam/task12/base/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- deployment.yaml
- service.yaml
EOF

echo ">>> Task 15 fixtures (Gateway API CRDs + GatewayClass exam-gc)"
GW_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml"
if kubectl apply -f "$GW_URL" >/dev/null 2>&1; then
  echo "    Gateway API CRDs installed"
else
  echo "    WARN: could not fetch Gateway API CRDs (offline?). Task 15 will not be solvable." >&2
fi
if kubectl get crd gatewayclasses.gateway.networking.k8s.io >/dev/null 2>&1; then
  kubectl apply -f - <<'EOF' >/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: exam-gc
spec:
  controllerName: example.com/exam-gateway-controller
EOF
fi

echo ">>> Task 16 fixtures (CustomResourceDefinition in ops.example.com)"
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: backupjobs.ops.example.com
spec:
  group: ops.example.com
  scope: Namespaced
  names:
    plural: backupjobs
    singular: backupjob
    kind: BackupJob
    shortNames:
    - bj
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              source:
                type: string
              schedule:
                type: string
              retainDays:
                type: integer
EOF

echo ">>> Waiting for baseline pods to be scheduled"
for ns in netz commerce secure-apps; do
  kubectl -n "$ns" wait --for=condition=PodScheduled pod --all --timeout=90s >/dev/null 2>&1 || true
done

echo ">>> Injecting fault: node kubelet down (Task 3)"
# disable + stop: the node goes NotReady and the fix must survive a reboot (systemctl enable --now).
docker exec "$W2" systemctl disable --now kubelet >/dev/null 2>&1 || true

echo ""
echo "=========================================================="
echo " Environment ready. Start your 120-minute timer NOW."
echo " Exam paper:        mock-exams/mock-exam-1.md"
echo " Answers directory: /tmp/exam"
echo " Node access:       docker exec -it <node> bash  (real exam: ssh + sudo)"
echo "=========================================================="
