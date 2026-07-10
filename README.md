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

Deep-dive masterclasses (internals, failure modes, exam traps, speed patterns) + exam-style exercises with full worked solutions, break-and-fix labs, three timed mock exams, and daily speed drills. Content is exam-current; the `notes/` files remain as a personal daily-log skeleton and each links to its deep module.

**Start here → [Exam Masterclass: passing mechanics](course/00-exam-masterclass.md)** — domain weights, PSI exam environment, time-triage, question-pattern recipes, docs-navigation, 6-week countdown, and the full curriculum coverage map.

| # | Module | Domain (weight) | Masterclass | Exercises |
|---|---|---|---|---|
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

Validate all course YAML/scripts anytime with [`scripts/validate-course.sh`](scripts/validate-course.sh).

---

## Repository Structure

```
cka-prep/
├── README.md            ← this file (plan + course index + progress)
├── progress.md          ← daily training log
├── cheatsheet.md        ← personal kubectl cheatsheet (grows over time)
├── kind-config.yaml     ← local lab cluster config
├── course/              ← 📘 the deep course
│   ├── 00-exam-masterclass.md         ← passing mechanics + coverage map
│   └── week-01..10-*/                 ← masterclass.md + exercises.md per module
├── mock-exams/          ← 3 timed mock exams (paper + solutions + setup script)
├── labs/breakfix/       ← break-the-cluster scenarios + SOLUTIONS.md
├── drills/              ← speed-drills.md + daily drill scripts
├── scripts/             ← validate-course.sh (YAML + bash static checks)
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
