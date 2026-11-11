import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    exclude: ["**/.cache/**", "**/workers/vendor/**"],
  },
});
