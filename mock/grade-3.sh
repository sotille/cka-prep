#!/usr/bin/env bash
# grade-3.sh — auto-grader for Mock Exam 3 (killer-level). Sourced by mock/grade.sh.
# Domain weights (killer-skewed): Troubleshooting 30 / Cluster Architecture 29 /
# Services & Networking 20 / Workloads & Scheduling 11 / Storage 10.
PASS_LINE=55   # killer calibration: >=55% here ~ real-exam ready
CALIBRATION_NOTE="Killer calibration: this paper is deliberately harder than the real CKA. 50–60% here ≈ on track; ≥55% ≈ exam-ready. Do NOT read this number against the real 66% line."
E=/tmp/exam3

begin_task 1 "Troubleshooting" 8 "Deployments cluster-wide create no pods"
  awardif 2 "canary is 1/1 Ready in apex"                     deploy_ready apex canary 1
  awardif 3 "phoenix is 3/3 Ready in apex"                    deploy_ready apex phoenix 3
  awardif 1 "$E/01-cause.txt written"                         file_ok "$E/01-cause.txt"
  awardif 2 "cause names the controller-manager"             bash -c 'grep -qi "controller-manager" "'"$E"'/01-cause.txt" 2>/dev/null'
end_task

begin_task 2 "Cluster Architecture" 8 "Certificate user, RBAC and kubeconfig"
  awardif 1 "mara.key and mara.crt exist"                     bash -c '[ -s "'"$E"'/mara.key" ] && [ -s "'"$E"'/mara.crt" ]'
  awardif 1 "CSR mara is Approved"                            jpgrep Approved csr mara -o jsonpath='{.status.conditions[*].type}'
  awardif 1 "Role deploy-manager exists in citadel"           kexists role deploy-manager -n citadel
  awardif 1 "RoleBinding mara-deploy-manager exists"          kexists rolebinding mara-deploy-manager -n citadel
  awardif 2 "mara CAN create deployments in citadel"          cani yes create deployments.apps --as=mara -n citadel
  awardif 1 "mara can NOT get secrets in citadel"             cani no get secrets --as=mara -n citadel
  awardif 1 "$E/mara.kubeconfig written"                      file_ok "$E/mara.kubeconfig"
end_task

begin_task 3 "Services & Networking" 7 "Gateway API canary traffic split"
  awardif 1 "GatewayClass exam-gwc exists"                    kexists gatewayclass exam-gwc
  awardif 1 "Gateway web-gw class exam-gwc in mesh"           jpeq exam-gwc gateway web-gw -n mesh -o jsonpath='{.spec.gatewayClassName}'
  awardif 1 "listener HTTP on port 80"                        bash -c 'l=$(kubectl --context '"$CTX"' -n mesh get gateway web-gw -o jsonpath="{.spec.listeners[0].protocol}/{.spec.listeners[0].port}" 2>/dev/null); [ "$l" = "HTTP/80" ]'
  awardif 1 "HTTPRoute web-split exists in mesh"              kexists httproute web-split -n mesh
  awardif 1 "split weight 80 present"                         jpgrep 80 httproute web-split -n mesh -o jsonpath='{.spec.rules[*].backendRefs[*].weight}'
  awardif 1 "split weight 20 present"                         jpgrep 20 httproute web-split -n mesh -o jsonpath='{.spec.rules[*].backendRefs[*].weight}'
  awardif 1 "$E/03-gateway.yaml written"                      file_ok "$E/03-gateway.yaml"
end_task

begin_task 4 "Storage" 6 "The PVC that would not bind"
  awardif 3 "PVC data-fast is Bound in vault"                 jpeq Bound pvc data-fast -n vault -o jsonpath='{.status.phase}'
  awardif 3 "consumer Deployment has 1 ready replica"         deploy_ready vault consumer 1
end_task

begin_task 5 "Troubleshooting" 8 "One deployment, two independent faults"
  awardif 6 "telemetry is 2/2 Ready in orbit"                 deploy_ready orbit telemetry 2
  awardif 2 "$E/05-causes.txt lists two causes"               bash -c '[ "$(grep -c . "'"$E"'/05-causes.txt" 2>/dev/null)" -ge 2 ]'
end_task

begin_task 6 "Cluster Architecture" 10 "etcd backup and restore roundtrip"
  awardif 4 "snapshot copied to $E/exam3-snap.db"             file_ok "$E/exam3-snap.db"
  awardif 3 "$E/06-datadir.txt written"                       file_ok "$E/06-datadir.txt"
  awardif 3 "API server healthy after restore"               bash -c 'kubectl --context '"$CTX"' get --raw=/healthz >/dev/null 2>&1'
end_task

begin_task 7 "Troubleshooting" 7 "Drain blocked by a PodDisruptionBudget"
  awardif 2 "cka-worker is schedulable (uncordoned)"          bash -c '[ "$(kubectl --context '"$CTX"' get node cka-worker -o jsonpath="{.spec.unschedulable}" 2>/dev/null)" != "true" ]'
  awardif 3 "ledger back to 2 ready replicas in fortress"     deploy_ready fortress ledger 2
  awardif 2 "$E/07-blocker.txt names the PDB / eviction block" bash -c 'grep -Eqi "poddisruptionbudget|pdb|ledger-pdb|cannot evict|disruption" "'"$E"'/07-blocker.txt" 2>/dev/null'
end_task

begin_task 8 "Services & Networking" 7 "Service, NetworkPolicy and DNS, combined"
  awardif 2 "api-svc has endpoints in bazaar"                 svc_has_endpoints bazaar api-svc
  awardif 1 "NetworkPolicy allow-frontend exists"             kexists netpol allow-frontend -n bazaar
  awardif 1 "policy selects pods app=api"                     jpeq api netpol allow-frontend -n bazaar -o jsonpath='{.spec.podSelector.matchLabels.app}'
  awardif 1 "ingress from pods role=frontend"                 jpeq frontend netpol allow-frontend -n bazaar -o jsonpath='{.spec.ingress[0].from[0].podSelector.matchLabels.role}'
  awardif 1 "ingress port TCP 80"                             jpeq 80 netpol allow-frontend -n bazaar -o jsonpath='{.spec.ingress[0].ports[0].port}'
  awardif 1 "$E/08-dns.txt written"                           file_ok "$E/08-dns.txt"
end_task

begin_task 9 "Workloads & Scheduling" 6 "CronJob plus manual trigger"
  awardif 1 "CronJob report exists in batchjobs"              kexists cronjob report -n batchjobs
  awardif 1 "concurrencyPolicy Forbid"                        jpeq Forbid cronjob report -n batchjobs -o jsonpath='{.spec.concurrencyPolicy}'
  awardif 1 "backoffLimit 2"                                  jpeq 2 cronjob report -n batchjobs -o jsonpath='{.spec.jobTemplate.spec.backoffLimit}'
  awardif 1 "activeDeadlineSeconds 60"                        jpeq 60 cronjob report -n batchjobs -o jsonpath='{.spec.jobTemplate.spec.activeDeadlineSeconds}'
  awardif 1 "schedule runs every 5 minutes"                   jpgrep '/5' cronjob report -n batchjobs -o jsonpath='{.spec.schedule}'
  awardif 1 "manual Job report-now created"                   kexists job report-now -n batchjobs
end_task

begin_task 10 "Troubleshooting" 7 "Node NotReady, kubelet won't stay up"
  awardif 4 "all nodes are Ready"                             all_nodes_ready
  awardif 1 "kubelet enabled on cka-worker2"                  kubelet_enabled cka-worker2
  awardif 2 "$E/10-cause.txt written"                         file_ok "$E/10-cause.txt"
end_task

begin_task 11 "Workloads & Scheduling" 5 "DaemonSet on every node"
  awardif 1 "DaemonSet node-agent exists in sentry"           kexists ds node-agent -n sentry
  awardif 2 "3/3 desired pods are Ready"                      bash -c 'r=$(kubectl --context '"$CTX"' -n sentry get ds node-agent -o jsonpath="{.status.numberReady}" 2>/dev/null); d=$(kubectl --context '"$CTX"' -n sentry get ds node-agent -o jsonpath="{.status.desiredNumberScheduled}" 2>/dev/null); [ "$r" = "3" ] && [ "$d" = "3" ]'
  awardif 1 "updateStrategy maxUnavailable 2"                 jpeq 2 ds node-agent -n sentry -o jsonpath='{.spec.updateStrategy.rollingUpdate.maxUnavailable}'
  awardif 1 "tolerates the control-plane taint"              jpgrep control-plane ds node-agent -n sentry -o jsonpath='{.spec.template.spec.tolerations[*].key}'
end_task

begin_task 12 "Cluster Architecture" 7 "Helm lifecycle: upgrade, rollback, evict"
  awardif 3 "release web exists in helmwork"                  bash -c 'helm --kube-context '"$CTX"' -n helmwork status web >/dev/null 2>&1'
  awardif 2 "$E/12-history.txt written"                       file_ok "$E/12-history.txt"
  awardif 2 "broken release removed (one release left)"       bash -c '[ "$(helm --kube-context '"$CTX"' -n helmwork ls -q 2>/dev/null | grep -c .)" -le 1 ]'
end_task

begin_task 13 "Services & Networking" 6 "Every in-cluster hostname fails to resolve"
  awardif 3 "CoreDNS is Available (>=1 ready)"                deploy_ready kube-system coredns 1
  awardif 1 "$E/13-verify.txt written"                        file_ok "$E/13-verify.txt"
  awardif 2 "verify shows kubernetes.default resolving"       file_has "$E/13-verify.txt" "kubernetes.default"
end_task

begin_task 14 "Storage" 4 "Replace the default StorageClass"
  awardif 1 "SC standard-retain reclaimPolicy Retain"        jpeq Retain sc standard-retain -o jsonpath='{.reclaimPolicy}'
  awardif 1 "standard-retain is the default class"           jpeq true sc standard-retain -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}'
  awardif 2 "PVC scratch is Bound in vault"                  jpeq Bound pvc scratch -n vault -o jsonpath='{.status.phase}'
end_task

begin_task 15 "Cluster Architecture" 4 "Kustomize overlay with a patch"
  awardif 1 "namespace prodapps exists"                       kexists ns prodapps
  awardif 2 "notify is 3/3 Ready in prodapps"                 deploy_ready prodapps notify 3
  awardif 1 "$E/15-rendered.yaml written"                     file_ok "$E/15-rendered.yaml"
end_task
