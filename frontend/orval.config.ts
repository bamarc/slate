import { defineConfig } from "orval";

export default defineConfig({
  api: {
    input: "../api/openapi.yaml",
    output: {
      target: "./src/api/generated/endpoints.ts",
      schemas: "./src/api/generated/schemas",
      client: "react-query",
      httpClient: "fetch",
      mock: false,
      override: {
        mutator: {
          path: "./src/api/fetcher.ts",
          name: "customFetch",
        },
      },
    },
  },
});
