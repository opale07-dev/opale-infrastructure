#!/bin/sh
# Installe / met à jour les timers de maintenance Opale sur une VM existante,
# sans rebuild. Maintenance de la maintenance — ne déploie aucune application.
#
# Usage : scripts/opale-maintenance-remote.sh <ip> [--offsite user@host:/path]
#
# Pousse le module maintenance/ vers la VM et exécute l'installeur idempotent.
# Réutilisable pour pay/data en adaptant les paramètres du bloc "case" ci-dessous.

set -eu

IP="${1:?Usage: opale-maintenance-remote.sh <ip> [--offsite <dest>]}"
OFFSITE=""
[ "${2:-}" = "--offsite" ] && OFFSITE="${3:?destination off-site requise}"

SSH_KEY="${VAULT_SSH_KEY:-$HOME/Dev/ProjetsPerso/.key/opale-vault-deploy.key}"
SRC="$(cd "$(dirname "$0")/../maintenance" && pwd)"

# Paramètres du service Vault (adapter pour un autre service).
SERVICE="opale-vault"
VOLUME="opale-vault_vault-data"
APP_DIR="/opt/opale-vault"
APP_PORT="8443"

echo "=== Push du module maintenance vers $IP ==="
ssh -i "$SSH_KEY" -p 2222 "ubuntu@$IP" 'sudo mkdir -p /opt/opale-maintenance-src && sudo chown ubuntu:ubuntu /opt/opale-maintenance-src'
scp -i "$SSH_KEY" -P 2222 -r "$SRC"/. "ubuntu@$IP:/opt/opale-maintenance-src/"

echo "=== Installation des timers de maintenance ==="
ssh -i "$SSH_KEY" -p 2222 "ubuntu@$IP" "
  set -eu
  chmod +x /opt/opale-maintenance-src/*.sh
  sudo /opt/opale-maintenance-src/opale-maintenance-install.sh \
    --service $SERVICE \
    --volume $VOLUME \
    --health-url https://127.0.0.1:$APP_PORT/api/health \
    --health-expect '\"status\":\"ok\"' \
    --ssh-port 2222 --app-port $APP_PORT --admin-user ubuntu --app-dir $APP_DIR \
    --cert-path $APP_DIR/tls/backend.crt \
    ${OFFSITE:+--offsite $OFFSITE} \
    --src-dir /opt/opale-maintenance-src
  echo '--- Timers actifs :'
  systemctl list-timers 'opale-*@$SERVICE.timer' --no-pager || true
"
