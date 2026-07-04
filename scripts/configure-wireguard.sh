#!/bin/sh
# Idempotent WireGuard configuration for Opale hosts.

set -eu

INTERFACE="wg0"
ADDRESS=""
PRIVATE_KEY=""
PEER_PUBLIC_KEY=""
PEER_ALLOWED_IPS=""
PEER_ENDPOINT=""
LISTEN_PORT=""
PERSISTENT_KEEPALIVE="25"

while [ $# -gt 0 ]; do
  case "$1" in
    --interface) INTERFACE="$2"; shift 2 ;;
    --address) ADDRESS="$2"; shift 2 ;;
    --private-key) PRIVATE_KEY="$2"; shift 2 ;;
    --peer-public-key) PEER_PUBLIC_KEY="$2"; shift 2 ;;
    --peer-allowed-ips) PEER_ALLOWED_IPS="$2"; shift 2 ;;
    --peer-endpoint) PEER_ENDPOINT="$2"; shift 2 ;;
    --listen-port) LISTEN_PORT="$2"; shift 2 ;;
    --persistent-keepalive) PERSISTENT_KEEPALIVE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root"
  exit 1
fi

require_value() {
  name="$1"
  value="$2"
  if [ -z "$value" ]; then
    echo "Missing required value: $name"
    exit 1
  fi
}

require_value "address" "$ADDRESS"
require_value "private-key" "$PRIVATE_KEY"
require_value "peer-public-key" "$PEER_PUBLIC_KEY"
require_value "peer-allowed-ips" "$PEER_ALLOWED_IPS"

export DEBIAN_FRONTEND=noninteractive

if ! command -v wg >/dev/null 2>&1 || ! command -v wg-quick >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq wireguard
fi

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

CONF="/etc/wireguard/${INTERFACE}.conf"
TMP_CONF="$(mktemp)"

{
  printf '[Interface]\n'
  printf 'Address = %s\n' "$ADDRESS"
  printf 'PrivateKey = %s\n' "$PRIVATE_KEY"
  if [ -n "$LISTEN_PORT" ]; then
    printf 'ListenPort = %s\n' "$LISTEN_PORT"
  fi
  printf '\n[Peer]\n'
  printf 'PublicKey = %s\n' "$PEER_PUBLIC_KEY"
  printf 'AllowedIPs = %s\n' "$PEER_ALLOWED_IPS"
  if [ -n "$PEER_ENDPOINT" ]; then
    printf 'Endpoint = %s\n' "$PEER_ENDPOINT"
  fi
  if [ -n "$PERSISTENT_KEEPALIVE" ]; then
    printf 'PersistentKeepalive = %s\n' "$PERSISTENT_KEEPALIVE"
  fi
} >"$TMP_CONF"

install -m 0600 -o root -g root "$TMP_CONF" "$CONF"
rm -f "$TMP_CONF"

systemctl enable "wg-quick@${INTERFACE}" >/dev/null
systemctl restart "wg-quick@${INTERFACE}"

if [ -n "$LISTEN_PORT" ] && command -v ufw >/dev/null 2>&1; then
  ufw allow "${LISTEN_PORT}/udp" >/dev/null 2>&1 || true
fi

wg show "$INTERFACE"
