#!/bin/sh
# Self-check de maintenance d'un service Opale : santé applicative, expiration
# du certificat TLS, âge des clés (rappel de rotation), présence de backups
# récents. Lecture seule — n'altère jamais l'état. Émet des AVERTISSEMENTS sur
# stdout (captés par journald) ; sort en code 1 si un contrôle critique échoue.
#
# Maintenance host-only.
#
# Variables :
#   OPALE_SERVICE            nom du service (ex. opale-vault)
#   OPALE_HEALTH_URL         URL healthcheck local (ex. https://127.0.0.1:8443/api/health)
#   OPALE_HEALTH_EXPECT      motif attendu dans la réponse (ex. "\"status\":\"ok\"")
#   OPALE_CERT_PATH          certificat TLS à surveiller (optionnel)
#   OPALE_CERT_WARN_DAYS     seuil d'alerte avant expiration (défaut 30)
#   OPALE_KEY_STAMP          fichier horodatant la dernière rotation de clé (optionnel)
#   OPALE_KEY_MAX_DAYS       âge max recommandé d'une clé (défaut 180)
#   OPALE_BACKUP_DIR         répertoire des backups à surveiller (optionnel)
#   OPALE_BACKUP_MAX_AGE_H   âge max du backup le plus récent en heures (défaut 48)

set -u

SERVICE="${OPALE_SERVICE:?OPALE_SERVICE requis}"
WARN=0
FAIL=0

log()  { printf '%s [selfcheck:%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SERVICE" "$*"; }
warn() { log "AVERTISSEMENT: $*"; WARN=$((WARN + 1)); }
fail() { log "CRITIQUE: $*"; FAIL=$((FAIL + 1)); }

# 1. Santé applicative.
if [ -n "${OPALE_HEALTH_URL:-}" ]; then
  BODY="$(curl -fsSk --max-time 15 "$OPALE_HEALTH_URL" 2>/dev/null || true)"
  if [ -z "$BODY" ]; then
    fail "healthcheck injoignable: $OPALE_HEALTH_URL"
  elif [ -n "${OPALE_HEALTH_EXPECT:-}" ] && ! printf '%s' "$BODY" | grep -q "$OPALE_HEALTH_EXPECT"; then
    fail "healthcheck: réponse inattendue (attendu: $OPALE_HEALTH_EXPECT)"
  else
    log "santé OK"
  fi
fi

# 2. Expiration du certificat TLS.
if [ -n "${OPALE_CERT_PATH:-}" ] && [ -f "$OPALE_CERT_PATH" ]; then
  WARN_DAYS="${OPALE_CERT_WARN_DAYS:-30}"
  END="$(openssl x509 -enddate -noout -in "$OPALE_CERT_PATH" 2>/dev/null | cut -d= -f2)"
  if [ -n "$END" ]; then
    END_TS="$(date -d "$END" +%s 2>/dev/null || true)"
    NOW_TS="$(date +%s)"
    if [ -n "$END_TS" ]; then
      DAYS_LEFT="$(( (END_TS - NOW_TS) / 86400 ))"
      if [ "$DAYS_LEFT" -lt 0 ]; then
        fail "certificat TLS EXPIRÉ ($OPALE_CERT_PATH)"
      elif [ "$DAYS_LEFT" -lt "$WARN_DAYS" ]; then
        warn "certificat TLS expire dans ${DAYS_LEFT}j ($OPALE_CERT_PATH)"
      else
        log "certificat TLS OK (${DAYS_LEFT}j restants)"
      fi
    fi
  fi
fi

# 3. Rappel de rotation de clé.
if [ -n "${OPALE_KEY_STAMP:-}" ] && [ -f "$OPALE_KEY_STAMP" ]; then
  MAX_DAYS="${OPALE_KEY_MAX_DAYS:-180}"
  STAMP_TS="$(stat -c %Y "$OPALE_KEY_STAMP" 2>/dev/null || echo 0)"
  AGE_DAYS="$(( ($(date +%s) - STAMP_TS) / 86400 ))"
  if [ "$AGE_DAYS" -ge "$MAX_DAYS" ]; then
    warn "clé âgée de ${AGE_DAYS}j (seuil ${MAX_DAYS}j) — envisager une rotation (procédure 03/04)"
  else
    log "âge de clé OK (${AGE_DAYS}j)"
  fi
fi

# 4. Fraîcheur des backups.
if [ -n "${OPALE_BACKUP_DIR:-}" ] && [ -d "$OPALE_BACKUP_DIR" ]; then
  MAX_AGE_H="${OPALE_BACKUP_MAX_AGE_H:-48}"
  LATEST="$(ls -1t "$OPALE_BACKUP_DIR"/*.tar.gz 2>/dev/null | head -1 || true)"
  if [ -z "$LATEST" ]; then
    warn "aucun backup trouvé dans $OPALE_BACKUP_DIR"
  else
    AGE_H="$(( ($(date +%s) - $(stat -c %Y "$LATEST")) / 3600 ))"
    if [ "$AGE_H" -gt "$MAX_AGE_H" ]; then
      warn "backup le plus récent âgé de ${AGE_H}h (seuil ${MAX_AGE_H}h)"
    else
      log "backup récent OK (${AGE_H}h)"
    fi
  fi
fi

log "self-check terminé — ${WARN} avertissement(s), ${FAIL} critique(s)"
[ "$FAIL" -eq 0 ] || exit 1
