/**
 * k6 Load Test: 60,000 users/hour against self-hosted Sentry
 *
 * Simulates realistic React Native app traffic:
 *   - 60% error events (what SDKs send for exceptions)
 *   - 25% transactions (performance monitoring)
 *   - 15% session envelopes (session tracking)
 *
 * Usage:
 *   # Install k6: https://k6.io/docs/get-started/installation/
 *
 *   # Quick smoke test (1 min, 10 VUs)
 *   k6 run --env SENTRY_DSN="https://key@sentry.example.com/1" example-app/k6/load-test.js
 *
 *   # Full 60k users/hour test
 *   k6 run --env SENTRY_DSN="https://key@sentry.example.com/1" \
 *          --env SCENARIO=full example-app/k6/load-test.js
 *
 *   # Stress test (2x the target)
 *   k6 run --env SENTRY_DSN="https://key@sentry.example.com/1" \
 *          --env SCENARIO=stress example-app/k6/load-test.js
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend, Counter } from "k6/metrics";
import {
  STORE_URL,
  ENVELOPE_URL,
  HEADERS,
  ENVELOPE_HEADERS,
} from "./config.js";
import {
  generateErrorEvent,
  generateTransaction,
  generateSessionEnvelope,
} from "./helpers.js";

// ── Custom metrics ─────────────────────────
const errorRate = new Rate("sentry_error_rate");
const eventDuration = new Trend("sentry_event_duration", true);
const transactionDuration = new Trend("sentry_transaction_duration", true);
const sessionDuration = new Trend("sentry_session_duration", true);
const eventsAccepted = new Counter("sentry_events_accepted");
const eventsRejected = new Counter("sentry_events_rejected");
const eventsTotal = new Counter("sentry_events_total");

// ── Scenario configuration ─────────────────
// 60,000 users/hour = 1,000 users/minute = ~17 users/second
//
// Each "user" (VU iteration) sends:
//   ~3 events on average (mix of errors, transactions, sessions)
//
// So we need ~17 VUs each doing 1 iteration/second = ~17 events/sec
// With 3 events per iteration = ~51 events/sec = ~3,000/min = ~180,000/hour
//
// That gives us ~60k unique user IDs per hour (each VU iteration = 1 user session)

const SCENARIO = __ENV.SCENARIO || "smoke";

const scenarios = {
  // Quick validation (1 min, light load)
  smoke: {
    executor: "constant-vus",
    vus: 10,
    duration: "1m",
  },

  // Full target: 60k users/hour
  // Ramp up over 2 min, sustain for 60 min, ramp down
  full: {
    executor: "ramping-vus",
    startVUs: 0,
    stages: [
      { duration: "2m", target: 17 },   // Ramp up
      { duration: "56m", target: 17 },   // Sustain 60k/hr rate
      { duration: "2m", target: 0 },     // Ramp down
    ],
    gracefulRampDown: "30s",
  },

  // Stress test: 2x target (120k users/hour)
  stress: {
    executor: "ramping-vus",
    startVUs: 0,
    stages: [
      { duration: "2m", target: 17 },    // Ramp to normal
      { duration: "5m", target: 17 },     // Hold normal
      { duration: "2m", target: 34 },     // Ramp to 2x
      { duration: "10m", target: 34 },    // Hold 2x
      { duration: "2m", target: 50 },     // Ramp to 3x
      { duration: "5m", target: 50 },     // Hold 3x (spike)
      { duration: "2m", target: 17 },     // Recovery
      { duration: "2m", target: 0 },      // Ramp down
    ],
    gracefulRampDown: "30s",
  },

  // Spike test: sudden burst
  spike: {
    executor: "ramping-vus",
    startVUs: 0,
    stages: [
      { duration: "30s", target: 5 },    // Warm up
      { duration: "10s", target: 100 },   // SPIKE
      { duration: "1m", target: 100 },    // Hold spike
      { duration: "10s", target: 5 },     // Drop
      { duration: "1m", target: 5 },      // Recovery
      { duration: "30s", target: 0 },     // Down
    ],
  },

  // Soak test: sustained moderate load for 4 hours
  soak: {
    executor: "constant-vus",
    vus: 17,
    duration: "4h",
  },
};

export const options = {
  scenarios: {
    default: scenarios[SCENARIO] || scenarios.smoke,
  },

  thresholds: {
    // 95% of events ingested under 500ms
    sentry_event_duration: ["p(95)<500"],
    // 99% of events ingested under 2s
    sentry_transaction_duration: ["p(99)<2000"],
    // Less than 5% error rate
    sentry_error_rate: ["rate<0.05"],
    // HTTP errors under 1%
    http_req_failed: ["rate<0.01"],
  },

  // Don't follow redirects (Sentry returns 200 directly)
  noConnectionReuse: false,
  userAgent: "sentry.javascript.react-native/6.5.0",
};

// ── Main test function ─────────────────────
// Each iteration simulates one user session
export default function () {
  const roll = Math.random();

  if (roll < 0.60) {
    // 60% - Send error event (via /store/ endpoint)
    sendErrorEvent();
  } else if (roll < 0.85) {
    // 25% - Send transaction (via /envelope/ endpoint)
    sendTransaction();
  } else {
    // 15% - Send session envelope
    sendSession();
  }

  // Simulate realistic user pacing (1 event per 0.5-2 seconds)
  sleep(0.5 + Math.random() * 1.5);
}

// ── Event senders ──────────────────────────

function sendErrorEvent() {
  const payload = JSON.stringify(generateErrorEvent());

  const res = http.post(STORE_URL, payload, {
    headers: HEADERS,
    tags: { event_type: "error" },
  });

  eventsTotal.add(1);

  const ok = check(res, {
    "error event accepted (200)": (r) => r.status === 200,
    "response has event_id": (r) => {
      try {
        const body = JSON.parse(r.body);
        return !!body.id;
      } catch {
        return false;
      }
    },
  });

  if (ok) {
    eventsAccepted.add(1);
  } else {
    eventsRejected.add(1);
  }

  errorRate.add(!ok);
  eventDuration.add(res.timings.duration);
}

function sendTransaction() {
  const tx = generateTransaction();

  // Transactions go via the envelope endpoint
  const header = JSON.stringify({
    event_id: tx.event_id,
    sent_at: new Date().toISOString(),
    sdk: { name: "sentry.javascript.react-native", version: "6.5.0" },
  });
  const itemHeader = JSON.stringify({
    type: "transaction",
    content_type: "application/json",
  });
  const envelope = `${header}\n${itemHeader}\n${JSON.stringify(tx)}`;

  const res = http.post(ENVELOPE_URL, envelope, {
    headers: ENVELOPE_HEADERS,
    tags: { event_type: "transaction" },
  });

  eventsTotal.add(1);

  const ok = check(res, {
    "transaction accepted (200)": (r) => r.status === 200,
  });

  if (ok) {
    eventsAccepted.add(1);
  } else {
    eventsRejected.add(1);
  }

  errorRate.add(!ok);
  transactionDuration.add(res.timings.duration);
}

function sendSession() {
  const envelope = generateSessionEnvelope();

  const res = http.post(ENVELOPE_URL, envelope, {
    headers: ENVELOPE_HEADERS,
    tags: { event_type: "session" },
  });

  eventsTotal.add(1);

  const ok = check(res, {
    "session accepted (200)": (r) => r.status === 200,
  });

  if (ok) {
    eventsAccepted.add(1);
  } else {
    eventsRejected.add(1);
  }

  errorRate.add(!ok);
  sessionDuration.add(res.timings.duration);
}

// ── Summary ────────────────────────────────
export function handleSummary(data) {
  const totalEvents = data.metrics.sentry_events_total
    ? data.metrics.sentry_events_total.values.count
    : 0;
  const accepted = data.metrics.sentry_events_accepted
    ? data.metrics.sentry_events_accepted.values.count
    : 0;
  const rejected = data.metrics.sentry_events_rejected
    ? data.metrics.sentry_events_rejected.values.count
    : 0;
  const duration = data.state.testRunDurationMs / 1000;
  const rps = totalEvents / duration;

  const summary = `
=====================================
  Sentry Load Test Summary
=====================================

  Scenario:         ${SCENARIO}
  Duration:         ${Math.round(duration)}s
  Total events:     ${totalEvents}
  Accepted:         ${accepted} (${totalEvents > 0 ? ((accepted / totalEvents) * 100).toFixed(1) : 0}%)
  Rejected:         ${rejected}
  Events/sec:       ${rps.toFixed(1)}
  Est. users/hour:  ${Math.round(rps * 3600)}

  p50 event:        ${data.metrics.sentry_event_duration ? Math.round(data.metrics.sentry_event_duration.values["p(50)"]) : "N/A"}ms
  p95 event:        ${data.metrics.sentry_event_duration ? Math.round(data.metrics.sentry_event_duration.values["p(95)"]) : "N/A"}ms
  p99 event:        ${data.metrics.sentry_event_duration ? Math.round(data.metrics.sentry_event_duration.values["p(99)"]) : "N/A"}ms

  p50 transaction:  ${data.metrics.sentry_transaction_duration ? Math.round(data.metrics.sentry_transaction_duration.values["p(50)"]) : "N/A"}ms
  p95 transaction:  ${data.metrics.sentry_transaction_duration ? Math.round(data.metrics.sentry_transaction_duration.values["p(95)"]) : "N/A"}ms

=====================================
`;

  return {
    stdout: summary,
    "k6/summary.json": JSON.stringify(data, null, 2),
  };
}
