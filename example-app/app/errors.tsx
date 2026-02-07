import { useState } from "react";
import { View, Text, Pressable, StyleSheet, ScrollView, Alert } from "react-native";
import {
  captureError,
  captureMessage,
  addBreadcrumb,
  Sentry,
} from "../src/utils/sentry";

export default function ErrorsScreen() {
  const [count, setCount] = useState(0);

  const triggerHandledError = () => {
    try {
      addBreadcrumb("User triggered handled error", "user.action");
      const obj: Record<string, unknown> = {};
      // @ts-expect-error -- intentional error for testing
      obj.nested.deep.value = "test";
    } catch (error) {
      captureError(error as Error, {
        screen: "errors",
        action: "triggerHandledError",
        count,
      });
      Alert.alert("Caught!", "Error captured and sent to Sentry.");
      setCount((c) => c + 1);
    }
  };

  const triggerUnhandledError = () => {
    addBreadcrumb("User triggered unhandled error", "user.action");
    throw new Error(`Unhandled error from example app #${count}`);
  };

  const triggerTypeError = () => {
    addBreadcrumb("User triggered type error", "user.action");
    try {
      const value: unknown = null;
      // @ts-expect-error -- intentional for testing
      value.toString();
    } catch (error) {
      captureError(error as Error, {
        screen: "errors",
        action: "triggerTypeError",
      });
      Alert.alert("TypeError!", "Null reference error sent to Sentry.");
      setCount((c) => c + 1);
    }
  };

  const triggerAsyncError = async () => {
    addBreadcrumb("User triggered async error", "user.action");
    try {
      const response = await fetch("https://httpstat.us/500");
      if (!response.ok) {
        throw new Error(`API returned ${response.status}`);
      }
    } catch (error) {
      captureError(error as Error, {
        screen: "errors",
        action: "triggerAsyncError",
        url: "https://httpstat.us/500",
      });
      Alert.alert("Network Error!", "API error captured and sent to Sentry.");
      setCount((c) => c + 1);
    }
  };

  const triggerWarning = () => {
    captureMessage(
      `Warning from example app (trigger #${count})`,
      "warning"
    );
    Alert.alert("Warning Sent!", "Warning-level message sent to Sentry.");
    setCount((c) => c + 1);
  };

  const triggerBulkErrors = () => {
    addBreadcrumb("User triggered bulk errors", "user.action");
    const errors = 10;
    for (let i = 0; i < errors; i++) {
      Sentry.captureException(
        new Error(`Bulk error ${i + 1}/${errors} - batch #${count}`),
        {
          extra: {
            batchId: count,
            errorIndex: i,
            totalInBatch: errors,
          },
        }
      );
    }
    Alert.alert("Bulk Sent!", `${errors} errors sent to Sentry.`);
    setCount((c) => c + 1);
  };

  return (
    <ScrollView style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.headerText}>
          Events sent this session: {count}
        </Text>
      </View>

      <View style={styles.section}>
        <Text style={styles.sectionTitle}>Handled Errors</Text>

        <Pressable style={[styles.button, styles.orange]} onPress={triggerHandledError}>
          <Text style={styles.buttonText}>Trigger Handled Error</Text>
          <Text style={styles.buttonSubtext}>Try-catch with captureException</Text>
        </Pressable>

        <Pressable style={[styles.button, styles.orange]} onPress={triggerTypeError}>
          <Text style={styles.buttonText}>Trigger TypeError</Text>
          <Text style={styles.buttonSubtext}>Null reference error</Text>
        </Pressable>

        <Pressable style={[styles.button, styles.orange]} onPress={triggerAsyncError}>
          <Text style={styles.buttonText}>Trigger Network Error</Text>
          <Text style={styles.buttonSubtext}>Fetch to a 500 endpoint</Text>
        </Pressable>
      </View>

      <View style={styles.section}>
        <Text style={styles.sectionTitle}>Unhandled / Crash</Text>

        <Pressable style={[styles.button, styles.red]} onPress={triggerUnhandledError}>
          <Text style={styles.buttonText}>Trigger Unhandled Error</Text>
          <Text style={styles.buttonSubtext}>
            Will crash the app (Sentry catches it)
          </Text>
        </Pressable>
      </View>

      <View style={styles.section}>
        <Text style={styles.sectionTitle}>Messages &amp; Bulk</Text>

        <Pressable style={[styles.button, styles.yellow]} onPress={triggerWarning}>
          <Text style={styles.buttonText}>Send Warning Message</Text>
          <Text style={styles.buttonSubtext}>Warning-level capture</Text>
        </Pressable>

        <Pressable style={[styles.button, styles.purple]} onPress={triggerBulkErrors}>
          <Text style={styles.buttonText}>Send 10 Errors at Once</Text>
          <Text style={styles.buttonSubtext}>Bulk ingestion test</Text>
        </Pressable>
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#1a1625" },
  header: {
    padding: 16,
    backgroundColor: "#2a2438",
    alignItems: "center",
  },
  headerText: { color: "#b4adc6", fontSize: 14 },
  section: { padding: 20 },
  sectionTitle: {
    fontSize: 16,
    fontWeight: "600",
    color: "#fff",
    marginBottom: 12,
  },
  button: {
    borderRadius: 10,
    padding: 16,
    marginBottom: 10,
  },
  orange: { backgroundColor: "#c57832" },
  red: { backgroundColor: "#c73852" },
  yellow: { backgroundColor: "#a38b29" },
  purple: { backgroundColor: "#6c5ce7" },
  buttonText: { fontSize: 15, fontWeight: "600", color: "#fff", marginBottom: 2 },
  buttonSubtext: { fontSize: 12, color: "rgba(255,255,255,0.65)" },
});
