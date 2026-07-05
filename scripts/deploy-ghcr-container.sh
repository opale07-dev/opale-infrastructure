#!/usr/bin/env sh
# Push a selected private GHCR image to a passive Opale VM.
#
# The script runs from GitHub Actions in opale-infrastructure. It does not pull
# Git on the VM and it requires an immutable image digest.

set -eu

SERVICE_NAME=""
IMAGE_REF=""
TARGET_IP=""
SSH_USER="ubuntu"
SSH_PORT="2222"
SSH_KEY=""
APP_DIR=""
HOST_PORT=""
CONTAINER_PORT=""
HEALTH_URL=""
HEALTH_EXPECT=""
ENV_FILE=""

usage() {
  cat >&2 <<'USAGE'
Usage:
  deploy-ghcr-container.sh \
    --service-name opale-vault \
    --image-ref ghcr.io/opale07-dev/opale-vault@sha256:... \
    --target-ip 203.0.113.10 \
    --ssh-user ubuntu \
    --ssh-port 2222 \
    --ssh-key /path/to/key \
    --app-dir /opt/opale-vault \
    --host-port 8443 \
    --container-port 8443 \
    --health-url https://127.0.0.1:8443/api/health \
    [--health-expect '"status":"ok"'] \
    [--env-file /opt/opale-vault/app.env]

Required environment:
  GHCR_USER
  GHCR_TOKEN
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --service-name) SERVICE_NAME="$2"; shift 2 ;;
    --image-ref) IMAGE_REF="$2"; shift 2 ;;
    --target-ip) TARGET_IP="$2"; shift 2 ;;
    --ssh-user) SSH_USER="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --app-dir) APP_DIR="$2"; shift 2 ;;
    --host-port) HOST_PORT="$2"; shift 2 ;;
    --container-port) CONTAINER_PORT="$2"; shift 2 ;;
    --health-url) HEALTH_URL="$2"; shift 2 ;;
    --health-expect) HEALTH_EXPECT="$2"; shift 2 ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

require_value() {
  name="$1"
  value="$2"
  if [ -z "$value" ]; then
    echo "Missing required value: $name" >&2
    usage
    exit 2
  fi
}

require_value SERVICE_NAME "$SERVICE_NAME"
require_value IMAGE_REF "$IMAGE_REF"
require_value TARGET_IP "$TARGET_IP"
require_value SSH_USER "$SSH_USER"
require_value SSH_PORT "$SSH_PORT"
require_value SSH_KEY "$SSH_KEY"
require_value APP_DIR "$APP_DIR"
require_value HOST_PORT "$HOST_PORT"
require_value CONTAINER_PORT "$CONTAINER_PORT"
require_value HEALTH_URL "$HEALTH_URL"
require_value GHCR_USER "${GHCR_USER:-}"
require_value GHCR_TOKEN "${GHCR_TOKEN:-}"

case "$IMAGE_REF" in
  ghcr.io/*@sha256:*) ;;
  *)
    echo "IMAGE_REF must be an immutable GHCR digest: ghcr.io/...@sha256:..." >&2
    exit 2
    ;;
esac

if [ ! -f "$SSH_KEY" ]; then
  echo "SSH key not found: $SSH_KEY" >&2
  exit 2
fi

if [ -z "$ENV_FILE" ]; then
  ENV_FILE="$APP_DIR/app.env"
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEY -p $SSH_PORT"
REMOTE="${SSH_USER}@${TARGET_IP}"

tmp_remote="/tmp/${SERVICE_NAME}-deploy.$$"
tmp_env="/tmp/${SERVICE_NAME}-deploy-env.$$"

b64_value() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

ssh $SSH_OPTS "$REMOTE" "cat > '$tmp_remote'" <<'REMOTE_SCRIPT'
#!/usr/bin/env sh
set -eu

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command on target: $1" >&2
    exit 1
  fi
}

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    echo "Missing docker compose implementation on target" >&2
    exit 1
  fi
}

require_cmd docker
require_cmd curl

: "${SERVICE_NAME:?}"
: "${IMAGE_REF:?}"
: "${APP_DIR:?}"
: "${HOST_PORT:?}"
: "${CONTAINER_PORT:?}"
: "${HEALTH_URL:?}"
: "${GHCR_USER:?}"
: "${GHCR_TOKEN:?}"
: "${ENV_FILE:?}"

sudo mkdir -p "$APP_DIR" "$APP_DIR/data"
sudo chown -R "$USER:$USER" "$APP_DIR"
chmod 750 "$APP_DIR"

COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_BLOCK=""
if [ -f "$ENV_FILE" ]; then
  ENV_BLOCK="    env_file:
      - $ENV_FILE"
fi

cat > "$COMPOSE_FILE" <<EOF
services:
  $SERVICE_NAME:
    image: $IMAGE_REF
    container_name: $SERVICE_NAME
    restart: unless-stopped
$ENV_BLOCK
    ports:
      - "0.0.0.0:$HOST_PORT:$CONTAINER_PORT"
    volumes:
      - "$APP_DIR/data:/data"
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
EOF

chmod 640 "$COMPOSE_FILE"

printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null
compose -f "$COMPOSE_FILE" pull
compose -f "$COMPOSE_FILE" up -d --remove-orphans

attempt=0
until curl -kfsS --max-time 5 "$HEALTH_URL" >/tmp/opale-healthcheck.out; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 24 ]; then
    echo "Healthcheck failed after $attempt attempts: $HEALTH_URL" >&2
    cat /tmp/opale-healthcheck.out >&2 || true
    exit 1
  fi
  sleep 5
done

if [ -n "${HEALTH_EXPECT:-}" ]; then
  if ! grep -q "$HEALTH_EXPECT" /tmp/opale-healthcheck.out; then
    echo "Healthcheck response did not contain expected text: $HEALTH_EXPECT" >&2
    cat /tmp/opale-healthcheck.out >&2 || true
    exit 1
  fi
fi

echo "$SERVICE_NAME deployed: $IMAGE_REF"
REMOTE_SCRIPT

ssh $SSH_OPTS "$REMOTE" "cat > '$tmp_env' && chmod 600 '$tmp_env'" <<EOF
SERVICE_NAME_B64='$(b64_value "$SERVICE_NAME")'
IMAGE_REF_B64='$(b64_value "$IMAGE_REF")'
APP_DIR_B64='$(b64_value "$APP_DIR")'
HOST_PORT_B64='$(b64_value "$HOST_PORT")'
CONTAINER_PORT_B64='$(b64_value "$CONTAINER_PORT")'
HEALTH_URL_B64='$(b64_value "$HEALTH_URL")'
HEALTH_EXPECT_B64='$(b64_value "$HEALTH_EXPECT")'
ENV_FILE_B64='$(b64_value "$ENV_FILE")'
GHCR_USER_B64='$(b64_value "$GHCR_USER")'
GHCR_TOKEN_B64='$(b64_value "$GHCR_TOKEN")'
EOF

ssh $SSH_OPTS "$REMOTE" "
  set -eu
  . '$tmp_env'
  export SERVICE_NAME=\$(printf '%s' \"\$SERVICE_NAME_B64\" | base64 -d)
  export IMAGE_REF=\$(printf '%s' \"\$IMAGE_REF_B64\" | base64 -d)
  export APP_DIR=\$(printf '%s' \"\$APP_DIR_B64\" | base64 -d)
  export HOST_PORT=\$(printf '%s' \"\$HOST_PORT_B64\" | base64 -d)
  export CONTAINER_PORT=\$(printf '%s' \"\$CONTAINER_PORT_B64\" | base64 -d)
  export HEALTH_URL=\$(printf '%s' \"\$HEALTH_URL_B64\" | base64 -d)
  export HEALTH_EXPECT=\$(printf '%s' \"\$HEALTH_EXPECT_B64\" | base64 -d)
  export ENV_FILE=\$(printf '%s' \"\$ENV_FILE_B64\" | base64 -d)
  export GHCR_USER=\$(printf '%s' \"\$GHCR_USER_B64\" | base64 -d)
  export GHCR_TOKEN=\$(printf '%s' \"\$GHCR_TOKEN_B64\" | base64 -d)
  chmod 700 '$tmp_remote'
  set +e
  '$tmp_remote'
  rc=\$?
  set -e
  rm -f '$tmp_remote' '$tmp_env'
  exit \$rc
"
