# Personal kubectl Cheatsheet

> Build this as you go. Don't copy from internet — only add what *you* actually had to look up.
> Decoded patterns retain better than copied patterns.

---

## Shell Setup (use during exam)

```bash
alias k=kubectl
export do='--dry-run=client -o yaml'
export now='--grace-period=0 --force'
source <(kubectl completion bash)
complete -F __start_kubectl k
```

## Speed Patterns

```bash
# Generate YAML scaffolding instead of writing from scratch
k run nginx --image=nginx $do > pod.yaml
k create deploy web --image=nginx --replicas=3 $do > deploy.yaml
k create svc clusterip web --tcp=80:80 $do > svc.yaml
k create cm app-config --from-literal=key=value $do > cm.yaml
k create secret generic app-secret --from-literal=password=s3cr3t $do > secret.yaml
k create role pod-reader --verb=get,list --resource=pods $do > role.yaml
k create rolebinding pod-reader-binding --role=pod-reader --user=jane $do > rb.yaml

# Force delete
k delete pod broken $now

# Logs from previous crash
k logs <pod> --previous

# Exec into pod
k exec -it <pod> -- /bin/sh

# Events (newest first)
k get events --sort-by='.lastTimestamp' -A
```

## Custom Patterns I Had To Look Up

<!-- Add here as you encounter them in study. Format:
### What I needed
```bash
# the command
```
Context: why it was hard to find.
-->

---

## Doc Navigation Patterns (exam-allowed: kubernetes.io)

| What you need | Direct path on kubernetes.io |
|---|---|
| Pod with env vars | /docs/tasks/inject-data-application/define-environment-variable-container/ |
| ConfigMap | /docs/tasks/configure-pod-container/configure-pod-configmap/ |
| Secret volume | /docs/tasks/inject-data-application/distribute-credentials-secure/ |
| NetworkPolicy | /docs/concepts/services-networking/network-policies/ |
| RBAC | /docs/reference/access-authn-authz/rbac/ |
| etcd backup | /docs/tasks/administer-cluster/configure-upgrade-etcd/ |
| Static pods | /docs/tasks/configure-pod-container/static-pod/ |
