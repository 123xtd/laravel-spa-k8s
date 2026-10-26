#!/usr/bin/env bash
#
# Everything that must be true for the live site to be healthy.
# RUN THIS AFTER EVERY ALTERATION. It is not optional and not a summary.
#
# WHY IT EXISTS
#
# For the first two weeks the site was live, every listing photo returned
# 403 to visitors. It was reported healthy throughout, because what was
# actually checked was "the page returns HTTP 200" and "Inertia rendered"
# -- neither of which says anything about whether an image resolves.
# Narrow verification was presented as general health, which is worse than
# no verification, because it manufactures confidence.
#
# So this checks the things a VISITOR experiences, not the things that are
# convenient to measure. Every check prints PASS or FAIL. Any FAIL exits
# non-zero. There is no "mostly fine".
#
# Usage:  ./health-check.sh            full run
#         ./health-check.sh --quick    skip the test suite and drift check

set -uo pipefail

NS=laravel-spa
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
note() { printf '        %s\n' "$*"; }
head_() { printf '\n== %s\n' "$*"; }

# ---------------------------------------------------------------- serving
head_ "the site answers"
for h in buyandsellpage.ca buyandsellpage.com; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$h/")
  [ "$code" = "200" ] && ok "$h returns 200" || bad "$h returns $code"
done

head_ "pages actually render (not a maintenance or error page)"
for h in buyandsellpage.ca buyandsellpage.com; do
  body=$(curl -s --max-time 20 "https://$h/")
  echo "$body" | grep -q '&quot;component&quot;:&quot;Home&quot;' \
    && ok "$h rendered the Home component" \
    || bad "$h returned 200 without rendering Home"
  want=${h##*.}
  echo "$body" | grep -q "&quot;region&quot;:&quot;${want}&quot;" \
    && ok "$h served region '$want'" \
    || bad "$h served the wrong region"
done

# --------------------------------------------------------------- the images
# THE CHECK THAT WAS MISSING. A page can return 200, render correctly and
# still show a visitor nothing but broken image icons.
head_ "listing photos load for an anonymous visitor"
POD=$(kubectl get pods -n $NS -l app=laravel-spa-app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
  bad "no app pod found; cannot check photos"
else
  URL=$(printf '%s\n' '$i = \App\Models\ListingImage::first(); echo "U=".($i ? \Illuminate\Support\Facades\Storage::disk("s3")->url($i->thumbnail_path ?: $i->path) : "");' \
        | kubectl exec -i -n $NS "$POD" -c app -- php artisan tinker 2>/dev/null \
        | grep -oE 'U=https?://[^"]+' | tail -1 | cut -d= -f2-)
  if [ -z "$URL" ]; then
    note "no listing images in the database; nothing to check"
  else
    read -r code type < <(curl -s -o /dev/null -w '%{http_code} %{content_type}' --max-time 20 "$URL")
    case "$code:$type" in
      200:image/*) ok "a real listing photo loads ($type)";;
      *)           bad "listing photo returned $code ($type) -- visitors see broken images"
                   note "$URL";;
    esac
  fi
fi

head_ "what must NOT be public"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://cdn.buyandsellpage.ca/laravel-spa-backups/")
[ "$code" = "403" ] && ok "database backups are not publicly readable" || bad "backups bucket returned $code, expected 403"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://cdn.buyandsellpage.ca/laravel-spa-uploads/")
[ "$code" = "403" ] && ok "the photo bucket cannot be listed" || bad "photo bucket listing returned $code, expected 403"
for p in /.env /.git/config /storage/logs/laravel.log; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://buyandsellpage.ca$p")
  case "$code" in 403|404) ok "$p refused ($code)";; *) bad "$p returned $code";; esac
done
hdr=$(curl -sI --max-time 15 https://buyandsellpage.ca/ | grep -ci "x-powered-by" || true)
[ "$hdr" = "0" ] && ok "no X-Powered-By version leak" || bad "X-Powered-By is being sent"

# ------------------------------------------------------------------- certs
head_ "TLS"
for h in buyandsellpage.ca buyandsellpage.com; do
  end=$(echo | timeout 15 openssl s_client -servername "$h" -connect "$h:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  if [ -z "$end" ]; then bad "$h: could not read the certificate"; else
    days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
    [ "$days" -gt 14 ] && ok "$h certificate valid for $days more days" || bad "$h certificate expires in $days days"
  fi
done

# ------------------------------------------------------------------- fleet
head_ "the fleet"
read -r digests replicas ready < <(kubectl get pods -n $NS -l app=laravel-spa-app -o json 2>/dev/null | python3 -c "
import json,sys
pods=[p for p in json.load(sys.stdin)['items'] if p['status'].get('phase')=='Running']
d={cs.get('imageID','?').split('@')[-1] for p in pods for cs in p['status'].get('containerStatuses',[])}
r=sum(1 for p in pods for cs in p['status'].get('containerStatuses',[]) if cs.get('ready'))
print(len(d), len(pods), r)
")
[ "${digests:-0}" = "1" ] && ok "all live pods run one image digest" || bad "live pods run $digests different digests -- a rollout is incomplete or stuck"
[ "${replicas:-0}" = "${ready:-1}" ] && ok "$ready/$replicas live pods ready" || bad "only $ready of $replicas live pods are ready"

head_ "data stores"
printf '%s\n' 'echo "DB=".DB::connection()->getPdo()->query("SELECT 1")->fetchColumn();' \
  | kubectl exec -i -n $NS "$POD" -c app -- php artisan tinker 2>/dev/null | grep -q "DB=1" \
  && ok "live database reachable from the app" || bad "live database NOT reachable from the app"
printf '%s\n' 'Cache::put("healthcheck", "x", 10); echo "CACHE=".Cache::get("healthcheck");' \
  | kubectl exec -i -n $NS "$POD" -c app -- php artisan tinker 2>/dev/null | grep -q "CACHE=x" \
  && ok "cache (dragonfly) reads and writes" || bad "cache NOT working"

head_ "storage headroom"
SPOD=$(kubectl get pods -n $NS -l app=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$SPOD" ]; then
  used=$(kubectl exec -n $NS "$SPOD" -- df -P /data 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')
  [ -n "$used" ] && { [ "$used" -lt 80 ] && ok "object storage ${used}% used" || bad "object storage ${used}% used"; }
  vols=$(kubectl exec -n $NS "$SPOD" -- sh -c 'ls -1 /data/seaweedfs/*.dat 2>/dev/null | wc -l' 2>/dev/null)
  size=$(kubectl exec -n $NS "$SPOD" -- df -P /data 2>/dev/null | awk 'NR==2 {print int($2/1048576)}')
  # SeaweedFS reserves a 1 GB volume per chunk; max volumes = disk / 1 GB.
  # Running out of SLOTS stops uploads even with the disk nearly empty.
  if [ -n "$vols" ] && [ -n "$size" ]; then
    free=$(( size - vols ))
    [ "$free" -gt 5 ] && ok "$free spare volume slots ($vols of ~$size used)" \
                      || bad "only $free spare volume slots -- uploads fail when this hits zero"
  fi
fi

head_ "external monitoring is actually running"
L="$HOME/.local/state/basp-uptime/probe.log"
if [ -f "$L" ]; then
  # Fields 1-3, INCLUDING the zone. The log writes Central
  # ("2026-10-26 14:25:01 CDT") while this box runs UTC, so dropping the
  # zone makes every reading five hours stale and reports a dead probe
  # that is running perfectly. That is exactly what the first run of this
  # script did -- the check was wrong, not the thing being checked.
  last=$(date -d "$(tail -1 "$L" | awk '{print $1" "$2" "$3}')" +%s 2>/dev/null || echo 0)
  age=$(( ($(date +%s) - last) / 60 ))
  [ "$age" -lt 15 ] && ok "uptime probe ran ${age}m ago" || bad "uptime probe last ran ${age}m ago -- cron may be dead"
else
  bad "no uptime probe log; monitoring is not running"
fi

# --------------------------------------------------------------- slow checks
if [ "$QUICK" -eq 0 ]; then
  head_ "manifests match the cluster"
  if (cd "$(dirname "$0")" && ./drift-check.sh >/tmp/hc-drift.$$ 2>&1); then
    ok "no drift between manifests, cluster and git"
  else
    bad "drift detected -- see ./drift-check.sh"
    grep -E "DRIFT|uncommitted" /tmp/hc-drift.$$ | head -4 | sed 's/^/        /'
  fi
  rm -f /tmp/hc-drift.$$

  head_ "the test suite"
  APP=/home/mars/laravel-deploy/laravel-spa
  if [ -d "$APP" ]; then
    r=$(cd "$APP" && ./vendor/bin/phpunit 2>/dev/null | head -1 | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read()); print(d.get('passed',0), d.get('tests',0))
except Exception: print(0,0)
")
    set -- $r
    [ "$1" -gt 0 ] && [ "$1" = "$2" ] && ok "$1/$2 tests passing" || bad "$1/$2 tests passing"
  fi
fi

printf '\n== %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { echo "   The site is NOT healthy. Do not report otherwise."; exit 1; }
echo "   Healthy."
