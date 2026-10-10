const baseURL =
  import.meta.env.VITE_API_BASE_URL ?? "";

type TokenProvider = () => string | null | Promise<string | null>;

let tokenProvider: TokenProvider = () =>
  import.meta.env.VITE_DEV_AUTH_TOKEN ?? null;

export function setAuthTokenProvider(provider: TokenProvider): void {
  tokenProvider = provider;
}

export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly statusText: string,
    public readonly body: unknown,
  ) {
    super(`HTTP ${status} ${statusText}`);
    this.name = "ApiError";
  }
}

export async function customFetch<T>(
  url: string,
  init: RequestInit = {},
): Promise<T> {
  const token = await tokenProvider();
  const headers = new Headers(init.headers);
  if (!headers.has("Accept")) headers.set("Accept", "application/json");
  if (init.body && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }
  if (token) headers.set("Authorization", `Bearer ${token}`);

  const response = await fetch(`${baseURL}${url}`, { ...init, headers });

  if (response.status === 403) {
    window.location.href = "/forbidden";
  }

  const contentType = response.headers.get("content-type") ?? "";
  const body: unknown = contentType.includes("application/json")
    ? await response.json().catch(() => null)
    : await response.text().catch(() => null);

  if (!response.ok) {
    throw new ApiError(response.status, response.statusText, body);
  }
  return body as T;
}

export default customFetch;
