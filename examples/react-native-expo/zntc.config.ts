// ZNTC dev server + bundler config — Expo 55 / RN 0.83.

import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { withRozenite } from "@rozenite/metro";
import { withExpo } from "@zntc/react-native";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const rozenitePlugins = [
  "@rozenite/controls-plugin",
  "@rozenite/expo-atlas-plugin",
  "@rozenite/network-activity-plugin",
  "@rozenite/react-navigation-plugin",
  "@rozenite/redux-devtools-plugin",
  "@rozenite/require-profiler-plugin",
  "@rozenite/sqlite-plugin",
  "@rozenite/storage-plugin",
  "@rozenite/tanstack-query-plugin",
] as const;

const config = withExpo({
  root: __dirname,
  projectRoot: __dirname,
  entry: "index.js",
  dev: true,
  minify: false,
  outDir: join(__dirname, ".zntc"),
  resolver: {
    sourceExts: [".tsx", ".ts", ".jsx", ".js", ".mjs", ".cjs", ".json"],
    assetExts: [
      ".bmp",
      ".gif",
      ".jpg",
      ".jpeg",
      ".png",
      ".webp",
      ".avif",
      ".ico",
      ".icns",
      ".svg",
    ],
    platforms: ["ios", "android", "native"],
    preferNativePlatform: true,
    nodeModulesPaths: [join(__dirname, "node_modules"), join(__dirname, "../../node_modules")],
  },
  transformer: {
    minifier: "terser",
    inlineRequires: false,
    babel: {},
  },
  serializer: {
    polyfills: [],
    prelude: [],
    bundleType: "plain",
  },
  server: {
    port: 8081,
    host: "localhost",
    useGlobalHotkey: true,
    forwardClientLogs: true,
    verifyConnections: false,
  },
});

// Rozenite DevTools middleware (Metro-compatible).
export default withRozenite(config as any, {
  enabled: true,
  include: [...rozenitePlugins],
  projectType: "expo",
});
