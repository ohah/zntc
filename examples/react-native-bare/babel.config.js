module.exports = {
  presets: ['module:@react-native/babel-preset'],
  plugins: [
    [
      'babel-plugin-root-import',
      {
        rootPathSuffix: './src',
        rootPathPrefix: '~/',
        functions: ['jest.mock'],
      },
    ],
    ['@babel/plugin-proposal-optional-chaining'],
    '@babel/plugin-transform-flow-strip-types',
    ['@babel/plugin-proposal-decorators', { version: 'legacy' }],
    ['@babel/plugin-transform-class-properties', { loose: true }],
    ['@babel/plugin-transform-private-methods', { loose: true }],
    ['lodash'],
    ['react-native-worklets/plugin'],
  ],
};
