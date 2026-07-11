#!/usr/bin/env bash
# mock/lib-checks.sh — assertion + scoring library for the mock-exam auto-graders.
# Source this from a grade-N.sh. Grades on FINAL cluster/file state, with partial credit.
#
# Contract for a grader task:
#   begin_task <id> <domain> <weight%> "<title>"
#     awardif <points> "<check description>" <command...>   # command exit 0 = pass
#     awardif ...
#   end_task
# ...then at the end of the grader:
#   summary
#
# Points inside a task are arbitrary integers; the task's <weight%> is split across them
# proportionally. Domain subtotals and a total vs the 66% pass line are printed by summary().

CTX="${CKA_CTX:-kind-cka}"
K() { kubectl --context "$CTX" "$@"; }

# reachability guard used by run.sh / grade.sh
require_cluster() {
  command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found on PATH" >&2; return 1; }
  kubectl config get-contexts "$CTX" >/dev/null 2>&1 || { echo "context $CTX not found — run labs/setup/bootstrap-cluster.sh" >&2; return 1; }
  K get nodes >/dev/null 2>&1 || { echo "cluster unreachable via context $CTX" >&2; return 1; }
}

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_cyn=$'\033[36m'; c_dim=$'\033[2m'; c_bld=$'\033[1m'; c_rst=$'\033[0m'

# result accumulators (parallel arrays, one entry per task)
R_IDS=(); R_DOM=(); R_W=(); R_E=()

_PTS=0; _MAX=0; _ID=""; _DOM=""; _W=0; _TITLE=""

begin_task() {
  _ID="$1"; _DOM="$2"; _W="$3"; _TITLE="$4"; _PTS=0; _MAX=0
  printf '%s── Task %s%s  %s[%s · %s%%]%s  %s\n' "$c_bld" "$_ID" "$c_rst" "$c_dim" "$_DOM" "$_W" "$c_rst" "$_TITLE"
}

# awardif <points> "<description>" <command...>
awardif() {
  local pts="$1" desc="$2"; shift 2
  _MAX=$((_MAX + pts))
  if "$@" >/dev/null 2>&1; then
    _PTS=$((_PTS + pts))
    printf '   %s✓%s [%s] %s\n' "$c_grn" "$c_rst" "$pts" "$desc"
  else
    printf '   %s✗%s [%s] %s\n' "$c_red" "$c_rst" "$pts" "$desc"
  fi
}

end_task() {
  local earned
  earned=$(awk -v w="$_W" -v p="$_PTS" -v m="$_MAX" 'BEGIN{ if(m==0){print "0.00"} else {printf "%.2f", w*p/m} }')
  R_IDS+=("$_ID"); R_DOM+=("$_DOM"); R_W+=("$_W"); R_E+=("$earned")
  local color="$c_red"; awk -v p="$_PTS" -v m="$_MAX" 'BEGIN{exit !(m>0 && p==m)}' && color="$c_grn"
  awk -v p="$_PTS" -v m="$_MAX" 'BEGIN{exit !(m>0 && p>0 && p<m)}' && color="$c_ylw"
  printf '   %s→ %s/%s checks · %s of %s%%%s\n\n' "$color" "$_PTS" "$_MAX" "$earned" "$_W" "$c_rst"
}

# ── predicate helpers (for use as the awardif command) ─────────────────────────
val_eq()  { [ "$1" = "$2" ]; }                                   # val_eq "$actual" "expected"
val_ne()  { [ "$1" != "$2" ]; }
num_ge()  { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'; }      # num_ge "$actual" min
nonempty(){ [ -n "$1" ]; }
file_ok() { [ -s "$1" ]; }                                       # file exists and non-empty
file_has(){ [ -f "$1" ] && grep -q -- "$2" "$1"; }               # file_has /path "pattern"
kexists() { K get "$@" >/dev/null 2>&1; }                        # kexists pod foo -n bar
# `kubectl get` field equals expected: jpeq <expected> <type> <name> -n <ns> -o jsonpath=...
jpeq() { local want="$1"; shift; [ "$(K get "$@" 2>/dev/null)" = "$want" ]; }
# `kubectl get` field matches a grep pattern: jpgrep <pattern> <type> <name> ... -o jsonpath=...
jpgrep() { local pat="$1"; shift; K get "$@" 2>/dev/null | grep -q -- "$pat"; }
# `kubectl auth can-i` result equals yes/no: cani <yes|no> <verb> <resource> [--as ...] -n <ns>
cani() { local want="$1"; shift; [ "$(K auth can-i "$@" 2>/dev/null)" = "$want" ]; }
# a Service has at least one ready endpoint address
svc_has_endpoints() { [ -n "$(K -n "$1" get endpoints "$2" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)" ]; }
# every node is Ready
all_nodes_ready() { [ "$(K get nodes --no-headers 2>/dev/null | awk '$2!="Ready"' | wc -l | tr -d ' ')" = "0" ]; }
# kubelet is enabled (survives reboot) on a kind node
kubelet_enabled() { docker exec "$1" systemctl is-enabled kubelet 2>/dev/null | grep -qx enabled; }
# echo the name of the (first) default StorageClass
default_sc() { K get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1; }
# only-matching-lines: file exists, non-empty, and every line matches pattern
file_only() { [ -s "$1" ] && ! grep -vq -- "$2" "$1"; }
# count of matching lines in a file >= n
file_count_ge() { [ -f "$1" ] && [ "$(grep -c -- "$2" "$1")" -ge "$3" ]; }
# ready replicas of a deployment >= n:  deploy_ready <ns> <name> <n>
deploy_ready() { local got; got="$(K -n "$1" get deploy "$2" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"; num_ge "${got:-0}" "$3"; }
# a resource's field via jsonpath (echoes value) — for building comparisons
jp() { K "$@" 2>/dev/null; }

summary() {
  echo "══════════════════════════════════════════════════════════════"
  printf '%s SCORE BY DOMAIN%s\n' "$c_bld" "$c_rst"
  echo "──────────────────────────────────────────────────────────────"
  # unique domains, preserving a sensible order
  local domains=("Troubleshooting" "Cluster Architecture" "Services & Networking" "Workloads & Scheduling" "Storage")
  local total_e=0 total_w=0 d
  for d in "${domains[@]}"; do
    local de=0 dw=0 i
    for i in "${!R_IDS[@]}"; do
      [ "${R_DOM[$i]}" = "$d" ] || continue
      de=$(awk -v a="$de" -v b="${R_E[$i]}" 'BEGIN{printf "%.2f", a+b}')
      dw=$(awk -v a="$dw" -v b="${R_W[$i]}" 'BEGIN{printf "%.2f", a+b}')
    done
    [ "$dw" = "0.00" ] && continue
    printf '  %-24s %5s / %-4s %%\n' "$d" "$de" "$dw"
    total_e=$(awk -v a="$total_e" -v b="$de" 'BEGIN{printf "%.2f", a+b}')
    total_w=$(awk -v a="$total_w" -v b="$dw" 'BEGIN{printf "%.2f", a+b}')
  done
  echo "──────────────────────────────────────────────────────────────"
  local passline="${PASS_LINE:-66}"
  local verdict color
  if awk -v s="$total_e" -v p="$passline" 'BEGIN{exit !(s>=p)}'; then
    verdict="PASS"; color="$c_grn"
  else
    verdict="BELOW PASS LINE"; color="$c_red"
  fi
  printf '  %sTOTAL  %s / %s %%   (pass line %s)   →  %s%s%s\n' "$c_bld" "$total_e" "$total_w" "$passline" "$color" "$verdict" "$c_rst"
  echo "══════════════════════════════════════════════════════════════"
  [ -n "${CALIBRATION_NOTE:-}" ] && printf '%s%s%s\n' "$c_cyn" "$CALIBRATION_NOTE" "$c_rst"
  printf '%sGrading is best-effort on final state; read the -solutions.md rubric for anything scored 0 you believe you solved.%s\n' "$c_dim" "$c_rst"
}
