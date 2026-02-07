# Self-Hosted Sentry

Self-hosted [Sentry](https://sentry.io) on Hetzner Cloud with Cloudflare, Prometheus, Grafana, and GitHub Actions CI/CD. Runs on a single ~$4/mo server.

## Why?

Sentry SaaS pricing adds up fast. Self-hosting gives you the full [Business plan feature set](https://develop.sentry.dev/self-hosted/) (error tracking, performance monitoring, session replay, cron monitoring) with no per-event billing. This repo automates the entire deployment: infrastructure provisioning, security hardening, monitoring, backups, and CI/CD - all on a single cheap Hetzner box behind Cloudflare's free tier.

# Table of contents

- [Self-Hosted Sentry](#self-hosted-sentry)
- [Why?](#why)
- [Cost breakdown](#cost-breakdown)
- [Architecture](#architecture)
- [Core dependencies](#core-dependencies)
- [Tradeoffs](#tradeoffs)
- [Getting started](#getting-started)
  - [Prerequisites](#prerequisites)
  - [1. Configure](#1-configure)
  - [2. Provision infrastructure](#2-provision-infrastructure)
  - [3. Cloudflare Origin Certificate](#3-cloudflare-origin-certificate)
  - [4. Deploy Sentry](#4-deploy-sentry)
  - [5. Post-deploy](#5-post-deploy)
- [Operations](#operations)
  - [Service management](#service-management)
  - [Monitoring (Prometheus + Grafana)](#monitoring-prometheus--grafana)
  - [Backups](#backups)
  - [Upgrading](#upgrading)
- [Configuration](#configuration)
  - [Environment variables](#environment-variables)
  - [Cloudflare settings](#cloudflare-settings)
  - [Scaling up](#scaling-up)
- [CI/CD (GitHub Actions)](#cicd-github-actions)
  - [Workflows](#workflows)
  - [Required GitHub secrets](#required-github-secrets)
  - [Manual triggers](#manual-triggers)
- [Example app + load testing](#example-app--load-testing)
- [Security](#security)
- [Self-hosted Sentry best practices](#self-hosted-sentry-best-practices)
- [Disk management](#disk-management)
- [Troubleshooting](#troubleshooting)
- [Project structure](#project-structure)
- [Contributing](#contributing)
- [License](#license)

## Cost breakdown

| Resource                                 | Cost                        |
| ---------------------------------------- | --------------------------- |
| Hetzner CX22 (2 vCPU, 4GB RAM, 40GB SSD) | ~EUR 3.99/mo                |
| Cloudflare (free plan)                   | $0                          |
| Separate volume                          | Disabled (uses server disk) |
| **Total**                                | **~$4.35/mo**               |

## Architecture

```
User -> Cloudflare (DNS + CDN + WAF + SSL) -> Hetzner CX22 -> Nginx -> Sentry (Docker Compose)
                                                            -> Prometheus + Grafana (monitoring)
```

The CX22 runs everything on a single box: Sentry's 15+ Docker containers, Nginx reverse proxy, Prometheus, Grafana, and node_exporter. It works via 4GB RAM + 8GB swap.

## Core dependencies

| Technology                                                     | Category        | Description                                        |
| -------------------------------------------------------------- | --------------- | -------------------------------------------------- |
| [Sentry self-hosted](https://github.com/getsentry/self-hosted) | Error tracking  | Official self-hosted distribution (Docker Compose) |
| [Hetzner Cloud](https://www.hetzner.com/cloud)                 | Infrastructure  | CX22 server (~EUR 4/mo)                            |
| [Cloudflare](https://cloudflare.com)                           | DNS / CDN / SSL | Free plan with Origin Certificates                 |
| [Terraform](https://www.terraform.io/)                         | IaC             | Provisions server + DNS + SSL settings             |
| [Nginx](https://nginx.org/)                                    | Reverse proxy   | SSL termination, rate limiting, Cloudflare real IP |
| [Prometheus](https://prometheus.io/)                           | Metrics         | Scrapes node, container, and Nginx metrics         |
| [Grafana](https://grafana.com/)                                | Dashboards      | Pre-built server health dashboard                  |
| [k6](https://k6.io/)                                           | Load testing    | 60k users/hour simulation                          |
| [GitHub Actions](https://github.com/features/actions)          | CI/CD           | Lint, deploy, load test, health check              |

## Tradeoffs

> [!IMPORTANT]
> The official Sentry docs recommend **4 CPU, 16GB RAM + 16GB swap, 20GB disk** as minimum. This setup runs on 2 vCPU + 4GB RAM + 8GB swap, which is well below that. It works for small teams but comes with tradeoffs.

- **Startup is slow**: ~2-3 min for all containers to be healthy (swap-heavy)
- **Page loads**: First load after idle is slower (~3-5s) as services swap back into RAM; subsequent loads are normal
- **Event ingestion**: Handles ~1000-5000 events/day comfortably
- **Disk**: 40GB total, ~20GB used by Sentry + Docker images, ~20GB for data
- **Retention**: Default 30 days to keep disk usage low

> [!TIP]
> If you need faster performance, upgrade to a CX32 (4 vCPU, 8GB RAM, ~EUR 7.49/mo) - see [Scaling up](#scaling-up).

# Getting started

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.5
- [Hetzner Cloud](https://console.hetzner.cloud) account + API token
- [Cloudflare](https://dash.cloudflare.com) account (free plan) with your domain added
- SSH key pair (`~/.ssh/id_ed25519` or similar)

## 1. Configure

```bash
cp .env.example .env
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# Edit with your values
vim .env                       # Domain, admin email/password, SMTP
vim terraform/terraform.tfvars # Hetzner token, Cloudflare token, SSH IPs
```

> [!WARNING]
> Set `ssh_allowed_ips` in `terraform.tfvars` to your IP address. Leaving it empty allows SSH from anywhere.

## 2. Provision infrastructure

```bash
make tf-init
make tf-plan    # Review: should show 1 server + DNS records (~EUR 4/mo)
make tf-apply
make tf-output  # Note the server IP and SSH command
```

Terraform creates:

- Hetzner CX22 server with cloud-init (Docker, firewall, SSH hardening, 8GB swap)
- Hetzner firewall (HTTP/HTTPS restricted to Cloudflare IPs only)
- Cloudflare DNS A + AAAA records (proxied)
- Cloudflare SSL/TLS settings (Full Strict, HSTS, TLS 1.2+)

## 3. Cloudflare Origin Certificate

1. **Cloudflare Dashboard** > your domain > **SSL/TLS** > **Origin Server**
2. Click **Create Certificate** (RSA 2048, 15 years)
3. SSH into the server and save the certificate:

```bash
ssh root@<SERVER_IP>
mkdir -p /etc/nginx/ssl
nano /etc/nginx/ssl/cloudflare-origin.pem       # Paste the certificate
nano /etc/nginx/ssl/cloudflare-origin-key.pem    # Paste the private key
chmod 600 /etc/nginx/ssl/cloudflare-origin-key.pem
```

4. Verify Cloudflare SSL mode is set to **Full (Strict)** (Terraform sets this automatically)

## 4. Deploy Sentry

```bash
ssh root@<SERVER_IP>

git clone <this-repo-url> /opt/sentry/deploy
cd /opt/sentry/deploy
cp .env.example .env && vim .env

# Full deployment: server setup + Sentry install + Nginx + monitoring
make deploy
```

> [!NOTE]
> First deploy takes ~20-30 minutes on a CX22. The Sentry installer pulls ~10GB of Docker images and runs database migrations. Subsequent deploys (via GitHub Actions) are much faster since they only sync config changes.

Or step by step:

```bash
make setup              # Docker, firewall, SSH hardening, 8GB swap, kernel tuning
make install            # Clone official self-hosted Sentry, configure, run installer (~15 min)
make nginx              # Nginx reverse proxy + Cloudflare SSL + Authenticated Origin Pulls
make monitoring-setup   # Prometheus + Grafana
make start              # Start Sentry via systemd
```

## 5. Post-deploy

```bash
make health        # Verify Sentry + Prometheus + Grafana are healthy
make cron-setup    # Install daily backup + 5-min health monitor + weekly Docker cleanup
```

Visit `https://sentry.yourdomain.com` and log in with your admin credentials.

Grafana is at `https://sentry.yourdomain.com/grafana/`.

# Operations

## Service management

```bash
make start          # Start Sentry (auto-starts on boot via systemd)
make stop           # Stop Sentry
make restart        # Restart all services
make status         # Systemd status + container list
make version        # Show installed Sentry version
make logs           # Tail all Sentry logs
make logs-web       # Web service only
make logs-worker    # Worker only
make logs-postgres  # PostgreSQL only
make logs-nginx     # Nginx access + error logs
```

## Monitoring (Prometheus + Grafana)

Prometheus scrapes system metrics (CPU, RAM, disk, swap, network), Docker container metrics (per-container resource usage), and Nginx request rates. A pre-built Grafana dashboard is auto-provisioned on first boot.

```bash
make monitoring-up       # Start Prometheus + Grafana
make monitoring-down     # Stop monitoring stack
make monitoring-restart  # Restart monitoring
make monitoring-logs     # Tail monitoring logs
make monitoring-status   # Container status + Prometheus target health
make health              # Full health check (Sentry + system + Prometheus + Redis + Postgres)
make monitor             # Health check + send webhook alert on failure
```

Prometheus alert rules fire on:

- Sentry web down for > 2 min
- Memory > 90% for > 5 min
- Swap > 80% for > 10 min
- Disk > 80% (warning) or > 90% (critical)
- Disk predicted to fill within 24 hours
- CPU > 85% for > 10 min
- Container OOM killed
- Container restart loops (> 3 in 15 min)

## Backups

Backups include a full PostgreSQL dump (compressed, verified non-empty), Sentry config files, Nginx config, and a metadata file. Archives are verified after creation.

```bash
make backup     # Manual backup
make restore    # Interactive restore from backup archive
make cron-setup # Install daily backup at 3:00 AM
```

> [!WARNING]
> Test your restore procedure **before** you need it. Run `make backup && make restore` on a staging instance to verify the process works end-to-end.

## Upgrading

```bash
make upgrade    # Backup -> pull latest tag -> reinstall -> restart
```

This runs the official self-hosted installer against the latest tagged release. Always check the [self-hosted changelog](https://github.com/getsentry/self-hosted/releases) before upgrading.

> [!CAUTION]
> The official Sentry team [recommends upgrading regularly](https://develop.sentry.dev/self-hosted/releases/). Falling too far behind makes future upgrades harder.

# Configuration

## Environment variables

| Variable                      | Default | Description                             |
| ----------------------------- | ------- | --------------------------------------- |
| `SENTRY_DOMAIN`               | -       | Full domain (e.g. `sentry.example.com`) |
| `SENTRY_ADMIN_EMAIL`          | -       | Admin superuser email                   |
| `SENTRY_ADMIN_PASSWORD`       | -       | Admin password (>= 12 characters)       |
| `SSH_PORT`                    | `22`    | SSH port (match Terraform `ssh_port`)   |
| `SENTRY_EVENT_RETENTION_DAYS` | `30`    | Days to keep events (lower = less disk) |
| `SENTRY_MAIL_FROM`            | -       | Sender email for alerts/invites         |
| `SENTRY_MAIL_HOST`            | -       | SMTP server                             |
| `SENTRY_MAIL_PORT`            | `587`   | SMTP port                               |
| `SENTRY_MAIL_USERNAME`        | -       | SMTP username                           |
| `SENTRY_MAIL_PASSWORD`        | -       | SMTP password                           |
| `SENTRY_MAIL_USE_TLS`         | `True`  | SMTP TLS                                |
| `BACKUP_RETENTION_DAYS`       | `7`     | Days to keep backup archives            |
| `MONITOR_WEBHOOK_URL`         | -       | Slack/Discord webhook for alerts        |
| `GRAFANA_ADMIN_USER`          | `admin` | Grafana login username                  |
| `GRAFANA_ADMIN_PASSWORD`      | -       | Grafana login password                  |

## Cloudflare settings

Terraform configures these automatically. Verify in the Cloudflare dashboard:

| Setting                    | Value                                               | Location                    |
| -------------------------- | --------------------------------------------------- | --------------------------- |
| SSL/TLS mode               | **Full (Strict)**                                   | SSL/TLS > Overview          |
| Always Use HTTPS           | **On**                                              | SSL/TLS > Edge Certificates |
| Minimum TLS Version        | **1.2**                                             | SSL/TLS > Edge Certificates |
| HSTS                       | **On** (max-age 1 year, includeSubDomains, preload) | SSL/TLS > Edge Certificates |
| Authenticated Origin Pulls | **On**                                              | SSL/TLS > Origin Server     |
| DNS record                 | **Proxied** (orange cloud)                          | DNS                         |

## Scaling up

If you outgrow the CX22, resize via Hetzner Cloud Console or update `terraform.tfvars`:

```hcl
server_type    = "cx32"       # 4 vCPU, 8GB RAM, 80GB disk - ~EUR 7.49/mo
enable_volume  = true         # Attach a separate data volume
volume_size_gb = 50           # +~EUR 2.50/mo
```

Then run `make tf-apply`. Update `SENTRY_EVENT_RETENTION_DAYS=90` in `.env` for longer retention.

| Server | vCPU | RAM   | Disk   | EUR/mo | Good for                       |
| ------ | ---- | ----- | ------ | ------ | ------------------------------ |
| CX22   | 2    | 4 GB  | 40 GB  | ~3.99  | 1-10 devs, low volume          |
| CX32   | 4    | 8 GB  | 80 GB  | ~7.49  | 10-50 devs, moderate volume    |
| CPX31  | 4    | 8 GB  | 160 GB | ~10.49 | 20-100 devs                    |
| CPX41  | 8    | 16 GB | 240 GB | ~18.49 | Matches official minimum specs |

# CI/CD (GitHub Actions)

## Workflows

| Workflow                  | Trigger                          | What it does                                                                                                                                        |
| ------------------------- | -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| **CI** (`ci.yml`)         | Push / PR to `main`              | ShellCheck scripts, Terraform fmt + validate, Docker Compose config check, Prometheus config + alert rule validation, Nginx syntax check, YAML lint |
| **Deploy** (`deploy.yml`) | Push to `main` / manual dispatch | Rsync files to server via SSH, restart Sentry + Nginx + monitoring, post-deploy health check, webhook alert on failure                              |
| **Backup** (`backup.yml`) | Daily at 3:00 AM UTC / manual    | SSH into server, run verified PostgreSQL backup, check archive integrity, alert on failure                                                          |

## Required GitHub secrets

Set these in **Settings > Secrets and variables > Actions**:

| Secret                | Required | Description                              |
| --------------------- | -------- | ---------------------------------------- |
| `SERVER_HOST`         | Yes      | Hetzner server IP address                |
| `SSH_PRIVATE_KEY`     | Yes      | SSH private key for `root@SERVER_HOST`   |
| `SSH_PORT`            | No       | SSH port (default: 22)                   |
| `MONITOR_WEBHOOK_URL` | No       | Slack/Discord webhook for failure alerts |

## Manual triggers

```bash
# Deploy a specific component
gh workflow run deploy.yml -f target=nginx
gh workflow run deploy.yml -f target=monitoring

# Trigger a manual backup
gh workflow run backup.yml
```

# Example app + load testing

An [Expo](https://expo.dev/) React Native TypeScript app lives in `example-app/`. It integrates the `@sentry/react-native` SDK with your self-hosted instance and includes screens for testing error capture, performance tracing, and API call instrumentation.

The `example-app/k6/` directory contains [k6](https://k6.io/) load test scripts that simulate 60,000 users/hour hitting the Sentry event ingestion API with realistic React Native SDK payloads (errors with stacktraces, transactions with spans, sessions with device context).

See [`example-app/README.md`](example-app/README.md) for setup instructions and load test scenarios.

# Security

Despite the budget, all production security hardening is applied:

| Layer        | What                                                                                                           |
| ------------ | -------------------------------------------------------------------------------------------------------------- |
| **Network**  | Hetzner firewall restricts HTTP/HTTPS to Cloudflare IPs only. SSH restricted to your IPs.                      |
| **SSL**      | Cloudflare Origin Certificate + Authenticated Origin Pulls (mutual TLS). TLS 1.2+ only.                        |
| **SSH**      | Key-only auth, password disabled, max 3 attempts, configurable port, no forwarding.                            |
| **Firewall** | UFW + fail2ban with SSH, Nginx auth, and Nginx rate-limit jails.                                               |
| **Docker**   | Log rotation (5MB/2 files), live-restore, file descriptor limits, memory limits on all containers.             |
| **Sentry**   | Registration disabled, CSRF protection, secure cookies (HttpOnly, SameSite=Lax), auth rate limiting.           |
| **Nginx**    | Rate limiting per endpoint type (auth: 5r/s, API: 50r/s, store: 100r/s), server_tokens off, WebSocket support. |
| **OS**       | Automatic security updates (unattended-upgrades), NTP sync (chrony), kernel hardening (sysctl).                |

# Self-hosted Sentry best practices

This repo follows the [official self-hosted Sentry documentation](https://develop.sentry.dev/self-hosted/) and implements the recommended [production enhancements](https://develop.sentry.dev/self-hosted/production-enhancements/):

- **Reverse proxy with SSL termination**: Nginx terminates SSL, forwards `X-Forwarded-For` and `X-Forwarded-Proto`, and exposes `/_health/` for load balancer health checks
- **`system.url-prefix`**: Set to `https://SENTRY_DOMAIN` in both `config.yml` and `sentry.conf.py`
- **CSRF configuration**: `CSRF_TRUSTED_ORIGINS`, `SECURE_PROXY_SSL_HEADER`, `SESSION_COOKIE_SECURE` all configured for HTTPS behind a proxy
- **Secret key persistence**: Generated once and stored on the data volume at `$SENTRY_DATA_DIR/.secret-key`, survives reinstalls and upgrades
- **Event retention cleanup**: `SENTRY_EVENT_RETENTION_DAYS` set with the `sentry cleanup` cron job enabled
- **Beacon disabled**: `beacon.anonymous: true` in `config.yml` to anonymize telemetry
- **Registration disabled**: `auth.allow-registration: false` to prevent unauthorized signups
- **Auth rate limiting**: `auth.ip-rate-limit: 10`, `auth.user-rate-limit: 5` to prevent brute force
- **Relay in managed mode**: The default for self-hosted, handles event ingestion
- **Symbolicator enabled**: For source map and debug symbol processing
- **Docker resource limits**: Memory limits on every container to prevent OOM cascades
- **Automated backups**: Verified PostgreSQL dumps with integrity checks and metadata

> [!NOTE]
> The official minimum is 4 CPU + 16GB RAM + 16GB swap. This setup runs below that threshold. For production workloads exceeding ~5,000 events/day, strongly consider upgrading to a CX32 or CPX31 server. See the official [reference architectures](https://develop.sentry.dev/self-hosted/reference-architecture/) for guidance on scaling.

# Disk management

The 40GB disk is the main constraint on the CX22. Tips:

- **30-day retention** is the default (saves ~50% disk vs 90 days)
- **Weekly Docker cleanup** cron removes dangling images automatically
- `make cleanup` for immediate disk reclamation
- `make disk` to check usage breakdown (system, Docker, backups)
- Prometheus alerts fire at 80% disk usage and predict disk-full within 24 hours
- If disk fills, lower retention: `SENTRY_EVENT_RETENTION_DAYS=14` in `.env` and `make restart`

# Troubleshooting

### Out of memory / slow

This is expected on 4GB RAM. Swap absorbs the memory pressure. If containers get OOM-killed:

```bash
# Check what happened
sudo dmesg | grep -i "out of memory" | tail -5
docker stats --no-stream

# Restart to recover
make restart
```

### Disk full

```bash
make disk        # Check what's using space
make cleanup     # Remove old Docker images and build cache

# Lower retention if needed
vim .env         # Set SENTRY_EVENT_RETENTION_DAYS=14
make restart
```

### Slow after idle

Normal on CX22. After periods of inactivity, services get swapped out to disk. The first request triggers swap-in which takes a few seconds. Subsequent requests are normal speed.

### SSL certificate issues

```bash
# Verify origin cert
openssl x509 -noout -dates -in /etc/nginx/ssl/cloudflare-origin.pem

# Check Nginx config
sudo nginx -t
tail -f /var/log/nginx/sentry-error.log

# Verify Cloudflare SSL mode is "Full (Strict)" in the dashboard
```

### Containers not starting

```bash
# Check systemd
sudo systemctl status sentry
sudo journalctl -u sentry --no-pager -n 50

# Check individual container logs
cd /opt/sentry/self-hosted
docker compose logs web
docker compose logs worker
docker compose logs postgres
```

# Project structure

```
.
├── .env.example                    # Configuration template
├── .github/workflows/
│   ├── ci.yml                      # Lint + validate on PR/push
│   ├── deploy.yml                  # SSH deploy on push to main
│   └── backup.yml                  # Daily automated backup (3:00 AM UTC)
├── Makefile                        # All operations (run `make help`)
├── docker-compose.override.yml     # Memory limits tuned for 4GB server
├── monitoring/
│   ├── docker-compose.yml          # Prometheus + Grafana + node_exporter + cAdvisor
│   ├── prometheus/
│   │   ├── prometheus.yml          # Scrape targets (node, cadvisor, nginx, sentry)
│   │   └── alerts.yml              # Alert rules (memory, disk, OOM, sentry down)
│   └── grafana/
│       ├── provisioning/           # Auto-configured datasource + dashboard provider
│       └── dashboards/             # Pre-built Sentry server overview dashboard
├── nginx/
│   └── sentry.conf                 # Reverse proxy (Cloudflare real IP, rate limits, WebSocket)
├── scripts/
│   ├── setup-server.sh             # Server hardening (SSH, firewall, Docker, swap, kernel)
│   ├── install-sentry.sh           # Clone self-hosted Sentry, configure, install, systemd
│   ├── setup-nginx.sh              # Nginx + Cloudflare SSL + Authenticated Origin Pulls
│   ├── setup-monitoring.sh         # Deploy Prometheus + Grafana + Nginx stub_status
│   ├── backup.sh                   # Verified PostgreSQL backup with metadata
│   ├── restore.sh                  # Interactive restore from backup archive
│   └── monitor.sh                  # Health checks + webhook alerting
├── example-app/
│   ├── app/                        # Expo Router screens (home, errors, performance)
│   ├── src/utils/                  # Sentry SDK wrapper + traced API client
│   └── k6/                         # Load tests (smoke, full 60k/hr, stress, spike, soak)
└── terraform/
    ├── main.tf                     # CX22 server + Cloudflare DNS + SSL + firewall
    ├── variables.tf                # All config with validation
    ├── outputs.tf                  # IP, URL, SSH command, cost estimate
    ├── cloud-init.yml              # Bootstrap (Docker, SSH, sysctl, swap, fail2ban, chrony)
    └── terraform.tfvars.example    # Variable template with server sizing table
```

# Contributing

1. Create a new branch from `main`
2. Make your changes
3. Open a PR against `main`
   - The CI workflow will automatically lint scripts, validate Terraform, check Docker Compose configs, and validate Prometheus rules
   - Provide a description of what changed and why
4. After approval and CI passes, merge to `main`
   - The Deploy workflow automatically syncs changes to the server

# License

MIT
