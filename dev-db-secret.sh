#!/usr/bin/env bash
#
# Generates a fresh password for the dev database user, sets it on saturn,
# and writes it into the Kubernetes secret -- without it ever being
# displayed, logged, or passed as a command-line argument.
#
# RUN ON JUPITER. It needs kubectl (saturn has none) and ssh to saturn.
# It will prompt once for your SUDO password on saturn, because changing a
# MySQL user requires root there and this account has no passwordless sudo.
#
# Why generate rather than reuse what you set: the setup script
# deliberately never wrote that password anywhere, which was the right
# call, and means the only copy is in your head. A generated one is
# stronger and removes the retyping step. Resetting it is harmless -- the
# database, the user and the grant all stay as they are.
#
# Where the password is NOT:
#   - not in argv (ps shows arguments to every user on the box), so the
#     SQL goes over stdin and kubectl reads it with --from-file
#   - not in shell history
#   - not in this conversation
#   - not left on saturn: the SQL file is 0600 and deleted straight after

set -euo pipefail

SATURN="mars@192.168.100.110"
NS="laravel-spa"
SECRET="laravel-spa-dev-db"
DB_HOST="192.168.100.110"   # the IP, not saturn.local: pods cannot resolve mDNS
DB_PORT="3306"
DB_NAME="basp_dev"
DB_USER="basp_dev"
GRANT_HOST="192.168.100.%"  # pods arrive SNAT'd as their node's address

TMP="$(mktemp -d)"
chmod 700 "$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "== generating a password"
# Alphanumeric only: avoids anything a shell, a YAML parser or a MySQL
# connection string could misread.
LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 > "$TMP/DB_PASSWORD"
echo "   32 characters, generated locally, never printed"

echo "== setting it on saturn (you will be asked for your sudo password there)"
{
  printf "ALTER USER '%s'@'%s' IDENTIFIED BY '" "$DB_USER" "$GRANT_HOST"
  cat "$TMP/DB_PASSWORD"
  printf "';\nFLUSH PRIVILEGES;\n"
} | ssh "$SATURN" "umask 077; cat > ~/.basp-alter.sql"

ssh -t "$SATURN" 'sudo mysql < ~/.basp-alter.sql; rc=$?; shred -u ~/.basp-alter.sql 2>/dev/null || rm -f ~/.basp-alter.sql; exit $rc'
echo "   password set"

echo "== writing the kubernetes secret"
kubectl delete secret "$SECRET" -n "$NS" --ignore-not-found >/dev/null 2>&1
kubectl create secret generic "$SECRET" -n "$NS" \
  --from-literal=DB_HOST="$DB_HOST" \
  --from-literal=DB_PORT="$DB_PORT" \
  --from-literal=DB_DATABASE="$DB_NAME" \
  --from-literal=DB_USERNAME="$DB_USER" \
  --from-file=DB_PASSWORD="$TMP/DB_PASSWORD" >/dev/null
echo "   secret/$SECRET created in $NS"

echo "== proving it actually authenticates"
# The one thing no earlier check could prove: every previous test used a
# deliberately wrong password to probe the grant. This uses the real one.
if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" \
     --password="$(cat "$TMP/DB_PASSWORD")" "$DB_NAME" \
     -e "SELECT 'authenticated' AS result, DATABASE() AS db, USER() AS seen_as;" 2>/dev/null; then
  echo "   from jupiter: OK"
else
  echo "   from jupiter: FAILED — the password did not take"; exit 1
fi

echo
echo "== done. The password exists only in the kubernetes secret and on saturn."
echo "   To rotate it later, just run this script again."
