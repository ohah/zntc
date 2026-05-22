import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as Repack from '@callstack/repack';
import { ReanimatedPlugin } from '@callstack/repack-plugin-reanimated';
import { SwcJsMinimizerRspackPlugin } from '@rspack/core';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Monorepo root (bun workspace) — RN deps may resolve from here.
const monorepoRoot = path.resolve(__dirname, '../..');

// Re.Pack/Metro resolver ignores the `exports` field (exportsFields: []) and
// handles the `browser` mainField differently, so modern packages resolve to
// the wrong entry: fabric (exports-only) -> raw `.ts` source, uuid -> the Node
// `crypto`-based build, konva -> its Node `main` (lib/index-node.js) instead of
// the `browser` field. ZNTC honors exports + mainFields ['react-native',
// 'browser', 'main'] and picks the RN-safe build. Pin these direct deps to the
// same built entry for parity. Exact aliases (`$`) so only the bare import is
// redirected, not subpaths or transitive copies at other versions.
//
// Resolved safely: if a package (or its pinned internal file) is absent — e.g.
// a future `bun install` dedupes it out of this example's node_modules, or a
// `^` bump relocates the file — the alias is skipped with a warning instead of
// throwing at config load, which would otherwise break every rspack command.
const parityEntry = (name, sub) => {
  let dir;
  try {
    dir = fs.realpathSync(path.join(__dirname, 'node_modules', name));
  } catch {
    console.warn(`[rspack.config] exports-parity: '${name}' not under node_modules; skipping alias`);
    return null;
  }
  const file = path.join(dir, sub);
  if (!fs.existsSync(file)) {
    console.warn(`[rspack.config] exports-parity: '${name}/${sub}' missing (dep restructured?); skipping alias`);
    return null;
  }
  return file;
};

const exportsParityAlias = Object.fromEntries(
  [
    ['fabric$', parityEntry('fabric', 'dist/index.min.mjs')],
    ['uuid$', parityEntry('uuid', 'dist/esm-browser/index.js')],
    ['konva$', parityEntry('konva', 'lib/index.js')],
  ].filter(([, file]) => file !== null),
);

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
      ...exportsParityAlias,
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
    // Re.Pack 5.2.5 forces terser-webpack-plugin for any Rspack != 1.4.11
    // (getMinimizerConfig.js). On Rspack 2.0.1 that path makes Terser parse the
    // SWC output, which trips over a single stray `this.#parent` left by SWC's
    // loose private-field transform in ethers.js abi-coder. The native Rspack
    // SWC minifier parses private fields correctly, so use it instead.
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
