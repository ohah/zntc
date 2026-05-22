const path = require('node:path');

// Absolute path to the expo-router app dir (file-based routing root).
const APP_ROOT = path.resolve(__dirname, 'app');

// expo-router's `_ctx.*.js` does `require.context(process.env.EXPO_ROUTER_APP_ROOT, ...)`.
// babel-preset-expo's expo-router plugin rewrites that member expression to a
// path *relative to the file being transformed*. With bun's isolated `.bun`
// store, expo-router's realpath sits far outside the project, so the relative
// app root (`../../../../app`) escapes the project and rspack can't resolve it.
// This plugin runs first (plugins before presets in babel) and replaces the
// env reference with the absolute app dir, which rspack's require.context can
// resolve regardless of where expo-router physically lives.
function absoluteExpoRouterAppRoot({ types: t }) {
  return {
    name: 'absolute-expo-router-app-root',
    visitor: {
      MemberExpression(p) {
        if (p.matchesPattern('process.env.EXPO_ROUTER_APP_ROOT')) {
          p.replaceWith(t.stringLiteral(APP_ROOT));
        }
      },
    },
  };
}

module.exports = function (api) {
  api.cache(true);
  return {
    // babel-preset-expo includes the RN/Expo transforms, expo-router, and the
    // react-native-worklets/reanimated plugin (auto-detected). Re.Pack's
    // babel-swc-loader reads this file per module, then hands plain JS to SWC.
    presets: ['babel-preset-expo'],
    plugins: [absoluteExpoRouterAppRoot],
  };
};
