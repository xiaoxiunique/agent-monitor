import { resolve } from "node:path";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  publicDir: false,
  resolve: {
    alias: {
      "@": resolve(__dirname, "web"),
    },
  },
  build: {
    outDir: "public",
    emptyOutDir: false,
  },
});
