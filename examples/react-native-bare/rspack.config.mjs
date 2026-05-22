import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as Repack from '@callstack/repack';
import { ReanimatedPlugin } from '@callstack/repack-plugin-reanimated';
import { SwcJsMinimizerRspackPlugin } from '@rspack/core';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Monorepo root (bun workspace) — RN deps may resolve from here.
const monorepoRoot = path.resolve(__dirname, '../..');

/**
 * Re.Pack 5.2.x (Rspack) configuration — mirror of the ZNTC/Metro input graph.
 *
 * Uses @callstack/repack/babel-swc-loader (the recommended RN >=0.80 path): it
 * reads babel.config.js per file (so @react-native/babel-preset handles Flow
 * `component`/`enum` via hermes-parser, RN codegen, and the reanimated worklets
 * plugin), then hands plain JS to SWC for downleveling. This replaces
 * getJsTransformRules() + flow-loader, which cannot parse RN 0.85's new Flow
 * `component`/`enum` syntax.
 *
 *  - `~/*`  -> src/*  path alias (same as tsconfig paths / zntc.config alias)
 *  - `*.svg` imported as a React component (svgr, native: true)
 *  - react-native-reanimated 4 worklets via babel.config.js plugin
 */
export default Repack.defineRspackConfig({
  context: __dirname,
  entry: './index.js',
  resolve: {
    ...Repack.getResolveOptions(),
    alias: {
      '~': path.resolve(__dirname, 'src'),
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
      // svg: 'svgr' -> @svgr/webpack (native: true); also keeps svg out of the
      // asset/source loader so `import Icon from '~/assets/check.svg'` is a component.
      ...Repack.getAssetTransformRules({ svg: 'svgr' }),
    ],
  },
  optimization: {
    // Use the native Rspack SWC minifier instead of Re.Pack 5.2.5's default
    // (it forces terser-webpack-plugin for any Rspack != 1.4.11). This is not
    // needed to build bare, but it pins all three RN examples (bare/large/expo)
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
    // Worklet transform is done by the babel plugin (babel.config.js) via
    // babel-swc-loader; disable the plugin's redundant babel-loader rules.
    new ReanimatedPlugin({ unstable_disableTransform: true }),
  ],
});
