import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { resolve } from "node:path";

export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    watch: {
      ignored: ["**/src-tauri/**"],
    },
  },
  build: {
    target: ["es2021", "chrome105", "safari15"],
    rollupOptions: {
      input: {
        main: resolve(__dirname, "index.html"),
        subtitle: resolve(__dirname, "subtitle.html"),
      },
    },
  },
});
