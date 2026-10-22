#!/usr/bin/env bash
#
# EXTERNAL uptime probe for buyandsellpage.ca / .com.
#
# WHY THIS EXISTS, and why it does not live in the cluster.
#
# Everything else that watches this site runs inside the cluster it is
# watching: Prometheus scrapes it, Alertmanager pages from it. That stack
# cannot report the one failure that matters most, because the failure
# takes the reporter with it. If the control plane goes, or MetalLB stops
# announcing the VIP, or Traefik dies, or the house loses its uplink, the
# in-cluster alerting does not fire a warning -- it goes quiet, and quiet
# is indistinguishable from healthy.
#
# jupiter is not a cluster node (192.168.100.114; the nodes are .101-.137),
# so it can observe a total cluster failure. It resolves the domains by
# public DNS and comes back in through the router, so a pass here exercises
# the whole real path: DNS -> public IP -> router -> MetalLB -> Traefik ->
# nginx -> php-fpm -> MySQL. That is strictly more than the in-cluster
# probes can see.
#
# WHAT IT STILL CANNOT SEE: jupiter is on the same LAN and the same power
# as the cluster. A house-wide outage takes out the site and the probe
# together, and you would get silence again. Closing that needs a probe
# off-premises -- see the note at the bottom of this file.
#
# WHY NOT A SYSTEMD USER TIMER: `loginctl show-user mars -p Linger` is
# `no`, so user units stop when the last session ends. Monitoring that
# silently stops when you log out is worse than no monitoring, because you
# believe you have it. System cron is active and a user crontab survives
# logout, so that is what schedules this.

set -uo pipefail

# ---------------------------------------------------------------- config
HOSTS=("buyandsellpage.ca:ca" "buyandsellpage.com:com")

# A third-party URL used ONLY to tell "the site is down" apart from "this
# machine has no internet". Google's generate_204 returns an empty 204, so
# it is the cheapest honest answer to "is it me?".
CONTROL_URL="https://www.google.com/generate_204"

TIMEOUT=20                 # seconds per request

# Identify this probe in the access logs so its traffic can be excluded
# from any view count. It runs every 5 minutes against two hostnames,
# which is 576 requests a day -- enough to dwarf real traffic on a new
# site and make a chart look like discovery when it is just monitoring.
# A default curl/x.y UA is indistinguishable from the scanners that
# arrive within seconds of a certificate hitting the public CT logs.
UA="BASP-UptimeProbe/1.0 (+internal monitoring from jupiter; not a visitor)"
FAIL_THRESHOLD=2           # consecutive bad runs before alerting (~10 min at */5)
REMIND_EVERY=12            # while still down, re-alert every N runs (~1 hour)
CERT_WARN_DAYS=14

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/basp-uptime"
STATE_FILE="$STATE_DIR/state.json"
LOG_FILE="$STATE_DIR/probe.log"
LOG_MAX_BYTES=1048576

# The webhook is read from a file, never passed as an argument -- arguments
# are visible in `ps` to every user on the box. 0600, and this script never
# echoes it.
WEBHOOK_FILE="${BASP_WEBHOOK_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/basp-uptime/discord-webhook}"

mkdir -p "$STATE_DIR"

# Timestamps in Central, not UTC. jupiter's system clock is UTC, and
# reading a UTC timestamp as local time has already caused a real
# misdiagnosis on this project -- a date rolled over in UTC while it was
# still the previous evening here. The offset is printed so there is
# nothing to infer.
log() {
  printf '%s  %s\n' "$(TZ=America/Chicago date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >> "$LOG_FILE"
  [ "${VERBOSE:-0}" = "1" ] && printf '%s\n' "$*"
  return 0
}

# Keep the log from growing without bound; cron output is nobody's friend.
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ]; then
  tail -c $((LOG_MAX_BYTES / 2)) "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

notify() {
  # $1 = message. Posts to Discord. Returns non-zero if it could not send,
  # which the caller logs -- a failed notification must not look like a
  # successful one.
  local msg="$1"
  if [ ! -r "$WEBHOOK_FILE" ]; then
    log "CANNOT NOTIFY: no readable webhook at $WEBHOOK_FILE"
    return 1
  fi
  local payload
  payload=$(MSG="$msg" python3 -c 'import json,os; print(json.dumps({"content": os.environ["MSG"]}))')
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" \
    -X POST -H 'Content-Type: application/json' \
    --data-binary "$payload" \
    --config <(printf 'url = "%s"\n' "$(cat "$WEBHOOK_FILE")") 2>/dev/null)
  case "$code" in
    2*) return 0 ;;
    *)  log "NOTIFY FAILED: discord returned $code"; return 1 ;;
  esac
}

# ------------------------------------------------------------ the checks
problems=()

check_host() {
  local host="$1" want_region="$2"
  local body code

  body=$(curl -s --max-time "$TIMEOUT" -A "$UA" -w '\n%{http_code}' "https://$host/" 2>/dev/null)
  if [ -z "$body" ]; then
    problems+=("$host: no response at all (DNS, TCP or TLS failed)")
    return
  fi
  code="${body##*$'\n'}"
  body="${body%$'\n'*}"

  if [ "$code" != "200" ]; then
    problems+=("$host: HTTP $code")
    return
  fi

  # 200 is not enough. The maintenance page, a Laravel error page and a
  # Basic-Auth prompt can all be 200-shaped from a monitor's point of
  # view, and an overflow checker on this project already false-passed on
  # a 401 for exactly this reason. Assert the app actually rendered.
  if ! printf '%s' "$body" | grep -q '&quot;component&quot;:&quot;Home&quot;'; then
    problems+=("$host: 200 but Inertia did not render Home (maintenance page, or an error page)")
    return
  fi

  # And assert it served the RIGHT region. The .ca/.com split is a real
  # feature with separate listings and contact addresses; if the wrong
  # region is served, the site is up and wrong, which no status code shows.
  if ! printf '%s' "$body" | grep -q "&quot;region&quot;:&quot;$want_region&quot;"; then
    local got
    got=$(printf '%s' "$body" | grep -oE '&quot;region&quot;:&quot;[a-z]+&quot;' | head -1)
    problems+=("$host: served the wrong region (wanted $want_region, got ${got:-none})")
    return
  fi

  log "ok   $host  HTTP 200, Home rendered, region $want_region"
}

check_cert() {
  local host="$1"
  command -v openssl >/dev/null 2>&1 || return 0
  local end days
  end=$(echo | timeout "$TIMEOUT" openssl s_client -servername "$host" -connect "$host:443" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  [ -n "$end" ] || { log "warn $host  could not read certificate expiry"; return 0; }
  days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
  log "cert $host  expires in $days day(s)"
  if [ "$days" -lt "$CERT_WARN_DAYS" ]; then
    problems+=("$host: TLS certificate expires in $days day(s)")
  fi
}

for pair in "${HOSTS[@]}"; do
  check_host "${pair%%:*}" "${pair##*:}"
  check_cert "${pair%%:*}"
done

# ------------------------------------------- is it the site, or just me?
if [ ${#problems[@]} -gt 0 ]; then
  if ! curl -s -o /dev/null --max-time "$TIMEOUT" -A "$UA" "$CONTROL_URL" 2>/dev/null; then
    # No internet from this box. Saying "the site is down" would be a
    # guess, and a wrong one often enough to train you to ignore it.
    log "LOCAL: ${#problems[@]} check(s) failed AND the control URL is unreachable -- treating as a local network fault, not alerting"
    exit 0
  fi
fi

# ------------------------------------------------------- state & alerting
# `notified_down` is NOT "a check failed" -- it is "we have already told
# someone". Conflating the two was a real bug here: the first failing
# run set down=true, so the second run took the "already down" branch
# and the opening alert was never sent at all. Monitoring that stays
# silent during an outage is the worst possible failure, so the two
# states are separate now and the test script covers it.
read -r prev_fails prev_notified_down prev_runs_since < <(
  python3 - "$STATE_FILE" <<'PY'
import json,sys,os
p=sys.argv[1]
d={}
if os.path.exists(p):
    try: d=json.load(open(p))
    except Exception: d={}
print(d.get("consecutive_failures",0), 1 if d.get("notified_down") else 0, d.get("runs_since_notify",0))
PY
)

now_bad=${#problems[@]}

if [ "$now_bad" -gt 0 ]; then
  fails=$((prev_fails + 1))
  summary=$(printf '%s\n' "${problems[@]}" | sed 's/^/\xe2\x80\xa2 /')
  log "FAIL ($fails consecutive): ${problems[*]}"

  notified_down="$prev_notified_down"
  runs_since="$prev_runs_since"
  should_notify=0

  if [ "$prev_notified_down" -eq 0 ]; then
    # Nobody told yet. Alert once the run of failures is long enough not
    # to be a blip.
    [ "$fails" -ge "$FAIL_THRESHOLD" ] && should_notify=1
  else
    # Already told. Remind periodically so an outage cannot be forgotten,
    # without alerting on every single run.
    runs_since=$((prev_runs_since + 1))
    [ "$runs_since" -ge "$REMIND_EVERY" ] && should_notify=1
  fi

  if [ "$should_notify" -eq 1 ]; then
    if notify "$(printf '\xf0\x9f\x94\xb4 **buyandsellpage is failing an external check**\n\nProbed from jupiter, which is outside the cluster \xe2\x80\x94 so this is what a visitor sees, not what the cluster thinks of itself.\n\n%s\n\n_%s consecutive failed run(s). The in-cluster alerts may be silent if the cluster itself is the problem._' "$summary" "$fails")"; then
      log "notified discord"
      notified_down=1
      runs_since=0
    else
      # Could NOT reach Discord. Deliberately do not record that we
      # notified: otherwise the outage would never be reported once the
      # webhook came back.
      log "wanted to notify but could not -- will retry next run"
    fi
  fi
else
  fails=0
  runs_since=0
  notified_down=0
  # Only announce recovery if an alarm was actually raised. A single
  # sub-threshold blip must not produce an all-clear for something nobody
  # was ever told about.
  if [ "$prev_notified_down" -eq 1 ]; then
    if notify "$(printf '\xe2\x9c\x85 **buyandsellpage is answering again**\n\nBoth hostnames return 200, Inertia renders Home, and each serves its own region. Checked from outside the cluster.')"; then
      log "RECOVERED -- notified discord"
    else
      log "RECOVERED -- could not notify"
    fi
  elif [ "$prev_fails" -gt 0 ]; then
    log "recovered from $prev_fails sub-threshold failure(s); nobody was alerted, so no all-clear sent"
  fi
fi

python3 - "$STATE_FILE" "$fails" "$notified_down" "$runs_since" <<'PY'
import json,sys
p,f,n,r=sys.argv[1],int(sys.argv[2]),int(sys.argv[3]),int(sys.argv[4])
json.dump({"consecutive_failures":f,"notified_down":bool(n),"runs_since_notify":r}, open(p,"w"))
PY

exit 0

# ---------------------------------------------------------------------
# THE REMAINING GAP, recorded rather than quietly left open.
#
# This probe and the cluster share a building, a power supply and an
# uplink. A failure of any of those three is invisible to BOTH, and the
# symptom is silence.
#
# The cheap fix is a dead-man's switch on a free external service
# (healthchecks.io is the usual one): this script pings a unique URL on
# every SUCCESSFUL run, and the service alerts if the pings stop. That
# inverts the logic -- instead of something having to reach out and say
# "it is broken", the absence of a heartbeat is itself the alarm, so it
# survives the cluster, the probe and the house all going dark.
#
# It needs an account, so it is left for a human to create. Once there is
# a ping URL, add to the success branch above:
#
#     curl -fsS --max-time 10 -o /dev/null "$(cat "$PING_URL_FILE")" || log "heartbeat ping failed"
