import { View, Text, Pressable, StyleSheet, ScrollView } from "react-native";
import { useRouter } from "expo-router";
import { captureMessage, addBreadcrumb } from "../src/utils/sentry";

export default function HomeScreen() {
  const router = useRouter();

  return (
    <ScrollView style={styles.container}>
      <View style={styles.hero}>
        <Text style={styles.title}>Self-Hosted Sentry</Text>
        <Text style={styles.subtitle}>Example React Native App</Text>
        <Text style={styles.description}>
          This app demonstrates Sentry SDK integration with a self-hosted
          Sentry instance. Use the buttons below to generate test events.
        </Text>
      </View>

      <View style={styles.section}>
        <Text style={styles.sectionTitle}>Test Sentry Features</Text>

        <Pressable
          style={[styles.button, styles.errorButton]}
          onPress={() => {
            addBreadcrumb("Navigated to error testing", "navigation");
            router.push("/errors");
          }}
        >
          <Text style={styles.buttonText}>Error Tracking</Text>
          <Text style={styles.buttonSubtext}>
            Trigger errors, exceptions, and crashes
          </Text>
        </Pressable>

        <Pressable
          style={[styles.button, styles.perfButton]}
          onPress={() => {
            addBreadcrumb("Navigated to performance testing", "navigation");
            router.push("/performance");
          }}
        >
          <Text style={styles.buttonText}>Performance Monitoring</Text>
          <Text style={styles.buttonSubtext}>
            Test transactions, spans, and API tracing
          </Text>
        </Pressable>

        <Pressable
          style={[styles.button, styles.messageButton]}
          onPress={() => {
            captureMessage("Hello from the example app!", "info");
          }}
        >
          <Text style={styles.buttonText}>Send Test Message</Text>
          <Text style={styles.buttonSubtext}>
            Capture an info-level message to Sentry
          </Text>
        </Pressable>
      </View>

      <View style={styles.footer}>
        <Text style={styles.footerText}>
          Configure EXPO_PUBLIC_SENTRY_DSN to point at your self-hosted Sentry
        </Text>
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "#1a1625",
  },
  hero: {
    padding: 24,
    paddingTop: 32,
    alignItems: "center",
  },
  title: {
    fontSize: 28,
    fontWeight: "bold",
    color: "#fff",
    marginBottom: 4,
  },
  subtitle: {
    fontSize: 16,
    color: "#b4adc6",
    marginBottom: 16,
  },
  description: {
    fontSize: 14,
    color: "#8c839e",
    textAlign: "center",
    lineHeight: 20,
  },
  section: {
    padding: 24,
  },
  sectionTitle: {
    fontSize: 18,
    fontWeight: "600",
    color: "#fff",
    marginBottom: 16,
  },
  button: {
    borderRadius: 12,
    padding: 20,
    marginBottom: 12,
  },
  errorButton: {
    backgroundColor: "#c73852",
  },
  perfButton: {
    backgroundColor: "#3b6ecc",
  },
  messageButton: {
    backgroundColor: "#2d8a4e",
  },
  buttonText: {
    fontSize: 17,
    fontWeight: "600",
    color: "#fff",
    marginBottom: 4,
  },
  buttonSubtext: {
    fontSize: 13,
    color: "rgba(255,255,255,0.7)",
  },
  footer: {
    padding: 24,
    alignItems: "center",
  },
  footerText: {
    fontSize: 12,
    color: "#5c5470",
    textAlign: "center",
  },
});
