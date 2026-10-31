import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

/**
 * The repository's star count, read once at build time so visitors' browsers never call GitHub
 * (the site loads nothing from anyone else). The Website workflow rebuilds daily to refresh it.
 */
async function githubStars(): Promise<number | null> {
  try {
    const token = process.env.GITHUB_TOKEN;
    const response = await fetch("https://api.github.com/repos/Krishnarajan7/Liova", {
      headers: token ? { Authorization: `Bearer ${token}` } : {},
      signal: AbortSignal.timeout(5000),
    });
    if (!response.ok) return null;
    const { stargazers_count } = (await response.json()) as { stargazers_count?: number };
    return typeof stargazers_count === "number" ? stargazers_count : null;
  } catch {
    return null;
  }
}

// GitHub Pages serves the site under /Liova/; a custom domain would use "/".
export default defineConfig(async () => ({
  base: process.env.SITE_BASE ?? "/",
  define: { __GITHUB_STARS__: JSON.stringify(await githubStars()) },
  plugins: [react(), tailwindcss()],
  build: { target: "es2022", cssMinify: true },
}));
