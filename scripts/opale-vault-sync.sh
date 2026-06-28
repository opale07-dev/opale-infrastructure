#!/bin/sh
# Pull-based backend deployment for the dedicated Opale Vault VM.
# This script is intended to live ON the VM and be executed at boot + periodically.

set -eu

APP_DIR="/opt/opale-vault"
DEPLOY_ENV="$APP_DIR/deploy.env"
COMPOSE_FILE="$APP_DIR/docker-compose.prod.yml"
CADDY_FILE="$APP_DIR/Caddyfile"
HEALTH_URL="https://127.0.0.1:8443/api/health"
REPO="opale07-dev/opale-core"
REF="${OPALE_CORE_REF:-main}"

log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

require_file() {
  if [ ! -f "$1" ]; then
    log "Missing required file: $1"
    exit 1
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "Missing required command: $1"
    exit 1
  fi
}

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    log "Missing docker compose implementation"
    exit 1
  fi
}

require_cmd curl
require_cmd docker

require_file "$DEPLOY_ENV"
. "$DEPLOY_ENV"

: "${GITHUB_DEPLOY_USER:?GITHUB_DEPLOY_USER is required in $DEPLOY_ENV}"
: "${GITHUB_DEPLOY_PAT:?GITHUB_DEPLOY_PAT is required in $DEPLOY_ENV}"
: "${VAULT_ADMIN_PUBKEYS:?VAULT_ADMIN_PUBKEYS is required in $DEPLOY_ENV}"

VAULT_TPM_NV_INDEX="${VAULT_TPM_NV_INDEX:-0x1500016}"

fetch_repo_file() {
  path="$1"
  dest="$2"
  tmp="${dest}.tmp"

  curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_DEPLOY_PAT}" \
    -H "Accept: application/vnd.github.raw" \
    "https://api.github.com/repos/${REPO}/contents/${path}?ref=${REF}" \
    -o "$tmp"

  mv "$tmp" "$dest"
}

write_runtime_env() {
  cat >"$APP_DIR/.env" <<EOF
VAULT_UNSEAL_MODE=tpm
VAULT_TPM_NV_INDEX=$VAULT_TPM_NV_INDEX
VAULT_ADMIN_PUBKEYS=$VAULT_ADMIN_PUBKEYS
EOF
  chmod 600 "$APP_DIR/.env"
}

log "Fetching deployment bundle from ${REPO}@${REF}"
fetch_repo_file "docker-compose.prod.yml" "$COMPOSE_FILE"
fetch_repo_file "Caddyfile" "$CADDY_FILE"
write_runtime_env

log "Logging in to GHCR"
printf '%s' "$GITHUB_DEPLOY_PAT" | docker login ghcr.io -u "$GITHUB_DEPLOY_USER" --password-stdin >/dev/null

log "Pulling backend image"
compose -f "$COMPOSE_FILE" pull

log "Applying compose state"
compose -f "$COMPOSE_FILE" up -d --remove-orphans

log "Waiting for backend health"
attempt=0
until curl -fsSk "$HEALTH_URL" | grep -q '"status":"ok"'; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 12 ]; then
    log "Backend healthcheck failed after ${attempt} attempts"
    exit 1
  fi
  sleep 5
done

log "Opale Vault backend is healthy"
