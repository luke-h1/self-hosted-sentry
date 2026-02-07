import { useEffect } from "react";
import { Stack } from "expo-router";
import { StatusBar } from "expo-status-bar";
import { initSentry, SentryWrap, setUser } from "../src/utils/sentry";

// Initialize Sentry before anything else
initSentry();

function RootLayout() {
  useEffect(() => {
    // Set a demo user context
    setUser({
      id: "demo-user-1",
      email: "demo@example.com",
      username: "demo",
    });
  }, []);

  return (
    <>
      <StatusBar style="auto" />
      <Stack
        screenOptions={{
          headerStyle: { backgroundColor: "#362D59" },
          headerTintColor: "#fff",
          headerTitleStyle: { fontWeight: "bold" },
        }}
      >
        <Stack.Screen
          name="index"
          options={{ title: "Sentry Example App" }}
        />
        <Stack.Screen
          name="errors"
          options={{ title: "Error Testing" }}
        />
        <Stack.Screen
          name="performance"
          options={{ title: "Performance Testing" }}
        />
      </Stack>
    </>
  );
}

export default SentryWrap(RootLayout);
