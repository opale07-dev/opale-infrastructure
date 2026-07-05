#!/bin/sh
# Backup de maintenance d'un service Opale — local-first, puis off-site optionnel.
# Sauvegarde un volume Docker nommé (données chiffrées au repos) sans arrêter
# le service. Idempotent, fail-safe : une erreur alerte (log + exit non nul
# capté par systemd) mais ne touche jamais au conteneur applicatif.
#
# Maintenance host-only : ne tire aucune image, ne change aucune version d'app.
#
# Variables (fournies par l'unité systemd) :
#   OPALE_SERVICE          nom du service (ex. opale-vault)
#   OPALE_BACKUP_VOLUME    volume Docker à sauvegarder (ex. opale-vault_vault-data)
#   OPALE_BACKUP_DIR       répertoire local des backups (défaut /opt/opale-backups)
#   OPALE_BACKUP_KEEP      nombre d'archives locales à conserver (défaut 14)
#   OPALE_BACKUP_OFFSITE   destination rsync off-site (ex. user@host:/chemin) ;
#                          vide = local uniquement (première étape)

set -eu

SERVICE="${OPALE_SERVICE:?OPALE_SERVICE requis}"
VOLUME="${OPALE_BACKUP_VOLUME:?OPALE_BACKUP_VOLUME requis}"
BACKUP_DIR="${OPALE_BACKUP_DIR:-/opt/opale-backups}/${SERVICE}"
KEEP="${OPALE_BACKUP_KEEP:-14}"
OFFSITE="${OPALE_BACKUP_OFFSITE:-}"

STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
ARCHIVE="${BACKUP_DIR}/${SERVICE}-${STAMP}.tar.gz"

log() { printf '%s [backup] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

mkdir -p "$BACKUP_DIR"
chmod 700 "$(dirname "$BACKUP_DIR")" "$BACKUP_DIR"

if ! docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  log "ERREUR: volume Docker introuvable: $VOLUME"
  exit 1
fi

# 1. Archive du volume via un conteneur jetable en lecture seule (le contenu est
#    déjà chiffré au repos par le Vault ; l'archive reste chiffrée).
log "Archivage du volume $VOLUME → $ARCHIVE"
docker run --rm \
  -v "${VOLUME}:/data:ro" \
  -v "${BACKUP_DIR}:/backup" \
  alpine:3 \
  tar czf "/backup/$(basename "$ARCHIVE")" -C /data .

# 2. Manifeste d'intégrité SHA-256.
( cd "$BACKUP_DIR" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256" )
chmod 600 "$ARCHIVE" "${ARCHIVE}.sha256"

# 3. Vérification immédiate (fail-closed : un backup non vérifiable est inutile).
if ! ( cd "$BACKUP_DIR" && sha256sum -c "$(basename "$ARCHIVE").sha256" >/dev/null ); then
  log "ERREUR: vérification SHA-256 échouée pour $ARCHIVE"
  rm -f "$ARCHIVE" "${ARCHIVE}.sha256"
  exit 1
fi
log "Backup local vérifié: $ARCHIVE"

# 4. Rotation locale.
COUNT="$(ls -1 "${BACKUP_DIR}"/${SERVICE}-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
if [ "$COUNT" -gt "$KEEP" ]; then
  ls -1t "${BACKUP_DIR}"/${SERVICE}-*.tar.gz | tail -n +"$((KEEP + 1))" | while read -r old; do
    log "Rotation: suppression de $(basename "$old")"
    rm -f "$old" "${old}.sha256"
  done
fi

# 5. Réplication off-site (optionnelle — première étape: local seul).
if [ -n "$OFFSITE" ]; then
  log "Réplication off-site → $OFFSITE"
  if rsync -a --partial "$ARCHIVE" "${ARCHIVE}.sha256" "$OFFSITE"/ 2>/dev/null; then
    log "Réplication off-site OK"
  else
    log "AVERTISSEMENT: réplication off-site échouée (backup local conservé)"
    exit 2
  fi
else
  log "Off-site non configuré (OPALE_BACKUP_OFFSITE vide) — backup local uniquement"
fi

log "Backup terminé"
