/**
 * Shared configuration for k6 load tests.
 *
 * Before running, set these environment variables:
 *   SENTRY_DSN       - Your full Sentry DSN (e.g. https://key@sentry.example.com/1)
 *   SENTRY_HOST      - Your Sentry host (e.g. https://sentry.example.com)
 *
 * Or export them:
 *   export SENTRY_DSN="https://abc123@sentry.example.com/1"
 */

// Parse DSN into components
const dsn = __ENV.SENTRY_DSN || "https://examplePublicKey@sentry.example.com/1";
const dsnMatch = dsn.match(/^(https?):\/\/([^@]+)@([^/]+)\/(.+)$/);

if (!dsnMatch) {
  throw new Error(
    `Invalid SENTRY_DSN: ${dsn}\n` +
      "Expected format: https://<key>@<host>/<project_id>"
  );
}

export const SENTRY_PROTOCOL = dsnMatch[1];
export const SENTRY_PUBLIC_KEY = dsnMatch[2];
export const SENTRY_HOST = `${dsnMatch[1]}://${dsnMatch[3]}`;
export const SENTRY_PROJECT_ID = dsnMatch[4];

// Endpoints
export const STORE_URL = `${SENTRY_HOST}/api/${SENTRY_PROJECT_ID}/store/?sentry_key=${SENTRY_PUBLIC_KEY}&sentry_version=7`;
export const ENVELOPE_URL = `${SENTRY_HOST}/api/${SENTRY_PROJECT_ID}/envelope/?sentry_key=${SENTRY_PUBLIC_KEY}&sentry_version=7`;

// Common headers
export const HEADERS = {
  "Content-Type": "application/json",
  "User-Agent": "sentry.javascript.react-native/6.5.0",
  "X-Sentry-Auth": `Sentry sentry_version=7, sentry_client=sentry.javascript.react-native/6.5.0, sentry_key=${SENTRY_PUBLIC_KEY}`,
};

export const ENVELOPE_HEADERS = {
  "Content-Type": "text/plain;charset=UTF-8",
  "User-Agent": "sentry.javascript.react-native/6.5.0",
};
