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

---

## Repository Structure

```
cka-prep/
├── README.md            ← this file (plan + progress)
├── progress.md          ← daily training log
├── cheatsheet.md        ← personal cheatsheet (grows over time)
├── kind-config.yaml     ← local lab cluster config
├── notes/               ← weekly study notes
│   ├── week-01-architecture.md
│   ├── week-02-workloads.md
│   └── ...
├── manifests/           ← YAML manifests from labs
└── drills/              ← daily kubectl drill scripts
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
