#!/bin/sh
# Pré-déploiement backend Vault — exécuté sur la VM par vault-app-deploy.yml,
# versionné ici (aucun script généré à la volée). Idempotent.
#
# 1. TPM fail-closed : le Vault exige l'unseal TPM, une VM sans vTPM est une
#    infra non conforme (image opale-ubuntu-26.04-tpm, région dc4-a).
# 2. Swap désactivé : la clé maître et les root keys ne doivent jamais pouvoir
#    être paginées sur disque.
# 3. Certificat TLS auto-signé du proxy (SANs loopback + IP publique + nom
#    stable), regénéré à chaque déploiement.

set -eu

APP_DIR="${1:-/opt/opale-vault}"

log() { printf '%s [predeploy] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

if [ ! -e /dev/tpmrm0 ]; then
  echo "ERREUR: /dev/tpmrm0 absent — pas de vTPM attache a cette VM." >&2
  echo "Le Vault exige l'unseal TPM. Recreer la VM avec l'image opale-ubuntu-26.04-tpm (dc4-a)." >&2
  exit 1
fi
log "TPM device present"

log "Disabling swap for backend secrets safety"
sudo swapoff -a 2>/dev/null || true
if [ -f /etc/fstab ]; then
  sudo sed -i.bak '/[[:space:]]swap[[:space:]]/s/^/# disabled by opale vault hardening: /' /etc/fstab
fi

PUBLIC_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)"
SAN="DNS:opale-vault-backend,IP:127.0.0.1${PUBLIC_IP:+,IP:$PUBLIC_IP}"
log "Generating backend TLS certificate (SAN: $SAN)"
mkdir -p "$APP_DIR/tls"
openssl req -x509 -newkey rsa:2048 -sha256 -days 825 -nodes \
  -keyout "$APP_DIR/tls/backend.key" -out "$APP_DIR/tls/backend.crt" \
  -subj "/CN=opale-vault-backend" -addext "subjectAltName=$SAN" 2>/dev/null
chmod 600 "$APP_DIR/tls/backend.key"
chmod 644 "$APP_DIR/tls/backend.crt"

log "predeploy OK"
