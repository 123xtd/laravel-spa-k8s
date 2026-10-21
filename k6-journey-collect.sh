#!/usr/bin/env bash
# Collect a journey run's results off the generator pods and merge them.
#
# Run this AFTER the job finishes, while its pods still exist -- the pods
# are the only copy of the summaries. `kubectl delete job k6-journey`
# takes them with it, so collect first, delete second.
#
# Usage:
#   k8s/k6-journey-collect.sh                 # live, into loadtest/results/journey-<stamp>
#   k8s/k6-journey-collect.sh --watch         # wait for the job to finish, then collect
set -euo pipefail

NAMESPACE="${NAMESPACE:-laravel-spa}"
SELECTOR="${SELECTOR:-app=k6-journey}"
RESULTS_ROOT="${RESULTS_ROOT:-$HOME/laravel-deploy/laravel-spa/loadtest/results}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "--watch" ]]; then
  echo "Waiting for the generators to finish (ctrl-c is safe, the pods keep their logs)..."
  while true; do
    active=$(kubectl get pods -n "$NAMESPACE" -l "$SELECTOR" \
      --no-headers 2>/dev/null | grep -c "Running" || true)
    [[ "$active" == "0" ]] && break
    echo "  $active generator(s) still running, $(date +%H:%M:%S)"
    sleep 30
  done
fi

mapfile -t pods < <(kubectl get pods -n "$NAMESPACE" -l "$SELECTOR" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

if [[ "${#pods[@]}" -eq 0 ]]; then
  echo "No pods matching $SELECTOR in $NAMESPACE. If the job was deleted, the" >&2
  echo "summaries are gone with it -- there is no other copy." >&2
  exit 1
fi

OUT="$RESULTS_ROOT/journey-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT/logs"
echo "Collecting ${#pods[@]} generator(s) into $OUT"

found=0
for pod in "${pods[@]}"; do
  kubectl logs -n "$NAMESPACE" "$pod" > "$OUT/logs/$pod.log" 2>/dev/null || {
    echo "  ! $pod: logs unavailable"
    continue
  }
  # Just keep the log. Extracting the summary from it is the merge
  # script's job, because that extraction is the part that needed
  # fixing: a grep for the marker line gets only the first 16 KiB of a
  # ~25 KB summary, since the container runtime splits log lines at that
  # boundary. Whether a given generator is affected depends on write
  # buffering, which is why it silently took out one generator in twelve.
  if grep -q "JOURNEY_SUMMARY_JSON" "$OUT/logs/$pod.log"; then
    found=$((found + 1))
    echo "  ok $pod"
  else
    echo "  ! $pod: no summary in its log (died, or was terminated before printing)"
  fi
done

echo
python3 "$HERE/k6-journey-merge.py" "$OUT" | tee "$OUT/merged.txt"
echo "Saved: $OUT/merged.txt"
