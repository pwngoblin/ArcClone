import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";

// Served by core through the arc-ui:// scheme, so all asset URLs must be relative.
export default defineConfig({
  base: "./",
  plugins: [svelte()],
  build: {
    outDir: "dist",
    emptyOutDir: true,
    target: "safari17",
    sourcemap: true,
    modulePreload: { polyfill: false },
  },
  server: { port: 5199, strictPort: true },
});
