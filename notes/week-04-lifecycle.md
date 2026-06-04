# Week 4 (Jun 29–Jul 5) — Logging, Monitoring, Lifecycle

**Goal:** Probes, rollout strategies, debugging methodology.

**Time budget:** 15h

---

## Topics

- [ ] Liveness, Readiness, Startup probes
- [ ] httpGet / tcpSocket / exec probes
- [ ] Rolling updates (maxSurge, maxUnavailable)
- [ ] Recreate vs RollingUpdate strategies
- [ ] `kubectl rollout` (history, status, undo, restart)
- [ ] `kubectl logs` patterns (--previous, -c, multi-container)
- [ ] `kubectl top` + metrics-server
- [ ] App-level debugging methodology

## Hands-On Labs

- [ ] Deploy app with broken liveness probe → observe restart loop
- [ ] Deploy with broken readiness probe → observe pod Ready=false
- [ ] Roll out new image, rollback to previous
- [ ] Check rollout history
- [ ] Install metrics-server in kind, run `kubectl top`

## Debug Drill (chains together everything)

1. Pod won't start. Debug.
2. Pod runs but service can't reach it. Debug.
3. Service exists but DNS doesn't resolve. Debug.

## Week 4 Checkpoint

- [ ] Diagnose a broken pod (image pull error, probe fail, resource limit) in < 5 min
- [ ] Explain RollingUpdate vs Recreate
- [ ] Use `kubectl rollout undo` to specific revision

## Insights

<!-- Add as you go -->
