import { useQuery } from "@tanstack/react-query";
import { customFetch, ApiError } from "@/api/fetcher";

interface HealthResponse {
  status: string;
  version: string;
}

function Index() {
  const { data, isLoading, error } = useQuery({
    queryKey: ["health"],
    queryFn: () => customFetch<HealthResponse>("/api/v1/health"),
  });

  const errorMessage =
    error instanceof ApiError
      ? `HTTP ${error.status}`
      : error instanceof Error
        ? error.message
        : null;

  return (
    <div className="min-h-[calc(100vh-8rem)] flex items-center justify-center">
      <div className="text-center space-y-4">
        <h1 className="text-4xl font-bold tracking-tight">
          Fullstack Template
        </h1>
        <p className="text-muted-foreground">React + Vite + Tailwind + FastAPI</p>

        {isLoading && (
          <p className="text-muted-foreground text-sm animate-pulse">Loading...</p>
        )}

        {errorMessage && (
          <p className="text-destructive text-sm" role="alert">
            API Error: {errorMessage}
          </p>
        )}

        {data && (
          <div className="space-y-2">
            <div className="inline-flex items-center gap-2 px-4 py-2 rounded-full bg-secondary text-sm">
              <span
                className={`w-2 h-2 rounded-full ${
                  data.status === "ok" ? "bg-green-400" : "bg-red-400"
                }`}
              />
              status: {data.status}
            </div>
            <p className="text-xs text-muted-foreground">version: {data.version}</p>
          </div>
        )}
      </div>
    </div>
  );
}

export default Index;
