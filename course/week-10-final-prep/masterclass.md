# Week 10 — Final Prep: killer.sh Protocol, Taper, and Exam-Day Execution (meta-module — protects points in all domains: Troubleshooting 30%, Cluster Architecture 25%, Networking 20%, Workloads 15%, Storage 10%)

> 🧭 **Learning path:** [‹ week-09-troubleshooting](../week-09-troubleshooting/masterclass.md) · [Tier map](../LEARNING-PATH.md) · [Mock exams ›](../../mock-exams/)


This module is not about Kubernetes. It is about converting eight weeks of Kubernetes into a passing score. The failure mode it targets: candidates who can solve every task in this course untimed and still fail because they burned 25 minutes on task 3, answered task 7 in the wrong context, and panicked after killer.sh scored them 45%. Everything below assumes the timeline in your plan: **today = 2026-07-08 (plan week 5), exam day = 2026-08-17, killer.sh weeks = Aug 3–9 and Aug 10–16**.

Verify the current exam version and domain weights on the CNCF curriculum page before your killer.sh week — weights shift between curriculum revisions.

## What the exam actually asks

The exam never asks you to "manage time" — it just gives you 15–20 performance tasks, 120 minutes, and a 66% bar. The math below is the entire strategy. Assume ~16 tasks as a planning number:

| Domain | Weight | Expected tasks (of ~16) | Time budget | Point value insight |
|---|---|---|---|---|
| Troubleshooting | 30% | 4–6 | ~36 min | Highest ROI per minute of prep — these are the tasks killer.sh predicts worst, and the ones where a fixed diagnostic sequence saves you |
| Cluster Architecture, Installation & Configuration | 25% | 4–5 | ~30 min | etcd backup and RBAC are near-guaranteed; both are pure muscle memory |
| Services & Networking | 20% | 3–4 | ~24 min | NetworkPolicy and Gateway API/Ingress are YAML-heavy — the never-author-from-scratch rule matters most here |
| Workloads & Scheduling | 15% | 2–3 | ~18 min | Almost entirely imperative-command territory — should be your fastest points |
| Storage | 10% | 1–2 | ~12 min | Small, predictable, bankable |

Three scoring facts that shape everything in this module:

1. **Partial credit is real.** A task with 4 steps scores each step. Apply what you have even if the last step eludes you.
2. **Tasks are independent and weighted (weight shown per task, typically 4–13%).** Skipping the two hardest tasks entirely and acing the rest passes comfortably: 100% of 87% of tasks > 66%.
3. **Wrong context = silent zero.** Every task header tells you which context to switch to. This is the cheapest way to lose 7% and the most common self-inflicted wound.

## The program: where you are and what's left

| Dates | Plan week | Focus |
|---|---|---|
| Jul 6 – Aug 2 | Weeks 5–8 | Finish remaining course modules + exercises; start `drills/speed-drills.md` rotation in week 7 at the latest |
| Aug 3 – Aug 9 | Week 9 | **killer.sh session 1** + debrief + triage-driven drilling |
| Aug 10 – Aug 16 | Week 10 | **killer.sh session 2** (timed re-test), spaced repetition, taper |
| Aug 17 | Exam day | Execute |

## The killer.sh protocol

killer.sh is bundled with your exam registration: **two sessions, 36 hours of environment access each, and — the fact most people miss — both sessions contain the same questions.** That is not a bug; it is the design. Session 1 is the diagnostic, session 2 is the re-test. Wasting session 2 expecting new content throws away the most valuable feature of the product.

### Session 1 — the diagnostic (activate Saturday Aug 8, morning)

1. **Activate on a free morning.** The 36-hour clock starts at activation, not first use. Activating Saturday 09:00 gives you until Sunday ~21:00 — a full weekend of environment access. Do not activate on a work night.
2. **First 2 hours: simulate the real exam exactly.** One monitor. Timer set to 120 minutes, hard stop. Only kubernetes.io/docs, kubernetes.io/blog, helm.sh/docs open. No notes, no cheatsheet, no pausing. Use the killer.sh remote-desktop environment itself — it deliberately mimics the PSI Bridge terminal, including the copy/paste quirks. This is your only chance to rehearse the environment before the real thing.
3. **Score it honestly.** killer.sh shows per-task scoring. Log it (debrief method below) before you look at any solutions.
4. **Calibrate, don't panic.** killer.sh is intentionally harder than the real exam — more steps per task, tighter time, nastier setups. **Most people who go on to pass score 40–60% on their first killer.sh attempt.** A 45% here is on track. What predicts failure is not a low score; it is a low score with no debrief.
5. **Remaining ~34 hours: redo every task until fluent.** Read the provided solution for every task, including ones you got right — killer.sh solutions frequently show a faster path than yours. Redo each failed task from scratch (the environment has a reset). "Fluent" means: you can complete it without the solution open, within the time you budgeted for its domain.

### Session 2 — the re-test (activate Wednesday Aug 12, morning)

Same questions, so the goal changes: **you are no longer testing knowledge, you are testing mechanics under time.** Run it as a strict 2-hour timed exam. Target: 90–100%. If you score below ~85% on questions you have already seen and drilled, the gap is speed or environment handling, not knowledge — and the fix is circuit drilling (`drills/speed-drills.md`), not more reading. Use the rest of the 36h window to re-drill only the tasks that failed twice.

## The debrief method

A killer.sh attempt without a structured debrief is worth about a third of one with it. Within 2 hours of finishing session 1 (while you still remember *why* each task went wrong), fill a per-task log:

| Task # | Domain | Weight | Time spent | Result (0/partial/full) | Fail reason | Fix action |
|---|---|---|---|---|---|---|
| 1 | Troubleshooting | 7% | 11 min | partial | speed | drill circuit F daily |
| 2 | Networking | 7% | 9 min | 0 | knowledge | reread NetPol module + killercoda scenario |
| 3 | Cluster Arch | 4% | 6 min | 0 | misread | solved in wrong namespace — reading protocol |

**Fail reason taxonomy — be strict, pick exactly one:**

- **knowledge** — you did not know how. Fix: the relevant course module's masterclass section + redo its exercises + one matching killercoda scenario (killercoda.com/killer-shell-cka — free, browser-based, enforcing CNI, resets in seconds).
- **speed** — you knew how but ran out of time. Fix: the matching circuit in `drills/speed-drills.md`, daily, until two consecutive clean runs.
- **misread** — you solved a different problem than the one asked (wrong namespace, wrong object name, missed a constraint, wrong context). Fix: reading protocol — read the task twice, second pass extracting exactly: context, namespace, object names, constraints, verification criterion. Misreads are a process failure, not a knowledge failure; more studying will not fix them.

### The weak-area triage matrix

Collapse the log into a matrix and compute priority = (points lost in domain) × (fail count):

| Domain | knowledge | speed | misread | Points lost | Priority |
|---|---|---|---|---|---|
| Troubleshooting | 1 | 2 | 0 | 18% | 1 — drill circuit F + module exercises |
| Networking | 2 | 0 | 0 | 14% | 2 — reread module, killercoda netpol scenarios |
| Cluster Arch | 0 | 1 | 1 | 8% | 3 — circuit E + reading protocol |

Rule: **knowledge gaps in high-weight domains outrank everything else** — they are worth the most points and take the longest to close. Speed gaps close fast with circuits. Misreads close with process discipline and cost nothing to fix.

Days Aug 5–9 (after session 1) and Aug 10–11 are spent exclusively on the top two rows of this matrix. Do not "review everything" — review what the matrix says.

## Final week: day-by-day (Aug 10–16)

The principle is spaced repetition with a hard taper. Fitness science applies: you do not get stronger in the final 48 hours, you only get more tired. The plan front-loads effort and protects the last two days.

| Day | Load | Plan |
|---|---|---|
| Mon Aug 10 | ~2h | Triage-matrix drilling: top-2 weak domains from session 1 debrief. Circuit A (core objects, no docs) + weakest domain circuit. Redo the 3 worst killer.sh tasks from memory. |
| Tue Aug 11 | ~2h | Muscle-memory day: etcd backup + restore rehearsal, kubeadm upgrade sequence (read through on kind, execute the etcd part), full RBAC circuit E. These are the highest-certainty exam tasks — they must be reflexes. |
| Wed Aug 12 | 2h + log | **killer.sh session 2**: activate in the morning, strict 120-minute timed re-test of the same questions. Evening: fill the per-task log again, compare per-task times against session 1. |
| Thu Aug 13 | ~90 min | Inside the session-2 window: redo any task that failed twice. Then docs-map rehearsal: open every page in the docs-map table below from a cold Firefox start in under 30 seconds each. |
| Fri Aug 14 | ~1h, stop | One mixed circuit (circuit M) at full speed. One rehearsal of the first-5-minutes setup routine (module 00). Then stop. No new content from here on. |
| Sat Aug 15 | ~45 min | Logistics day: run the PSI system compatibility test **on the exact machine and network you will use**. Install/verify the PSI Secure Browser. Clear the desk, plan the room, check your ID against your registration name. Optional: one Circuit A run, 10 minutes, to stay warm. |
| Sun Aug 16 | ≤20 min | Rest. Optional morning warmup: aliases, two context switches, three jsonpath queries. Nothing after noon. No labs, no killer.sh, no docs reading. Prepare clothes/water/ID. Sleep 8 hours. |
| Aug 17 | — | **Exam day.** Protocol below. |

The taper feels wrong. It is not. Marginal knowledge gained on Aug 15–16 is worth less than the working-memory capacity and calm you lose acquiring it. Trust the eight weeks.

## Exam-day logistics (PSI Bridge)

The exam runs in PSI's Secure Browser on a remote XFCE desktop with Firefox — everything (terminal, docs browser) lives inside that remote desktop. Module 00 covers the in-environment mechanics; this section covers getting into it cleanly.

**Before the day (Sat Aug 15 at the latest):**

- Run the PSI online compatibility/system test — the link is in your exam preparation checklist email and in My Portal on trainingportal.linuxfoundation.org. Test on the exact machine + network + webcam you will use.
- Use a **personal machine**. Corporate laptops with MDM, VPN clients, or endpoint agents are the single most common cause of PSI Secure Browser failures. As a SWIFT-managed-device owner: do not even try it on the work laptop.
- One monitor only. If you normally run externals, unplug them the night before so the check-in doesn't flag them.
- Wired connection if possible; otherwise sit next to the router.

**Check-in (starts 30 minutes before your slot — use all of it):**

- Log in to My Portal and hit "Take Exam" the moment the window opens. Onboarding routinely consumes the full 30 minutes: launch secure browser, ID verification, room scan, proctor queue.
- **ID**: government-issued photo ID; the name must match your registration exactly, in Latin characters (passport is the safe default if your ID is not Latin-script).
- **Room scan**: you will pan the webcam 360° — desk surface, under the desk, walls, ceiling. Requirements: clean desk (nothing but the machine), no papers or notes, no second monitor, no headphones, no smartwatch. Phone must be shown, then placed out of arm's reach. Drinks only in a transparent container without a label. If your webcam is built into a laptop, be ready to pick the laptop up and pan it.
- During the exam: stay in frame, face visible, no talking or reading aloud (mouthing task text gets you flagged), no covering your mouth, no leaving frame without proctor permission.

**Breaks:** technically permitted by asking the proctor via chat — but **the clock does not stop**, and the request/return overhead costs several minutes. Plan for zero breaks in 120 minutes. Bathroom before check-in, water on the desk.

**If you get disconnected:** do not panic — this is recoverable and panicking is the only way to make it unrecoverable. Relaunch the PSI Secure Browser from the same "Take Exam" link; you will re-enter through the proctor and resume your session. Note the wall-clock time of the drop and reconnection. If material time was lost or you cannot resume, use PSI's live chat support immediately and file a Linux Foundation support ticket after — documented timestamps are what make a credit/retake case. A 3-minute disconnect handled calmly costs 3 minutes; handled badly it costs the exam.

## The mental game

At the margin, triage discipline beats knowledge. The candidate who knows 80% of the material and executes triage perfectly beats the candidate who knows 95% and free-solos the task list in order.

**The flag-and-move rule.** Hard thresholds, decided now, not during the exam:

- If after **60 seconds** of reading you do not know your first command: flag, move on.
- If you are **2× over** the domain time budget for a task and not on the final step: apply whatever partial state you have, flag, move on.
- First pass = bank every task at or below your fluency level. Second pass = flagged tasks, hardest last. There is no third pass.

**Never author YAML from scratch.** Every YAML on the exam comes from one of three generators: `k create/run ... $do`, `k get <existing> -o yaml`, or a copy-paste from the docs page you already rehearsed finding. You mutate; you do not compose. Composing a PV from memory is how a 4-minute task becomes a 12-minute task with a typo in `accessModes`.

**Verify every task with one command.** `k get` the thing, `k auth can-i` the grant, `wget` the service. Ten seconds of verification protects the points you just earned — an unverified task is a hypothesis, not a score.

**Context, always.** First action of every task: paste the `kubectl config use-context ...` line from the task header, even if you believe you are already there.

**Breathe.** Three slow breaths at every task boundary. Misreads — the purest waste in the failure taxonomy — come from panic-skimming, and panic-skimming comes from the previous task's adrenaline. The breath is not wellness advice; it is a misread countermeasure.

## Catch-up plan: if you are behind at a checkpoint

Check against these three gates. Being behind is a routing problem, not a crisis.

**Gate 1 — Aug 2: course modules for weeks 5–8 not finished.**
Cut depth, not domains. Priority order = weight × drillability: Troubleshooting → Cluster Architecture (etcd, RBAC, upgrade) → Networking (Services, NetPol, Gateway/Ingress) → Workloads → Storage. For each remaining module: skip the masterclass prose except its **Traps** section, do the exercises directly, look up what you don't know as you hit it. Exercises teach faster than reading at this stage. Keep the killer.sh dates fixed — do not push session 1 later than Aug 8–9.

**Gate 2 — Aug 9: killer.sh session 1 below ~40%, majority fail reason = knowledge.**
Convert the final week from taper to targeted drilling: Mon–Thu become triage-matrix days (top weak domain each morning, its circuit each evening), session 2 moves to Thu Aug 13. **But the last two taper days (Sat–Sun) stay untouchable.** Rest is performance-enhancing; a fried candidate with 5% more knowledge scores lower.

**Gate 3 — Aug 13: session 2 below ~70% on known questions.**
The gap is mechanics under time. Drop all content review; run circuit M and circuit F daily Fri included (short, 30 min), and rehearse the first-5-minutes routine until it is automatic. And recalibrate expectations: session 2 at 70% on killer.sh difficulty is still consistent with passing the real exam.

**The floor.** You have one free retake. That is a safety net, not a plan — but knowing it exists should remove the fear that causes panic-skimming. Play attempt 1 to win: 66% on a partial-credit exam with two skippable tasks is a very reachable bar.

## Traps

Each trap: the assumption that costs points → the correction.

1. **"My killer.sh score predicts my exam score."** → It under-predicts by design; killer.sh is harder. 40–60% on first attempt is the normal range for eventual passers. The predictive signal is your *debrief quality* and session-2 delta, not the session-1 number.
2. **"Two killer.sh sessions = two sets of practice questions."** → Same questions in both. Session 2 spent hunting novelty is wasted; its value is the timed re-test.
3. **"I'll take a bathroom break halfway."** → Clock keeps running and proctor round-trip costs 3–5 minutes. Plan for zero breaks.
4. **"My notes/second monitor will be fine if they're off."** → Room scan requires a clean desk and a single monitor. A visible second monitor (even powered off, in some proctors' interpretation) triggers delays or refusal. Unplug and remove the night before.
5. **"Copy/paste works like my terminal."** → The remote desktop clipboard is its own world: Ctrl+Shift+C/V in the terminal, right-click menus in Firefox, and the notepad app as a staging area. You rehearsed this in killer.sh session 1 — that was the point of doing it in their environment.
6. **"I'm probably already in the right context."** → Every task declares its context; several clusters exist. Solving a task in the wrong context scores zero and *feels* identical to solving it correctly. Paste the context line every task, no exceptions.
7. **"One more study night before the exam helps."** → Sleep beats a final circuit. The exam tests execution under pressure; execution degrades with fatigue faster than knowledge improves with cramming.
8. **"All tasks are worth the same, so finish in order."** → Task weights range roughly 4–13%. A flagged 13% task deserves your second-pass time before a 4% one. Note weights during the first pass.
9. **"Disconnection means the exam is lost."** → Sessions are resumable via the same launch link. The real risk is the 10 minutes of panic, not the drop itself.
10. **"I must finish all tasks to pass."** → 66% bar, partial credit, independent tasks. Two or three abandoned tasks are survivable; twenty minutes sunk into one task is what kills attempts.
11. **"My work laptop is fine, it has a better camera."** → MDM/VPN/endpoint agents break PSI Secure Browser in ways you cannot fix at check-in. Personal machine, tested Saturday.
12. **"I'll write that PV/NetPol from memory to save doc-lookup time."** → Authoring from memory is slower and error-prone under adrenaline. Generate or copy, then mutate. The docs tab is allowed — rehearsed lookups cost 30 seconds.

## Speed patterns

Exam-day-specific patterns; the per-domain ones live in the domain modules and `drills/speed-drills.md`.

**Minute 0–2, before task 1** (module 00 has the full routine):

```bash
alias k=kubectl                       # usually preset on exam terminals — verify, don't assume
export do="--dry-run=client -o yaml"
export now="--grace-period=0 --force"
k config get-contexts                 # see the battlefield once
```

**Per task, the frame:**

```bash
# 1. paste the task's context line — ALWAYS
kubectl config use-context k8s        # example; use the one in the task header
# 2. if the task names a node: ssh into it, and watch your prompt
ssh node01
sudo -i
# ... work ...
exit    # from root
exit    # from node — solving the next task while still on node01 = zero
```

**Generate-mutate, never compose:**

```bash
k create deploy web --image=nginx --replicas=3 $do > d.yaml   # generator
k -n team-a get deploy legacy -o yaml > d.yaml                # clone existing
# third source: docs copy-paste for kinds with no generator (PV, NetPol, Ingress, HTTPRoute)
vim d.yaml && k apply -f d.yaml
```

**One-command verification, per task type:** `k rollout status deploy/x`, `k auth can-i list pods --as=system:serviceaccount:ns:sa -n ns`, `k run tmp --rm -it --image=busybox --restart=Never -- wget -qO- http://svc:80`, `k get pvc -n ns` (look for `Bound`), `k -n kube-system exec etcd-<node> -- ls -l /path/snap.db`.

**Docs speed:** search the kubernetes.io docs box with the exact terms you rehearsed (docs-map below), not natural language. One Firefox window, few tabs — the remote desktop punishes tab sprawl.

**Flag tracking:** the exam UI has per-task flags and a notepad. First pass: flag + one-line note ("t7 netpol egress dns?"). Notes beat memory under adrenaline.

## Docs map

Pages to reach in under 30 seconds each — rehearse Thu Aug 13. Search terms in the docs search box are usually faster than navigating menus.

| What you need | Path on kubernetes.io (or helm.sh) | Search term |
|---|---|---|
| kubectl command reference | /docs/reference/kubectl/quick-reference/ | "quick reference" |
| JSONPath syntax | /docs/reference/kubectl/jsonpath/ | "jsonpath" |
| etcd backup/restore | /docs/tasks/administer-cluster/configure-upgrade-etcd/ | "operating etcd" |
| kubeadm upgrade | /docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/ | "kubeadm upgrade" |
| NetworkPolicy (copy-paste base) | /docs/concepts/services-networking/network-policies/ | "network policies" |
| Ingress | /docs/concepts/services-networking/ingress/ | "ingress" |
| Gateway API | /docs/concepts/services-networking/gateway/ | "gateway" |
| PV / PVC / pod volume | /docs/concepts/storage/persistent-volumes/ | "persistent volumes" |
| StorageClass / default class | /docs/concepts/storage/storage-classes/ | "storage classes" |
| RBAC (Role/Binding examples) | /docs/reference/access-authn-authz/rbac/ | "rbac" |
| DaemonSet / Deployment specs | /docs/concepts/workloads/controllers/ | "daemonset" |
| HPA walkthrough | /docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/ | "horizontalpodautoscaler walkthrough" |
| CRDs | /docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/ | "custom resource definitions" |
| Kustomize | /docs/tasks/manage-kubernetes-objects/kustomization/ | "kustomization" |
| Helm CLI reference | helm.sh/docs/helm/ | (helm.sh → Docs → Helm Commands) |

**Before exam day only (not reachable during the exam):** CNCF curriculum repo (github.com/cncf/curriculum) for current weights; the Candidate Handbook and Important Instructions on docs.linuxfoundation.org; the PSI compatibility check from your exam-prep email; killer.sh FAQ for session mechanics.

## Checkpoint

Run this list on Fri Aug 14. Every "no" maps to a fix above.

- Can you execute the first-5-minutes setup (aliases, env vars, `k config get-contexts`) in **2 minutes** without thinking?
- Can you state your flag-and-move thresholds (60s no-first-command; 2× domain budget) from memory, **instantly**?
- Can you do a full etcd snapshot save + verify in **5 minutes** without docs?
- Can you produce a working NetworkPolicy (one namespace selector + one port) from the docs page in **5 minutes**?
- Can you open every docs-map page above, cold, in **30 seconds each**?
- Can you complete circuit M in `drills/speed-drills.md` in **under 20 minutes** at 100% pass conditions?
- Can you recite the disconnect procedure (relaunch link → proctor → PSI chat → LF ticket, with timestamps) **cold**?
- Did you run the PSI system test **on the exam machine and network**, and does your ID name match your registration **exactly**?
- Is Sunday Aug 16 actually empty after noon? If not, fix the calendar, not the study plan.
