#!/bin/sh
# Installe/actualise les timers de maintenance Opale pour un service (systemd).
# Idempotent : sûr au premier boot (cloud-init) et à chaque ré-exécution.
# Possédé par opale-infrastructure (doctrine DevOps : maintenance ≠ déploiement).
#
# Ce script pose les scripts, les unités systemd templatées et l'EnvironmentFile
# du service, active unattended-upgrades, puis active les timers backup /
# selfcheck / harden. Il ne déploie AUCUNE application.
#
# Usage :
#   opale-maintenance-install.sh \
#     --service opale-vault \
#     --volume opale-vault_vault-data \
#     --health-url https://127.0.0.1:8443/api/health \
#     --health-expect '"status":"ok"' \
#     --ssh-port 2222 --app-port 8443 --admin-user ubuntu --app-dir /opt/opale-vault \
#     [--cert-path <pem>] [--key-stamp <file>] [--offsite user@host:/path] \
#     [--src-dir <dir contenant ce script et units/>]

set -eu

SERVICE=""
VOLUME=""
HEALTH_URL=""
HEALTH_EXPECT=""
SSH_PORT="2222"
APP_PORT=""
ADMIN_USER="ubuntu"
APP_DIR=""
CERT_PATH=""
KEY_STAMP=""
OFFSITE=""
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --service) SERVICE="$2"; shift 2 ;;
    --volume) VOLUME="$2"; shift 2 ;;
    --health-url) HEALTH_URL="$2"; shift 2 ;;
    --health-expect) HEALTH_EXPECT="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --app-port) APP_PORT="$2"; shift 2 ;;
    --admin-user) ADMIN_USER="$2"; shift 2 ;;
    --app-dir) APP_DIR="$2"; shift 2 ;;
    --cert-path) CERT_PATH="$2"; shift 2 ;;
    --key-stamp) KEY_STAMP="$2"; shift 2 ;;
    --offsite) OFFSITE="$2"; shift 2 ;;
    --src-dir) SRC_DIR="$2"; shift 2 ;;
    *) echo "Option inconnue: $1" >&2; exit 1 ;;
  esac
done

[ -n "$SERVICE" ] || { echo "--service requis" >&2; exit 1; }
[ -n "$VOLUME" ]  || { echo "--volume requis" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "doit s'exécuter en root" >&2; exit 1; }

log() { printf '%s [maint-install] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

LIB_DIR="/usr/local/lib/opale-maintenance"
ENV_DIR="/etc/opale/maintenance"
BACKUP_ROOT="/opt/opale-backups"

# 1. Scripts de maintenance.
log "Installation des scripts dans $LIB_DIR"
install -d -m 0755 "$LIB_DIR"
install -m 0755 "$SRC_DIR/opale-backup.sh" "$LIB_DIR/opale-backup.sh"
install -m 0755 "$SRC_DIR/opale-selfcheck.sh" "$LIB_DIR/opale-selfcheck.sh"

# 2. EnvironmentFile du service (0600 : peut contenir une cible off-site).
log "Écriture de l'EnvironmentFile $ENV_DIR/$SERVICE.env"
install -d -m 0700 "$ENV_DIR"
umask 077
cat > "$ENV_DIR/$SERVICE.env" <<EOF
OPALE_SERVICE=$SERVICE
OPALE_BACKUP_VOLUME=$VOLUME
OPALE_BACKUP_DIR=$BACKUP_ROOT
OPALE_BACKUP_KEEP=14
OPALE_BACKUP_OFFSITE=$OFFSITE
OPALE_HEALTH_URL=$HEALTH_URL
OPALE_HEALTH_EXPECT=$HEALTH_EXPECT
OPALE_CERT_PATH=$CERT_PATH
OPALE_CERT_WARN_DAYS=30
OPALE_KEY_STAMP=$KEY_STAMP
OPALE_KEY_MAX_DAYS=180
OPALE_BACKUP_MAX_AGE_H=48
OPALE_SSH_PORT=$SSH_PORT
OPALE_APP_PORT=$APP_PORT
OPALE_ADMIN_USER=$ADMIN_USER
OPALE_APP_DIR=$APP_DIR
EOF
chmod 0600 "$ENV_DIR/$SERVICE.env"

# 3. Unités systemd templatées.
log "Installation des unités systemd"
for u in opale-backup@.service opale-backup@.timer \
         opale-selfcheck@.service opale-selfcheck@.timer \
         opale-harden@.service opale-harden@.timer; do
  install -m 0644 "$SRC_DIR/units/$u" "/etc/systemd/system/$u"
done

# 4. Backups locaux : répertoire protégé.
install -d -m 0700 "$BACKUP_ROOT"

# 5. unattended-upgrades (patches sécurité OS).
if command -v unattended-upgrade >/dev/null 2>&1 || dpkg -s unattended-upgrades >/dev/null 2>&1; then
  log "Activation de unattended-upgrades"
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
else
  log "AVERTISSEMENT: unattended-upgrades absent (le hardening devrait l'installer)"
fi

# 6. Activation des timers.
log "Activation des timers de maintenance pour $SERVICE"
systemctl daemon-reload
for t in opale-backup opale-selfcheck opale-harden; do
  systemctl enable --now "${t}@${SERVICE}.timer" >/dev/null 2>&1
done

log "Maintenance installée. Timers actifs :"
systemctl list-timers "opale-*@${SERVICE}.timer" --no-pager 2>/dev/null || true
