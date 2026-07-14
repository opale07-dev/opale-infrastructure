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
  echo "CLN rune unavailable: bitcoind or CLN may still be synchronizing."
fi

compose up -d --remove-orphans --force-recreate lnbits proxy

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
