import { describe, it, expect } from "vitest";
import { screen } from "@testing-library/react";
import { renderWithProviders } from "@/test/utils";
import Index from "./pages/Index";

describe("Index page", () => {
  it("renders the app title immediately", () => {
    renderWithProviders(<Index />);
    expect(screen.getByText("Fullstack Template")).toBeInTheDocument();
  });

  it("shows loading indicator initially", () => {
    renderWithProviders(<Index />);
    expect(screen.getByText("Loading...")).toBeInTheDocument();
  });
});
