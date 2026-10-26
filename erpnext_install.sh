#!/usr/bin/env bash
# Fresh Ubuntu 24.04 Frappe/ERPNext v15 installer.
# Run as a regular sudo-capable user; do NOT run as root.
# This script deliberately refuses to overwrite an existing bench.
set -Eeuo pipefail
trap 'rc=$?; echo "ERROR line $LINENO (exit $rc). Review command output above." >&2' ERR

log(){ printf '\n\033[1;34m%s\033[0m\n' "$*"; }
fatal(){ echo "ERROR: $*" >&2; exit 1; }
command -v lsb_release >/dev/null || fatal 'lsb_release unavailable'
[[ "$(lsb_release -is)" == 'Ubuntu' && "$(lsb_release -rs)" == '24.04' ]] || fatal 'This script targets Ubuntu 24.04 only'
[[ "$EUID" -ne 0 ]] || fatal 'Run as a normal sudo user, not root'
sudo -v
[[ -n "${HOME:-}" && "$HOME" == "/home/$USER" ]] || fatal 'Expected a standard /home/<user> account'

read -rp 'Site FQDN (e.g. erp.example.com): ' SITE
[[ "$SITE" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ && "$SITE" == *.* ]] || fatal 'Use a valid fully qualified domain name'
read -rp 'Bench folder [frappe-bench]: ' BENCH
BENCH="${BENCH:-frappe-bench}"
[[ "$BENCH" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || fatal 'Invalid bench directory name'
[[ ! -e "$HOME/$BENCH" ]] || fatal "Existing bench $HOME/$BENCH detected; refusing to overwrite"
read -rsp 'New MariaDB root password (used only on fresh database): ' DBPASS; echo
read -rsp 'New Frappe Administrator password: ' ADMINPASS; echo
[[ -n "$DBPASS" && -n "$ADMINPASS" ]] || fatal 'Passwords cannot be empty'
# Avoid password interpolation into SQL, shell commands or process arguments for DB provisioning.
# Ubuntu MariaDB root can authenticate over the local socket by default; Bench prompts for a DB root password.
# Configure root with safely escaped SQL on a fresh, single-purpose instance only.

log 'Installing system prerequisites'
sudo apt-get update
sudo apt-get install -y git curl wget ca-certificates gnupg lsb-release python3-dev python3-venv python3-pip python3-setuptools build-essential pkg-config libmariadb-dev libffi-dev libssl-dev mariadb-server mariadb-client redis-server supervisor nginx cron fontconfig xvfb libxrender1 xfonts-base pipx
sudo systemctl enable --now mariadb supervisor nginx

log 'Setting MariaDB root password (fresh instance only)'
# Check that local unix-socket root login is available and no Frappe DB exists.
if ! sudo mariadb --protocol=socket -u root -N -e 'SELECT 1' >/dev/null 2>&1; then
  fatal 'MariaDB root socket login unavailable; configure database manually (installer will not reset existing credentials)'
fi
# Restrict this step to a database with no user-created databases.
DATABASES=$(sudo mariadb --protocol=socket -u root -N -e 'SHOW DATABASES' | grep -Ev '^(information_schema|performance_schema|mysql|sys)$' || true)
[[ -z "$DATABASES" ]] || fatal "Non-system databases already exist; refusing to reset MariaDB root. Databases: $DATABASES"
# Encode the password as hex and use a SQL string expression rather than unsafe quotation.
HEX=$(printf '%s' "$DBPASS" | od -An -tx1 | tr -d ' \n')
[[ -n "$HEX" ]] || fatal 'Invalid DB password'
sudo mariadb --protocol=socket -u root <<SQL
SET @newpass = CONVERT(0x${HEX} USING utf8mb4);
SET @stmt = CONCAT('ALTER USER ''root''@''localhost'' IDENTIFIED BY ', QUOTE(@newpass));
PREPARE pwstmt FROM @stmt;
EXECUTE pwstmt;
DEALLOCATE PREPARE pwstmt;
FLUSH PRIVILEGES;
SQL
# Use socket-based auth or securely provision an installer user for an existing DB instead.
# Client configuration should live in a separate .cnf, not appended repeatedly.
sudo tee /etc/mysql/mariadb.conf.d/90-frappe-utf8.cnf >/dev/null <<'MYSQL'
[mysqld]
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
[client]
default-character-set=utf8mb4
MYSQL
sudo systemctl restart mariadb

log 'Installing Node 20 LTS for this Frappe v15 bench'
export NVM_DIR="$HOME/.nvm"
if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
 curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
fi
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"
nvm install 20
nvm alias default 20
nvm use 20
npm install -g yarn@1.22.22

log 'Installing Bench via pipx (avoids breaking system Python)'
pipx install frappe-bench
export PATH="$HOME/.local/bin:$PATH"
command -v bench >/dev/null || fatal 'bench not on PATH'

log 'Initializing version-15 bench'
cd "$HOME"
bench init "$BENCH" --frappe-branch version-15 --python /usr/bin/python3
cd "$BENCH"

log 'Creating site and installing compatible apps'
# Pass passwords through Bench CLI, with shell history disabled; process args may still be visible briefly.
bench new-site "$SITE" --db-root-username root --db-root-password "$DBPASS" --admin-password "$ADMINPASS"
unset ADMINPASS DBPASS
bench get-app --branch version-15 erpnext https://github.com/frappe/erpnext.git
bench --site "$SITE" install-app erpnext
bench get-app --branch version-15 hrms https://github.com/frappe/hrms.git
bench --site "$SITE" install-app hrms
bench get-app --branch version-15.2 education https://github.com/frappe/education.git
bench --site "$SITE" install-app education
bench --site "$SITE" migrate
bench build

log 'Preflight: checking ports and existing Supervisor configs'
if sudo ss -ltnp | grep -E ':(11000|12000|13000|8000|9000)[[:space:]]' ; then
  fatal 'One or more bench service ports are occupied. Resolve conflicts BEFORE production setup.'
fi
if sudo grep -Rl --include='*.conf' 'redis_\|redis-server\|frappe-bench' /etc/supervisor/conf.d/ 2>/dev/null | grep -q .; then
  fatal 'Existing Frappe/Supervisor configurations detected. Avoid installing another bench on same ports.'
fi

log 'Applying Bench production configuration once'
# sudo must see the same PATH, especially the nvm Node path.
# Avoid editing /etc/supervisor/supervisord.conf or manually launching Redis.
sudo env "PATH=$PATH" bench setup production "$USER" --yes
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl status
bench --site "$SITE" scheduler enable

log 'Final checks'
bench version
sudo nginx -t
sudo systemctl is-active nginx mariadb supervisor
printf '\nInstallation attempt complete. Configure DNS and TLS separately before public launch.\n'
