#!/usr/bin/env bash
# Push is step one of four, and the other three are easy to forget.
#
# On 2026-10-20 three changes were committed, pushed, and built by CI --
# and nothing reached visitors for a day, because the clone was never
# restarted and the live digest was never bumped. Both tiers kept serving
# the previous image while every individual step looked successful.
#
# What this does, in order, stopping at the first thing that is wrong:
#
#   1. refuses if the app repo has unpushed commits (CI has nothing new)
#   2. restarts the clone, which is what actually pulls :latest
#   3. refuses if the clone came back on the digest live is already
#      running -- that means CI has not published yet
#   4. checks the clone serves 200
#   5. STOPS for you to look at www.foasfo.ca
#   6. bumps the digest in app-deployment.yaml and applies it
#   7. clears the page cache, which otherwise serves the old HTML for
#      up to PAGE_CACHE_TTL (300s) and makes a good deploy look broken
#   8. checks live serves 200 on both domains
#
# Safe to re-run: every step is idempotent, and it exits rather than
# guessing if anything looks unexpected.
#
#   ./promote.sh            normal, pauses before touching live
#   ./promote.sh --yes      no pause (for when you have already looked)
#   ./promote.sh --clone    stop after the clone; do not touch live
set -uo pipefail
cd "$(dirname "$0")"

APP_REPO="${APP_REPO:-../laravel-spa}"
NS=laravel-spa
IMAGE=ghcr.io/123xtd/laravel-spa-app
MANIFEST=app-deployment.yaml

ASSUME_YES=0
CLONE_ONLY=0
for a in "$@"; do
  case "$a" in
    --yes) ASSUME_YES=1 ;;
    --clone) CLONE_ONLY=1 ;;
    *) echo "unknown option: $a"; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
die()  { printf '\n  STOPPED: %s\n\n' "$*"; exit 1; }

live_digest() {
  kubectl get deploy laravel-spa-app -n "$NS" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*@//'
}
clone_digest() {
  kubectl get pods -n "$NS" -l app=laravel-spa-app-clone \
    -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' | sed 's/.*@//'
}
# Two probes, because the clone and the live site are reached differently.
#
# serves_200_internal talks straight to a ClusterIP service with a Host
# header. It is the only way to check the clone: the clone's Basic Auth is
# a Traefik middleware, so a request arriving through the ingress gets a
# 401 and the check would report a broken site that is in fact fine.
#
# serves_200_public goes through Traefik over real TLS, pinned to Traefik's
# ClusterIP with --resolve so it does not depend on the cluster being able
# to hairpin its own public address. Certificate verification stays ON --
# an expired cert SHOULD fail a promotion.
#
# Live is checked the public way on purpose. The plaintext probe only ever
# proved "the app pod answers": it says nothing about TLS, the certificate,
# the IngressRoute or the redirect middlewares, any one of which can break
# a promotion by itself. It is also the exact shape of request that once
# poisoned the page cache with an http:// render -- the cache key carries
# no scheme, so a single plaintext fetch of / could then be served to every
# HTTPS visitor. URL::forceScheme('https') defuses that now, but a deploy
# script has no reason to keep firing the gun that caused an outage.
TRAEFIK_SVC_IP="${TRAEFIK_SVC_IP:-$(kubectl get svc traefik -n traefik-system -o jsonpath='{.spec.clusterIP}' 2>/dev/null)}"

# A bare `kubectl run` trips the cluster's `restricted` PodSecurity
# default on all four of its rules, so each probe prints a warning. It is
# a WARNING only -- no namespace sets pod-security.kubernetes.io/enforce,
# so the pod is admitted and the gate works. Left as-is on purpose.
#
# Tried and reverted 2026-10-21: adding --overrides with a compliant
# securityContext BREAKS the probe. `kubectl run` names the container
# after the pod, so a container named anything else is "not found" when
# kubectl attaches, and the override replaces the container spec
# wholesale, dropping the curl arguments with it. The failure is silent
# in the way that matters: probe returns an empty string, which this
# script reads as "not 200" and refuses to promote a healthy site.
#
# If enforcement is ever switched on, build the override JSON with the
# container name set to the generated pod name AND the command included.
# Do not bolt a securityContext onto this call and assume it worked.
probe() {
  kubectl run "promote-probe-$RANDOM" -n "$NS" --rm -i --restart=Never \
    --image=curlimages/curl:latest --command -- "$@" 2>/dev/null \
    | grep -oE '^[0-9]{3}' | head -1
}

serves_200_internal() {
  local svc="$1" host="$2"
  probe curl -s -o /dev/null -w '%{http_code}' -H "Host: $host" "http://$svc/"
}

serves_200_public() {
  local host="$1"
  [ -n "$TRAEFIK_SVC_IP" ] || die "could not find Traefik's ClusterIP, so the live site cannot be checked over HTTPS."
  probe curl -s -o /dev/null -w '%{http_code}' --resolve "$host:443:$TRAEFIK_SVC_IP" "https://$host/"
}

# ---- 1. is there anything to promote? ----
say ""
say "=== 1. app repo ==="
if [ -d "$APP_REPO/.git" ]; then
  unpushed=$(git -C "$APP_REPO" log --oneline @{u}..HEAD 2>/dev/null | wc -l | tr -d ' ')
  if [ "${unpushed:-0}" -gt 0 ]; then
    git -C "$APP_REPO" log --oneline @{u}..HEAD | sed 's/^/     /'
    die "$unpushed commit(s) not pushed. CI has not seen them, so there is nothing new to promote."
  fi
  say "  in sync with origin: $(git -C "$APP_REPO" log --oneline -1 | cut -c1-60)"
else
  say "  (app repo not found at $APP_REPO -- skipping the check)"
fi

BEFORE=$(live_digest)
say "  live is running:  ${BEFORE:0:19}"

# ---- 2. the clone is what pulls :latest ----
say ""
say "=== 2. pulling :latest onto the clone ==="
kubectl -n "$NS" rollout restart deployment/laravel-spa-app-clone >/dev/null || die "could not restart the clone"
kubectl -n "$NS" rollout status deployment/laravel-spa-app-clone --timeout=400s >/dev/null \
  || die "the clone did not become ready. Its pods are probably failing on the new image -- kubectl logs will say why. Live is untouched."
NEW=$(clone_digest)
say "  clone now running: ${NEW:0:19}"

# ---- 3. did CI actually publish something new? ----
if [ "$NEW" = "$BEFORE" ]; then
  die "the clone came back on the digest live already runs. CI has not published a new image yet -- give it a few minutes and re-run."
fi

# ---- 4. does it serve? ----
code=$(serves_200_internal laravel-spa-app-clone www.foasfo.ca)
[ "$code" = "200" ] || die "the clone answers HTTP $code, not 200. Not promoting that. Live is untouched."
say "  clone serves HTTP 200"

if [ "$CLONE_ONLY" -eq 1 ]; then
  say ""
  say "=== stopping here (--clone). Live still on ${BEFORE:0:19} ==="
  say "    look at https://www.foasfo.ca then re-run without --clone"
  exit 0
fi

# ---- 5. the human gate ----
if [ "$ASSUME_YES" -eq 0 ]; then
  say ""
  say "=== 5. look at it before it goes live ==="
  say "    https://www.foasfo.ca   (clone, running the new build)"
  say ""
  printf "    promote %s to the live site? [y/N] " "${NEW:0:19}"
  read -r reply </dev/tty
  case "$reply" in [yY]*) ;; *) say "    not promoted. Live still on ${BEFORE:0:19}"; exit 0 ;; esac
fi

# ---- 6. bump the digest and apply ----
say ""
say "=== 6. promoting ==="
grep -q "$IMAGE@$BEFORE" "$MANIFEST" || die "could not find $BEFORE in $MANIFEST. Has it been edited by hand? Not touching it."
sed -i "s|$IMAGE@$BEFORE|$IMAGE@$NEW|" "$MANIFEST"
say "  $MANIFEST: ${BEFORE:0:19} -> ${NEW:0:19}"
kubectl apply -f "$MANIFEST" | sed 's/^/  /'
kubectl -n "$NS" rollout status deployment/laravel-spa-app --timeout=400s >/dev/null \
  || die "the live rollout stalled. The readiness probe is holding old pods in place, so the site is still up on the previous image. Roll back with: kubectl -n $NS rollout undo deployment/laravel-spa-app"
say "  rolled out"

# ---- 7. the step that makes a good deploy look broken ----
say ""
say "=== 7. clearing the page cache ==="
kubectl run "promote-cc-$RANDOM" -n "$NS" --rm -i --restart=Never --image="$IMAGE:latest" \
  --overrides="{\"spec\":{\"imagePullSecrets\":[{\"name\":\"ghcr-pull-secret\"}],\"containers\":[{\"name\":\"runner\",\"image\":\"$IMAGE:latest\",\"workingDir\":\"/var/www/html\",\"command\":[\"php\",\"artisan\",\"cache:clear\"],\"envFrom\":[{\"secretRef\":{\"name\":\"laravel-spa-secrets\"}}]}]}}" \
  2>/dev/null | grep -iE "cleared|error" | sed 's/^/  /'

# ---- 8. is the live site actually up? ----
say ""
say "=== 8. live ==="
for host in buyandsellpage.ca buyandsellpage.com; do
  c=$(serves_200_public "$host")
  say "  $host -> HTTPS $c"
  [ "$c" = "200" ] || die "$host answers $c over HTTPS. Roll back with: kubectl -n $NS rollout undo deployment/laravel-spa-app"
done

say ""
say "=== promoted. Commit the digest bump so the repo matches the cluster: ==="
say "    git add $MANIFEST && git commit -m 'Promote ${NEW:0:19} to live' && git push"
say ""
