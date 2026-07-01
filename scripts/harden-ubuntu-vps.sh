#!/bin/sh
# Idempotent Ubuntu hardening baseline for Opale service VMs.

set -eu

SSH_PORT=22
APP_PORT=""
ADMIN_USER="ubuntu"
APP_DIR=""
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --app-port) APP_PORT="$2"; shift 2 ;;
    --admin-user) ADMIN_USER="$2"; shift 2 ;;
    --app-dir) APP_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

run() {
  if [ "$DRY_RUN" = true ]; then
    log "[DRY-RUN] $*"
  else
    sh -c "$*"
  fi
}

write_file() {
  path="$1"
  content="$2"
  if [ "$DRY_RUN" = true ]; then
    log "[DRY-RUN] write $path"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  if [ -f "$path" ] && [ ! -f "${path}.bak" ]; then
    cp "$path" "${path}.bak"
  fi
  printf '%s' "$content" >"$path"
}

reload_systemd_service() {
  service_name="$1"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable "$service_name" >/dev/null 2>&1 || true
    systemctl restart "$service_name" >/dev/null 2>&1 || systemctl start "$service_name" >/dev/null 2>&1 || true
  fi
}

if [ "$DRY_RUN" = false ] && [ "$(id -u)" -ne 0 ]; then
  echo "Run as root"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

log "Updating apt index"
run "apt-get update -qq"
run "apt-get upgrade -y -qq"

log "Installing security and runtime packages"
run "apt-get install -y -qq auditd ca-certificates curl docker.io docker-compose-plugin fail2ban jq openssh-server ufw unattended-upgrades"

log "Applying SSH hardening"
SSH_CONF="/etc/ssh/sshd_config.d/99-opale-hardening.conf"
SSH_CONTENT="Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitEmptyPasswords no
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers ${ADMIN_USER}
Banner /etc/issue.net
"
write_file "$SSH_CONF" "$SSH_CONTENT"
write_file "/etc/issue.net" "UNAUTHORIZED ACCESS PROHIBITED. All connections are logged and audited.
"

if [ "$DRY_RUN" = false ]; then
  sshd -t
  reload_systemd_service ssh
fi

log "Configuring firewall"
run "ufw --force reset"
run "ufw default deny incoming"
run "ufw default allow outgoing"
run "ufw allow ${SSH_PORT}/tcp"
if [ -n "$APP_PORT" ]; then
  run "ufw allow ${APP_PORT}/tcp"
fi
run "ufw --force enable"

log "Configuring fail2ban"
FAIL2BAN_CONF="/etc/fail2ban/jail.d/opale-hardening.local"
FAIL2BAN_CONTENT="[DEFAULT]
bantime = 2h
findtime = 10m
maxretry = 3

[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
"
write_file "$FAIL2BAN_CONF" "$FAIL2BAN_CONTENT"
if [ "$DRY_RUN" = false ]; then
  reload_systemd_service fail2ban
fi

log "Applying sysctl baseline"
SYSCTL_CONF="/etc/sysctl.d/99-opale-hardening.conf"
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
run "sysctl --system >/dev/null 2>&1"

log "Registering auditd rules"
AUDIT_RULES="/etc/audit/rules.d/opale-hardening.rules"
AUDIT_CONTENT="-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/docker/daemon.json -p wa -k docker_config
"
if [ -n "$APP_DIR" ]; then
  AUDIT_CONTENT="${AUDIT_CONTENT}-w ${APP_DIR}/deploy.env -p wa -k app_env
"
fi
write_file "$AUDIT_RULES" "$AUDIT_CONTENT"
if [ "$DRY_RUN" = false ]; then
  augenrules --load >/dev/null 2>&1 || true
  reload_systemd_service auditd
fi

log "Configuring Docker daemon"
DOCKER_DAEMON="/etc/docker/daemon.json"
DOCKER_DAEMON_CONTENT='{
  "icc": false,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}'
write_file "$DOCKER_DAEMON" "$DOCKER_DAEMON_CONTENT"
if [ "$DRY_RUN" = false ]; then
  mkdir -p /etc/systemd/system/docker.service.d
  usermod -aG docker "$ADMIN_USER" >/dev/null 2>&1 || true
  reload_systemd_service docker
fi

log "Preparing app workspace"
if [ -n "$APP_DIR" ]; then
  run "mkdir -p '${APP_DIR}' '${APP_DIR}/data'"
  run "chmod 750 '${APP_DIR}'"
  run "chmod 700 '${APP_DIR}/data'"
fi

log "Enabling unattended security updates"
AUTO_UPGRADES='/etc/apt/apt.conf.d/20auto-upgrades'
AUTO_UPGRADES_CONTENT='APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
'
write_file "$AUTO_UPGRADES" "$AUTO_UPGRADES_CONTENT"
if [ "$DRY_RUN" = false ]; then
  reload_systemd_service unattended-upgrades
fi

log "Ubuntu hardening baseline complete"
