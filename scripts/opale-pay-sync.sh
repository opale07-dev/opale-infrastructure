#!/bin/sh
# Pull-based backend deployment for the dedicated Opale Pay VM.
# This script is intended to live ON the VM and be executed at boot + periodically.

set -eu

APP_DIR="/opt/opale-pay"
DEPLOY_ENV="$APP_DIR/deploy.env"
COMPOSE_FILE="$APP_DIR/docker-compose.prod.yml"
RUNTIME_ENV="$APP_DIR/runtime.env"
HEALTH_URL="http://127.0.0.1:8080/health"
REPO="opale07-dev/OpalePay"
REF="${OPALE_PAY_REF:-main}"

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

json_get() {
  key="$1"
  sed -n "s/.*\"${key}\":\"\\([^\"]*\\)\".*/\\1/p"
}

resolve_secret() {
  name="$1"
  capability="$2"
  purpose="$3"
  fallback_value="${4:-}"

  if [ -n "${VAULT_BASE_URL:-}" ] && [ -n "${VAULT_PROJECT_TOKEN:-}" ] && [ -n "$capability" ]; then
    grant_payload=$(printf '{"tenant_id":"%s","project_id":"%s","environment":"%s","actor_id":"%s","actor_type":"%s","capability":"%s","purpose":"%s","ttl_seconds":60}' \
      "${VAULT_TENANT_ID:-opale-pay}" \
      "${VAULT_PROJECT_ID:-opale-pay}" \
      "${VAULT_ENVIRONMENT:-production}" \
      "${VAULT_ACTOR_ID:-opale-pay-runtime}" \
      "${VAULT_ACTOR_TYPE:-service}" \
      "$capability" \
      "$purpose")

    grant_response=$(curl -fsSL \
      -H "Authorization: Bearer ${VAULT_PROJECT_TOKEN}" \
      -H "Content-Type: application/json" \
      -H "X-Opale-Tenant: ${VAULT_TENANT_ID:-opale-pay}" \
      -H "X-Opale-Project: ${VAULT_PROJECT_ID:-opale-pay}" \
      -H "X-Opale-Environment: ${VAULT_ENVIRONMENT:-production}" \
      -X POST \
      -d "$grant_payload" \
      "${VAULT_BASE_URL}/api/vault/grants" 2>/dev/null || true)

    grant_id=$(printf '%s' "$grant_response" | json_get grant_id)
    if [ -n "$grant_id" ]; then
      lease_response=$(curl -fsSL \
        -H "Authorization: Bearer ${VAULT_PROJECT_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "X-Opale-Tenant: ${VAULT_TENANT_ID:-opale-pay}" \
        -H "X-Opale-Project: ${VAULT_PROJECT_ID:-opale-pay}" \
        -H "X-Opale-Environment: ${VAULT_ENVIRONMENT:-production}" \
        -X POST \
        -d '{}' \
        "${VAULT_BASE_URL}/api/vault/grants/${grant_id}/secret" 2>/dev/null || true)
      value=$(printf '%s' "$lease_response" | json_get value)
      curl -fsSL \
        -H "Authorization: Bearer ${VAULT_PROJECT_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "X-Opale-Tenant: ${VAULT_TENANT_ID:-opale-pay}" \
        -H "X-Opale-Project: ${VAULT_PROJECT_ID:-opale-pay}" \
        -H "X-Opale-Environment: ${VAULT_ENVIRONMENT:-production}" \
        -X POST \
        -d '{"reason":"Opale Pay bootstrap complete"}' \
        "${VAULT_BASE_URL}/api/vault/grants/${grant_id}/revoke" >/dev/null 2>&1 || true

      if [ -n "$value" ]; then
        log "Resolved $name from Vault"
        printf '%s' "$value"
        return 0
      fi
    fi

    log "Vault lookup failed for $name, falling back to deploy.env"
  fi

  if [ -n "$fallback_value" ]; then
    printf '%s' "$fallback_value"
    return 0
  fi

  return 1
}

write_runtime_env() {
  cln_rest_macaroon=$(resolve_secret "CLN_REST_MACAROON" "${VAULT_CAP_CLN_REST_MACAROON:-}" "Bootstrap LNbits -> CLN REST access" "${CLN_REST_MACAROON:-}") || {
    log "Missing required secret: CLN_REST_MACAROON"
    exit 1
  }
  lnbits_admin=$(resolve_secret "LNBITS_WALLET_HEDGE_ADMIN_KEY" "${VAULT_CAP_LNBITS_HEDGE_ADMIN_KEY:-}" "Bootstrap Opale Pay hedge admin key" "${LNBITS_WALLET_HEDGE_ADMIN_KEY:-}") || {
    log "Missing required secret: LNBITS_WALLET_HEDGE_ADMIN_KEY"
    exit 1
  }
  lnbits_invoice=$(resolve_secret "LNBITS_WALLET_HEDGE_INVOICE_KEY" "${VAULT_CAP_LNBITS_HEDGE_INVOICE_KEY:-}" "Bootstrap Opale Pay hedge invoice key" "${LNBITS_WALLET_HEDGE_INVOICE_KEY:-}") || {
    log "Missing required secret: LNBITS_WALLET_HEDGE_INVOICE_KEY"
    exit 1
  }
  l402_secret=$(resolve_secret "L402_MACAROON_SECRET" "${VAULT_CAP_L402_MACAROON_SECRET:-}" "Bootstrap Opale Pay L402 macaroon secret" "${L402_MACAROON_SECRET:-}") || {
    log "Missing required secret: L402_MACAROON_SECRET"
    exit 1
  }

  cat >"$RUNTIME_ENV" <<EOF
CLN_REST_MACAROON=$cln_rest_macaroon
LNBITS_WALLET_HEDGE_ADMIN_KEY=$lnbits_admin
LNBITS_WALLET_HEDGE_INVOICE_KEY=$lnbits_invoice
L402_MACAROON_SECRET=$l402_secret
GEOBLOCK_ENABLED=${GEOBLOCK_ENABLED:-false}
EOF
  chmod 600 "$RUNTIME_ENV"
}

require_cmd curl
require_cmd docker

require_file "$DEPLOY_ENV"
. "$DEPLOY_ENV"

: "${GITHUB_DEPLOY_USER:?GITHUB_DEPLOY_USER is required in $DEPLOY_ENV}"
: "${GITHUB_DEPLOY_PAT:?GITHUB_DEPLOY_PAT is required in $DEPLOY_ENV}"

log "Fetching deployment bundle from ${REPO}@${REF}"
fetch_repo_file "docker-compose.prod.yml" "$COMPOSE_FILE"
write_runtime_env
set -a
. "$RUNTIME_ENV"
set +a

log "Logging in to GHCR"
printf '%s' "$GITHUB_DEPLOY_PAT" | docker login ghcr.io -u "$GITHUB_DEPLOY_USER" --password-stdin >/dev/null

log "Pulling backend images"
compose -f "$COMPOSE_FILE" pull

log "Applying compose state"
compose -f "$COMPOSE_FILE" up -d --remove-orphans

log "Waiting for Opale Pay health"
attempt=0
until curl -fsS "$HEALTH_URL" | grep -q '"status":"ok"'; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 24 ]; then
    log "Opale Pay healthcheck failed after ${attempt} attempts"
    exit 1
  fi
  sleep 5
done

log "Opale Pay backend is healthy"
