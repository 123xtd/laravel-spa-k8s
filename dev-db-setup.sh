#!/usr/bin/env bash
#
# Sets up the DEVELOPMENT database for buyandsellpage.
#
# RUN THIS ON THE DEV DATABASE BOX (192.168.100.110), not on jupiter and
# not on a cluster node.
#
# Why that box: the real MySQL lives outside the cluster at
# 192.168.100.111, so a separate external box mirrors production's
# topology rather than inventing a new one. It is also neither the
# workstation nor the production database server, so development cannot
# reach live data by accident -- which was the whole point. The existing
# clone is deliberately left sharing the live database, so it stays
# usable as a comparison tier.
#
# Ubuntu 26.04 ships MySQL 8.4.11, which is exactly what production runs
# (verified: 8.4.11-0ubuntu0.26.04.1). Same major, same minor, no
# surprises between dev and live.
#
# Safe to re-run: every step checks first.

set -euo pipefail

DB_NAME="basp_dev"
DB_USER="basp_dev"
# Pods reach an external address SNAT'd to their NODE's ip, not their own
# -- verified by asking the live database what it sees: the connection
# arrived as laravel@192.168.100.123 (a node) and matched the grant
# laravel@192.168.100.%. So the grant is a subnet wildcard, mirroring how
# production is already configured. A per-pod grant would never match.
GRANT_HOST="192.168.100.%"
LAN="192.168.100.0/24"

say() { printf '\n== %s\n' "$*"; }

say "checking the machine"
if ! grep -qi ubuntu /etc/os-release; then
  echo "   this does not look like Ubuntu. Stopping."; exit 1
fi
echo "   $(. /etc/os-release && echo "$PRETTY_NAME")"
echo "   address(es): $(hostname -I)"
case "$(hostname -I)" in
  *192.168.100.110*) ;;
  *) echo "   WARNING: expected to run on 192.168.100.110. Continue only if you moved it." ;;
esac

say "installing mysql-server (skipped if present)"
if command -v mysqld >/dev/null 2>&1; then
  echo "   already installed: $(mysqld --version | head -1)"
else
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server
  echo "   installed: $(mysqld --version | head -1)"
fi

say "allowing connections from the cluster"
CNF=/etc/mysql/mysql.conf.d/99-basp-dev.cnf
if [ -f "$CNF" ] && grep -q "bind-address" "$CNF"; then
  echo "   $CNF already present"
else
  # 0.0.0.0 rather than the literal address: if this box is on DHCP and
  # its lease changes, binding to a fixed address stops mysql starting.
  # The firewall rule below is what actually limits exposure.
  sudo tee "$CNF" >/dev/null <<'EOF'
[mysqld]
bind-address = 0.0.0.0
EOF
  echo "   wrote $CNF"
fi
sudo systemctl restart mysql
sudo systemctl is-active mysql | sed 's/^/   mysql is /'

say "database and user"
echo "   Choose a password for the '$DB_USER' user."
echo "   It is NOT echoed, NOT written to disk, and NOT passed as an argument"
echo "   (arguments are visible in ps to every user on this box)."
read -r -s -p "   password: " DB_PASS; echo
read -r -s -p "   again   : " DB_PASS2; echo
[ "$DB_PASS" = "$DB_PASS2" ] || { echo "   they do not match. Stopping."; exit 1; }
[ -n "$DB_PASS" ] || { echo "   empty password. Stopping."; exit 1; }

sudo mysql <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'${GRANT_HOST}' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'${GRANT_HOST}' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${GRANT_HOST}';
FLUSH PRIVILEGES;
EOF
unset DB_PASS DB_PASS2
echo "   database '${DB_NAME}' and user '${DB_USER}'@'${GRANT_HOST}' are ready"

say "firewall"
if command -v ufw >/dev/null 2>&1 && sudo ufw status | head -1 | grep -qi active; then
  sudo ufw allow from "$LAN" to any port 3306 proto tcp
  echo "   allowed 3306 from $LAN only"
else
  echo "   ufw is not active — nothing to open. Note that bind-address is"
  echo "   0.0.0.0, so 3306 is reachable from anything on this network."
fi

say "checking it from here"
sudo mysql -e "SELECT @@version AS version, @@bind_address AS bind_address;" | sed 's/^/   /'

cat <<'NEXT'

== done. Next:

  1. Tell Claude it is ready. It will verify reachability from jupiter
     and from inside the cluster.

  2. Create the Kubernetes secret FROM YOUR OWN SHELL so the password
     never passes through the conversation:

       kubectl create secret generic laravel-spa-dev-db \
         -n laravel-spa \
         --from-literal=DB_HOST=192.168.100.110 \
         --from-literal=DB_PORT=3306 \
         --from-literal=DB_DATABASE=basp_dev \
         --from-literal=DB_USERNAME=basp_dev \
         --from-literal=DB_PASSWORD='the-password-you-just-set'

  3. If this box is on DHCP, give it a reservation. The dev tier breaks
     if .110 moves.

NEXT
