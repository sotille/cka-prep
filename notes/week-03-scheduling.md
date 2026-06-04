# Week 3 (Jun 22–28) — Scheduling

**Goal:** Master NodeSelector, Affinity, Taints/Tolerations, Static Pods.

**Time budget:** 18h

---

## Topics

- [ ] Manual scheduling (`nodeName`)
- [ ] NodeSelector
- [ ] Node Affinity / Anti-Affinity (required vs preferred)
- [ ] Pod Affinity / Anti-Affinity
- [ ] Taints and Tolerations (NoSchedule, PreferNoSchedule, NoExecute)
- [ ] DaemonSets
- [ ] Static Pods
- [ ] Custom Schedulers (light)
- [ ] Multiple Schedulers

## Critical Distinctions to Master

| Concept | Use case |
|---|---|
| **NodeSelector** | Simple label match. Most basic. |
| **Node Affinity** | Complex expressions (In, NotIn, Exists, DoesNotExist) |
| **Taints/Tolerations** | Node-side: "keep pods away unless they tolerate" |
| **Pod Affinity** | "Place me NEAR/AWAY from pod with label X" |

## Hands-On Labs

- [ ] Schedule pod to specific node via `nodeName`
- [ ] Same via `nodeSelector`
- [ ] Same via `nodeAffinity` (required + preferred)
- [ ] Add taint to node, observe pods can't schedule
- [ ] Add toleration to pod, observe it now schedules
- [ ] Static pod via kubelet manifests path (`/etc/kubernetes/manifests/`)

## Week 3 Checkpoint

- [ ] Explain in 30 seconds: difference between nodeSelector, affinity, taints
- [ ] Apply NoExecute taint and observe existing pods evicted
- [ ] Identify a static pod via name suffix

## Insights

<!-- Add as you go -->
