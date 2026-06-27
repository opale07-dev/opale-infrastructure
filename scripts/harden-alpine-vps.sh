#!/bin/sh
# harden-alpine-generic.sh — Universal Alpine Linux 3 Hardening Script.
# Idempotent: can be run multiple times safely.
# Usage: sudo sh harden-alpine-generic.sh --ssh-port 22 --app-port 8200 --app-dir /opt/my-app

set -eu

SSH_PORT=22
APP_PORT=""
ADMIN_USER="root"
APP_DIR=""
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --app-port) APP_PORT="$2"; shift 2 ;; # Port spécifique de ton service (ex: 8200, 3000, 6379)
    --admin-user) ADMIN_USER="$2"; shift 2 ;;
    --app-dir) APP_DIR="$2"; shift 2 ;;   # Optionnel : Dossier à sécuriser pour l'app
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo "${BLUE}[INFO]${NC}  $*"; }
log_ok() { echo "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo "${YELLOW}[WARN]${NC}  $*"; }
log_section() { echo "\n${BLUE}━━━ $* ━━━${NC}"; }

run() {
  if [ "$DRY_RUN" = true ]; then
    echo "${YELLOW}[DRY-RUN]${NC} $*"
  else
    eval "$*"
  fi
}

write_file() {
  local path="$1"
  local content="$2"
  if [ "$DRY_RUN" = true ]; then
    echo "${YELLOW}[DRY-RUN]${NC} write $path"
    return
  fi
  if [ -f "$path" ] && [ ! -f "${path}.bak" ]; then
    cp "$path" "${path}.bak"
  fi
  echo "$content" > "$path"
}

if [ "$DRY_RUN" = false ] && [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo sh harden-alpine-generic.sh"
  exit 1
fi

log_info "Generic Alpine VPS Hardening Baseline"
log_info "ssh_port=$SSH_PORT app_port=$APP_PORT admin_user=$ADMIN_USER app_dir=$APP_DIR"

log_section "1/9 — System updates"
run "apk update && apk upgrade"
log_ok "System packages updated"

log_section "2/9 — Core Security Packages"
run "apk add --no-cache ca-certificates curl fail2ban iptables awall audit openrc"
log_ok "Security stack installed"

log_section "3/9 — SSH Hardening"
SSH_CONF="/etc/ssh/sshd_config.d/99-vps-hardening.conf"
run "mkdir -p /etc/ssh/sshd_config.d"

SSH_CONTENT="Port ${SSH_PORT}
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2
LogLevel VERBOSE
AllowUsers ${ADMIN_USER}
Banner /etc/issue.net
"
write_file "$SSH_CONF" "$SSH_CONTENT"
write_file "/etc/issue.net" "UNAUTHORIZED ACCESS PROHIBITED. All connections are logged and audited."

if [ "$DRY_RUN" = false ]; then
  if sshd -t; then
    rc-service sshd restart 2>/dev/null || true
    log_ok "SSH service reloaded"
  else
    log_warn "Invalid SSH configuration; reverting"
    cp "${SSH_CONF}.bak" "$SSH_CONF" 2>/dev/null || rm -f "$SSH_CONF"
    exit 1
  fi
fi

log_section "4/9 — Firewall Configuration (Awall)"
mkdir -p /etc/awall/optional

# Construction dynamique des règles de filtrage selon la présence d'un port d'application
FILTER_RULES="[ { \"in\": \"internet\", \"out\": \"_fw\", \"service\": \"ssh\", \"action\": \"ACCEPT\" }"
if [ -n "$APP_PORT" ]; then
  FILTER_RULES="${FILTER_RULES}, { \"in\": \"internet\", \"out\": \"_fw\", \"service\": { \"proto\": \"tcp\", \"port\": ${APP_PORT} }, \"action\": \"ACCEPT\" }"
fi
FILTER_RULES="${FILTER_RULES} ]"

AWALL_CONTENT="{
  \"description\": \"VPS Custom Base Rules\",
  \"zone\": { \"internet\": { \"iface\": \"eth0\" } },
  \"policy\": [
    { \"in\": \"internet\", \"out\": \"_fw\", \"action\": \"DROP\" },
    { \"in\": \"_fw\", \"out\": \"internet\", \"action\": \"ACCEPT\" }
  ],
  \"filter\": ${FILTER_RULES}
}"
write_file "/etc/awall/optional/vps-rules.json" "$AWALL_CONTENT"

if [ "$DRY_RUN" = false ]; then
  awall enable vps-rules
  awall activate
  rc-update add iptables default
  log_ok "Firewall policies applied successfully"
fi

log_section "5/9 — Fail2ban Intrusion Prevention"
FAIL2BAN_CONF="/etc/fail2ban/jail.d/vps-hardening.conf"
FAIL2BAN_CONTENT="[DEFAULT]
bantime = 2h
findtime = 10m
maxretry = 3
banaction = iptables-multiport

[sshd]
enabled = true
port = ${SSH_PORT}
logpath = /var/log/messages
backend = auto
"
write_file "$FAIL2BAN_CONF" "$FAIL2BAN_CONTENT"
run "rc-update add fail2ban default"
run "rc-service fail2ban restart || true"
log_ok "Fail2ban enabled"

log_section "6/9 — Kernel Hardening (Sysctl)"
SYSCTL_CONF="/etc/sysctl.d/99-vps-hardening.conf"
SYSCTL_CONTENT="net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
fs.suid_dumpable = 0
"
write_file "$SYSCTL_CONF" "$SYSCTL_CONTENT"
run "sysctl -p $SYSCTL_CONF >/dev/null 2>&1 || true"
log_ok "Kernel constraints applied"

log_section "7/9 — Audit Daemon Rules"
AUDIT_RULES="/etc/audit/rules.d/vps-hardening.rules"
mkdir -p /etc/audit/rules.d
AUDIT_CONTENT="-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/docker/daemon.json -p wa -k docker_config
"
if [ -n "$APP_DIR" ]; then
  AUDIT_CONTENT="${AUDIT_CONTENT}
-w ${APP_DIR}/.env -p wa -k app_env"
fi
write_file "$AUDIT_RULES" "$AUDIT_CONTENT"
run "rc-update add auditd default"
run "rc-service auditd restart || true"
log_ok "Auditd rules registered"

log_section "8/9 — Lean Docker Isolation Engine"
run "apk add --no-cache docker docker-compose"
DOCKER_DAEMON="/etc/docker/daemon.json"
DOCKER_DAEMON_CONTENT='{
  "icc": false,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true,
  "no-new-privileges": true
}'
write_file "$DOCKER_DAEMON" "$DOCKER_DAEMON_CONTENT"
run "rc-update add docker default"
run "rc-service docker restart || true"
log_ok "Docker daemon sandboxed"

log_section "9/9 — Optional Workspace & Clean Up"
if [ -n "$APP_DIR" ]; then
  run "mkdir -p ${APP_DIR} ${APP_DIR}/data"
  run "chmod 750 ${APP_DIR} && chmod 700 ${APP_DIR}/data"
  if [ "$DRY_RUN" = false ] && [ ! -f "${APP_DIR}/.env" ]; then
    touch "${APP_DIR}/.env" && chmod 600 "${APP_DIR}/.env"
  fi
  log_ok "Workspace built at $APP_DIR"
fi

# Cron de mise à jour quotidienne
CRON_PATH="/etc/periodic/daily/security-upgrade"
write_file "$CRON_PATH" "#!/bin/sh\napk update && apk upgrade"
if [ "$DRY_RUN" = false ]; then
  chmod +x "$CRON_PATH"
  rc-update add crond default
fi

echo "\n${GREEN}✔ Universal Alpine Hardening Baseline Complete.${NC}\n"