# CKA + CKS Preparation Journey

> Public study log for the **Certified Kubernetes Administrator (CKA)** and **Certified Kubernetes Security Specialist (CKS)** certifications.
> Maintained by [Felipe Sotille](https://linkedin.com/in/Felipe-Sotille/) — Senior DevSecOps Engineer at SWIFT.

---

## Goals

| Cert | Target Date | Status |
|---|---|---|
| **CKA** (Certified Kubernetes Administrator) | August 17, 2026 | 🟡 In progress |
| **CKS** (Certified Kubernetes Security Specialist) | December 14, 2026 | ⚪ Not started |

---

## 10-Week CKA Plan

| Week | Dates | Focus | Status |
|---|---|---|---|
| 1 | Jun 8 – Jun 14 | Core concepts + Architecture | ⚪ |
| 2 | Jun 15 – Jun 21 | Workloads + Configuration | ⚪ |
| 3 | Jun 22 – Jun 28 | Scheduling | ⚪ |
| 4 | Jun 29 – Jul 5 | Logging, Monitoring, Lifecycle | ⚪ |
| 5 | Jul 6 – Jul 12 | Cluster Maintenance (etcd, upgrade) | ⚪ |
| 6 | Jul 13 – Jul 19 | Security + RBAC | ⚪ |
| 7 | Jul 20 – Jul 26 | Storage | ⚪ |
| 8 | Jul 27 – Aug 2 | Networking (the trap) | ⚪ |
| 9 | Aug 3 – Aug 9 | killer.sh Simulator #1 | ⚪ |
| 10 | Aug 10 – Aug 16 | killer.sh #2 + Polish | ⚪ |
| **🎯** | **Aug 17** | **CKA Exam** | ⚪ |

Legend: ⚪ pending · 🟡 in progress · ✅ done

> ⚠️ **Curriculum note (read first):** the week labels above and the `notes/` files were written against the **pre-Feb-2025** CKA. The exam was restructured on **Feb 18, 2025**. Current domain weights: **Troubleshooting 30%, Cluster Architecture 25%, Services & Networking 20%, Workloads & Scheduling 15%, Storage 10%** — *Troubleshooting*, not Networking, is the 30% domain. New topics added in 2025: Helm, Kustomize, Gateway API, CRDs/operators, dynamic provisioning, CNI/CSI/CRI awareness. The deep course below is aligned to the current curriculum; start with the [Exam Masterclass](course/00-exam-masterclass.md).

---

## 📘 The Deep Course

Deep-dive masterclasses (internals, failure modes, exam traps, speed patterns) + exam-style exercises with full worked solutions, break-and-fix labs, three timed mock exams with an **auto-grader**, daily speed drills, flashcards, and a **basic → advanced learning path**. Content is exam-current; the `notes/` files remain as a personal daily-log skeleton and each links to its deep module.

**The ramp (basic → advanced → exam-ready):**
1. **[Take the diagnostic](course/diagnostic.md)** (45 min, timed) — find your baseline; it routes you to the right starting tier.
2. **[Follow the Learning Path](course/LEARNING-PATH.md)** — the tiered spine: Fundamentals → Core → Advanced → Troubleshooting → Simulation, with prerequisites and per-tier instructions. Every masterclass has a prev/next nav line.
3. **[Read the Exam Masterclass](course/00-exam-masterclass.md)** — passing mechanics: domain weights, PSI environment, time-triage, question-pattern recipes, docs-navigation, 6-week countdown, coverage map.

Daily, from the first module on: **[flashcards](drills/flashcards.md)** (active recall, 160 cards; [Anki CSV](drills/flashcards.csv)) and the **[mastery tracker](progress/mastery-tracker.md)** (mark every competency 🔴/🟡/🟢).

| # | Module | Domain (weight) | Masterclass | Exercises |
|---|---|---|---|---|
| 0 | **Fundamentals & lab bootstrap** (entry ramp) | speed foundation | [masterclass](course/week-00-fundamentals/masterclass.md) | [exercises](course/week-00-fundamentals/exercises.md) |
| 1 | Architecture & API machinery | Cluster Arch (25%) | [masterclass](course/week-01-architecture/masterclass.md) | [exercises](course/week-01-architecture/exercises.md) |
| 2 | Workloads, Config, Helm & Kustomize | Workloads (15%) | [masterclass](course/week-02-workloads-config/masterclass.md) | [exercises](course/week-02-workloads-config/exercises.md) |
| 3 | Scheduling | Workloads (15%) | [masterclass](course/week-03-scheduling/masterclass.md) | [exercises](course/week-03-scheduling/exercises.md) |
| 4 | Lifecycle & Observability | Troubleshooting (30%) | [masterclass](course/week-04-lifecycle-observability/masterclass.md) | [exercises](course/week-04-lifecycle-observability/exercises.md) |
| 5 | Cluster Maintenance (kubeadm, etcd) | Cluster Arch (25%) | [masterclass](course/week-05-cluster-maintenance/masterclass.md) | [exercises](course/week-05-cluster-maintenance/exercises.md) |
| 6 | Security & RBAC | Cluster Arch (25%) | [masterclass](course/week-06-security-rbac/masterclass.md) | [exercises](course/week-06-security-rbac/exercises.md) |
| 7 | Storage | Storage (10%) | [masterclass](course/week-07-storage/masterclass.md) | [exercises](course/week-07-storage/exercises.md) |
| 8 | Services & Networking (+ Gateway API) | Networking (20%) | [masterclass](course/week-08-networking/masterclass.md) | [exercises](course/week-08-networking/exercises.md) |
| 9 | **Troubleshooting** ⭐ | Troubleshooting (30%) | [masterclass](course/week-09-troubleshooting/masterclass.md) | [exercises](course/week-09-troubleshooting/exercises.md) |
| 10 | Final Prep & killer.sh protocol | exam strategy | [masterclass](course/week-10-final-prep/masterclass.md) | [speed drills](drills/speed-drills.md) |

### Break-and-fix labs

Scripts that intentionally break the kind lab cluster so you practice diagnosis under the clock. Run one, diagnose, fix — then check yourself.

- [labs/breakfix/SOLUTIONS.md](labs/breakfix/SOLUTIONS.md) — diagnosis walkthrough + fix + restore for each
- 8 scenarios: [node NotReady](labs/breakfix/break-01-node-notready.sh) · [CNI not ready](labs/breakfix/break-02-node-network-not-ready.sh) · [pods Pending](labs/breakfix/break-03-pods-stay-pending.sh) · [DNS dead](labs/breakfix/break-04-dns-dead.sh) · [app unreachable](labs/breakfix/break-05-app-unreachable.sh) · [PVC never binds](labs/breakfix/break-06-pvc-never-binds.sh) · [new services dead](labs/breakfix/break-07-new-services-dead.sh) · [kubeconfig refuses](labs/breakfix/break-08-kubeconfig-refuses.sh)

### Mock exams (2 h each, self-graded, 66 % to pass)

| Exam | Difficulty | Paper | Solutions + rubric | Setup |
|---|---|---|---|---|
| 1 | Confidence-builder | [mock-exam-1.md](mock-exams/mock-exam-1.md) | [solutions](mock-exams/mock-exam-1-solutions.md) | [setup.sh](mock-exams/mock-exam-1-setup.sh) |
| 2 | True exam level | [mock-exam-2.md](mock-exams/mock-exam-2.md) | [solutions](mock-exams/mock-exam-2-solutions.md) | [setup.sh](mock-exams/mock-exam-2-setup.sh) |
| 3 | killer.sh-hard | [mock-exam-3.md](mock-exams/mock-exam-3.md) | [solutions](mock-exams/mock-exam-3-solutions.md) | [setup.sh](mock-exams/mock-exam-3-setup.sh) |

Each mock has a blind setup script (run it first, don't read it — it seeds the broken/pre-existing resources), per-task weights summing to 100 % across the five domains, and a solutions file with full YAML + partial-credit rubric.

**Run a mock like the real thing** — seed + 2-hour timer, then auto-grade on final cluster state:

```bash
mock/run.sh 2       # seeds mock 2 and starts the 120-min countdown
mock/grade.sh 2     # scores it on final state: per-check ✓/✗, domain subtotals, total vs 66%
```

The grader ([`mock/grade.sh`](mock/grade.sh)) checks the real end-state of every task (objects, fields, endpoints, files) and prints a weighted score by domain. Mock 3 is killer-calibrated (pass line 55).

### Lab automation

Stop hand-plumbing the lab — these set it up so lab time goes to practice:

- [`labs/setup/bootstrap-cluster.sh`](labs/setup/bootstrap-cluster.sh) — create the 3-node kind cluster `cka` if missing
- [`labs/setup/install-addons.sh`](labs/setup/install-addons.sh) — metrics-server, ingress-nginx, Gateway API CRDs (idempotent)
- [`labs/setup/reset-cluster.sh`](labs/setup/reset-cluster.sh) — fast reset between labs (drops lab namespaces, repairs injected node faults)
- [`labs/setup/calico-netpol-cluster.sh`](labs/setup/calico-netpol-cluster.sh) — a **second** cluster that actually *enforces* NetworkPolicy (kindnet doesn't), for real netpol testing

### After CKA → CKS

[course/cks-bridge](course/cks-bridge/README.md) — roadmap into the Certified Kubernetes Security Specialist: what carries over, what's net-new (Falco, Trivy, kube-bench, AppArmor/seccomp, gVisor, Kyverno, audit logging, image signing), and a dated Aug→Dec 2026 plan.

Validate all course YAML/scripts anytime with [`scripts/validate-course.sh`](scripts/validate-course.sh) (181 YAML blocks + 24 shell scripts).

---

## Repository Structure

```
cka-prep/
├── README.md            ← this file (plan + course index + progress)
├── progress.md          ← daily training log
├── cheatsheet.md        ← personal kubectl cheatsheet (grows over time)
├── kind-config.yaml     ← local lab cluster config
├── course/              ← 📘 the deep course
│   ├── diagnostic.md                   ← placement test (take first)
│   ├── LEARNING-PATH.md                ← tiered basic→advanced spine
│   ├── 00-exam-masterclass.md          ← passing mechanics + coverage map
│   ├── week-00-fundamentals/           ← entry ramp (kubectl/YAML speed)
│   ├── week-01..10-*/                  ← masterclass.md + exercises.md per module
│   └── cks-bridge/                     ← roadmap into CKS
├── mock-exams/          ← 3 timed mock exams (paper + solutions + setup script)
├── mock/                ← simulator: run.sh (seed+timer) + grade.sh (auto-grader)
├── labs/
│   ├── setup/           ← bootstrap / reset / addons / calico-netpol automation
│   └── breakfix/        ← break-the-cluster scenarios + SOLUTIONS.md
├── drills/              ← speed-drills.md + flashcards.md/.csv + daily drill scripts
├── progress/            ← mastery-tracker.md (per-competency 🔴/🟡/🟢)
├── scripts/             ← validate-course.sh + add-nav.rb
├── notes/               ← weekly study-log skeletons (link to each module)
│   ├── week-01-architecture.md
│   ├── week-02-workloads.md
│   └── ...
└── manifests/           ← YAML manifests from labs
```

---

## Lab Setup

Local 3-node cluster via [kind](https://kind.sigs.k8s.io/):

```bash
kind create cluster --name cka --config kind-config.yaml
kubectl get nodes
```

---

## Resources

### Primary
- 🥇 [Mumshad Mannambeth's CKA course](https://www.udemy.com/course/certified-kubernetes-administrator-with-practice-tests/) (Udemy)
- 🥇 [killer.sh](https://killer.sh) (bundled with exam — 2 attempts, 36h each)
- 🥇 [Kubernetes official docs](https://kubernetes.io/docs) (allowed during exam)

### Secondary
- [Killercoda free scenarios](https://killercoda.com)
- [@walidshaari/Kubernetes-Certified-Administrator](https://github.com/walidshaari/Kubernetes-Certified-Administrator)
- [kube.academy](https://kube.academy)

---

## Why This Matters

This repo serves three purposes:

1. **Personal accountability** — public commitment to the 18-month roadmap
2. **Knowledge consolidation** — writing things down beats passive consumption
3. **Career artifact** — evidence of continuous technical investment and supply-chain security expertise

---

## License

MIT — feel free to fork and adapt for your own CKA/CKS journey.
