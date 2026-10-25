#!/usr/bin/env bash
#
# Creates a user account in the DEVELOPMENT database (basp_dev on saturn).
#
# RUN ON JUPITER. Needs kubectl.
#
# Why this exists: basp_dev starts empty, so there is nothing to log into
# on ba-sp.com even though the Basic Auth wall lets you through. The live
# account does not help -- that is the isolation working, not a fault.
#
# Why not just register through the form: reCAPTCHA v3 guards
# registration and its site key is domain-restricted at Google. On
# ba-sp.com the grecaptcha object never initialises, so whether a
# registration would complete is unknown. This path does not involve it.
#
# The password:
#   - prompted for, never echoed
#   - never in argv on this machine or inside the pod (ps shows arguments
#     to every user on the box)
#   - base64'd in transit purely so quoting cannot mangle it, which is
#     encoding, not secrecy
#   - hashed by Laravel's own Hash::make, so it matches what the login
#     form expects
#
# email_verified_at is set deliberately. Without it the account exists but
# every page bounces to "verify your email", and dev has no working mail.

set -euo pipefail

NS="laravel-spa"
DEPLOY="deploy/laravel-spa-app-dev"

echo "== creating a user in basp_dev (the dev database, not live)"

read -r -p "   name    : " NEWNAME
read -r -p "   email   : " NEWEMAIL
read -r -s -p "   password: " NEWPASS; echo
read -r -s -p "   again   : " NEWPASS2; echo
[ "$NEWPASS" = "$NEWPASS2" ] || { echo "   passwords do not match. Stopping."; exit 1; }
[ -n "$NEWPASS" ] || { echo "   empty password. Stopping."; exit 1; }
[ -n "$NEWEMAIL" ] || { echo "   empty email. Stopping."; exit 1; }

B64_PASS=$(printf '%s' "$NEWPASS" | base64 -w0)
B64_EMAIL=$(printf '%s' "$NEWEMAIL" | base64 -w0)
B64_NAME=$(printf '%s' "$NEWNAME" | base64 -w0)
unset NEWPASS NEWPASS2

# A guard worth having: refuse to run against anything but the dev
# database. One wrong context and this would be creating accounts on the
# live site.
DB=$(kubectl exec -n "$NS" "$DEPLOY" -c app -- printenv DB_DATABASE 2>/dev/null | tr -d '\r')
if [ "$DB" != "basp_dev" ]; then
  echo "   REFUSING: that deployment's DB_DATABASE is '$DB', not basp_dev."
  exit 1
fi
echo "   target database confirmed: $DB"

# The code goes in on stdin rather than as an argument.
cat <<PHP | kubectl exec -i -n "$NS" "$DEPLOY" -c app -- php artisan tinker
\$email = base64_decode('${B64_EMAIL}');
\$name  = base64_decode('${B64_NAME}');
\$pass  = base64_decode('${B64_PASS}');
if (\App\Models\User::where('email', \$email)->exists()) {
    \$u = \App\Models\User::where('email', \$email)->first();
    \$u->password = \Illuminate\Support\Facades\Hash::make(\$pass);
    \$u->email_verified_at = \$u->email_verified_at ?: now();
    \$u->save();
    echo "updated existing account id {\$u->id}\n";
} else {
    \$u = \App\Models\User::create([
        'name' => \$name,
        'email' => \$email,
        'password' => \Illuminate\Support\Facades\Hash::make(\$pass),
        'email_verified_at' => now(),
    ]);
    echo "created account id {\$u->id}\n";
}
PHP

echo
echo "== done. Sign in at https://ba-sp.com with that email and password."
echo "   (The Basic Auth prompt first, then the application's own form.)"
