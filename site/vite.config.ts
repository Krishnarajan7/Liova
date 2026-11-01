import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

/**
 * The repository's star count, read once at build time so visitors' browsers never call GitHub
 * (the site loads nothing from anyone else). It's as fresh as the last build.
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

export default defineConfig(async () => ({
  base: "/",
  define: { __GITHUB_STARS__: JSON.stringify(await githubStars()) },
  plugins: [react(), tailwindcss()],
  build: { target: "es2022", cssMinify: true },
}));
