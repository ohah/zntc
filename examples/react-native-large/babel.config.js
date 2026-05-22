module.exports = {
  presets: ['module:@react-native/babel-preset'],
  // react-native-reanimated 4 worklets. Required by both Metro and Re.Pack's
  // babel-swc-loader (the latter via ReanimatedPlugin unstable_disableTransform).
  plugins: ['react-native-worklets/plugin'],
};
