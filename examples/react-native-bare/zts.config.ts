// ZTS dev server + bundler config — React Native 0.85 bare.
// `zts dev --platform=react-native` 가 본 파일을 자동 로드.

import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

export default {
  root: __dirname,
  entry: "index.js",
  dev: true,
  minify: false,
  outDir: join(__dirname, ".zts"),
  resolver: {
    sourceExts: [".tsx", ".ts", ".jsx", ".js", ".mjs", ".cjs", ".json", ".svg"],
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
      ".icxl",
    ],
    platforms: ["ios", "android", "native"],
    preferNativePlatform: true,
    nodeModulesPaths: [join(__dirname, "../../node_modules")],
  },
  transformer: {
    minifier: "terser",
    inlineRequires: false,
    babelTransformerPath: "react-native-svg-transformer/react-native",
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
};
