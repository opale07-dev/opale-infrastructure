#!/bin/sh
# Idempotent IFK-side configuration for Opale Pay bitcoind.

set -eu

ENV_FILE="${ENV_FILE:-/etc/opale/ifk-bitcoind.env}"
APP_DIR="${APP_DIR:-/opt/opale/ifk-bitcoind}"
COMPOSE_FILE="${COMPOSE_FILE:-${APP_DIR}/docker-compose.yml}"
WG_CONFIGURATOR="${WG_CONFIGURATOR:-/usr/local/bin/opale-configure-wireguard}"
WG_INTERFACE="${WG_INTERFACE:-wg0}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root"
  exit 1
fi

require_file() {
  path="$1"
  if [ ! -f "$path" ]; then
    echo "Missing required file: $path"
    exit 1
  fi
}

require_executable() {
  path="$1"
  if [ ! -x "$path" ]; then
    echo "Missing required executable: $path"
    exit 1
  fi
}

require_command() {
  name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Missing required command: $name"
    exit 1
  fi
}

require_value() {
  name="$1"
  value="$2"
  if [ -z "$value" ]; then
    echo "Missing required value: $name"
    exit 1
  fi
}

require_file "$ENV_FILE"
require_file "$COMPOSE_FILE"
require_executable "$WG_CONFIGURATOR"
require_command docker
docker compose version >/dev/null

install -d -m 0750 -o root -g ubuntu /etc/opale
install -d -m 0750 -o ubuntu -g ubuntu "$APP_DIR"
chown root:ubuntu "$ENV_FILE"
chmod 0640 "$ENV_FILE"
chown ubuntu:ubuntu "$COMPOSE_FILE"
chmod 0640 "$COMPOSE_FILE"

set -a
. "$ENV_FILE"
set +a

require_value IFK_WG_ADDRESS "${IFK_WG_ADDRESS:-}"
require_value IFK_WG_PRIVATE_KEY "${IFK_WG_PRIVATE_KEY:-}"
require_value IFK_WG_LISTEN_PORT "${IFK_WG_LISTEN_PORT:-}"
require_value OPALE_PAY_WG_PUBLIC_KEY "${OPALE_PAY_WG_PUBLIC_KEY:-}"
require_value OPALE_PAY_WG_ALLOWED_IPS "${OPALE_PAY_WG_ALLOWED_IPS:-}"
require_value BITCOIN_RPC_BIND "${BITCOIN_RPC_BIND:-}"
require_value BITCOIN_RPC_ALLOW_IP "${BITCOIN_RPC_ALLOW_IP:-}"
require_value BITCOIN_RPC_USER "${BITCOIN_RPC_USER:-}"
require_value BITCOIN_RPC_PASSWORD "${BITCOIN_RPC_PASSWORD:-}"

"$WG_CONFIGURATOR" \
  --interface "$WG_INTERFACE" \
  --address "$IFK_WG_ADDRESS" \
  --private-key "$IFK_WG_PRIVATE_KEY" \
  --peer-public-key "$OPALE_PAY_WG_PUBLIC_KEY" \
  --peer-allowed-ips "$OPALE_PAY_WG_ALLOWED_IPS" \
  --listen-port "$IFK_WG_LISTEN_PORT" \
  --persistent-keepalive ""

if command -v ufw >/dev/null 2>&1; then
  ufw allow "${IFK_WG_LISTEN_PORT}/udp" >/dev/null 2>&1 || true
fi

cd "$APP_DIR"
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps
