# Self-Hosted Sentry

Self-hosted [Sentry](https://sentry.io) on Hetzner Cloud with K3s, Helm, Cloudflare, Prometheus, Grafana, and GitHub Actions CI/CD. Runs on a single ~$7/mo server.

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
  - [3. Deploy Sentry](#3-deploy-sentry)
  - [4. Post-deploy](#4-post-deploy)
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

| Resource                                  | Cost                        |
| ----------------------------------------- | --------------------------- |
| Hetzner CX33 (4 vCPU, 8GB RAM, 80GB SSD) | ~EUR 7.49/mo                |
| Cloudflare (free plan)                    | $0                          |
| **Total**                                 | **~$7.49/mo**               |

## Architecture

```
User -> Cloudflare (DNS + CDN + WAF + SSL) -> Hetzner CX33 -> K3s Traefik Ingress -> Sentry (Helm chart)
                                                             -> Prometheus + Grafana (K8s monitoring)
```

The CX33 runs everything on a single K3s node: Sentry's pods (web, worker, consumers, relay, snuba, PostgreSQL, Redis, Kafka, ClickHouse), Traefik ingress, Prometheus, Grafana, and node-exporter. Cloudflare terminates TLS; Traefik handles HTTP routing.

## Core dependencies

| Technology                                                                   | Category        | Description                                                 |
| ---------------------------------------------------------------------------- | --------------- | ----------------------------------------------------------- |
| [Sentry Helm chart](https://github.com/sentry-kubernetes/charts)            | Error tracking  | Community Helm chart for Sentry on Kubernetes               |
| [K3s](https://k3s.io/)                                                       | Orchestration   | Lightweight Kubernetes with built-in Traefik ingress        |
| [Helm](https://helm.sh/)                                                     | Package manager | Manages Sentry deployment and upgrades                      |
| [Hetzner Cloud](https://www.hetzner.com/cloud)                               | Infrastructure  | CX33 server (~EUR 7.49/mo)                                 |
| [Cloudflare](https://cloudflare.com)                                         | DNS / CDN / SSL | Free plan with TLS termination                              |
| [Terraform](https://www.terraform.io/)                                       | IaC             | Provisions server + DNS + SSL settings                      |
| [Prometheus](https://prometheus.io/)                                         | Metrics         | Scrapes node and pod metrics via K8s service discovery       |
| [Grafana](https://grafana.com/)                                              | Dashboards      | Server health dashboards                                    |
| [k6](https://k6.io/)                                                         | Load testing    | 60k users/hour simulation                                  |
| [GitHub Actions](https://github.com/features/actions)                        | CI/CD           | Lint, deploy via Helm, health check                         |

## Tradeoffs

> [!IMPORTANT]
> The official Sentry docs recommend **4 CPU, 16GB RAM + 16GB swap, 20GB disk** as minimum. This setup runs on 4 vCPU + 8GB RAM + 8GB swap with aggressive memory limits and non-essential features disabled. It works for small teams but comes with tradeoffs.

- **Startup is slow**: ~3-5 min for all pods to be Running (swap-heavy during initial scheduling)
- **Page loads**: First load after idle is slower (~3-5s) as pods swap back into RAM; subsequent loads are normal
- **Event ingestion**: Handles ~1000-5000 events/day comfortably
- **Disk**: 80GB total, ~30GB used by K3s images + PVCs, ~50GB for data
- **Retention**: Default 30 days to keep disk usage low
- **Disabled features**: Profiling, spans, uptime, feedback, and symbolicator are disabled to save memory

> [!TIP]
> If you need faster performance or more features, upgrade to a CPX31 (4 vCPU, 8GB RAM, 160GB disk, ~EUR 10.49/mo) for more disk, or CPX41 (8 vCPU, 16GB RAM, ~EUR 18.49/mo) to match official specs and re-enable all features.

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
make tf-plan    # Review: should show 1 server + DNS records (~EUR 7.49/mo)
make tf-apply
make tf-output  # Note the server IP and SSH command
```

Terraform creates:

- Hetzner CX33 server with cloud-init (K3s, Helm, firewall, SSH hardening, 8GB swap)
- Hetzner firewall (HTTP/HTTPS restricted to Cloudflare IPs only)
- Cloudflare DNS A + AAAA records (proxied)
- Cloudflare SSL/TLS settings (Full Strict, HSTS, TLS 1.2+)

## 3. Deploy Sentry

```bash
ssh root@<SERVER_IP>

git clone <this-repo-url> /opt/sentry/deploy
cd /opt/sentry/deploy
cp .env.example .env && vim .env

# Full deployment: server setup + Sentry install + monitoring
make deploy
```

> [!NOTE]
> First deploy takes ~20-30 minutes. The Helm chart pulls container images and runs database migrations. Subsequent deploys (via GitHub Actions) are much faster since they only apply config changes via `helm upgrade`.

Or step by step:

```bash
make setup              # K3s, Helm, firewall, SSH hardening, 8GB swap, kernel tuning
make install            # Deploy Sentry via Helm chart (~15-30 min)
make monitoring-setup   # Prometheus + Grafana + node-exporter
```

## 4. Post-deploy

```bash
make health        # Verify Sentry + K3s node + pods are healthy
make cron-setup    # Install daily backup + 5-min health monitor + weekly image cleanup
```

Visit `https://sentry.yourdomain.com` and log in with your admin credentials.

# Operations

## Service management

```bash
make start          # Scale up all Sentry deployments
make stop           # Scale down all Sentry deployments (0 replicas)
make restart        # Rolling restart all deployments
make status         # K3s node + pod status + monitoring pods
make pods           # Detailed pod list with node/IP info
make events         # Recent K8s events (useful for debugging)
make top            # Pod resource usage (CPU/memory)
make version        # Show Helm release info
make logs           # Tail Sentry web logs
make logs-web       # Web pod only
make logs-worker    # Worker pod only
make logs-postgres  # PostgreSQL pod only
```

## Monitoring (Prometheus + Grafana)

Prometheus scrapes system metrics (CPU, RAM, disk, swap, network) via node-exporter and Sentry pod metrics via K8s service discovery.

```bash
make monitoring-setup    # Deploy Prometheus + Grafana + node-exporter
make monitoring-status   # Show monitoring pod status
make monitoring-logs     # Tail Prometheus logs
make health              # Full health check (Sentry HTTP + pods + system + Postgres + Redis)
make monitor             # Health check + send webhook alert on failure
```

## Backups

Backups include a full PostgreSQL dump (compressed, verified non-empty), Helm values export, and ClickHouse metadata. Archives are verified after creation.

```bash
make backup     # Manual backup
make restore    # Interactive restore from backup archive
make cron-setup # Install daily backup at 3:00 AM
```

> [!WARNING]
> Test your restore procedure **before** you need it. Run `make backup && make restore` on a staging instance to verify the process works end-to-end.

## Upgrading

```bash
make upgrade    # Backup -> helm repo update -> helm upgrade -> verify
```

This runs `helm upgrade` with the latest chart version. Always check the [Sentry Helm chart releases](https://github.com/sentry-kubernetes/charts/releases) before upgrading.

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
| DNS record                 | **Proxied** (orange cloud)                          | DNS                         |

## Scaling up

If you outgrow the CX33, resize via Hetzner Cloud Console or update `terraform.tfvars`:

```hcl
server_type = "cpx41"    # 8 vCPU, 16GB RAM, 240GB disk - ~EUR 18.49/mo
```

Then run `make tf-apply`. With more RAM you can re-enable features in `k8s/sentry-values.yaml`:

```yaml
# Enable features disabled for low-memory deployment
sentry:
  profiling:
    enabled: true
  spans:
    enabled: true
symbolicator:
  enabled: true
```

Update `SENTRY_EVENT_RETENTION_DAYS=90` in `.env` for longer retention and run `make upgrade`.

| Server | vCPU | RAM   | Disk   | EUR/mo | Good for                       |
| ------ | ---- | ----- | ------ | ------ | ------------------------------ |
| CX33   | 4    | 8 GB  | 80 GB  | ~7.49  | 1-10 devs, low volume          |
| CPX31  | 4    | 8 GB  | 160 GB | ~10.49 | 10-50 devs, more disk          |
| CPX41  | 8    | 16 GB | 240 GB | ~18.49 | Matches official minimum specs |

# CI/CD (GitHub Actions)

## Workflows

| Workflow                  | Trigger                          | What it does                                                                                            |
| ------------------------- | -------------------------------- | ------------------------------------------------------------------------------------------------------- |
| **CI** (`ci.yml`)         | Push / PR to `main`              | ShellCheck scripts, Terraform fmt + validate, Helm template validation, K8s manifest validation, YAML lint |
| **Deploy** (`deploy.yml`) | Push to `main` / manual dispatch | Rsync files to server, `helm upgrade --reuse-values`, post-deploy health check, webhook alert on failure   |
| **Backup** (`backup.yml`) | Daily at 3:00 AM UTC / manual    | SSH into server, run verified PostgreSQL backup via kubectl, check archive integrity, alert on failure     |

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
gh workflow run deploy.yml -f target=sentry
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

| Layer           | What                                                                                                     |
| --------------- | -------------------------------------------------------------------------------------------------------- |
| **Network**     | Hetzner firewall restricts HTTP/HTTPS to Cloudflare IPs only. SSH restricted to your IPs.                |
| **SSL**         | Cloudflare terminates TLS. Full (Strict) mode with TLS 1.2+ only.                                        |
| **SSH**         | Key-only auth, password disabled, max 3 attempts, configurable port, no forwarding.                      |
| **Firewall**    | UFW + fail2ban with SSH jail.                                                                             |
| **K8s**         | Resource limits on all pods, K3s with default pod security, RBAC for monitoring.                          |
| **Sentry**      | Registration disabled, CSRF protection, secure cookies (HttpOnly, SameSite=Lax), auth rate limiting.     |
| **Ingress**     | K3s Traefik handles routing. Cloudflare WAF protects the edge.                                            |
| **OS**          | Automatic security updates (unattended-upgrades), NTP sync (chrony), kernel hardening (sysctl).          |

# Self-hosted Sentry best practices

This repo follows the [official self-hosted Sentry documentation](https://develop.sentry.dev/self-hosted/) and implements the recommended [production enhancements](https://develop.sentry.dev/self-hosted/production-enhancements/):

- **Reverse proxy with SSL termination**: Cloudflare terminates TLS, K3s Traefik routes to Sentry pods, forwarding `X-Forwarded-For` and `X-Forwarded-Proto`
- **`system.url-prefix`**: Set to `https://SENTRY_DOMAIN` via Helm values
- **CSRF configuration**: `CSRF_TRUSTED_ORIGINS`, `SECURE_PROXY_SSL_HEADER`, `SESSION_COOKIE_SECURE` all configured for HTTPS behind a proxy in `config.sentryConfPy`
- **Event retention cleanup**: `SENTRY_EVENT_RETENTION_DAYS` set via Helm values with cleanup job enabled
- **Beacon disabled**: `beacon.anonymous: true` in config values
- **Registration disabled**: `auth.allow-registration: false` in config values
- **Auth rate limiting**: `auth.ip-rate-limit: 10`, `auth.user-rate-limit: 5`
- **K8s resource limits**: Memory limits on every pod to prevent OOM cascades, with K8s eviction handling memory pressure
- **Automated backups**: Verified PostgreSQL dumps via `kubectl exec` with Helm values export

> [!NOTE]
> The official minimum is 4 CPU + 16GB RAM + 16GB swap. This setup runs below that threshold with non-essential features disabled. For production workloads exceeding ~5,000 events/day, strongly consider upgrading to a CPX41 server.

# Disk management

The 80GB disk on the CX33 provides reasonable headroom. Tips:

- **30-day retention** is the default (saves ~50% disk vs 90 days)
- **Weekly K3s image cleanup** cron removes unused container images automatically
- `make cleanup` for immediate disk reclamation
- `make disk` to check usage breakdown (system, K8s PVCs, backups)
- If disk fills, lower retention: `SENTRY_EVENT_RETENTION_DAYS=14` in `.env` and `make upgrade`

# Troubleshooting

### Out of memory / pods evicted

K8s handles memory pressure better than Docker Compose by evicting low-priority pods. If pods keep getting evicted:

```bash
# Check pod events
make events
kubectl -n sentry describe pod <pod-name>

# Check node memory pressure
kubectl describe node | grep -A5 Conditions

# Rolling restart to recover
make restart
```

### Disk full

```bash
make disk        # Check what's using space
make cleanup     # Remove unused K3s images

# Lower retention if needed
vim .env         # Set SENTRY_EVENT_RETENTION_DAYS=14
make upgrade
```

### Slow after idle

Normal on 8GB RAM. After periods of inactivity, pods get swapped out to disk. The first request triggers swap-in which takes a few seconds. Subsequent requests are normal speed.

### Pods not starting

```bash
# Check pod status and events
make pods
make events

# Check individual pod logs
kubectl -n sentry logs <pod-name>
kubectl -n sentry describe pod <pod-name>

# Check Helm release status
make helm-status
```

### Helm upgrade issues

```bash
# Check what would change before upgrading
make helm-diff

# Check current values
make helm-values

# View Helm release history
helm -n sentry history sentry
```

# Project structure

```
.
├── .env.example                    # Configuration template
├── .github/workflows/
│   ├── ci.yml                      # Lint + validate on PR/push (Helm, K8s, Terraform)
│   ├── deploy.yml                  # Helm upgrade on push to main
│   └── backup.yml                  # Daily automated backup (3:00 AM UTC)
├── Makefile                        # All operations via kubectl/helm (run `make help`)
├── k8s/
│   ├── sentry-values.yaml          # Helm values tuned for 8GB RAM (memory limits, single replicas)
│   ├── clickhouse.yaml             # ClickHouse StatefulSet + Service (external to Helm chart)
│   └── monitoring/
│       ├── prometheus.yaml          # Prometheus Deployment + ConfigMap + RBAC
│       ├── grafana.yaml             # Grafana Deployment + PVC
│       └── node-exporter.yaml       # Node Exporter DaemonSet
├── scripts/
│   ├── setup-server.sh             # Server hardening (SSH, firewall, K3s, Helm, swap, kernel)
│   ├── install-sentry.sh           # Deploy Sentry via Helm chart
│   ├── setup-monitoring.sh         # Deploy monitoring manifests to K8s
│   ├── backup.sh                   # Verified PostgreSQL backup via kubectl exec
│   ├── restore.sh                  # Interactive restore from backup archive
│   └── monitor.sh                  # Health checks (pods, HTTP, Postgres, Redis) + webhook alerting
├── example-app/
│   ├── app/                        # Expo Router screens (home, errors, performance)
│   ├── src/utils/                  # Sentry SDK wrapper + traced API client
│   └── k6/                         # Load tests (smoke, full 60k/hr, stress, spike, soak)
└── terraform/
    ├── main.tf                     # CX33 server + Cloudflare DNS + SSL + firewall
    ├── variables.tf                # All config with validation
    ├── outputs.tf                  # IP, URL, SSH command, cost estimate
    ├── cloud-init.yml              # Bootstrap (K3s, Helm, SSH, sysctl, swap, fail2ban, chrony)
    └── terraform.tfvars.example    # Variable template with server sizing table
```

# Contributing

1. Create a new branch from `main`
2. Make your changes
3. Open a PR against `main`
   - The CI workflow will automatically lint scripts, validate Terraform, run Helm template checks, and validate K8s manifests
   - Provide a description of what changed and why
4. After approval and CI passes, merge to `main`
   - The Deploy workflow automatically runs `helm upgrade` on the server

# License

MIT
