import { test, expect } from "@playwright/test";

test.describe("Index page", () => {
  test("renders without console errors and shows the title", async ({ page }) => {
    const errors: string[] = [];
    page.on("console", (msg) => {
      if (msg.type() === "error") errors.push(msg.text());
    });

    await page.goto("/");
    await expect(
      page.getByRole("heading", { name: "Fullstack Template" }),
    ).toBeVisible();

    expect(errors).toEqual([]);
  });
});
