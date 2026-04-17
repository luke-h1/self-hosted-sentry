#!/usr/bin/env bash
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

echo "[1/9] Updating packages..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

echo "[2/9] Installing dependencies..."
apt-get install -y -qq \
  apt-transport-https ca-certificates curl gnupg lsb-release \
  htop iotop git fail2ban ufw unattended-upgrades jq chrony

echo "[3/9] Installing K3s..."
if ! command -v k3s &>/dev/null; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server" sh -s - \
    --write-kubeconfig-mode 644
else
  echo "  already installed: $(k3s --version | head -1)"
fi
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" > /etc/profile.d/k3s.sh

echo "[4/9] Installing Helm..."
if ! command -v helm &>/dev/null; then
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
  echo "  already installed: $(helm version --short)"
fi
helm repo add sentry https://sentry-kubernetes.github.io/charts 2>/dev/null || true
helm repo update

echo "[5/9] Hardening SSH..."
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
systemctl restart ssh

echo "[6/9] Configuring firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp"
ufw --force enable

echo "[7/9] Configuring fail2ban..."
cat > /etc/fail2ban/jail.d/sshd.conf <<EOF
[sshd]
enabled  = true
port     = ${SSH_PORT}
maxretry = 3
bantime  = 3600
findtime = 600
EOF
systemctl enable fail2ban && systemctl restart fail2ban

echo "[8/9] Tuning kernel..."
cat > /etc/sysctl.d/99-sentry.conf <<'EOF'
vm.max_map_count = 262144
vm.swappiness = 10
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

echo "[9/9] Configuring 16GB swap..."
if [[ ! -f /swapfile ]]; then
  fallocate -l 16G /swapfile
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "  created"
elif [[ $(stat -c %s /swapfile 2>/dev/null || stat -f %z /swapfile) -lt 16000000000 ]]; then
  swapoff /swapfile 2>/dev/null || true
  rm -f /swapfile
  fallocate -l 16G /swapfile
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo "  resized to 16GB"
else
  echo "  already configured"
fi

systemctl enable chrony && systemctl start chrony
systemctl enable unattended-upgrades && systemctl start unattended-upgrades

if [[ -f /etc/sentry/cloudflare-tunnel-token ]]; then
  echo "Configuring Cloudflare Tunnel service..."
  mkdir -p --mode=0755 /usr/share/keyrings /var/log/cloudflared
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' > /etc/apt/sources.list.d/cloudflared.list
  apt-get update -qq
  apt-get install -y -qq cloudflared
  cat > /etc/systemd/system/cloudflared.service <<'EOF'
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
TimeoutStartSec=0
ExecStart=/usr/bin/cloudflared tunnel --loglevel info --logfile /var/log/cloudflared/cloudflared.log --metrics 127.0.0.1:20241 run --token-file /etc/sentry/cloudflare-tunnel-token
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable cloudflared
  systemctl restart cloudflared
else
  echo "Cloudflare tunnel token not found at /etc/sentry/cloudflare-tunnel-token; skipping cloudflared setup."
fi

echo ""
echo "Done. RAM: $(free -h | awk '/^Mem:/ {print $2}'), Swap: $(free -h | awk '/^Swap:/ {print $2}'), Disk: $(df -h / | tail -1 | awk '{print $4}') free"
echo "K3s: $(kubectl get nodes -o wide 2>/dev/null | tail -1 || echo 'starting...')"
echo "Next: ./scripts/install-sentry.sh"
