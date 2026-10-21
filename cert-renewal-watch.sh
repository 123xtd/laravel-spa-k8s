#!/usr/bin/env bash
#
# Tells you when the live TLS certificate is about to renew, and then
# whether it actually did.
#
# WHY THIS RATHER THAN A CALENDAR ENTRY
#
# The thing worth knowing is not the date -- it is whether cert-manager
# succeeded. A dated reminder fires whether or not anything happened, and
# recurs every year on a date that stops meaning anything after the first
# renewal. This reads the certificate instead, so it reports the event.
#
# It exists because the ACME path has NOT been exercised since go-live
# rerouted things on 2026-10-20. The last successful issuance was
# 2026-09-13, under the old routing. The solver is HTTP-01 through the
# Traefik ingress class, Traefik does have --providers.kubernetesingress,
# and there is no entrypoint-level HTTPS redirect -- so it should work.
# But Traefik ranks routers by rule length, the live HTTP route's rule is
# 122 characters and a challenge route's is about 114, so which one takes
# the challenge request was never measured. This watches the outcome.
#
# Three notices, each sent at most once per renewal cycle:
#   heads-up  -- renewal is a few days out
#   renewed   -- the revision went up; renewal worked, with the new expiry
#   overdue   -- the renewal date passed and the revision did not move
#
# Independent of this, Prometheus alerts under 14 days to expiry and
# uptime-probe.sh warns at the same threshold from outside the cluster.
# This script is the early, specific warning; those two are the backstop.

set -uo pipefail

NS=laravel-spa
CERT=buyandsellpage-cert

HEADS_UP_DAYS="${HEADS_UP_DAYS:-4}"   # how many days before renewal to speak up
OVERDUE_GRACE_DAYS="${OVERDUE_GRACE_DAYS:-2}"
OVERDUE_REPEAT_DAYS="${OVERDUE_REPEAT_DAYS:-7}"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/basp-uptime"
STATE_FILE="$STATE_DIR/cert-watch.json"
LOG_FILE="$STATE_DIR/cert-watch.log"
WEBHOOK_FILE="${BASP_WEBHOOK_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/basp-uptime/discord-webhook}"

mkdir -p "$STATE_DIR"

log() {
  printf '%s  %s\n' "$(TZ=America/Chicago date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >> "$LOG_FILE"
  [ "${VERBOSE:-0}" = "1" ] && printf '%s\n' "$*"
  return 0
}

notify() {
  local msg="$1"
  if [ ! -r "$WEBHOOK_FILE" ]; then
    log "CANNOT NOTIFY: no readable webhook at $WEBHOOK_FILE"
    return 1
  fi
  local payload code
  payload=$(MSG="$msg" python3 -c 'import json,os; print(json.dumps({"content": os.environ["MSG"]}))')
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -X POST -H 'Content-Type: application/json' --data-binary "$payload" \
    --config <(printf 'url = "%s"\n' "$(cat "$WEBHOOK_FILE")") 2>/dev/null)
  case "$code" in
    2*) return 0 ;;
    *)  log "NOTIFY FAILED: discord returned $code"; return 1 ;;
  esac
}

# ------------------------------------------------------------ read state
cert_json=$(kubectl get certificate "$CERT" -n "$NS" -o json 2>/dev/null)
if [ -z "$cert_json" ]; then
  log "could not read certificate $CERT in $NS -- is the cluster reachable?"
  exit 0
fi

read -r revision days_to_renewal days_to_expiry expiry_date renewal_date ready < <(
  CERT_JSON="$cert_json" python3 <<'PYEOF'
import json, os, datetime
d = json.loads(os.environ["CERT_JSON"])
st = d.get("status", {})
now = datetime.datetime.now(datetime.timezone.utc)
def parse(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None
na, rt = parse(st.get("notAfter")), parse(st.get("renewalTime"))
ready = "unknown"
for c in st.get("conditions", []):
    if c.get("type") == "Ready":
        ready = c.get("status", "unknown")
print(
    st.get("revision", 0),
    int((rt - now).total_seconds() // 86400) if rt else 9999,
    int((na - now).total_seconds() // 86400) if na else 9999,
    na.strftime("%Y-%m-%d") if na else "unknown",
    rt.strftime("%Y-%m-%d") if rt else "unknown",
    ready,
)
PYEOF
)

read -r prev_revision sent_headsup sent_overdue_at < <(
  python3 - "$STATE_FILE" <<'PYEOF'
import json, sys, os
p = sys.argv[1]
d = {}
if os.path.exists(p):
    try:
        d = json.load(open(p))
    except Exception:
        d = {}
print(d.get("revision", 0), 1 if d.get("sent_headsup") else 0, d.get("sent_overdue_at", 0))
PYEOF
)

today_epoch=$(( $(date +%s) / 86400 ))
log "revision=$revision ready=$ready renewal in ${days_to_renewal}d ($renewal_date), expires in ${days_to_expiry}d ($expiry_date)"

# --------------------------------------------------------------- notices
if [ "$revision" -gt "$prev_revision" ] && [ "$prev_revision" -gt 0 ]; then
  # The revision moved. That is the answer we were waiting for.
  if notify "$(printf '\xf0\x9f\x94\x92 **The live TLS certificate renewed successfully**\n\nbuyandsellpage-cert is now revision %s, valid until **%s** (%s days).\n\nThis was the open question: the ACME HTTP-01 path had not been exercised since go-live changed the Traefik routing. It works. Nothing to do.' "$revision" "$expiry_date" "$days_to_expiry")"; then
    log "notified: renewed to revision $revision"
  fi
  sent_headsup=0
  sent_overdue_at=0

elif [ "$days_to_renewal" -le "$HEADS_UP_DAYS" ] && [ "$days_to_renewal" -ge 0 ] && [ "$sent_headsup" -eq 0 ]; then
  if notify "$(printf '\xf0\x9f\x93\x85 **Heads-up: the live TLS certificate renews in %s day(s)** (%s)\n\nYou asked to be reminded a few days out.\n\nbuyandsellpage-cert expires %s. cert-manager should renew it automatically — but the HTTP-01 challenge path has not been exercised since go-live rerouted Traefik on 2026-10-20, so this is the first renewal that proves it.\n\nI will post again either way: a confirmation if the revision moves, or a warning if the date passes and it does not. Prometheus and the external probe both still alert under 14 days as a backstop.' "$days_to_renewal" "$renewal_date" "$expiry_date")"; then
    log "notified: heads-up, renewal in ${days_to_renewal}d"
    sent_headsup=1
  fi

elif [ "$days_to_renewal" -lt "$(( -OVERDUE_GRACE_DAYS ))" ]; then
  # Past the renewal date with no revision bump.
  if [ "$sent_overdue_at" -eq 0 ] || [ "$(( today_epoch - sent_overdue_at ))" -ge "$OVERDUE_REPEAT_DAYS" ]; then
    if notify "$(printf '\xe2\x9a\xa0\xef\xb8\x8f **The live TLS certificate has NOT renewed**\n\nbuyandsellpage-cert was due to renew on %s — %s day(s) ago — and is still revision %s. It expires **%s**, in %s days.\n\nThis is the failure mode that was flagged as unverified: the HTTP-01 challenge likely is not reaching cert-manager through the current Traefik routing.\n\nTo investigate:\n```\nkubectl describe certificate %s -n %s\nkubectl get order,challenge -n %s\n```' "$renewal_date" "$(( -days_to_renewal ))" "$revision" "$expiry_date" "$days_to_expiry" "$CERT" "$NS" "$NS")"; then
      log "notified: OVERDUE, still revision $revision"
      sent_overdue_at=$today_epoch
    fi
  fi
fi

python3 - "$STATE_FILE" "$revision" "$sent_headsup" "$sent_overdue_at" <<'PYEOF'
import json, sys
p, rev, hu, ov = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
json.dump({"revision": rev, "sent_headsup": bool(hu), "sent_overdue_at": ov}, open(p, "w"))
PYEOF

exit 0
