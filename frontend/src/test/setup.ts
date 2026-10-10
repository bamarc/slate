/// <reference types="vitest" />

import "@testing-library/jest-dom/vitest";

const originalConsoleError = console.error;

beforeAll(() => {
  console.error = (...args: unknown[]) => {
    if (
      typeof args[0] === "string" &&
      args[0].includes("ReactDOMTestUtils.act")
    ) {
      return;
    }
    originalConsoleError.call(console, ...args);
  };
});

afterAll(() => {
  console.error = originalConsoleError;
});
