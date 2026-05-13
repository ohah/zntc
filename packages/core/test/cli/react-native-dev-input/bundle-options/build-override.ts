import { describe, expect, test } from '../../helpers';
import { loadBuildRnBundleOverride } from '../helpers';

describe('buildRnBundleOverride — options object 시그니처', () => {
  test('빈 인자 — undefined 반환', async () => {
    const buildRnBundleOverride = await loadBuildRnBundleOverride();
    expect(buildRnBundleOverride()).toBeUndefined();
    expect(buildRnBundleOverride({})).toBeUndefined();
    expect(buildRnBundleOverride({ config: {} })).toBeUndefined();
  });

  test('config.alias → out.alias', async () => {
    const buildRnBundleOverride = await loadBuildRnBundleOverride();
    const out = buildRnBundleOverride({
      config: { alias: { '~': '/abs/src' } },
    });
    expect(out?.alias).toEqual({ '~': '/abs/src' });
  });

  test('config.moduleSpecifierMap → out.moduleSpecifierMap', async () => {
    const buildRnBundleOverride = await loadBuildRnBundleOverride();
    const out = buildRnBundleOverride({
      config: { moduleSpecifierMap: { lodash: 'lodash/{name}' } },
    });
    expect(out?.moduleSpecifierMap).toEqual({ lodash: 'lodash/{name}' });
  });

  test('opts.experimentalDecorators → out.experimentalDecorators', async () => {
    const buildRnBundleOverride = await loadBuildRnBundleOverride();
    const out = buildRnBundleOverride({
      config: {},
      opts: { experimentalDecorators: true },
    });
    expect(out?.experimentalDecorators).toBe(true);
  });

  test('config.experimentalDecorators (opts 미지정) → out.experimentalDecorators', async () => {
    const buildRnBundleOverride = await loadBuildRnBundleOverride();
    const out = buildRnBundleOverride({
      config: { experimentalDecorators: true },
    });
    expect(out?.experimentalDecorators).toBe(true);
  });

  test('CLI opts 우선 — opts.useDefineForClassFields=false 가 config.true 덮음', async () => {
    const buildRnBundleOverride = await loadBuildRnBundleOverride();
    const out = buildRnBundleOverride({
      config: { useDefineForClassFields: true },
      opts: { useDefineForClassFields: false },
    });
    expect(out?.useDefineForClassFields).toBe(false);
  });

  test('override 인자 — 가장 마지막 Object.assign 으로 덮어쓰기', async () => {
    const buildRnBundleOverride = await loadBuildRnBundleOverride();
    const out = buildRnBundleOverride({
      config: { experimentalDecorators: true },
      override: { outfile: '/out/bundle.js', write: true },
    });
    expect(out?.experimentalDecorators).toBe(true);
    expect(out?.outfile).toBe('/out/bundle.js');
    expect(out?.write).toBe(true);
  });

  test('override 가 config 의 값을 덮음', async () => {
    const buildRnBundleOverride = await loadBuildRnBundleOverride();
    const out = buildRnBundleOverride({
      config: { alias: { '~': '/abs/src' } },
      override: { alias: { '~': '/override/src' } },
    });
    expect(out?.alias).toEqual({ '~': '/override/src' });
  });
});
