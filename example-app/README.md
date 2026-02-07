# Sentry Example App + Load Tests

An Expo React Native TypeScript app that integrates with your self-hosted Sentry, plus k6 load tests that simulate 60,000 users/hour.

## Example App

A 3-screen Expo Router app with:
- **Home**: Navigation hub with test message button
- **Error Tracking**: Handled errors, unhandled crashes, type errors, network errors, bulk sends
- **Performance**: API tracing (GET/POST with spans), CPU profiling, concurrent request batching

### Setup

```bash
cd example-app

# Install dependencies
npm install

# Configure your Sentry DSN
cp .env.example .env
# Edit .env with the DSN from your self-hosted Sentry project

# Run
npx expo start
```

### Get Your DSN

1. Open your self-hosted Sentry at `https://sentry.yourdomain.com`
2. Create a project (React Native)
3. Go to **Project Settings** > **Client Keys (DSN)**
4. Copy the DSN into `.env`

## k6 Load Tests

### Install k6

```bash
# macOS
brew install k6

# Linux
sudo gpg -k
sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
  --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update && sudo apt-get install k6

# Docker
docker run --rm -i grafana/k6 run - <example-app/k6/load-test.js
```

### Run Tests

All tests require your Sentry DSN:

```bash
export SENTRY_DSN="https://your-public-key@sentry.yourdomain.com/1"
```

#### Smoke Test (1 min, quick validation)

```bash
k6 run --env SENTRY_DSN="$SENTRY_DSN" example-app/k6/load-test.js
```

#### Full Load Test (60k users/hour, 1 hour)

```bash
k6 run --env SENTRY_DSN="$SENTRY_DSN" \
       --env SCENARIO=full \
       example-app/k6/load-test.js
```

#### Stress Test (ramps to 3x target)

```bash
k6 run --env SENTRY_DSN="$SENTRY_DSN" \
       --env SCENARIO=stress \
       example-app/k6/load-test.js
```

#### Spike Test (sudden burst to 100 VUs)

```bash
k6 run --env SENTRY_DSN="$SENTRY_DSN" \
       --env SCENARIO=spike \
       example-app/k6/load-test.js
```

#### Soak Test (4 hours sustained, budget-tuned)

```bash
k6 run --env SENTRY_DSN="$SENTRY_DSN" \
       example-app/k6/soak-test.js
```

### What the Tests Send

The k6 tests generate realistic Sentry SDK payloads that match what `@sentry/react-native` sends:

| Event Type | Endpoint | Weight | Content |
|------------|----------|--------|---------|
| Errors | `/api/PROJECT/store/` | 60% | Exception with stacktrace, breadcrumbs, device context |
| Transactions | `/api/PROJECT/envelope/` | 25% | Performance spans (HTTP, UI render, DB), measurements |
| Sessions | `/api/PROJECT/envelope/` | 15% | Session start/end with device info |

Each event includes:
- Randomized device context (iPhone/Samsung/Pixel models)
- Realistic OS versions (iOS 17-18, Android 13-15)
- 60,000 unique user IDs per hour
- App version distribution across 4 releases
- Proper stacktraces with in-app / library frames

### Thresholds

| Metric | Target | Description |
|--------|--------|-------------|
| `p95 < 500ms` | Event ingestion latency | 95th percentile under 500ms |
| `p99 < 2000ms` | Transaction ingestion | 99th percentile under 2s |
| `error_rate < 5%` | Acceptance rate | Less than 5% rejected events |
| `http_req_failed < 1%` | HTTP success | Less than 1% HTTP failures |

### Understanding the Results

```
=====================================
  Sentry Load Test Summary
=====================================

  Scenario:         full
  Duration:         3600s
  Total events:     61,234
  Accepted:         60,891 (99.4%)
  Rejected:         343
  Events/sec:       17.0
  Est. users/hour:  61,200

  p50 event:        45ms
  p95 event:        210ms
  p99 event:        890ms
=====================================
```

- **Events/sec ~17**: Matches the 60k/hr target (17 * 3600 = 61,200)
- **Accepted > 95%**: Sentry is keeping up with ingestion
- **p95 < 500ms**: Events are being processed quickly
- If p95 spikes above 2s or error_rate exceeds 5%, the server is overloaded

### Budget Server (CX22) Expectations

On the CX22 (4GB RAM), expect:
- Smoke test: passes easily
- Full 60k/hr: may see elevated p95 (1-3s) and some rejected events
- Stress test: will likely hit limits, expect ~10-20% rejection at 3x load
- Soak test: runs at 50% load (30k/hr) which the CX22 can sustain

For reliable 60k/hr throughput, upgrade to CX32 (8GB RAM, ~EUR 7.49/mo).

## File Structure

```
example-app/
├── app/
│   ├── _layout.tsx       # Root layout with Sentry init
│   ├── index.tsx          # Home screen
│   ├── errors.tsx         # Error testing screen
│   └── performance.tsx    # Performance testing screen
├── src/
│   └── utils/
│       ├── sentry.ts      # Sentry SDK wrapper
│       └── api.ts         # API client with tracing
├── k6/
│   ├── config.js          # DSN parsing + endpoints
│   ├── helpers.js         # Payload generators (errors, transactions, sessions)
│   ├── load-test.js       # Main load test (smoke/full/stress/spike scenarios)
│   └── soak-test.js       # 4-hour sustained load test
├── .env.example
├── app.json
├── package.json
├── tsconfig.json
└── README.md
```
