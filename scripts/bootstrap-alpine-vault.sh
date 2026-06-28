#!/bin/sh
# Bootstrap the dedicated Alpine backend after Terraform created the VM.
# This script is copied and executed by GitHub Actions over SSH.

set -eu

SSH_PORT="${VAULT_SSH_PORT:-2222}"
APP_PORT="${VAULT_APP_PORT:-8443}"
APP_DIR="${VAULT_APP_DIR:-/opt/opale-vault}"
ADMIN_USER="${VAULT_ADMIN_USER:-root}"
RUN_SYNC="${VAULT_RUN_SYNC:-true}"

require_file() {
  if [ ! -f "$1" ]; then
    echo "Missing required file: $1" >&2
    exit 1
  fi
}

require_file /tmp/harden-alpine-vps.sh
require_file /tmp/opale-vault-sync.sh
require_file /tmp/deploy.env

install -m 700 /tmp/harden-alpine-vps.sh /root/harden-alpine-vps.sh
install -m 700 /tmp/opale-vault-sync.sh /usr/local/bin/opale-vault-sync

mkdir -p "$APP_DIR" /etc/local.d /etc/periodic/15min
install -m 600 /tmp/deploy.env "$APP_DIR/deploy.env"

/bin/sh /root/harden-alpine-vps.sh \
  --ssh-port "$SSH_PORT" \
  --app-port "$APP_PORT" \
  --admin-user "$ADMIN_USER" \
  --app-dir "$APP_DIR"

cat >/etc/local.d/opale-vault-sync.start <<'SCRIPT'
#!/bin/sh
/usr/local/bin/opale-vault-sync >>/var/log/opale-vault-sync.log 2>&1 &
SCRIPT

cat >/etc/periodic/15min/opale-vault-sync <<'SCRIPT'
#!/bin/sh
/usr/local/bin/opale-vault-sync >>/var/log/opale-vault-sync.log 2>&1
SCRIPT

chmod 755 /etc/local.d/opale-vault-sync.start /etc/periodic/15min/opale-vault-sync
rc-update add local default

if [ "$RUN_SYNC" = "true" ]; then
  /usr/local/bin/opale-vault-sync
fi
