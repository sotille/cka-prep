# Week 2 (Jun 15–21) — Workloads + Configuration

> 📚 **Deep module:** [masterclass](../course/week-02-workloads-config/masterclass.md) · [exercises](../course/week-02-workloads-config/exercises.md)

**Goal:** Master ConfigMaps, Secrets, environment variables, resource limits.

**Time budget:** 17h

---

## Topics

- [ ] ConfigMaps: 4 ways to consume (env, envFrom, volume, command args)
- [ ] Secrets: same 4 ways + base64 mechanics
- [ ] Resource Requests vs Limits
- [ ] QoS classes (Guaranteed, Burstable, BestEffort)
- [ ] Multi-container patterns: sidecar, init container, ambassador
- [ ] SecurityContext at pod and container level
- [ ] Pod priority + preemption (light intro)

## Mumshad Sections

- Section 4 — Logging & Monitoring (partial)
- Section 5 — Application Lifecycle (partial)
- Configuration sections

## Hands-On Labs

- [ ] Mount ConfigMap as env var
- [ ] Mount ConfigMap as volume
- [ ] Create Secret from literal, from file, from yaml
- [ ] Deploy pod with init container that waits for service
- [ ] Set resource limits and observe QoS class

## Week 2 Checkpoint

By Sunday Jun 21:
- [ ] Mount a Secret as env var AND as volume in under 2 min
- [ ] Explain difference between `env.valueFrom` and `envFrom`
- [ ] Create an initContainer that blocks until DB is ready

## Insights

<!-- Add as you go -->
