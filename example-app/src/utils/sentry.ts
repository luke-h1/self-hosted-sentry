import * as Sentry from "@sentry/react-native";

/**
 * Initialize Sentry SDK pointing at your self-hosted instance.
 *
 * Set EXPO_PUBLIC_SENTRY_DSN in your .env or replace the default below
 * with the DSN from your self-hosted Sentry project settings.
 */
export function initSentry() {
  const dsn =
    process.env.EXPO_PUBLIC_SENTRY_DSN ??
    "https://examplePublicKey@sentry.example.com/1";

  Sentry.init({
    dsn,

    // Performance: capture 100% of transactions in dev, 20% in production
    tracesSampleRate: __DEV__ ? 1.0 : 0.2,

    // Session replay (if available)
    replaysSessionSampleRate: 0,
    replaysOnErrorSampleRate: 1.0,

    // Only send events in non-dev builds by default
    enabled: !__DEV__,

    // Environment tag
    environment: __DEV__ ? "development" : "production",

    // Attach user IP for geo data
    sendDefaultPii: true,

    // Breadcrumb limits (keep memory low)
    maxBreadcrumbs: 50,

    beforeSend(event) {
      // Strip sensitive data if needed
      if (event.request?.cookies) {
        delete event.request.cookies;
      }
      return event;
    },
  });
}

/**
 * Wrap the root component with Sentry's error boundary and performance wrapper.
 */
export const SentryWrap = Sentry.wrap;

/**
 * Capture a manual error with optional context.
 */
export function captureError(error: Error, context?: Record<string, unknown>) {
  Sentry.captureException(error, {
    extra: context,
  });
}

/**
 * Capture a message with severity level.
 */
export function captureMessage(
  message: string,
  level: Sentry.SeverityLevel = "info"
) {
  Sentry.captureMessage(message, level);
}

/**
 * Set user context for error tracking.
 */
export function setUser(user: {
  id: string;
  email?: string;
  username?: string;
}) {
  Sentry.setUser(user);
}

/**
 * Add a breadcrumb for debugging context.
 */
export function addBreadcrumb(
  message: string,
  category: string,
  data?: Record<string, unknown>
) {
  Sentry.addBreadcrumb({
    message,
    category,
    data,
    level: "info",
  });
}

/**
 * Start a performance transaction span.
 */
export function startSpan<T>(
  name: string,
  op: string,
  callback: () => T
): T {
  return Sentry.startSpan({ name, op }, callback);
}

export { Sentry };
