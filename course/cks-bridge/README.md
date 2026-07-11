# CKA → CKS Bridge / Roadmap

> Roadmap/orientation only — build the full CKS course after passing CKA.

This module assumes you hold CKA-level knowledge (or are days from the exam). It is **not** a CKS course. It is an accurate map of what changes when you cross from "make it run" (CKA) to "make it safe" (CKS): the exam contract, the domains, the CKA knowledge you carry forward, the tools that are net-new, a set of hands-on primers to run on the kind lab, and a dated Aug→Dec 2026 study plan that plugs into this repo.

Every weight, allowed-docs URL, and exam parameter below **must be re-verified on the live curriculum** before you rely on it. CNCF revises these between exam versions:

- Curriculum + weights: **https://github.com/cncf/curriculum** (the `CKS_Curriculum_*.pdf` for the version you're sitting)
- Program handbook + exam rules: **https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist-cks/**

Lab target for every primer here: **kind, Kubernetes v1.36**. CKS itself tracks a slightly older pinned version — check which k8s version the current CKS exam runs, because AppArmor/seccomp/admission field names and defaults move between minors.

---

## 1. What CKS is, and the gate to sit it

CKS = **Certified Kubernetes Security Specialist**. Performance-based, hands-on, same Remote-Desktop/PSI environment and same `kubectl`-in-a-terminal muscle memory as CKA.

**Hard prerequisite — the one that surprises people:** you must hold a **current, non-expired CKA** at the moment you take CKS. CKA is not a co-requisite you can clear later; if your CKA has lapsed, you cannot sit CKS. Plan the CKS date to fall inside your CKA validity window. (Your CKA sitting is 2026-08-17, so a 2026-12-14 CKS target is safely inside the window — confirm the exact CKA validity duration on your certificate.)

| Parameter | Value (verify on the live handbook) |
|---|---|
| Format | Performance-based, live cluster(s) in a browser terminal |
| Duration | **2 hours** |
| Tasks | ~15–20 weighted performance tasks |
| Passing score | **67%** (note: CKA is 66% — CKS is one point higher) |
| Prerequisite | Active/valid **CKA** required to register/sit |
| Retake | One free retake included (confirm current policy) |
| Cert validity | Confirm current duration on the handbook |

**Allowed documentation during the exam.** CKS is stricter and *more* generous than CKA at the same time: still only `kubernetes.io/docs` (and its subdomains, e.g. `kubernetes.io/blog`) for core docs, **plus** a short allow-list of tool docs. Historically that extra list has been:

- **Trivy** — `https://aquasecurity.github.io/trivy/` (docs have been moving to `https://trivy.dev/` — confirm which host the exam allows)
- **Falco** — `https://falco.org/docs/`
- **AppArmor** — `https://gitlab.com/apparmor/apparmor/-/wikis/Documentation` (and/or `https://apparmor.net/`)

Treat that list as **subject to change** — re-read the current "allowed resources" section of the CKS handbook before exam day. You may not open general Google, GitHub source, blogs outside kubernetes.io, or your own notes. Bookmark the exact allowed pages in the exam browser before the clock starts.

---

## 2. The domains

CKS has six domains. The **names** are stable; the **weights** drift between curriculum versions, so the table below shows the long-standing weighting **only as a planning shape** — confirm the live numbers on the CNCF curriculum PDF and correct this table before you build a plan around it.

| # | Domain | Long-standing weight (VERIFY) | What it demands of you |
|---|---|---|---|
| 1 | **Cluster Setup** | ~10% | Default-deny NetworkPolicy, Ingress with TLS, CIS-benchmark the control plane (kube-bench), protect node metadata/endpoints, verify platform binaries |
| 2 | **Cluster Hardening** | ~15% | Minimize RBAC, restrict/secure API access, disable default ServiceAccount token automount, keep k8s upgraded, harden kubelet |
| 3 | **System Hardening** | ~15% | Minimize host OS footprint & IAM, kernel hardening, **AppArmor**, **seccomp**, restrict syscalls, remove obsolete packages/services |
| 4 | **Minimize Microservice Vulnerabilities** | ~20% | securityContext + Pod Security Admission (restricted), admission policy (OPA Gatekeeper / Kyverno), managed secrets, mTLS, **runtime sandboxing (gVisor/Kata)** |
| 5 | **Supply Chain Security** | ~20% | Minimize base-image footprint, scan images (Trivy), sign/verify images (cosign/sigstore), whitelist registries via admission, static-analyse manifests (kubesec/kube-linter), SBOM awareness |
| 6 | **Monitoring, Logging & Runtime Security** | ~20% | Behavioral detection at the syscall level (**Falco**), API-server **audit logging**, detect malicious activity, enforce container immutability at runtime |

Reality of the split for prep: domains **4, 5, 6** together are the bulk of the exam and the bulk of the *net-new* material. Domains 1–3 lean hardest on things CKA already trained.

---

## 3. The CKA → CKS delta

CKS is not a fresh start. About half of it is CKA concepts turned up to enforcement grade. Know precisely which half so you don't re-study what you own.

### Already yours from CKA (deepen, don't relearn)

| CKA capability | How CKS pushes it further |
|---|---|
| **RBAC** (Roles, bindings, `kubectl auth can-i`) | Now about *minimization*: no wildcard verbs, no `cluster-admin` handed out, aggregate carefully, audit who can escalate |
| **NetworkPolicy** (authoring) | Now **default-deny** first, then least-privilege ingress **and egress**, including DNS egress carve-outs |
| **Pod Security Admission** (labels, modes) | Now enforce **restricted** by default and know exactly why a pod is rejected |
| **securityContext** (`runAsNonRoot`, caps, `allowPrivilegeEscalation`) | Now also `readOnlyRootFilesystem`, drop-ALL capabilities, plus the new `seccompProfile` and `appArmorProfile` fields |
| **ServiceAccounts** | Now `automountServiceAccountToken: false`, projected/bound tokens, audience scoping, delete unused default-SA rights |
| **Static pods / editing apiserver manifest** | Same file (`/etc/kubernetes/manifests/kube-apiserver.yaml`), new flags: audit policy, admission plugins, `--anonymous-auth`, encryption provider |
| **etcd backup/restore** | Now **encryption at rest** for Secrets (`EncryptionConfiguration`), and securing etcd peer/client TLS |
| **kubeadm cluster ops** | Now CIS-benchmark that same cluster and remediate findings |

### Net-new — must be learned fresh

- **Runtime security & syscall-level detection** — Falco (rules, drivers, alerts). No CKA analogue.
- **Vulnerability & misconfig scanning** — Trivy (`image`/`fs`/`k8s`), kubesec, kube-linter.
- **CIS auditing tooling** — kube-bench, and reading its remediation output.
- **Host/OS + kernel hardening** — AppArmor profiles, custom seccomp profiles, minimizing services, kernel-module restriction.
- **Runtime sandboxing** — gVisor (`runsc`) / Kata via **RuntimeClass**.
- **Policy-as-admission engines** — OPA Gatekeeper (ConstraintTemplate/Constraint) and/or Kyverno (ClusterPolicy).
- **API-server audit logging** — audit `Policy` object, `--audit-policy-file` / `--audit-log-path`.
- **Supply-chain trust** — image signing/verification (cosign/sigstore), registry allow-listing at admission, `ImagePolicyWebhook`, SBOM concepts.
- **Secrets encryption at rest** — `EncryptionConfiguration`, provider ordering, optional KMS.

Rule of thumb: if it lives in `securityContext`, RBAC, NetworkPolicy, PSA, or the apiserver manifest, you already have the reflex — CKS just raises the bar. Everything with its own binary (falco, trivy, kube-bench, cosign, kyverno, apparmor_parser) is new surface to drill.

---

## 4. The new toolchain — orientation + one canonical pattern each

For each tool: what it is, why CKS cares, and the single command/manifest pattern to burn into memory. Command patterns are shown in `text` fences (illustrative); complete, apply-ready manifests are in valid `yaml` fences.

### Falco — runtime threat detection
Userspace agent that taps kernel syscalls (via eBPF or a kernel module) and fires alerts when runtime behavior matches a rule (e.g. a shell spawned in a container, a write to `/etc`, an unexpected outbound connection). Rules live in `falco_rules.yaml` + your `falco_rules.local.yaml`. This is the whole of "detect malicious activity at runtime."

```text
# read the shipped + local rules, watch syscalls, print alerts
falco -r /etc/falco/falco_rules.yaml -r /etc/falco/falco_rules.local.yaml
# alerts land in stdout / syslog / a file, depending on falco.yaml outputs
```

### Trivy — image / filesystem / cluster scanning
Aqua's scanner for CVEs, misconfigurations, secrets, and licenses. In CKS you use it to answer "which of these images has a CRITICAL vuln?" under time pressure. Know the three targets cold.

```text
trivy image --severity HIGH,CRITICAL nginx:1.29        # a container image
trivy fs --scanners vuln,secret,misconfig ./app        # a local directory
trivy k8s --report summary cluster                     # live cluster resources
```

### kube-bench — CIS Kubernetes Benchmark
Runs the CIS checks against a node and reports PASS/FAIL/WARN with remediation text you paste into the apiserver/kubelet config. Usually run as a Job/pod on the node.

```text
kube-bench run --targets master        # or: node, etcd, policies
```

### kube-linter / kubesec — static manifest analysis
Pre-deploy linters that score/flag insecure manifest patterns (running as root, no resource limits, writable rootfs, privilege escalation). Cheap "make it safe before it ships" checks.

```text
kube-linter lint deployment.yaml       # policy-based linter (StackRox)
kubesec scan pod.yaml                  # risk score + rationale (JSON)
```

### AppArmor — mandatory access control profiles
Linux LSM that confines a process's file/capability/network access via a named profile loaded on the node. In CKS you load a profile on the node and attach it to a container. The old `container.apparmor.security.beta.kubernetes.io/<container>` **annotation is legacy/deprecated**; the canonical way on modern k8s (field went GA ~v1.31) is the `securityContext.appArmorProfile` field.

```text
# load/replace a profile on the node
apparmor_parser -r -W /etc/apparmor.d/k8s-apparmor-example-deny-write
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: apparmor-demo
spec:
  containers:
  - name: app
    image: nginx:1.29
    securityContext:
      appArmorProfile:
        type: Localhost
        localhostProfile: k8s-apparmor-example-deny-write
```

### seccomp — syscall filtering
Restricts which syscalls a container may make. `RuntimeDefault` uses the container runtime's curated profile (the easy, high-value answer). Custom `Localhost` profiles are JSON files under `/var/lib/kubelet/seccomp/`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-default
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: nginx:1.29
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-custom
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/audit.json
  containers:
  - name: app
    image: nginx:1.29
```

(The kubelet flag `--seccomp-default` makes `RuntimeDefault` the cluster-wide default — worth knowing, not required to enable in-exam.)

### gVisor / runsc — runtime sandboxing via RuntimeClass
gVisor (`runsc` handler) intercepts syscalls in a userspace kernel, shrinking the host attack surface for untrusted workloads. Selected per-pod through a `RuntimeClass`. **kind limitation:** gVisor generally does not run inside kind's containerized nodes — treat this as read-and-understand on the lab, hands-on only on a real node/VM.

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sandboxed
spec:
  runtimeClassName: gvisor
  containers:
  - name: app
    image: nginx:1.29
```

### OPA Gatekeeper / Kyverno — policy as admission control
Validating (and mutating) admission engines that enforce org policy at apiserver admission time — "no privileged pods," "images only from `registry.internal`," "every pod needs a label." **Kyverno** uses `ClusterPolicy` (YAML, no Rego). **Gatekeeper** uses a `ConstraintTemplate` (Rego) + a `Constraint`. Know at least one well; Kyverno is usually faster to write under time pressure.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: privileged-containers
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      message: "Privileged mode is disallowed."
      pattern:
        spec:
          containers:
          - name: "*"
            securityContext:
              privileged: false
```

(In newer Kyverno, `validationFailureAction` moved under `spec.rules[].validate.failureAction` — confirm against the version you install.)

### API-server audit logging
Records who did what to the apiserver. You supply an audit `Policy` (levels: `None`/`Metadata`/`Request`/`RequestResponse`) and wire it into the apiserver static pod with flags + a hostPath mount for the log.

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: RequestResponse
  resources:
  - group: ""
    resources:
    - pods
- level: Metadata
  resources:
  - group: ""
    resources:
    - secrets
    - configmaps
- level: None
```

```text
# flags added to /etc/kubernetes/manifests/kube-apiserver.yaml
--audit-policy-file=/etc/kubernetes/audit/policy.yaml
--audit-log-path=/var/log/kubernetes/audit/audit.log
--audit-log-maxage=7
# plus a hostPath volume + volumeMount for both dirs, then wait for the apiserver pod to restart
```

### Image signing / verification — cosign (sigstore)
Sign images and verify signatures at deploy time, so only trusted images run. Verification is enforced either by cosign in CI or by an admission policy (Kyverno `verifyImages`, or Gatekeeper).

```text
cosign generate-key-pair
cosign sign   --key cosign.key registry.example.com/app:1.0
cosign verify --key cosign.pub registry.example.com/app:1.0
```

### Admission controllers — ImagePolicyWebhook & friends
Beyond policy engines, know the built-in admission plugins list on the apiserver (`--enable-admission-plugins=...`) and specifically **`ImagePolicyWebhook`**, which calls out to an external service to allow/deny images. Also relevant: `NodeRestriction`, `PodSecurity`, `AlwaysPullImages`.

```text
--enable-admission-plugins=NodeRestriction,PodSecurity,ImagePolicyWebhook
--admission-control-config-file=/etc/kubernetes/admission/config.yaml
```

### Secrets encryption at rest + SBOM awareness
Encrypt Secrets in etcd with an `EncryptionConfiguration` (provider order matters — first provider encrypts; `identity` last means "readable/no-op"). SBOM (Software Bill of Materials, CycloneDX/SPDX) is mostly awareness: know it lists an artifact's components and that Trivy/syft can generate one (`trivy image --format cyclonedx`).

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources:
  - secrets
  providers:
  - aescbc:
      keys:
      - name: key1
        secret: c2VjcmV0IG11c3QgYmUgZXhhY3RseSAzMiBieXRlcyE=
  - identity: {}
```

---

## 5. Hands-on primers to build on the kind lab (v1.36)

Short, do-them-this-week reps. Each is one clear objective + the one key command. Build these into `labs/` (mirror the CKA lab layout). Do them in a throwaway kind cluster you can `kind delete cluster && kind create cluster` freely.

1. **Enable an audit policy on the apiserver static pod.** Drop a `Policy`, add the two flags + hostPath mounts, watch the apiserver pod restart, then tail the log.
   `--audit-policy-file=/etc/kubernetes/audit/policy.yaml --audit-log-path=/var/log/kubernetes/audit/audit.log`
2. **Scan a local image with Trivy.** Pull/build something, then read the CRITICALs.
   `trivy image --severity HIGH,CRITICAL nginx:1.29`
3. **Run a seccomp `RuntimeDefault` pod, then a custom profile.** Apply the two seccomp manifests from §4; for the custom one, place the JSON at `/var/lib/kubelet/seccomp/profiles/audit.json` on the node.
   `kubectl apply -f seccomp-default.yaml && kubectl get pod seccomp-default`
4. **Attach an AppArmor profile.** Load a deny-write profile on the node, apply the `appArmorProfile` pod, prove the write is blocked.
   `apparmor_parser -r -W /etc/apparmor.d/k8s-apparmor-example-deny-write`
5. **Install Falco and trigger a rule.** Install (Helm/DaemonSet), then `kubectl exec` a shell into a pod and confirm Falco fires "Terminal shell in container."
   `kubectl exec -it <pod> -- sh   # then check Falco output/logs`
6. **Install Kyverno and enforce disallow-privileged.** Apply the `ClusterPolicy` from §4, then try to create a privileged pod and watch admission reject it.
   `kubectl apply -f disallow-privileged.yaml && kubectl run bad --image=nginx:1.29 --privileged`
7. **Set up a RuntimeClass for gVisor.** Create the `RuntimeClass` and a pod referencing it. **Expect it to fail to actually sandbox inside kind** — the exercise is the wiring + knowing the kind limitation; verify the mechanism on a real VM if you want a green pod.
   `kubectl apply -f runtimeclass-gvisor.yaml`

Bonus reps once the seven are automatic: `kube-bench run --targets master`, `EncryptionConfiguration` for Secrets (then `etcdctl get` to prove ciphertext), default-deny NetworkPolicy + DNS egress carve-out, `cosign sign`/`verify` against a local registry.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```

---

## 6. Study plan — Aug → Dec 2026

Anchors: **CKA exam 2026-08-17**, **CKS target 2026-12-14**. That's ~17 weeks. Shape: one recovery/gap week, ~14 domain weeks, two killer.sh weeks, exam. **killer.sh bundles two CKS simulator sessions with the exam purchase** — spend them near the end, exactly as you're doing for CKA.

| Dates (2026) | Phase | Focus |
|---|---|---|
| Aug 18 – Aug 23 | **Recovery + gap week** | Rest post-CKA. Read the current CKS curriculum PDF, correct the §2 weights, stand up the kind v1.36 CKS lab, bookmark the allowed docs, scaffold `course/cks-week01…` dirs |
| Aug 24 – Aug 30 | Cluster Setup ①  | Default-deny NetworkPolicy, least-privilege ingress/egress + DNS, Ingress TLS |
| Aug 31 – Sep 06 | Cluster Setup ②  | kube-bench / CIS remediation, protect node metadata, verify platform binaries |
| Sep 07 – Sep 13 | Cluster Hardening ① | RBAC minimization, kill default-SA token automount, bound/projected tokens |
| Sep 14 – Sep 20 | Cluster Hardening ② | Admission plugins, restrict/upgrade cluster, `--anonymous-auth`, kubelet hardening |
| Sep 21 – Sep 27 | System Hardening ① | seccomp: `RuntimeDefault` + custom profiles |
| Sep 28 – Oct 04 | System Hardening ② | AppArmor profiles, kernel/OS minimization, service/module restriction |
| Oct 05 – Oct 11 | Microservice Vuln ① | securityContext hard mode, PSA `restricted`, decode rejections |
| Oct 12 – Oct 18 | Microservice Vuln ② | Kyverno / Gatekeeper admission policies |
| Oct 19 – Oct 25 | Microservice Vuln ③ | gVisor/RuntimeClass, Secrets encryption at rest, mTLS awareness |
| Oct 26 – Nov 01 | Supply Chain ① | Trivy `image`/`fs`/`k8s`, minimal base images |
| Nov 02 – Nov 08 | Supply Chain ② | cosign sign/verify, registry allow-listing at admission, kubesec/kube-linter, SBOM |
| Nov 09 – Nov 15 | Monitoring/Runtime ① | API-server audit logging end-to-end |
| Nov 16 – Nov 22 | Monitoring/Runtime ② | Falco rules + runtime detection, container immutability |
| Nov 23 – Nov 29 | **Integration week** | Mixed cross-domain timed drills; speed reps on all tool binaries |
| Nov 30 – Dec 06 | **killer.sh session 1** | Full simulator, debrief, triage weakest domains, re-drill |
| Dec 07 – Dec 13 | **killer.sh session 2** + taper | Second simulator, close remaining gaps, taper reps, prep exam-day setup |
| **Dec 14** | **CKS exam** | — |

If Aug/Sep slips, compress the two-part domain weeks before you ever compress the killer.sh weeks — the simulator is the single highest-signal input, same as your CKA plan treats it.

### Repo layout to grow into

Mirror the CKA course structure so the CKS build feels identical to work in. Suggested (build after passing CKA):

```text
course/
  cks-bridge/            # this module
  cks-week01-cluster-setup/
    masterclass.md
    exercises.md
  cks-week02-cluster-setup-cis/
  cks-week03-hardening-rbac/
  ...
  cks-week14-integration/
labs/
  cks/                   # the seven §5 primers, scripted for kind v1.36
mock-exams/
  cks-killer-debrief.md
```

Each `cks-weekNN` gets the same `masterclass.md` + `exercises.md` pair the CKA weeks use — one conceptual deep-dive, one set of timed reps.

---

## 7. What's actually different in the exam room

The mental-model shift is the whole point: CKA rewards **"make it work"**; CKS rewards **"make it safe."** Concretely:

- **More reading/editing than authoring.** Many CKS tasks hand you an *existing* insecure manifest, apiserver config, or policy and ask you to *fix* it — tighten a securityContext, close a NetworkPolicy, remove a privileged flag. You edit far more than you write from scratch.
- **Scanners under the clock.** Expect tasks that are literally "run Trivy, find the image with a CRITICAL, delete/replace the offending Deployment." Fluency with `trivy image`, output filtering, and fast triage directly scores points.
- **Multi-step, verify-your-own-work tasks.** Enable audit logging *and* prove an event landed; load an AppArmor profile *and* prove the write is denied. Half-finished ≠ scored — build the "confirm it actually blocks" step into your reflex.
- **Same survival rules as CKA, higher stakes.** Right context per task (silent zero if wrong), partial credit is real, `--dry-run=client -o yaml` scaffolds still save time, and the allowed-docs set is smaller — pre-bookmark Falco/Trivy/AppArmor/k8s pages before the timer starts.
- **The reflex to retrain:** at CKA you asked "does the pod run?" At CKS ask "what can this pod reach, become, or call — and what stops it?" Every task is a least-privilege / attack-surface question wearing a kubectl prompt.

---

*Re-verify §1 exam parameters, §2 weights, and the §4 allowed-docs list against the live CNCF/Linux Foundation pages before trusting any number here. Then delete this bridge's placeholder status by building `course/cks-weekNN/` for real — after CKA is in the bag.*
