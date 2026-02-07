import { startSpan, addBreadcrumb, captureError } from "./sentry";

const API_BASE =
  process.env.EXPO_PUBLIC_API_URL ?? "https://jsonplaceholder.typicode.com";

interface Post {
  id: number;
  title: string;
  body: string;
  userId: number;
}

interface User {
  id: number;
  name: string;
  email: string;
  username: string;
}

/**
 * Generic fetch wrapper with Sentry tracing and error capture.
 */
async function fetchWithTracing<T>(
  endpoint: string,
  options?: RequestInit
): Promise<T> {
  return startSpan(`HTTP ${options?.method ?? "GET"} ${endpoint}`, "http.client", async () => {
    addBreadcrumb(`Fetching ${endpoint}`, "http", {
      method: options?.method ?? "GET",
      url: `${API_BASE}${endpoint}`,
    });

    const response = await fetch(`${API_BASE}${endpoint}`, {
      ...options,
      headers: {
        "Content-Type": "application/json",
        ...options?.headers,
      },
    });

    if (!response.ok) {
      const error = new Error(`HTTP ${response.status}: ${response.statusText}`);
      captureError(error, {
        endpoint,
        status: response.status,
        statusText: response.statusText,
      });
      throw error;
    }

    return response.json() as Promise<T>;
  });
}

export async function getPosts(): Promise<Post[]> {
  return fetchWithTracing<Post[]>("/posts?_limit=20");
}

export async function getPost(id: number): Promise<Post> {
  return fetchWithTracing<Post>(`/posts/${id}`);
}

export async function getUsers(): Promise<User[]> {
  return fetchWithTracing<User[]>("/users");
}

export async function createPost(post: Omit<Post, "id">): Promise<Post> {
  return fetchWithTracing<Post>("/posts", {
    method: "POST",
    body: JSON.stringify(post),
  });
}

export type { Post, User };
