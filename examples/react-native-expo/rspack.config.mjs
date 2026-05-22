import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as Repack from '@callstack/repack';
import { ReanimatedPlugin } from '@callstack/repack-plugin-reanimated';
import { SwcJsMinimizerRspackPlugin } from '@rspack/core';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Monorepo root (bun workspace) — RN/Expo deps may resolve from here.
const monorepoRoot = path.resolve(__dirname, '../..');

/**
 * Re.Pack 5.2.x (Rspack) configuration for the Expo (expo-router) example —
 * mirror of the ZNTC/Metro input graph.
 *
 * Uses @callstack/repack/babel-swc-loader: it reads babel.config.js per file
 * (babel-preset-expo handles Flow, expo-router, RN codegen, and the
 * reanimated/worklets plugin), then hands plain JS to SWC for downleveling.
 *
 *  - entry `index.js` -> `import 'expo-router/entry'` (file-based routing)
 *  - `@/*` -> project root path alias (same as tsconfig paths)
 *  - `*.svg` imported as a React component (svgr, native: true)
 *  - react-native-reanimated 4 worklets via babel-preset-expo
 */
export default Repack.defineRspackConfig({
  context: __dirname,
  entry: './index.js',
  resolve: {
    ...Repack.getResolveOptions(),
    alias: {
      '@': path.resolve(__dirname),
    },
    modules: [
      path.resolve(__dirname, 'node_modules'),
      path.resolve(monorepoRoot, 'node_modules'),
      'node_modules',
    ],
  },
  module: {
    rules: [
      {
        test: /\.[cm]?[jt]sx?$/,
        type: 'javascript/auto',
        use: {
          loader: '@callstack/repack/babel-swc-loader',
          parallel: true,
          options: {},
        },
      },
      ...Repack.getAssetTransformRules({ svg: 'svgr' }),
    ],
  },
  optimization: {
    // Use the native Rspack SWC minifier instead of Re.Pack 5.2.5's default
    // (it forces terser-webpack-plugin for any Rspack != 1.4.11). This is not
    // needed to build expo, but it pins all three RN examples (bare/large/expo)
    // to the *same* minify engine so the ZNTC-vs-Re.Pack size/time numbers stay
    // comparable across examples. Mirrors react-native-large/rspack.config.mjs.
    minimizer: [
      new SwcJsMinimizerRspackPlugin({
        test: /\.(js)?bundle(\?.*)?$/i,
        extractComments: false,
        minimizerOptions: { format: { comments: false } },
      }),
    ],
  },
  plugins: [
    new Repack.RepackPlugin(),
    // Worklet transform is done by babel-preset-expo via babel-swc-loader;
    // disable the plugin's redundant babel-loader rules.
    new ReanimatedPlugin({ unstable_disableTransform: true }),
  ],
});
