#!/usr/bin/env bash
# Prepare a fresh Hetzner server for Sentry.
# Optimized for CX22 (4GB RAM). Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "$PROJECT_DIR/.env" ]]; then
  set -a; source "$PROJECT_DIR/.env"; set +a
fi

SSH_PORT="${SSH_PORT:-22}"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run as root"; exit 1
fi

echo "[1/11] Updating packages..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

echo "[2/11] Installing dependencies..."
apt-get install -y -qq \
  apt-transport-https ca-certificates curl gnupg lsb-release \
  htop iotop git nginx fail2ban ufw unattended-upgrades jq logrotate chrony

echo "[3/11] Installing Docker..."
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker && systemctl start docker
else
  echo "  already installed: $(docker --version)"
fi

mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "5m", "max-file": "2" },
  "default-ulimits": { "nofile": { "Name": "nofile", "Hard": 1048576, "Soft": 1048576 } },
  "live-restore": true,
  "userland-proxy": false
}
EOF
systemctl restart docker

echo "[4/11] Installing Docker Compose..."
if ! docker compose version &>/dev/null; then
  apt-get install -y -qq docker-compose-plugin
else
  echo "  already installed: $(docker compose version)"
fi

echo "[5/11] Hardening SSH..."
cat > /etc/ssh/sshd_config.d/99-hardened.conf <<SSHCFG
Port ${SSH_PORT}
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
MaxAuthTries 3
MaxSessions 5
ClientAliveInterval 300
ClientAliveCountMax 2
AllowAgentForwarding no
AllowTcpForwarding no
LoginGraceTime 30
SSHCFG
systemctl restart sshd

echo "[6/11] Configuring firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "[7/11] Configuring fail2ban..."
cat > /etc/fail2ban/jail.d/sshd.conf <<EOF
[sshd]
enabled  = true
port     = ${SSH_PORT}
maxretry = 3
bantime  = 3600
findtime = 600
EOF

cat > /etc/fail2ban/jail.d/nginx.conf <<'EOF'
[nginx-http-auth]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/sentry-error.log
maxretry = 5
bantime  = 3600

[nginx-limit-req]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/sentry-error.log
maxretry = 10
bantime  = 600
EOF
systemctl enable fail2ban && systemctl restart fail2ban

echo "[8/11] Enabling NTP..."
systemctl enable chrony && systemctl start chrony

echo "[9/11] Tuning kernel..."
cat > /etc/sysctl.d/99-sentry.conf <<'EOF'
vm.max_map_count = 262144
vm.swappiness = 60
vm.overcommit_memory = 1
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
fs.file-max = 1048576
fs.inotify.max_user_watches = 524288
EOF
sysctl --system > /dev/null 2>&1

cat > /etc/security/limits.d/99-sentry.conf <<'EOF'
*    soft nofile 1048576
*    hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
*    soft nproc  65535
*    hard nproc  65535
EOF

echo "[10/11] Configuring 8GB swap..."
if [[ ! -f /swapfile ]]; then
  fallocate -l 8G /swapfile
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "  created"
elif [[ $(stat -c %s /swapfile 2>/dev/null || stat -f %z /swapfile) -lt 8000000000 ]]; then
  swapoff /swapfile 2>/dev/null || true
  rm -f /swapfile
  fallocate -l 8G /swapfile
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo "  resized to 8GB"
else
  echo "  already configured"
fi

echo "[11/11] Configuring log rotation..."
cat > /etc/logrotate.d/nginx-sentry <<'EOF'
/var/log/nginx/sentry-*.log {
  daily
  missingok
  rotate 7
  compress
  delaycompress
  notifempty
  sharedscripts
  postrotate
    [ -f /var/run/nginx.pid ] && kill -USR1 $(cat /var/run/nginx.pid)
  endscript
}
EOF

systemctl enable unattended-upgrades && systemctl start unattended-upgrades

echo ""
echo "Done. RAM: $(free -h | awk '/^Mem:/ {print $2}'), Swap: $(free -h | awk '/^Swap:/ {print $2}'), Disk: $(df -h / | tail -1 | awk '{print $4}') free"
echo "Next: ./scripts/install-sentry.sh"
