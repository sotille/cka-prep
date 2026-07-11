#!/usr/bin/env bash
# grade-1.sh — auto-grader for Mock Exam 1. Sourced by mock/grade.sh (lib-checks.sh already loaded).
# Grades on final cluster/file state. Domain tags follow the 2025 blueprint
# (Kustomize → Cluster Architecture); weights sum to 100 = 30/25/20/15/10.
PASS_LINE=66
SA=system:serviceaccount:cicd:deploy-bot

begin_task 1 "Cluster Architecture" 6 "Least-privilege for a CI bot (RBAC)"
  awardif 1 "ServiceAccount deploy-bot exists in cicd"        kexists sa deploy-bot -n cicd
  awardif 2 "SA can update deployments.apps in cicd"          cani yes update deployments.apps --as="$SA" -n cicd
  awardif 1 "SA can get deployments.apps in cicd"             cani yes get deployments.apps --as="$SA" -n cicd
  awardif 1 "least privilege: SA can NOT delete deployments"  bash -c 'kubectl --context '"$CTX"' get sa deploy-bot -n cicd >/dev/null 2>&1 && [ "$(kubectl --context '"$CTX"' auth can-i delete deployments.apps --as='"$SA"' -n cicd 2>/dev/null)" = "no" ]'
  awardif 1 "/tmp/exam/task1-cani.txt says yes"               file_has /tmp/exam/task1-cani.txt "yes"
end_task

begin_task 2 "Troubleshooting" 6 "Deployment won't come up (bad image)"
  awardif 1 "deployment web-frontend exists in apex"          kexists deploy web-frontend -n apex
  awardif 5 "web-frontend has 3 ready replicas"               deploy_ready apex web-frontend 3
end_task

begin_task 3 "Troubleshooting" 7 "Node NotReady (kubelet)"
  awardif 5 "all nodes are Ready"                             all_nodes_ready
  awardif 2 "kubelet enabled on cka-worker2 (survives reboot)" kubelet_enabled cka-worker2
end_task

begin_task 4 "Services & Networking" 6 "NodePort on a fixed port"
  awardif 1 "echo-svc type is NodePort"                       jpeq NodePort svc echo-svc -n netz -o jsonpath='{.spec.type}'
  awardif 1 "service port is 8080"                            jpeq 8080 svc echo-svc -n netz -o jsonpath='{.spec.ports[0].port}'
  awardif 1 "targetPort is 8080"                              jpeq 8080 svc echo-svc -n netz -o jsonpath='{.spec.ports[0].targetPort}'
  awardif 1 "nodePort is 30080"                               jpeq 30080 svc echo-svc -n netz -o jsonpath='{.spec.ports[0].nodePort}'
  awardif 1 "service selects pods (has endpoints)"            svc_has_endpoints netz echo-svc
  awardif 1 "task4-clusterip.txt matches the real ClusterIP"  bash -c 'cip=$(kubectl --context '"$CTX"' -n netz get svc echo-svc -o jsonpath="{.spec.clusterIP}" 2>/dev/null); [ -n "$cip" ] && grep -q -- "$cip" /tmp/exam/task4-clusterip.txt'
end_task

begin_task 5 "Workloads & Scheduling" 8 "Deployment rollout controls"
  awardif 1 "deployment api-gateway exists in apps"           kexists deploy api-gateway -n apps
  awardif 1 "image updated to nginx:1.28"                     jpeq nginx:1.28 deploy api-gateway -n apps -o jsonpath='{.spec.template.spec.containers[0].image}'
  awardif 2 "scaled to 4 ready replicas"                      deploy_ready apps api-gateway 4
  awardif 1 "requests cpu=100m memory=128Mi"                  bash -c 'r=$(kubectl --context '"$CTX"' -n apps get deploy api-gateway -o jsonpath="{.spec.template.spec.containers[0].resources.requests.cpu}{\"/\"}{.spec.template.spec.containers[0].resources.requests.memory}" 2>/dev/null); [ "$r" = "100m/128Mi" ]'
  awardif 1 "memory limit 256Mi"                              jpeq 256Mi deploy api-gateway -n apps -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
  awardif 1 "strategy maxSurge=1 maxUnavailable=0"            bash -c 's=$(kubectl --context '"$CTX"' -n apps get deploy api-gateway -o jsonpath="{.spec.strategy.rollingUpdate.maxSurge}{\"/\"}{.spec.strategy.rollingUpdate.maxUnavailable}" 2>/dev/null); [ "$s" = "1/0" ]'
  awardif 1 "task5-history.txt written"                       file_ok /tmp/exam/task5-history.txt
end_task

begin_task 6 "Troubleshooting" 6 "Pod failing to start (bad secret key)"
  awardif 5 "orders-api has 1 ready replica"                  deploy_ready commerce orders-api 1
  awardif 1 "secret orders-secret left intact (db-password)"  jpgrep . secret orders-secret -n commerce -o jsonpath='{.data.db-password}'
end_task

begin_task 7 "Cluster Architecture" 7 "etcd snapshot"
  awardif 5 "snapshot saved to /tmp/exam/task7-snapshot.db"   file_ok /tmp/exam/task7-snapshot.db
  awardif 2 "snapshot status written to task7-status.txt"     file_ok /tmp/exam/task7-status.txt
end_task

begin_task 8 "Storage" 5 "Static provisioning"
  awardif 2 "PVC data-claim is Bound"                         jpeq Bound pvc data-claim -n data -o jsonpath='{.status.phase}'
  awardif 1 "bound to PV pv-manual-1g"                        jpeq pv-manual-1g pvc data-claim -n data -o jsonpath='{.spec.volumeName}'
  awardif 2 "pod data-pod is Running"                         jpeq Running pod data-pod -n data -o jsonpath='{.status.phase}'
end_task

begin_task 9 "Services & Networking" 7 "NetworkPolicy: lock down the db"
  awardif 1 "NetworkPolicy db-allow-api exists"               kexists netpol db-allow-api -n secure-apps
  awardif 2 "selects pods role=db"                            jpeq db netpol db-allow-api -n secure-apps -o jsonpath='{.spec.podSelector.matchLabels.role}'
  awardif 2 "ingress from pods role=api"                      jpeq api netpol db-allow-api -n secure-apps -o jsonpath='{.spec.ingress[0].from[0].podSelector.matchLabels.role}'
  awardif 1 "ingress port TCP 5432"                           jpeq 5432 netpol db-allow-api -n secure-apps -o jsonpath='{.spec.ingress[0].ports[0].port}'
  awardif 1 "policyTypes is [Ingress] (egress unrestricted)"  jpeq Ingress netpol db-allow-api -n secure-apps -o jsonpath='{.spec.policyTypes[0]}'
end_task

begin_task 10 "Workloads & Scheduling" 7 "Run a pod on the control plane"
  awardif 2 "pod cp-agent is Running"                         jpeq Running pod cp-agent -n apps -o jsonpath='{.status.phase}'
  awardif 2 "scheduled on cka-control-plane"                  jpeq cka-control-plane pod cp-agent -n apps -o jsonpath='{.spec.nodeName}'
  awardif 2 "tolerates the control-plane taint"               jpgrep 'node-role.kubernetes.io/control-plane' pod cp-agent -n apps -o jsonpath='{.spec.tolerations[*].key}'
  awardif 1 "uses a control-plane nodeSelector"               jpgrep 'control-plane' pod cp-agent -n apps -o jsonpath='{.spec.nodeSelector}'
end_task

begin_task 11 "Troubleshooting" 6 "Service without endpoints"
  awardif 4 "catalog-svc now has endpoints"                   svc_has_endpoints commerce catalog-svc
  awardif 2 "task11-response.txt written"                     file_ok /tmp/exam/task11-response.txt
end_task

begin_task 12 "Cluster Architecture" 6 "Kustomize prod overlay"
  awardif 1 "deployment prod-nginx-web exists in prod-apps"   kexists deploy prod-nginx-web -n prod-apps
  awardif 3 "prod-nginx-web has 3 ready replicas"             deploy_ready prod-apps prod-nginx-web 3
  awardif 2 "service prod-nginx-web exists in prod-apps"      kexists svc prod-nginx-web -n prod-apps
end_task

begin_task 13 "Storage" 5 "Dynamic provisioning"
  awardif 1 "task13-sc.txt names the default StorageClass"    bash -c 'd=$(kubectl --context '"$CTX"' get sc -o jsonpath="{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class==\"true\")]}{.metadata.name}{end}" 2>/dev/null); [ -n "$d" ] && grep -q -- "$d" /tmp/exam/task13-sc.txt'
  awardif 2 "PVC logs-pvc is Bound"                           jpeq Bound pvc logs-pvc -n data -o jsonpath='{.status.phase}'
  awardif 2 "pod logs-writer is Running"                      jpeq Running pod logs-writer -n data -o jsonpath='{.status.phase}'
end_task

begin_task 14 "Troubleshooting" 5 "Extract error logs"
  awardif 1 "task14-errors.txt written"                       file_ok /tmp/exam/task14-errors.txt
  awardif 2 "every line contains level=ERROR"                 file_only /tmp/exam/task14-errors.txt "level=ERROR"
  awardif 2 "at least 3 ERROR lines captured"                 file_count_ge /tmp/exam/task14-errors.txt "level=ERROR" 3
end_task

begin_task 15 "Services & Networking" 7 "Gateway API routing"
  awardif 1 "Gateway web-gw exists in netz"                   kexists gateway web-gw -n netz
  awardif 1 "gatewayClassName is exam-gc"                     jpeq exam-gc gateway web-gw -n netz -o jsonpath='{.spec.gatewayClassName}'
  awardif 2 "listener HTTP on port 80"                        bash -c 'l=$(kubectl --context '"$CTX"' -n netz get gateway web-gw -o jsonpath="{.spec.listeners[0].protocol}{\"/\"}{.spec.listeners[0].port}" 2>/dev/null); [ "$l" = "HTTP/80" ]'
  awardif 1 "HTTPRoute echo-route exists in netz"             kexists httproute echo-route -n netz
  awardif 1 "route attached to web-gw"                        jpeq web-gw httproute echo-route -n netz -o jsonpath='{.spec.parentRefs[0].name}'
  awardif 1 "backend echo-svc:8080"                           bash -c 'b=$(kubectl --context '"$CTX"' -n netz get httproute echo-route -o jsonpath="{.spec.rules[0].backendRefs[0].name}{\":\"}{.spec.rules[0].backendRefs[0].port}" 2>/dev/null); [ "$b" = "echo-svc:8080" ]'
end_task

begin_task 16 "Cluster Architecture" 6 "Custom resources"
  awardif 1 "task16-crd.txt names the CRD"                    file_has /tmp/exam/task16-crd.txt "backupjobs.ops.example.com"
  awardif 2 "BackupJob 'nightly' exists in ops"              kexists backupjobs.ops.example.com nightly -n ops
  awardif 1 "spec.source = /var/lib/app-data"                jpeq /var/lib/app-data backupjobs.ops.example.com nightly -n ops -o jsonpath='{.spec.source}'
  awardif 1 "spec.schedule = 0 2 * * *"                      jpeq '0 2 * * *' backupjobs.ops.example.com nightly -n ops -o jsonpath='{.spec.schedule}'
  awardif 1 "spec.retainDays = 14"                           jpeq 14 backupjobs.ops.example.com nightly -n ops -o jsonpath='{.spec.retainDays}'
end_task
