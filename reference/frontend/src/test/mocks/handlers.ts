import { setupServer } from "msw/node";
import { http, HttpResponse } from "msw";

/**
 * Mock API handlers for tests.
 * Add request handlers here as the API surface grows.
 */
const handlers = [
  http.get("http://localhost:8000/api/v1/health", () => {
    return HttpResponse.json({
      status: "ok",
      version: "0.1.0",
    });
  }),

  // Catch-all: pass through unhandled requests to the real server
  // (remove this if you want unhandled requests to fail tests)
];

const server = setupServer(...handlers);

export { server, http, HttpResponse };
