#!/usr/bin/env bash
# What is running is not what is in these files, and that is the bug.
#
# Capacity has appeared to drop ~25% overnight, run after run, and part of
# the reason is that three different versions of this configuration exist
# at once:
#
#   1. the live cluster
#   2. these files on disk
#   3. what is committed to git
#
# An edit written but never applied leaves 1 behind 2. An `kubectl edit`
# or a hand-patched field leaves 2 behind 1. An uncommitted file leaves 3
# behind both, so tomorrow there is no record of what today measured.
# Found on 2026-10-15: app-clone.yaml said `maxReplicas: 200` and the
# live HPA said 40 -- the raise was written and never applied, so the
# fleet was capped at a third of what the file claimed.
#
# Run this BEFORE a load test and AFTER changing anything. A capacity
# number is only comparable to yesterday's if the configuration is.
#
#   ./drift-check.sh          report drift, exit 1 if any
#   ./drift-check.sh --quiet  exit code only, for a pre-run guard
#
# It changes nothing. `kubectl diff` is read-only; it renders what an
# apply WOULD do.
set -uo pipefail
cd "$(dirname "$0")"

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

# app-secrets.yaml is gitignored and holds real credentials; it is never
# diffed, because the output would print them. app-secrets.example.yaml is
# a template with no live counterpart. traefik-values.yaml is Helm input,
# not a manifest, so there is nothing for kubectl to compare it to.
#
# The one-shot Jobs are skipped because their drift is meaningless noise:
# a completed Job reports every field the API server defaulted
# (podReplacementPolicy, completionMode, controller-uid labels), and its
# pod template is immutable anyway, so a diff can never be acted on. The
# one that matters -- the journey ConfigMap -- is checked by hand before a
# run, and the soak reads the same ConfigMap.
SKIP='app-secrets.yaml|app-secrets.example.yaml|traefik-values.yaml|^k6-.*-job\.yaml|^restore-.*-job\.yaml'

DRIFTED=()
MISSING=()

say ""
say "=== LIVE CLUSTER vs THESE FILES ==="
say ""

for f in $(ls *.yaml monitoring/*.yaml 2>/dev/null | grep -Ev "$SKIP"); do
  out=$(kubectl diff -f "$f" 2>&1)
  rc=$?
  if [ $rc -eq 0 ]; then
    say "  same    $f"
  elif echo "$out" | grep -q "not found\|NotFound\|doesn't have a resource type"; then
    # Objects in the file that do not exist in the cluster at all. Normal
    # for one-shot Jobs that have been deleted; a problem for anything
    # that is supposed to be running.
    MISSING+=("$f")
    say "  ABSENT  $f  (object does not exist in the cluster)"
  else
    DRIFTED+=("$f")
    say "  DRIFT   $f"
    if [ "$QUIET" -eq 0 ]; then
      echo "$out" | grep -E '^[+-][^+-]' | sed 's/^/            /' | head -20
    fi
  fi
done

say ""
say "=== THESE FILES vs GIT ==="
say ""
if git rev-parse --git-dir >/dev/null 2>&1; then
  UNCOMMITTED=$(git status --porcelain | wc -l | tr -d ' ')
  if [ "$UNCOMMITTED" -eq 0 ]; then
    say "  clean -- every manifest on disk is committed"
  else
    say "  $UNCOMMITTED uncommitted change(s):"
    [ "$QUIET" -eq 0 ] && git status --short | sed 's/^/     /'
    say ""
    say "  Uncommitted manifests are the reason a result cannot be"
    say "  reproduced tomorrow: there is no record of what produced it."
  fi
else
  say "  NOT A GIT REPOSITORY -- nothing here is recoverable."
  UNCOMMITTED=1
fi

say ""
if [ ${#DRIFTED[@]} -eq 0 ] && [ "${UNCOMMITTED:-0}" -eq 0 ]; then
  say "=== OK -- live, disk and git agree. Results are comparable. ==="
  exit 0
fi

say "=== NOT SAFE TO COMPARE TO A PREVIOUS RUN ==="
say ""
[ ${#DRIFTED[@]} -gt 0 ] && say "  ${#DRIFTED[@]} file(s) differ from the cluster: ${DRIFTED[*]}"
[ ${#DRIFTED[@]} -gt 0 ] && say "    -> kubectl apply -f <file>   to make the cluster match the file"
[ "${UNCOMMITTED:-0}" -ne 0 ] && say "  uncommitted changes -> commit them, so this run has a record"
say ""
exit 1
