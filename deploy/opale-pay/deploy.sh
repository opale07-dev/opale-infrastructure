#!/bin/sh
# Converge and verify the declared Opale Pay backend state on the target VM.

set -eu

APP_DIR="${APP_DIR:-/opt/opale-pay}"
cd "$APP_DIR"

set -a
. "$APP_DIR/app.env"
set +a

if docker ps >/dev/null 2>&1; then
  DOCKER="docker"
else
  DOCKER="sudo docker"
fi

compose() {
  $DOCKER compose --env-file .env -f docker-compose.yml "$@"
}

compose config --quiet
$DOCKER load -i /tmp/opale-pay-proxy-image.tar.gz
rm -f /tmp/opale-pay-proxy-image.tar.gz

compose pull cln lnbits postgres

blockchain_info="$(curl -fsS --max-time 30 \
  --user "$BITCOIN_RPC_USER:$BITCOIN_RPC_PASSWORD" \
  --header "content-type: text/plain;" \
  --data-binary '{"jsonrpc":"1.0","id":"opale-pay-ci","method":"getblockchaininfo","params":[]}' \
  "http://${BITCOIN_RPC_HOST}:${BITCOIN_RPC_PORT}/")"
if [ "$(printf '%s' "$blockchain_info" | jq -r '.result.initialblockdownload')" != "false" ]; then
  compose stop cln lnbits proxy >/dev/null 2>&1 || true
  progress="$(printf '%s' "$blockchain_info" | jq -r '.result.verificationprogress // 0')"
  blocks="$(printf '%s' "$blockchain_info" | jq -r '.result.blocks // 0')"
  headers="$(printf '%s' "$blockchain_info" | jq -r '.result.headers // 0')"
  echo "bitcoind IBD is still running (progress=${progress}, blocks=${blocks}, headers=${headers}); Pay services remain stopped." >&2
  exit 1
fi

compose up -d --remove-orphans postgres cln

attempt=0
until $DOCKER exec opalepay-postgres pg_isready -U lnbits -d lnbits >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  [ "$attempt" -ge 24 ] && { $DOCKER logs --tail 100 opalepay-postgres; exit 1; }
  sleep 5
done

# Existing testnet volumes were initialized with a legacy static password.
# Converge the database role to the secret injected by this deployment.
printf '%s\n' "ALTER ROLE lnbits WITH PASSWORD :'new_password';" \
  | $DOCKER exec -i -e NEW_PASSWORD="$POSTGRES_PASSWORD" opalepay-postgres sh -c \
    'psql -U lnbits -d lnbits -v ON_ERROR_STOP=1 -v new_password="$NEW_PASSWORD"' \
  >/dev/null

CLN_RUNE=""
attempt=0
while [ "$attempt" -lt 40 ]; do
  CLN_RUNE="$($DOCKER exec opalepay-cln lightning-cli commando-rune 2>/dev/null | jq -r '.rune // empty' || true)"
  [ -n "$CLN_RUNE" ] && break
  attempt=$((attempt + 1))
  sleep 3
done

if [ -n "$CLN_RUNE" ]; then
  sed -i '/^CLN_REST_MACAROON=/d' app.env
  printf "CLN_REST_MACAROON='%s'\n" "$CLN_RUNE" >> app.env
else
  $DOCKER logs --tail 120 opalepay-cln 2>&1 || true
  echo "CLN rune unavailable: bitcoind or CLN is not ready." >&2
  exit 1
fi

compose up -d --remove-orphans --force-recreate lnbits

attempt=0
until $DOCKER exec opalepay-lnbits python -c \
  'import httpx; r = httpx.get("http://127.0.0.1:5000/api/v1/health", timeout=5); r.raise_for_status()' \
  >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 40 ]; then
    $DOCKER logs --tail 120 opalepay-lnbits 2>&1 || true
    echo "LNbits did not become ready" >&2
    exit 1
  fi
  sleep 3
done

wallet_keys="$($DOCKER exec opalepay-postgres psql -U lnbits -d lnbits -Atc \
  "SELECT adminkey || ':' || inkey FROM wallets WHERE name = 'Opale Pay Service' LIMIT 1;")"
if [ -z "$wallet_keys" ]; then
  wallet_json="$($DOCKER exec opalepay-lnbits python -c \
    'import httpx; r = httpx.post("http://127.0.0.1:5000/api/v1/account", json={"name": "Opale Pay Service"}, timeout=10); r.raise_for_status(); print(r.text)')"
  wallet_admin_key="$(printf '%s' "$wallet_json" | jq -r '.adminkey // empty')"
  wallet_invoice_key="$(printf '%s' "$wallet_json" | jq -r '.inkey // empty')"
else
  wallet_admin_key="${wallet_keys%%:*}"
  wallet_invoice_key="${wallet_keys#*:}"
fi

[ -n "$wallet_admin_key" ] && [ -n "$wallet_invoice_key" ] \
  || { echo "LNbits wallet bootstrap returned empty keys" >&2; exit 1; }
sed -i '/^LNBITS_WALLET_HEDGE_ADMIN_KEY=/d;/^LNBITS_WALLET_HEDGE_INVOICE_KEY=/d' app.env
printf "LNBITS_WALLET_HEDGE_ADMIN_KEY='%s'\n" "$wallet_admin_key" >> app.env
printf "LNBITS_WALLET_HEDGE_INVOICE_KEY='%s'\n" "$wallet_invoice_key" >> app.env

compose up -d --remove-orphans --force-recreate proxy

attempt=0
until curl -fsS http://127.0.0.1:8080/health | grep -q '"status":"ok"'; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 40 ]; then
    compose ps || true
    $DOCKER logs --tail 100 opalepay-proxy || true
    echo "Opale Pay proxy healthcheck failed" >&2
    exit 1
  fi
  sleep 3
done

curl -fsS --max-time 10 \
  --user "$BITCOIN_RPC_USER:$BITCOIN_RPC_PASSWORD" \
  --header "content-type: text/plain;" \
  --data-binary '{"jsonrpc":"1.0","id":"opale-pay-ci","method":"getblockchaininfo","params":[]}' \
  "http://${BITCOIN_RPC_HOST}:${BITCOIN_RPC_PORT}/" >/dev/null

attempt=0
until $DOCKER exec opalepay-proxy python -c \
  'import httpx; r = httpx.get("http://lnbits:5000", timeout=5, follow_redirects=True); r.raise_for_status()' \
  >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 40 ]; then
    compose ps || true
    $DOCKER logs --tail 100 opalepay-lnbits || true
    echo "LNbits is unreachable from the Pay proxy" >&2
    exit 1
  fi
  sleep 3
done

if [ -n "$CLN_RUNE" ] && $DOCKER logs opalepay-lnbits 2>&1 | grep -q "Fallback to VoidWallet"; then
  $DOCKER logs --tail 120 opalepay-lnbits || true
  echo "LNbits fell back to VoidWallet after CLN rune configuration" >&2
  exit 1
fi

compose ps
curl -fsS http://127.0.0.1:8080/health
