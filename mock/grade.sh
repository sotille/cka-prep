#!/usr/bin/env bash
# mock/grade.sh — auto-grade a mock exam on final cluster/file state.
# Usage: mock/grade.sh <1|2|3>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib-checks.sh"

N="${1:-}"; case "$N" in 1|2|3) ;; *) echo "usage: mock/grade.sh <1|2|3>"; exit 2;; esac
GRADER="$HERE/grade-$N.sh"
[ -f "$GRADER" ] || { echo "missing $GRADER"; exit 1; }

require_cluster 2>/dev/null || { echo "cluster not reachable via context $CTX"; exit 1; }

printf '%sGrading Mock Exam %s on final state (context %s)…%s\n\n' "$c_bld" "$N" "$CTX" "$c_rst"
# shellcheck source=/dev/null
. "$GRADER"
summary
