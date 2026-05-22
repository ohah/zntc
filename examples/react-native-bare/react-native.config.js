// Re.Pack 5.x: override RN CLI bundle/start commands with the Rspack pipeline.
// `react-native bundle` / `react-native start` will now go through rspack.config.mjs.
module.exports = {
  commands: require('@callstack/repack/commands/rspack'),
};
