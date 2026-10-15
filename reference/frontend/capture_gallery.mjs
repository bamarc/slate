import { chromium } from "@playwright/test";
import fs from "node:fs";
import path from "node:path";

const OUT_DIR = path.resolve("../renders");
fs.mkdirSync(OUT_DIR, { recursive: true });

async function main() {
  console.log("🌐 Launching Chromium to capture all webapp component tabs...");
  const browser = await chromium.launch();
  const context = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    deviceScaleFactor: 1.5,
  });

  const page = await context.newPage();

  // 1. Fetch mock token from backend
  const tokenRes = await fetch("http://localhost:8000/api/v1/auth/mock-token", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      kid: "K99998",
      name: "Admin, Thomas",
      email: "admin@netz.de",
      roles: ["admin"],
    }),
  });
  const { access_token } = await tokenRes.json();

  // 2. Set token in localStorage
  await page.addInitScript(({ token }) => {
    window.localStorage.setItem("auth_token", token);
    window.localStorage.setItem(
      "user",
      JSON.stringify({
        subject: "K99998",
        name: "Admin, Thomas",
        email: "admin@netz.de",
        roles: ["admin"],
        permissions: ["User.Read", "Administration.Read"],
      })
    );
  }, { token: access_token });

  await page.goto("http://localhost:5173/showcase", { waitUntil: "networkidle" });
  await page.waitForTimeout(500);

  const tabs = [
    { label: "Buttons & Badges", file: "webapp-tab-buttons.png" },
    { label: "Forms & Inputs", file: "webapp-tab-forms.png" },
    { label: "Data Display", file: "webapp-tab-data.png" },
    { label: "Feedback", file: "webapp-tab-feedback.png" },
    { label: "Navigation", file: "webapp-tab-navigation.png" },
    { label: "Overlays", file: "webapp-tab-overlays.png" },
    { label: "Components", file: "webapp-tab-components.png" },
  ];

  for (const tab of tabs) {
    console.log(`Clicking tab "${tab.label}"...`);
    const tabBtn = page.getByRole("tab", { name: tab.label });
    if (await tabBtn.count() > 0) {
      await tabBtn.click();
      await page.waitForTimeout(400);
      const outPath = path.join(OUT_DIR, tab.file);
      await page.screenshot({ path: outPath });
      console.log(`✓ Saved ${tab.label} to ${outPath}`);
    }
  }

  await browser.close();
  console.log("🎉 All tabs captured!");
}

main().catch((err) => {
  console.error("Capture failed:", err);
  process.exit(1);
});
