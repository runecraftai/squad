// @ts-check
import js from "@eslint/js";
import eslintConfigPrettier from "eslint-config-prettier/flat";
import { defineConfig } from "eslint/config";
import globals from "globals";

export default defineConfig(js.configs.recommended, eslintConfigPrettier, {
  files: ["**/*.js"],
  ignores: ["dist/", "node_modules/", ".lavish-axi/", "lavish-code-review.html"],
  languageOptions: {
    ecmaVersion: "latest",
    sourceType: "module",
    globals: {
      ...globals.node,
    },
  },
  rules: {
    "no-unused-vars": ["error", { argsIgnorePattern: "^_" }],
  },
});
