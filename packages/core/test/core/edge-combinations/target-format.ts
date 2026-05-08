import { afterAll, beforeAll, build, buildSync, describe, expect, test } from '../helpers';
import { createEdgeCombinationFixture, type EdgeCombinationFixture } from './fixture';

describe('엣지 케이스 + 조합 보강: target and format', () => {
  let fixture: EdgeCombinationFixture;

  beforeAll(() => {
    fixture = createEdgeCombinationFixture();
  });

  afterAll(() => fixture.cleanup());

  test('target: es5 + format: umd → arrow 변환 + UMD 래핑', async () => {
    const result = await build({
      entryPoints: [fixture.simple],
      target: 'es5',
      format: 'umd',
      globalName: 'Lib',
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).not.toContain('=>');
    expect(text).toContain('typeof define');
    expect(text).toContain('factory');
  });

  test('target: es5 + format: amd → arrow 변환 + AMD 래핑', async () => {
    const result = await build({
      entryPoints: [fixture.simple],
      target: 'es5',
      format: 'amd',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('=>');
    expect(result.outputFiles[0].text).toContain('define([]');
  });

  test('format: esm → export 구문 유지', () => {
    const result = buildSync({
      entryPoints: [fixture.multiExport],
      format: 'esm',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('export');
  });

  test('format: cjs + minify', () => {
    const result = buildSync({
      entryPoints: [fixture.simple],
      format: 'cjs',
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('"use strict"');
  });
});
