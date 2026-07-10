# Week 7 (Jul 20–26) — Storage

> 📚 **Deep module:** [masterclass](../course/week-07-storage/masterclass.md) · [exercises](../course/week-07-storage/exercises.md)

**Goal:** Volumes, PVs, PVCs, StorageClasses, Reclaim Policy.

**Time budget:** 14h

> **🎯 AGENDE O EXAME ESTA SEMANA** — escolha 17 Aug 2026 (segunda) na manhã.

---

## Topics

- [ ] Volumes vs PersistentVolumes vs PersistentVolumeClaims
- [ ] Volume types: emptyDir, hostPath, NFS, configMap, secret as volume
- [ ] PV access modes: ReadWriteOnce, ReadOnlyMany, ReadWriteMany, ReadWriteOncePod
- [ ] Reclaim policies: Retain, Delete, Recycle (deprecated)
- [ ] StorageClass + dynamic provisioning
- [ ] Binding lifecycle: Available → Bound → Released → ???

## Mental Model

```
StorageClass ──provisions──> PV ──binds to──> PVC ──used by──> Pod
```

- **Static**: admin creates PV, user creates PVC, K8s matches them
- **Dynamic**: user creates PVC referencing StorageClass, PV created on-demand

## Speed Patterns

```bash
# Quick PVC
cat <<EOF | k apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: standard
EOF

# Mount in pod
volumes:
- name: data
  persistentVolumeClaim:
    claimName: data
```

## Common Troubleshooting

| Symptom | Likely Cause |
|---|---|
| PVC Pending | No matching PV / no default StorageClass / size mismatch |
| Pod Pending after PVC bound | Node-level mount issue, check events |
| Released PV won't reuse | Manual cleanup needed (Retain policy) |

## Hands-On Labs

- [ ] Create PV manually + PVC that binds to it
- [ ] Create StorageClass + PVC, observe dynamic PV creation
- [ ] Mount ConfigMap as volume + observe file projection
- [ ] Delete pod, observe PV/PVC remain (or get reclaimed)

## Week 7 Checkpoint

- [ ] Troubleshoot "PVC Pending" in < 3 min
- [ ] Mount a hostPath volume read-only

## Insights

<!-- Add as you go -->
