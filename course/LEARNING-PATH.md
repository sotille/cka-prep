# CKA Learning Path — basic → advanced → exam-ready

The spine that turns this repo from a pile of modules into a ramp. Follow the tiers in order; inside a tier, the module order is the study order. Every masterclass has a nav line at the top linking back here and to its neighbours.

> **Where do I start?** Take [the diagnostic](diagnostic.md) first (45 min, timed). Your score routes you to the right tier below instead of grinding material you already own.

---

## The ramp at a glance

| Tier | Modules | You leave the tier able to… |
|---|---|---|
| **0 · Fundamentals** | [week-00](week-00-fundamentals/masterclass.md) | drive kubectl at exam speed, write/repair YAML from memory, live in the imperative generators |
| **1 · Core objects** | [week-01](week-01-architecture/masterclass.md) → [week-02](week-02-workloads-config/masterclass.md) → [week-03](week-03-scheduling/masterclass.md) → [week-04](week-04-lifecycle-observability/masterclass.md) | model the control plane, ship/roll back workloads, place pods, read probes/logs/events |
| **2 · Advanced operations** | [week-05](week-05-cluster-maintenance/masterclass.md) → [week-06](week-06-security-rbac/masterclass.md) → [week-07](week-07-storage/masterclass.md) → [week-08](week-08-networking/masterclass.md) | upgrade a cluster, back up etcd, grant RBAC, bind storage, route and firewall traffic |
| **3 · Troubleshooting (30%)** | [week-09](week-09-troubleshooting/masterclass.md) + [labs/breakfix](../labs/breakfix/SOLUTIONS.md) | diagnose a broken cluster fast — the single biggest exam bucket |
| **4 · Simulation & polish** | [mock exams](../mock-exams/) · [speed drills](../drills/speed-drills.md) · [week-10](week-10-final-prep/masterclass.md) | finish a full 2-hour exam over 66% under time pressure |

Cross-cutting, every day from Tier 1 on: **[flashcards](../drills/flashcards.md)** (active recall) and the **[mastery tracker](../progress/mastery-tracker.md)** (mark each competency 🔴/🟡/🟢). Read **[the exam masterclass](00-exam-masterclass.md)** once at the start of Tier 1 and again in Tier 4.

---

## Prerequisites (what each tier assumes)

- **Tier 0** assumes only Linux/CLI comfort. If the diagnostic put you at 10+/15, skim it and move on.
- **Tier 1** assumes Tier 0 speed: you can `k create deploy … $do`, edit, and `apply` without thinking. Week 2 also assumes the Helm/Kustomize basics introduced there.
- **Tier 2** assumes Tier 1: you understand Pods/Deployments/Services and can read events. Week 5 needs the architecture model from week-01; week-08 builds on the Services intro from week-01/02.
- **Tier 3** assumes Tiers 1–2: you cannot diagnose what you cannot build. Troubleshooting is a *skill layered on top of* knowing the correct end-state.
- **Tier 4** assumes everything: mocks interleave all five domains and cluster-wide faults.

---

## How to run a tier

1. **Read** the module `masterclass.md` — internals, traps, speed patterns, then its Checkpoint.
2. **Bootstrap the lab** if needed: `labs/setup/bootstrap-cluster.sh` then `labs/setup/install-addons.sh`. For NetworkPolicy *enforcement* practice (week-08), `labs/setup/calico-netpol-cluster.sh`.
3. **Drill** the module `exercises.md` — timed, in order (warmup → exam → hard). Reset between attempts with `labs/setup/reset-cluster.sh`.
4. **Record** each competency in the [mastery tracker](../progress/mastery-tracker.md). A skill is 🟢 only when done correctly, under its time target, without docs.
5. **Recall** the tier's [flashcards](../drills/flashcards.md) sections daily (Leitner cadence: 🔴 next day, 🟡 in 3 days, 🟢 weekly).

## Gate to the exam

You are ready to book/sit when: every Troubleshooting (30%) and Cluster Architecture (25%) competency is 🟢, no domain has a 🔴, and you have cleared **mock-exam-2 ≥ 66%** under time and **mock-exam-3 ≥ 55%**. Then retake the [diagnostic](diagnostic.md) for a final confidence read (target 13+/15).

## After CKA

[course/cks-bridge](cks-bridge/README.md) maps the road to CKS (target Dec 2026): what carries over, what is net-new, and the tool/scanner layer to learn next.
