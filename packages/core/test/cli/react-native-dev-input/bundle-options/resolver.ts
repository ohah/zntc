import { describe, expect, test } from '../../helpers';
import { loadBuildRnDevServerInput } from '../helpers';

describe('buildRnDevServerInput — resolver bundle option config 추출 (#2605)', () => {
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
});
