import { describe, test, expect } from '../helpers';
import { loadBuildRnDevServerInput } from './helpers';

describe('buildRnDevServerInput — bundle option config 추출 (#2605)', () => {
  test('config.resolver.* → bundle.extra + nodeModulesPaths 매핑', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      {
        resolver: {
          nodeModulesPaths: ['../../node_modules'],
          blockList: [/.web.tsx?$/],
          extraNodeModules: { foo: '/x' },
          sourceExts: ['.ts'],
          assetExts: ['.png'],
        },
      },
    );
    expect(input?.nodeModulesPaths).toEqual(['../../node_modules']);
    expect(input?.bundle.extra?.blockList).toEqual([/.web.tsx?$/]);
    expect(input?.bundle.extra?.fallback).toEqual({ foo: '/x' });
    expect(input?.bundle.extra?.sourceExts).toEqual(['.ts']);
    expect(input?.bundle.extra?.assetExts).toEqual(['.png']);
  });

  test('config.watchFolders → bundle.extra.watchFolders', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { watchFolders: ['../shared', '../tokens'] },
    );
    expect(input?.bundle.extra?.watchFolders).toEqual(['../shared', '../tokens']);
  });

  test('config.alias / moduleSpecifierMap → bundle.override 매핑', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      {
        alias: { '~': '/abs/src' },
        moduleSpecifierMap: { lodash: 'lodash/{name}' },
      },
    );
    expect(input?.bundle.override?.alias).toEqual({ '~': '/abs/src' });
    expect(input?.bundle.override?.moduleSpecifierMap).toEqual({ lodash: 'lodash/{name}' });
  });

  test('config.transformer.babelTransformerPath 매핑', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { transformer: { babelTransformerPath: 'react-native-svg-transformer' } },
    );
    expect(input?.bundle.extra?.babelTransformerPath).toBe('react-native-svg-transformer');
  });

  test('config.dev=false → bundle.dev=false (CLI override 가능)', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const a = buildRnDevServerInput({ entryPoints: ['i.js'] }, { dev: false });
    expect(a?.bundle.dev).toBe(false);

    const b = buildRnDevServerInput({ entryPoints: ['i.js'], devMode: false }, { dev: true });
    expect(b?.bundle.dev).toBe(false);
  });

  test('config.minify → bundle.minify', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput({ entryPoints: ['i.js'] }, { minify: true });
    expect(input?.bundle.minify).toBe(true);
  });

  test('config.root → projectRoot (resolve 적용)', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput({ entryPoints: ['i.js'] }, { root: '/abs/path' });
    expect(input?.bundle.projectRoot).toBe('/abs/path');
  });

  test('rnPlatform=android override', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput({ entryPoints: ['i.js'], rnPlatform: 'android' }, {});
    expect(input?.bundle.rnPlatform).toBe('android');
  });

  test('config.serializer.polyfills → bundle.extra.polyfills 매핑', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { serializer: { polyfills: ['./shims/myPolyfill.js'] } },
    );
    expect(input?.bundle.extra?.polyfills).toEqual(['./shims/myPolyfill.js']);
  });

  test('config.serializer.extraVars → bundle.extra.extraVars 매핑', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { serializer: { extraVars: { __APP_VERSION__: '1.0.0', __FLAG__: true } } },
    );
    expect(input?.bundle.extra?.extraVars).toEqual({
      __APP_VERSION__: '1.0.0',
      __FLAG__: true,
    });
  });
});
