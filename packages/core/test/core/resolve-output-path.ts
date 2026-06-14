import { resolve } from 'node:path';

import { describe, expect, test } from 'bun:test';

import { resolveOutputPath } from '../../index';

describe('#4334 resolveOutputPath — outfile .map 충돌 방지', () => {
  const outfileResolved = resolve('/out/app.js');

  test('메인 번들 bundle.js → outfile 경로', () => {
    expect(resolveOutputPath('bundle.js', { outfileResolved })).toBe(outfileResolved);
  });

  test('메인 map bundle.js.map → outfile.map', () => {
    expect(resolveOutputPath('bundle.js.map', { outfileResolved })).toBe(`${outfileResolved}.map`);
  });

  test('메인이 아닌 .map 은 outfile.map 으로 hijack 되지 않음(충돌 방지)', () => {
    // 과거 endsWith('.map') 는 이걸 outfile.map 으로 보내 메인 map 을 덮어썼다.
    const got = resolveOutputPath('dynamic-abc123.js.map', { outfileResolved });
    expect(got).not.toBe(`${outfileResolved}.map`);
    expect(got).toBe(resolve('dynamic-abc123.js.map'));
  });

  test('outdir 모드: 비-메인 파일은 outdir 아래 자기 경로', () => {
    const got = resolveOutputPath('dynamic-abc123.js.map', {
      outfileResolved,
      outdir: '/out',
    });
    expect(got).toBe(resolve('/out', 'dynamic-abc123.js.map'));
  });

  test('outfile 없으면 cwd 기준 해석', () => {
    expect(resolveOutputPath('chunk.js', { outfileResolved: null })).toBe(resolve('chunk.js'));
  });
});
