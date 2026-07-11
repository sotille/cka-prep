#!/usr/bin/env bash
# grade-2.sh — auto-grader for Mock Exam 2 (true exam level). Sourced by mock/grade.sh.
# Domain weights: Troubleshooting 30 / Cluster Architecture 25 / Services & Networking 20 /
# Workloads & Scheduling 15 / Storage 10.
PASS_LINE=66
E=/tmp/exam2

begin_task 1 "Cluster Architecture" 6 "Certificate-based user access (ana)"
  awardif 1 "private key at $E/ana/ana.key"                   file_ok "$E/ana/ana.key"
  awardif 1 "issued cert at $E/ana/ana.crt"                   file_ok "$E/ana/ana.crt"
  awardif 1 "CSR ana is Approved"                             jpgrep Approved csr ana -o jsonpath='{.status.conditions[*].type}'
  awardif 1 "Role pod-reader exists in dev-ana"               kexists role pod-reader -n dev-ana
  awardif 1 "RoleBinding ana-pod-reader exists"               kexists rolebinding ana-pod-reader -n dev-ana
  awardif 1 "user ana can list pods in dev-ana"               cani yes list pods --as=ana -n dev-ana
end_task

begin_task 2 "Troubleshooting" 8 "Deployment not becoming Ready"
  awardif 1 "deployment orders-api exists in troubled"        kexists deploy orders-api -n troubled
  awardif 7 "orders-api has 3 ready replicas"                 deploy_ready troubled orders-api 3
end_task

begin_task 3 "Workloads & Scheduling" 8 "HorizontalPodAutoscaler"
  awardif 1 "HPA checkout-hpa exists in fintech"              kexists hpa checkout-hpa -n fintech
  awardif 1 "targets Deployment checkout"                     jpeq checkout hpa checkout-hpa -n fintech -o jsonpath='{.spec.scaleTargetRef.name}'
  awardif 1 "minReplicas 2"                                   jpeq 2 hpa checkout-hpa -n fintech -o jsonpath='{.spec.minReplicas}'
  awardif 1 "maxReplicas 8"                                   jpeq 8 hpa checkout-hpa -n fintech -o jsonpath='{.spec.maxReplicas}'
  awardif 2 "target CPU utilization 65%"                      jpeq 65 hpa checkout-hpa -n fintech -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}'
  awardif 2 "scaleDown stabilization 300s"                    jpeq 300 hpa checkout-hpa -n fintech -o jsonpath='{.spec.behavior.scaleDown.stabilizationWindowSeconds}'
end_task

begin_task 4 "Troubleshooting" 7 "Service serves no traffic"
  awardif 5 "catalog-svc now has endpoints"                   svc_has_endpoints commerce catalog-svc
  awardif 2 "$E/04-curl.txt written"                          file_ok "$E/04-curl.txt"
end_task

begin_task 5 "Cluster Architecture" 5 "Kustomize overlay"
  awardif 2 "deployment prod-web exists in prod-web"          kexists deploy prod-web -n prod-web
  awardif 2 "prod-web has 3 ready replicas"                   deploy_ready prod-web prod-web 3
  awardif 1 "$E/05-rendered.yaml written"                     file_ok "$E/05-rendered.yaml"
end_task

begin_task 6 "Services & Networking" 7 "NetworkPolicy for the database"
  awardif 1 "NetworkPolicy db-allow-api exists in secure-api" kexists netpol db-allow-api -n secure-api
  awardif 2 "selects pods app=db"                             jpeq db netpol db-allow-api -n secure-api -o jsonpath='{.spec.podSelector.matchLabels.app}'
  awardif 2 "ingress from pods app=api"                       jpeq api netpol db-allow-api -n secure-api -o jsonpath='{.spec.ingress[0].from[0].podSelector.matchLabels.app}'
  awardif 1 "ingress port TCP 5432"                           jpeq 5432 netpol db-allow-api -n secure-api -o jsonpath='{.spec.ingress[0].ports[0].port}'
  awardif 1 "policyTypes is [Ingress]"                        jpeq Ingress netpol db-allow-api -n secure-api -o jsonpath='{.spec.policyTypes[0]}'
end_task

begin_task 7 "Troubleshooting" 8 "Node NotReady"
  awardif 6 "all nodes are Ready"                             all_nodes_ready
  awardif 2 "kubelet enabled on cka-worker2 (survives reboot)" kubelet_enabled cka-worker2
end_task

begin_task 8 "Storage" 5 "Dynamic provisioning"
  awardif 1 "SC fast-local uses WaitForFirstConsumer"         jpeq WaitForFirstConsumer sc fast-local -o jsonpath='{.volumeBindingMode}'
  awardif 1 "SC fast-local reclaimPolicy Delete"              jpeq Delete sc fast-local -o jsonpath='{.reclaimPolicy}'
  awardif 2 "PVC data-pvc is Bound"                           jpeq Bound pvc data-pvc -n storage-task -o jsonpath='{.status.phase}'
  awardif 1 "pod data-pod is Running"                         jpeq Running pod data-pod -n storage-task -o jsonpath='{.status.phase}'
end_task

begin_task 9 "Services & Networking" 7 "Gateway API route"
  awardif 1 "Gateway web-gw exists in gateway-ns"             kexists gateway web-gw -n gateway-ns
  awardif 1 "gatewayClassName is cka-gwc"                     jpeq cka-gwc gateway web-gw -n gateway-ns -o jsonpath='{.spec.gatewayClassName}'
  awardif 1 "listener HTTP on port 80"                        bash -c 'l=$(kubectl --context '"$CTX"' -n gateway-ns get gateway web-gw -o jsonpath="{.spec.listeners[0].protocol}/{.spec.listeners[0].port}" 2>/dev/null); [ "$l" = "HTTP/80" ]'
  awardif 1 "HTTPRoute shop-route exists"                     kexists httproute shop-route -n gateway-ns
  awardif 1 "route attached to web-gw"                        jpeq web-gw httproute shop-route -n gateway-ns -o jsonpath='{.spec.parentRefs[0].name}'
  awardif 1 "routes to backend cart"                          jpgrep cart httproute shop-route -n gateway-ns -o jsonpath='{.spec.rules[*].backendRefs[*].name}'
  awardif 1 "routes to backend shop"                          jpgrep shop httproute shop-route -n gateway-ns -o jsonpath='{.spec.rules[*].backendRefs[*].name}'
end_task

begin_task 10 "Workloads & Scheduling" 7 "PriorityClass"
  awardif 2 "PriorityClass critical-services exists"          kexists priorityclass critical-services
  awardif 1 "it is not the global default"                    bash -c '[ "$(kubectl --context '"$CTX"' get priorityclass critical-services -o jsonpath="{.globalDefault}" 2>/dev/null)" != "true" ]'
  awardif 2 "payments Deployment uses it"                     jpeq critical-services deploy payments -n fintech -o jsonpath='{.spec.template.spec.priorityClassName}'
  awardif 2 "payments rollout complete (>=1 ready)"           deploy_ready fintech payments 1
end_task

begin_task 11 "Cluster Architecture" 4 "Certificate expiry"
  awardif 2 "$E/11-expiry.txt written"                        file_ok "$E/11-expiry.txt"
  awardif 2 "content looks like a cert expiry date"           bash -c 'grep -Eq "20[0-9]{2}|GMT|notAfter" "'"$E"'/11-expiry.txt" 2>/dev/null'
end_task

begin_task 12 "Cluster Architecture" 5 "Helm release lifecycle"
  awardif 3 "helm release web exists in namespace web"        bash -c 'helm --kube-context '"$CTX"' -n web status web >/dev/null 2>&1'
  awardif 2 "$E/12-history.txt written"                       file_ok "$E/12-history.txt"
end_task

begin_task 13 "Services & Networking" 6 "NodePort Service and DNS"
  awardif 1 "frontend-svc type NodePort"                      jpeq NodePort svc frontend-svc -n web-frontend -o jsonpath='{.spec.type}'
  awardif 1 "nodePort 30080"                                  jpeq 30080 svc frontend-svc -n web-frontend -o jsonpath='{.spec.ports[0].nodePort}'
  awardif 2 "frontend-svc has endpoints"                      svc_has_endpoints web-frontend frontend-svc
  awardif 2 "$E/13-fqdn.txt has the FQDN"                     file_has "$E/13-fqdn.txt" "frontend-svc.web-frontend.svc.cluster.local"
end_task

begin_task 14 "Storage" 5 "Bind a pre-provisioned PV"
  awardif 2 "PVC archive-pvc bound to pv-archive"             jpeq pv-archive pvc archive-pvc -n storage-task -o jsonpath='{.spec.volumeName}'
  awardif 1 "PVC phase Bound"                                 jpeq Bound pvc archive-pvc -n storage-task -o jsonpath='{.status.phase}'
  awardif 2 "pod archive-pod is Running"                      jpeq Running pod archive-pod -n storage-task -o jsonpath='{.status.phase}'
end_task

begin_task 15 "Cluster Architecture" 5 "Static Pod on the control plane"
  awardif 3 "mirror pod web-static-cka-control-plane Running" jpeq Running pod web-static-cka-control-plane -n default -o jsonpath='{.status.phase}'
  awardif 2 "$E/15-staticpod.txt has the mirror pod name"     file_has "$E/15-staticpod.txt" "web-static-cka-control-plane"
end_task

begin_task 16 "Troubleshooting" 7 "Pods stuck Pending cluster-wide (scheduler)"
  awardif 5 "stuck-app is Running (scheduler fixed)"          deploy_ready recovery stuck-app 1
  awardif 2 "$E/16-cause.txt points at the scheduler manifest" bash -c 'grep -qi "scheduler" "'"$E"'/16-cause.txt" 2>/dev/null'
end_task
