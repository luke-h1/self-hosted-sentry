import { useState, useCallback } from "react";
import {
  View,
  Text,
  Pressable,
  StyleSheet,
  ScrollView,
  FlatList,
  Alert,
  ActivityIndicator,
} from "react-native";
import { startSpan, addBreadcrumb } from "../src/utils/sentry";
import { getPosts, getUsers, createPost } from "../src/utils/api";
import type { Post, User } from "../src/utils/api";

export default function PerformanceScreen() {
  const [posts, setPosts] = useState<Post[]>([]);
  const [users, setUsers] = useState<User[]>([]);
  const [loading, setLoading] = useState(false);
  const [lastDuration, setLastDuration] = useState<number | null>(null);

  const fetchPosts = useCallback(async () => {
    setLoading(true);
    const start = Date.now();
    addBreadcrumb("Fetching posts", "api");

    try {
      const data = await getPosts();
      setPosts(data);
      const duration = Date.now() - start;
      setLastDuration(duration);
    } catch {
      Alert.alert("Error", "Failed to fetch posts");
    } finally {
      setLoading(false);
    }
  }, []);

  const fetchUsers = useCallback(async () => {
    setLoading(true);
    const start = Date.now();
    addBreadcrumb("Fetching users", "api");

    try {
      const data = await getUsers();
      setUsers(data);
      const duration = Date.now() - start;
      setLastDuration(duration);
    } catch {
      Alert.alert("Error", "Failed to fetch users");
    } finally {
      setLoading(false);
    }
  }, []);

  const runHeavyComputation = () => {
    addBreadcrumb("Running heavy computation", "benchmark");

    startSpan("Heavy Computation", "task", () => {
      const start = Date.now();

      // Simulate CPU-intensive work
      let result = 0;
      for (let i = 0; i < 1_000_000; i++) {
        result += Math.sqrt(i) * Math.sin(i);
      }

      const duration = Date.now() - start;
      setLastDuration(duration);

      Alert.alert(
        "Complete",
        `Computed in ${duration}ms (result: ${result.toFixed(2)})`
      );
    });
  };

  const runConcurrentRequests = async () => {
    setLoading(true);
    addBreadcrumb("Running concurrent API requests", "benchmark");

    const start = Date.now();

    try {
      await startSpan("Concurrent Fetch", "http.batch", async () => {
        const promises = Array.from({ length: 5 }, (_, i) =>
          createPost({
            title: `Load test post ${i + 1}`,
            body: `Generated during performance testing at ${new Date().toISOString()}`,
            userId: 1,
          })
        );
        await Promise.all(promises);
      });

      const duration = Date.now() - start;
      setLastDuration(duration);
      Alert.alert("Complete", `5 concurrent POST requests in ${duration}ms`);
    } catch {
      Alert.alert("Error", "Concurrent request test failed");
    } finally {
      setLoading(false);
    }
  };

  const renderPost = ({ item }: { item: Post }) => (
    <View style={styles.listItem}>
      <Text style={styles.listTitle} numberOfLines={1}>
        {item.title}
      </Text>
      <Text style={styles.listBody} numberOfLines={2}>
        {item.body}
      </Text>
    </View>
  );

  const renderUser = ({ item }: { item: User }) => (
    <View style={styles.listItem}>
      <Text style={styles.listTitle}>{item.name}</Text>
      <Text style={styles.listBody}>{item.email}</Text>
    </View>
  );

  return (
    <ScrollView style={styles.container}>
      {lastDuration !== null && (
        <View style={styles.metric}>
          <Text style={styles.metricLabel}>Last operation</Text>
          <Text style={styles.metricValue}>{lastDuration}ms</Text>
        </View>
      )}

      {loading && (
        <ActivityIndicator
          size="large"
          color="#6c5ce7"
          style={{ marginVertical: 16 }}
        />
      )}

      <View style={styles.section}>
        <Text style={styles.sectionTitle}>API Tracing</Text>

        <Pressable style={[styles.button, styles.blue]} onPress={fetchPosts}>
          <Text style={styles.buttonText}>Fetch Posts (GET)</Text>
          <Text style={styles.buttonSubtext}>20 posts with HTTP span tracing</Text>
        </Pressable>

        <Pressable style={[styles.button, styles.blue]} onPress={fetchUsers}>
          <Text style={styles.buttonText}>Fetch Users (GET)</Text>
          <Text style={styles.buttonSubtext}>10 users with HTTP span tracing</Text>
        </Pressable>

        <Pressable
          style={[styles.button, styles.blue]}
          onPress={runConcurrentRequests}
        >
          <Text style={styles.buttonText}>5x Concurrent POST</Text>
          <Text style={styles.buttonSubtext}>
            Batch create with parallel spans
          </Text>
        </Pressable>
      </View>

      <View style={styles.section}>
        <Text style={styles.sectionTitle}>CPU Profiling</Text>

        <Pressable
          style={[styles.button, styles.teal]}
          onPress={runHeavyComputation}
        >
          <Text style={styles.buttonText}>Heavy Computation</Text>
          <Text style={styles.buttonSubtext}>
            1M iterations with sqrt + sin (custom span)
          </Text>
        </Pressable>
      </View>

      {posts.length > 0 && (
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Posts ({posts.length})</Text>
          <FlatList
            data={posts}
            renderItem={renderPost}
            keyExtractor={(item) => item.id.toString()}
            scrollEnabled={false}
          />
        </View>
      )}

      {users.length > 0 && (
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Users ({users.length})</Text>
          <FlatList
            data={users}
            renderItem={renderUser}
            keyExtractor={(item) => item.id.toString()}
            scrollEnabled={false}
          />
        </View>
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#1a1625" },
  metric: {
    flexDirection: "row",
    justifyContent: "space-between",
    padding: 16,
    backgroundColor: "#2a2438",
  },
  metricLabel: { color: "#8c839e", fontSize: 14 },
  metricValue: { color: "#6c5ce7", fontSize: 14, fontWeight: "bold" },
  section: { padding: 20 },
  sectionTitle: {
    fontSize: 16,
    fontWeight: "600",
    color: "#fff",
    marginBottom: 12,
  },
  button: { borderRadius: 10, padding: 16, marginBottom: 10 },
  blue: { backgroundColor: "#3b6ecc" },
  teal: { backgroundColor: "#2d8a7e" },
  buttonText: {
    fontSize: 15,
    fontWeight: "600",
    color: "#fff",
    marginBottom: 2,
  },
  buttonSubtext: { fontSize: 12, color: "rgba(255,255,255,0.65)" },
  listItem: {
    backgroundColor: "#2a2438",
    borderRadius: 8,
    padding: 12,
    marginBottom: 8,
  },
  listTitle: { color: "#fff", fontSize: 14, fontWeight: "500", marginBottom: 4 },
  listBody: { color: "#8c839e", fontSize: 12, lineHeight: 16 },
});
