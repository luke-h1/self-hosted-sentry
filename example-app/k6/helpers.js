/**
 * Helper functions to generate realistic Sentry event payloads
 * that mimic what the @sentry/react-native SDK sends.
 */

// Random hex string generator
export function randomHex(len) {
  const chars = "0123456789abcdef";
  let result = "";
  for (let i = 0; i < len; i++) {
    result += chars[Math.floor(Math.random() * chars.length)];
  }
  return result;
}

export function eventId() {
  return randomHex(32);
}

export function traceId() {
  return randomHex(32);
}

export function spanId() {
  return randomHex(16);
}

// Random item from array
function pick(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

// Realistic device/OS combos
const DEVICES = [
  { family: "iPhone", model: "iPhone 15 Pro", arch: "arm64" },
  { family: "iPhone", model: "iPhone 14", arch: "arm64" },
  { family: "iPhone", model: "iPhone 13 mini", arch: "arm64" },
  { family: "Samsung", model: "Galaxy S24", arch: "aarch64" },
  { family: "Samsung", model: "Galaxy A54", arch: "aarch64" },
  { family: "Google", model: "Pixel 8", arch: "aarch64" },
  { family: "Google", model: "Pixel 7a", arch: "aarch64" },
  { family: "OnePlus", model: "12", arch: "aarch64" },
];

const IOS_VERSIONS = ["17.0", "17.1", "17.2", "17.3", "17.4", "18.0", "18.1"];
const ANDROID_VERSIONS = ["13", "14", "15"];

const SCREENS = [
  "HomeScreen",
  "ErrorsScreen",
  "PerformanceScreen",
  "SettingsScreen",
  "ProfileScreen",
  "NotificationsScreen",
];

const ERROR_TYPES = [
  { type: "TypeError", value: "Cannot read properties of null (reading 'map')" },
  { type: "TypeError", value: "undefined is not a function" },
  { type: "ReferenceError", value: "'fetchData' is not defined" },
  { type: "RangeError", value: "Maximum call stack size exceeded" },
  { type: "NetworkError", value: "Network request failed" },
  { type: "SyntaxError", value: "Unexpected token '<' in JSON at position 0" },
  { type: "Error", value: "Request failed with status code 500" },
  { type: "Error", value: "Timeout of 30000ms exceeded" },
  { type: "Error", value: "User session expired" },
  { type: "Error", value: "Failed to load resource bundle" },
];

const APP_VERSIONS = ["1.0.0", "1.0.1", "1.1.0", "1.2.0"];

/**
 * Generate a realistic Sentry error event payload.
 */
export function generateErrorEvent() {
  const device = pick(DEVICES);
  const isIOS = device.family === "iPhone";
  const osVersion = isIOS ? pick(IOS_VERSIONS) : pick(ANDROID_VERSIONS);
  const error = pick(ERROR_TYPES);
  const screen = pick(SCREENS);
  const userId = `user-${Math.floor(Math.random() * 60000)}`;

  return {
    event_id: eventId(),
    timestamp: new Date().toISOString(),
    platform: "javascript",
    level: "error",
    logger: "sentry.javascript.react-native",
    server_name: `${device.model}`,
    release: `com.example.sentryapp@${pick(APP_VERSIONS)}`,
    dist: "1",
    environment: "production",
    tags: {
      "device.family": device.family,
      "device.model": device.model,
      "os.name": isIOS ? "iOS" : "Android",
      "os.version": osVersion,
      "app.screen": screen,
    },
    user: {
      id: userId,
      ip_address: "{{auto}}",
    },
    sdk: {
      name: "sentry.javascript.react-native",
      version: "6.5.0",
    },
    contexts: {
      os: {
        name: isIOS ? "iOS" : "Android",
        version: osVersion,
      },
      device: {
        family: device.family,
        model: device.model,
        arch: device.arch,
        simulator: false,
      },
      app: {
        app_name: "Sentry Example App",
        app_version: pick(APP_VERSIONS),
        app_build: "1",
      },
      trace: {
        trace_id: traceId(),
        span_id: spanId(),
        op: "navigation",
      },
    },
    exception: {
      values: [
        {
          type: error.type,
          value: error.value,
          mechanism: {
            type: "generic",
            handled: Math.random() > 0.3, // 70% handled, 30% unhandled
          },
          stacktrace: {
            frames: [
              {
                filename: "app:///node_modules/react-native/Libraries/Core/ExceptionsManager.js",
                function: "reportException",
                lineno: 95,
                colno: 32,
                in_app: false,
              },
              {
                filename: `app:///src/screens/${screen}.tsx`,
                function: "onPress",
                lineno: Math.floor(Math.random() * 200) + 10,
                colno: Math.floor(Math.random() * 40) + 1,
                in_app: true,
              },
              {
                filename: "app:///src/utils/api.ts",
                function: "fetchWithTracing",
                lineno: Math.floor(Math.random() * 50) + 10,
                colno: 15,
                in_app: true,
              },
            ],
          },
        },
      ],
    },
    breadcrumbs: {
      values: [
        {
          timestamp: new Date(Date.now() - 5000).toISOString(),
          category: "navigation",
          message: `Navigated to ${screen}`,
          level: "info",
        },
        {
          timestamp: new Date(Date.now() - 2000).toISOString(),
          category: "ui.click",
          message: "Button pressed",
          level: "info",
        },
        {
          timestamp: new Date(Date.now() - 500).toISOString(),
          category: "http",
          message: `GET /api/data`,
          level: "info",
          data: { method: "GET", status_code: 500 },
        },
      ],
    },
  };
}

/**
 * Generate a realistic Sentry transaction (performance) event.
 */
export function generateTransaction() {
  const device = pick(DEVICES);
  const isIOS = device.family === "iPhone";
  const osVersion = isIOS ? pick(IOS_VERSIONS) : pick(ANDROID_VERSIONS);
  const screen = pick(SCREENS);
  const userId = `user-${Math.floor(Math.random() * 60000)}`;
  const txTraceId = traceId();
  const txSpanId = spanId();

  // Transaction duration: 200ms - 5000ms
  const durationMs = 200 + Math.floor(Math.random() * 4800);
  const startTimestamp = Date.now() / 1000 - durationMs / 1000;
  const endTimestamp = Date.now() / 1000;

  return {
    type: "transaction",
    event_id: eventId(),
    timestamp: endTimestamp,
    start_timestamp: startTimestamp,
    platform: "javascript",
    release: `com.example.sentryapp@${pick(APP_VERSIONS)}`,
    dist: "1",
    environment: "production",
    transaction: `/${screen}`,
    transaction_info: { source: "component" },
    tags: {
      "device.family": device.family,
      "os.name": isIOS ? "iOS" : "Android",
    },
    user: {
      id: userId,
      ip_address: "{{auto}}",
    },
    sdk: {
      name: "sentry.javascript.react-native",
      version: "6.5.0",
    },
    contexts: {
      os: {
        name: isIOS ? "iOS" : "Android",
        version: osVersion,
      },
      device: {
        family: device.family,
        model: device.model,
      },
      trace: {
        trace_id: txTraceId,
        span_id: txSpanId,
        op: "navigation",
        status: "ok",
      },
    },
    spans: [
      {
        trace_id: txTraceId,
        span_id: spanId(),
        parent_span_id: txSpanId,
        op: "http.client",
        description: "GET /api/data",
        start_timestamp: startTimestamp + 0.05,
        timestamp: startTimestamp + 0.05 + (50 + Math.random() * 500) / 1000,
        status: "ok",
        data: {
          "http.method": "GET",
          "http.status_code": 200,
          url: "https://api.example.com/data",
        },
      },
      {
        trace_id: txTraceId,
        span_id: spanId(),
        parent_span_id: txSpanId,
        op: "ui.render",
        description: `Render ${screen}`,
        start_timestamp: startTimestamp + 0.1,
        timestamp: startTimestamp + 0.1 + (10 + Math.random() * 100) / 1000,
        status: "ok",
      },
      {
        trace_id: txTraceId,
        span_id: spanId(),
        parent_span_id: txSpanId,
        op: "db.query",
        description: "AsyncStorage.getItem",
        start_timestamp: startTimestamp + 0.02,
        timestamp: startTimestamp + 0.02 + (5 + Math.random() * 30) / 1000,
        status: "ok",
      },
    ],
    measurements: {
      ttid: { value: 50 + Math.random() * 500, unit: "millisecond" },
      ttfd: { value: 100 + Math.random() * 1000, unit: "millisecond" },
      app_start_cold: { value: 500 + Math.random() * 2000, unit: "millisecond" },
      frames_total: { value: Math.floor(30 + Math.random() * 90), unit: "none" },
      frames_slow: { value: Math.floor(Math.random() * 5), unit: "none" },
      frames_frozen: { value: Math.floor(Math.random() * 2), unit: "none" },
    },
  };
}

/**
 * Generate a Sentry session envelope payload.
 */
export function generateSessionEnvelope() {
  const sid = eventId();
  const userId = `user-${Math.floor(Math.random() * 60000)}`;
  const device = pick(DEVICES);
  const isIOS = device.family === "iPhone";

  const header = JSON.stringify({
    sent_at: new Date().toISOString(),
    sdk: { name: "sentry.javascript.react-native", version: "6.5.0" },
  });

  const itemHeader = JSON.stringify({ type: "session" });

  const session = JSON.stringify({
    sid,
    init: true,
    started: new Date().toISOString(),
    timestamp: new Date().toISOString(),
    status: pick(["ok", "ok", "ok", "ok", "exited", "crashed", "abnormal"]),
    errors: Math.random() > 0.8 ? 1 : 0,
    attrs: {
      release: `com.example.sentryapp@${pick(APP_VERSIONS)}`,
      environment: "production",
      user_agent: `sentry.javascript.react-native/6.5.0 (${isIOS ? "iOS" : "Android"} ${isIOS ? pick(IOS_VERSIONS) : pick(ANDROID_VERSIONS)})`,
    },
    did: userId,
  });

  return `${header}\n${itemHeader}\n${session}`;
}
