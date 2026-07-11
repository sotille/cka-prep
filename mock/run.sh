#!/usr/bin/env bash
# mock/run.sh — start a mock exam: seed the cluster (blind), print the paper location,
# and run a 120-minute countdown timer. Grade afterwards with mock/grade.sh.
#
# Usage: mock/run.sh <1|2|3> [--no-timer]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib-checks.sh"

N="${1:-}"; case "$N" in 1|2|3) ;; *) echo "usage: mock/run.sh <1|2|3> [--no-timer]"; exit 2;; esac
NOTIMER="${2:-}"

SETUP="$REPO/mock-exams/mock-exam-$N-setup.sh"
PAPER="$REPO/mock-exams/mock-exam-$N.md"
[ -f "$SETUP" ] || { echo "missing $SETUP"; exit 1; }

require_cluster 2>/dev/null || { echo "cluster not reachable — run labs/setup/bootstrap-cluster.sh"; exit 1; }

printf '%s\n' "Seeding mock exam $N (do not read the setup script — it contains the answers)…"
bash "$SETUP"

case "$N" in
  1) ANS=/tmp/exam ;; 2) ANS=/tmp/exam2 ;; 3) ANS=/tmp/exam3 ;;
esac

cat <<EOF

══════════════════════════════════════════════════════════════
  MOCK EXAM $N — clock starts NOW
  Paper:            $PAPER
  Answer files:     $ANS/
  Grade when done:  mock/grade.sh $N
  Pass line:        66%$( [ "$N" = 3 ] && printf '  (killer-calibrated: ≥55%% ≈ exam-ready)' )
══════════════════════════════════════════════════════════════
EOF

[ "$NOTIMER" = "--no-timer" ] && { echo "(timer skipped)"; exit 0; }

END=$(( $(date +%s) + 120*60 ))
printf 'Timer running — Ctrl-C to stop it (your work and the cluster stay put).\n'
while :; do
  now=$(date +%s); rem=$(( END - now ))
  (( rem <= 0 )) && { printf '\r%-60s\n' "⏰  TIME — 120:00 elapsed. Stop typing and grade: mock/grade.sh $N"; break; }
  printf '\r  ⏳ %02d:%02d remaining   ' $(( rem/60 )) $(( rem%60 ))
  sleep 1
done
