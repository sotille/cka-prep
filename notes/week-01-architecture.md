# Week 1 (Jun 8–14) — Core Concepts + Architecture

> 📚 **Deep module:** [masterclass](../course/week-01-architecture/masterclass.md) · [exercises](../course/week-01-architecture/exercises.md)

**Goal:** Be fluent in kubectl basics. Understand control plane components.

**Time budget:** 15h

---

## Topics

- [ ] Kubernetes architecture: control plane components (kube-apiserver, etcd, kube-scheduler, controller-manager)
- [ ] Node components: kubelet, kube-proxy, container runtime
- [ ] kubectl basics: get, describe, create, delete, apply
- [ ] Namespaces
- [ ] Pods: lifecycle, multi-container basics
- [ ] ReplicaSets and Deployments
- [ ] kubectl run / create with --dry-run

## Mumshad Sections to Cover

- Section 1 — Core Concepts
- Section 2 — Cluster Architecture
- Section 3 — kubectl

## Hands-On Labs

- [ ] Boot kind 3-node cluster
- [ ] Inspect control plane pods in kube-system namespace
- [ ] Create deployments and scale them
- [ ] Run a rolling update + rollback
- [ ] Delete a node and observe behavior

## Week 1 Checkpoint

By Sunday Jun 14 I can, in under 2 minutes without doc lookup:
- [ ] Create a deployment via CLI
- [ ] Scale it up/down
- [ ] Roll out a new image version
- [ ] Rollback the deployment

## Insights / Aha Moments

<!-- Add as you go -->
