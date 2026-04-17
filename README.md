# Self-Hosted Sentry

Self-hosted [Sentry](https://sentry.io) on Hetzner Cloud with K3s, Helm, Cloudflare Tunnel, and GitHub Actions CI/CD. Tuned for a single 4 vCPU / 16GB RAM server.

## Why?

Sentry SaaS pricing adds up fast. Self-hosting gives you the full [Business plan feature set](https://develop.sentry.dev/self-hosted/) (error tracking, performance monitoring, session replay, cron monitoring) with no per-event billing. This repo automates the entire deployment: infrastructure provisioning, security hardening, backups, and CI/CD - all on a single cheap Hetzner box behind Cloudflare's free tier.

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

| Resource                                 | Cost          |
| ---------------------------------------- | ------------- |
| Hetzner CCX23 (4 vCPU, 16GB RAM, 160GB SSD) | Check current Hetzner pricing |
| Cloudflare (free plan)                   | $0            |
| **Total**                                | **Server + optional volume** |

## Architecture

```
User -> Cloudflare (DNS + Tunnel + WAF + SSL) -> cloudflared on Hetzner -> K3s Traefik -> Sentry (Helm chart)
```

The recommended host profile is a single 4 vCPU / 16GB node. `cloudflared` forwards only the Sentry hostname to local Traefik on `127.0.0.1:80`, so the VPS does not need public 80/443 exposure. **Filestore (attachments, source maps) is stored in Cloudflare R2 S3-compatible object storage**, reducing local disk dependency and keeping more local disk available for PostgreSQL, ClickHouse, and Kafka.

## Core dependencies

| Technology                                                       | Category        | Description                                            |
| ---------------------------------------------------------------- | --------------- | ------------------------------------------------------ |
| [Sentry Helm chart](https://github.com/sentry-kubernetes/charts) | Error tracking  | Community Helm chart for Sentry on Kubernetes          |
| [K3s](https://k3s.io/)                                           | Orchestration   | Lightweight Kubernetes with built-in Traefik ingress   |
| [Helm](https://helm.sh/)                                         | Package manager | Manages Sentry deployment and upgrades                 |
| [Hetzner Cloud](https://www.hetzner.com/cloud)                   | Infrastructure  | 4 vCPU / 16GB server profile                           |
| [Cloudflare](https://cloudflare.com)                             | DNS / CDN / SSL | Free plan with TLS termination                         |
| [Terraform](https://www.terraform.io/)                           | IaC             | Provisions server + DNS + SSL settings                 |
| [k6](https://k6.io/)                                             | Load testing    | 60k users/hour simulation                              |
| [GitHub Actions](https://github.com/features/actions)            | CI/CD           | Lint, deploy via Helm, health check                    |

## Tradeoffs

> [!IMPORTANT]
> The official Sentry docs recommend **4 CPU, 16GB RAM + 16GB swap, 20GB disk** as minimum. This repo is now tuned around that baseline on a single 4 core / 16GB host, with 16GB swap and optional features still disabled to preserve headroom.

- **Startup is still non-trivial**: ~3-5 min for all pods to settle after a cold deploy
- **Page loads**: Much steadier than the older 8GB profile, but background consumers can still contend during upgrades and migrations
- **Event ingestion**: Sized for a small production workload with room above the previous 8GB build
- **Disk**: plan for at least 160GB local disk if you keep all bundled stateful services on-box
- **Retention**: Default 30 days to keep disk usage low
- **Disabled features**: Profiling, spans, uptime, feedback, and symbolicator are disabled to save memory

> [!TIP]
> If you need more throughput after this profile, move the stateful services off-box first or step up to a larger Hetzner dedicated-vCPU plan before re-enabling heavier Sentry features.

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
vim terraform/terraform.tfvars # Hetzner token, Cloudflare token, R2 config, SSH IPs
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

- Hetzner server with cloud-init (K3s, Helm, cloudflared, firewall, SSH hardening, **16GB swap**)
- Hetzner firewall with SSH-only inbound by default
- Cloudflare Tunnel + proxied DNS CNAME for the Sentry hostname
- Cloudflare cache bypass rule for the Sentry hostname
- **Cloudflare R2 bucket + scoped API token** for Sentry filestore

## 3. Deploy Sentry

```bash
ssh root@<SERVER_IP>

git clone <this-repo-url> /opt/sentry/deploy
cd /opt/sentry/deploy
cp .env.example .env && vim .env


rsync -avz --exclude '.git' --exclude 'node_modules' /Users/lukehowsam/srv/dev/self-hosted-sentry/ root@<SERVER_IP>:/opt/sentry/deploy/
# Full deployment: server setup + Sentry install
make deploy
```

> [!NOTE]
> First deploy takes ~20-30 minutes. The Helm chart pulls container images and runs database migrations. Subsequent deploys (via GitHub Actions) are much faster since they only apply config changes via `helm upgrade`.

Or step by step:

```bash
make setup              # K3s, Helm, cloudflared, firewall, SSH hardening, 16GB swap, kernel tuning
make install            # Deploy Sentry via Helm chart (~15-30 min)
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
make status         # K3s node + pod status
make pods           # Detailed pod list with node/IP info
make events         # Recent K8s events (useful for debugging)
make top            # Pod resource usage (CPU/memory)
make version        # Show Helm release info
make logs           # Tail Sentry web logs
make logs-web       # Web pod only
make logs-worker    # Worker pod only
make logs-postgres  # PostgreSQL pod only
```

`make health` performs local Sentry and node checks (HTTP, pods, disk, RAM, swap, PostgreSQL, Redis). `make monitor` runs the same checks and sends a webhook alert on failure.

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
| `SENTRY_S3_BUCKET`            | -       | R2 bucket name (auto-set by Terraform)  |
| `SENTRY_S3_ENDPOINT`          | -       | R2 S3 endpoint                          |
| `SENTRY_S3_ACCESS_KEY_ID`     | -       | R2 access key (auto-set by Terraform)   |
| `SENTRY_S3_SECRET_ACCESS_KEY` | -       | R2 secret key (auto-set by Terraform)   |
| `R2_BACKUP_ENABLED`           | `true`  | Sync backups to R2                      |

## Object Storage (Cloudflare R2)

Sentry filestore (event attachments, source maps, debug symbols) is stored in **Cloudflare R2** instead of local disk. This provides:

- **Zero egress fees** (unlike AWS S3)
- **S3-compatible API** (works with existing Sentry S3 support)
- **10GB free storage** per month
- **Automatic replication** across Cloudflare's edge network

### R2 Configuration

Terraform automatically creates:
- R2 bucket (`sentry-filestore` by default)
- Endpoint + bucket wiring injected into the server via cloud-init

You still need to create an R2 S3 access key pair in Cloudflare and place it in `terraform.tfvars` if you want Sentry to use R2 for filestore. The Cloudflare provider path that creates secondary API tokens is not reliable when authenticated only with a scoped API token.

### Backup to R2

Backups can be automatically synced to a separate R2 bucket:

```bash
# Enable in .env
R2_BACKUP_ENABLED=true
R2_BACKUP_BUCKET=sentry-backups

# Run backup with R2 sync
make backup
```

### Using a different S3 provider

To use AWS S3, Hetzner Object Storage, or MinIO instead:

1. Disable R2 in `terraform.tfvars`:
   ```hcl
   enable_r2 = false
   ```

2. Set S3 credentials in `.env`:
   ```bash
   SENTRY_S3_BUCKET=your-bucket
   SENTRY_S3_REGION=us-east-1
   SENTRY_S3_ENDPOINT=https://s3.amazonaws.com
   SENTRY_S3_ACCESS_KEY_ID=your-access-key
   SENTRY_S3_SECRET_ACCESS_KEY=your-secret-key
   ```

## Cloudflare settings

Terraform configures these automatically. Verify in the Cloudflare dashboard:

| Setting             | Value                                               | Location                    |
| ------------------- | --------------------------------------------------- | --------------------------- |
| SSL/TLS mode        | **Full (Strict)**                                   | SSL/TLS > Overview          |
| Always Use HTTPS    | **On**                                              | SSL/TLS > Edge Certificates |
| Minimum TLS Version | **1.2**                                             | SSL/TLS > Edge Certificates |
| HSTS                | **On** (max-age 1 year, includeSubDomains, preload) | SSL/TLS > Edge Certificates |
| DNS record          | **Proxied** (orange cloud)                          | DNS                         |

## Scaling up

### Vertical Scaling

If you outgrow the baseline profile, resize via Hetzner Cloud Console or update `terraform.tfvars`:

```hcl
server_type = "ccx33"    # 8 vCPU, 32GB RAM, 240GB disk
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

### Multi-Node / HA Ready

This setup is designed to make multi-node Kubernetes easier:

1. **External filestore**: R2 removes local disk dependency for attachments
2. **16GB swap**: Gives the single-node install room during upgrades and migrations without leaning on swap in steady state
3. **K3s multi-node**: Ready to add worker nodes:
   ```bash
   # On existing server (control plane)
   kubectl get node-token  # Get join token
   
   # On new worker node
   curl -sfL https://get.k3s.io | K3S_URL=https://<server-ip>:6443 K3S_TOKEN=<token> sh -
   ```

For full HA, migrate PostgreSQL and Redis to managed services (Hetzner Databases, AWS RDS, etc.).

| Server | vCPU | RAM   | Disk   | EUR/mo | Good for                       |
| ------ | ---- | ----- | ------ | ------ | ------------------------------ |
| CCX23  | 4    | 16 GB | 160 GB | Check current pricing | Recommended baseline |
| CCX33  | 8    | 32 GB | 240 GB | Check current pricing | Higher sustained volume |
| CCX43  | 16   | 64 GB | 360 GB | Check current pricing | Headroom for more features |

# CI/CD (GitHub Actions)

## Workflows

| Workflow                  | Trigger                          | What it does                                                                                               |
| ------------------------- | -------------------------------- | ---------------------------------------------------------------------------------------------------------- |
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
# Trigger a manual deploy
gh workflow run deploy.yml

# Trigger a manual backup
gh workflow run backup.yml
```

# Example app + load testing

An [Expo](https://expo.dev/) React Native TypeScript app lives in `example-app/`. It integrates the `@sentry/react-native` SDK with your self-hosted instance and includes screens for testing error capture, performance tracing, and API call instrumentation.

The `example-app/k6/` directory contains [k6](https://k6.io/) load test scripts that simulate 60,000 users/hour hitting the Sentry event ingestion API with realistic React Native SDK payloads (errors with stacktraces, transactions with spans, sessions with device context).

See [`example-app/README.md`](example-app/README.md) for setup instructions and load test scenarios.

# Security

Despite the budget, all production security hardening is applied:

| Layer        | What                                                                                                 |
| ------------ | ---------------------------------------------------------------------------------------------------- |
| **Network**  | Hetzner firewall exposes SSH only by default. Sentry traffic enters through Cloudflare Tunnel.        |
| **SSL**      | Cloudflare terminates TLS. Full (Strict) mode with TLS 1.2+ only.                                    |
| **SSH**      | Key-only auth, password disabled, max 3 attempts, configurable port, no forwarding.                  |
| **Firewall** | UFW + fail2ban with SSH jail.                                                                        |
| **K8s**      | Resource limits on all pods, K3s with default pod security.                                          |
| **Sentry**   | Registration disabled, CSRF protection, secure cookies (HttpOnly, SameSite=Lax), auth rate limiting. |
| **Ingress**  | `cloudflared` terminates the tunnel locally and forwards to Traefik on loopback. Cloudflare WAF protects the edge. |
| **OS**       | Automatic security updates (unattended-upgrades), NTP sync (chrony), kernel hardening (sysctl).      |

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

The 160GB disk on the 4 core / 16GB profile provides reasonable headroom. Tips:

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

Much less common than on the old 8GB build, but still possible after upgrades or long idle periods while background consumers reclaim memory.

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

### TaskBroker pods in CrashLoopBackOff

If `sentry-taskbroker-*` pods fail with `UnknownTopicOrPartition` errors, the Kafka topics may not have been provisioned correctly:

```bash
# Check taskbroker logs for missing topic errors
kubectl -n sentry logs sentry-taskbroker-ingest-0

# List existing Kafka topics
kubectl exec sentry-kafka-controller-0 -n sentry -- kafka-topics.sh --bootstrap-server localhost:9092 --list

# Create missing taskworker topics manually
kubectl exec sentry-kafka-controller-0 -n sentry -- kafka-topics.sh --bootstrap-server localhost:9092 --create --topic taskworker-ingest --partitions 1 --replication-factor 1

# Restart the failing pod
kubectl delete pod sentry-taskbroker-ingest-0 -n sentry
```

The `k8s/sentry-values.yaml` includes the taskworker topics in the Kafka provisioning config to prevent this on fresh installs.

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
│   ├── sentry-values.yaml          # Helm values tuned for the 4 core / 16GB profile
│   ├── clickhouse.yaml             # ClickHouse StatefulSet + Service (external to Helm chart)
├── scripts/
│   ├── setup-server.sh             # Server hardening (SSH, firewall, K3s, Helm, swap, kernel)
│   ├── install-sentry.sh           # Deploy Sentry via Helm chart
│   ├── backup.sh                   # Verified PostgreSQL backup via kubectl exec
│   ├── restore.sh                  # Interactive restore from backup archive
│   └── monitor.sh                  # Health checks (pods, HTTP, Postgres, Redis) + webhook alerting
├── example-app/
│   ├── app/                        # Expo Router screens (home, errors, performance)
│   ├── src/utils/                  # Sentry SDK wrapper + traced API client
│   └── k6/                         # Load tests (smoke, full 60k/hr, stress, spike, soak)
└── terraform/
    ├── main.tf                     # Hetzner server + Cloudflare Tunnel + DNS + firewall
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
