/**
 * k6 Soak Test: 4-hour sustained load for the budget CX22 server.
 *
 * Tests whether the CX22 (4GB RAM + 8GB swap) can handle
 * continuous Sentry ingestion without degrading or running out of disk.
 *
 * Runs at ~50% of the 60k/hr target to match the budget server's capacity.
 *
 * Usage:
 *   k6 run --env SENTRY_DSN="https://key@sentry.example.com/1" \
 *          example-app/k6/soak-test.js
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

const errorRate = new Rate("sentry_error_rate");
const eventDuration = new Trend("sentry_event_duration", true);
const eventsAccepted = new Counter("sentry_events_accepted");
const eventsRejected = new Counter("sentry_events_rejected");
const eventsTotal = new Counter("sentry_events_total");

export const options = {
  scenarios: {
    soak: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "5m", target: 8 },   // Gentle ramp
        { duration: "3h50m", target: 8 }, // Sustain ~30k users/hr
        { duration: "5m", target: 0 },    // Ramp down
      ],
      gracefulRampDown: "30s",
    },
  },

  thresholds: {
    sentry_error_rate: ["rate<0.10"],       // Allow up to 10% errors on budget
    sentry_event_duration: ["p(95)<2000"],  // More lenient on CX22
    http_req_failed: ["rate<0.05"],         // Allow some failures during swap pressure
  },
};

export default function () {
  const roll = Math.random();

  if (roll < 0.60) {
    sendError();
  } else if (roll < 0.85) {
    sendTransaction();
  } else {
    sendSession();
  }

  // Slower pacing for budget server
  sleep(1 + Math.random() * 2);
}

function sendError() {
  const res = http.post(STORE_URL, JSON.stringify(generateErrorEvent()), {
    headers: HEADERS,
    tags: { event_type: "error" },
  });

  eventsTotal.add(1);
  const ok = check(res, { "error accepted": (r) => r.status === 200 });
  ok ? eventsAccepted.add(1) : eventsRejected.add(1);
  errorRate.add(!ok);
  eventDuration.add(res.timings.duration);
}

function sendTransaction() {
  const tx = generateTransaction();
  const header = JSON.stringify({
    event_id: tx.event_id,
    sent_at: new Date().toISOString(),
    sdk: { name: "sentry.javascript.react-native", version: "6.5.0" },
  });
  const itemHeader = JSON.stringify({ type: "transaction" });
  const envelope = `${header}\n${itemHeader}\n${JSON.stringify(tx)}`;

  const res = http.post(ENVELOPE_URL, envelope, {
    headers: ENVELOPE_HEADERS,
    tags: { event_type: "transaction" },
  });

  eventsTotal.add(1);
  const ok = check(res, { "transaction accepted": (r) => r.status === 200 });
  ok ? eventsAccepted.add(1) : eventsRejected.add(1);
  errorRate.add(!ok);
  eventDuration.add(res.timings.duration);
}

function sendSession() {
  const envelope = generateSessionEnvelope();

  const res = http.post(ENVELOPE_URL, envelope, {
    headers: ENVELOPE_HEADERS,
    tags: { event_type: "session" },
  });

  eventsTotal.add(1);
  const ok = check(res, { "session accepted": (r) => r.status === 200 });
  ok ? eventsAccepted.add(1) : eventsRejected.add(1);
  errorRate.add(!ok);
  eventDuration.add(res.timings.duration);
}

export function handleSummary(data) {
  const total = data.metrics.sentry_events_total?.values.count || 0;
  const accepted = data.metrics.sentry_events_accepted?.values.count || 0;
  const duration = data.state.testRunDurationMs / 1000;
  const rps = total / duration;

  return {
    stdout: `
=== Soak Test Complete ===
  Duration:     ${(duration / 3600).toFixed(1)} hours
  Total events: ${total}
  Accepted:     ${accepted} (${total > 0 ? ((accepted / total) * 100).toFixed(1) : 0}%)
  Avg rate:     ${rps.toFixed(1)} events/sec
  p95 latency:  ${data.metrics.sentry_event_duration ? Math.round(data.metrics.sentry_event_duration.values["p(95)"]) : "N/A"}ms
==========================
`,
    "k6/soak-summary.json": JSON.stringify(data, null, 2),
  };
}
