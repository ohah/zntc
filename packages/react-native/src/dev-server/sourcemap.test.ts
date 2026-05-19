import { describe, expect, test } from 'bun:test';

import { postProcessSourceMap } from './sourcemap.ts';

describe('postProcessSourceMap', () => {
  test('invalid JSON → rawJson 그대로', () => {
    expect(postProcessSourceMap('not json')).toBe('not json');
  });

  test('version != 3 → 그대로', () => {
    const v2 = JSON.stringify({ version: 2, sources: ['a.js'] });
    expect(postProcessSourceMap(v2)).toBe(v2);
  });

  test('sources 없음 → 그대로', () => {
    const noSources = JSON.stringify({ version: 3 });
    expect(postProcessSourceMap(noSources)).toBe(noSources);
  });

  test('node_modules sources → x_google_ignoreList 추가', () => {
    const input = JSON.stringify({
      version: 3,
      sources: ['src/app.ts', '/node_modules/react/index.js', 'src/util.ts'],
    });
    const out = JSON.parse(postProcessSourceMap(input));
    expect(out.x_google_ignoreList).toEqual([1]);
    expect(out.ignoreList).toBeUndefined();
  });

  test('Metro 호환 — dev-server sourcemap 에서 file 과 기본 빈 sourceRoot 제거', () => {
    const input = JSON.stringify({
      version: 3,
      file: '/tmp/zntc-rn-ios/bundle.js',
      sourceRoot: '',
      sources: ['src/app.ts', '/node_modules/react/index.js'],
    });
    const out = JSON.parse(postProcessSourceMap(input));
    expect(out.file).toBeUndefined();
    expect(out.sourceRoot).toBeUndefined();
    expect(out.x_google_ignoreList).toEqual([1]);
  });

  test('기존 ignore hint input 소비 + node_modules 추가 (sort + dedup)', () => {
    const input = JSON.stringify({
      version: 3,
      sources: ['polyfill.js', 'src/app.ts', '/node_modules/react/index.js', 'zntc:runtime/foo'],
      x_google_ignoreList: [0],
      ignoreList: [3],
    });
    const out = JSON.parse(postProcessSourceMap(input));
    expect(out.x_google_ignoreList).toEqual([0, 2, 3]);
    expect(out.ignoreList).toBeUndefined();
  });

  test('중복 인덱스 dedup', () => {
    const input = JSON.stringify({
      version: 3,
      sources: ['/node_modules/x/y.js'],
      x_google_ignoreList: [0],
    });
    const out = JSON.parse(postProcessSourceMap(input));
    expect(out.x_google_ignoreList).toEqual([0]);
    expect(out.ignoreList).toBeUndefined();
  });

  test('non-string source 항목 무시', () => {
    const input = JSON.stringify({
      version: 3,
      sources: ['src/app.ts', 42, '/node_modules/foo/index.js'],
    });
    const out = JSON.parse(postProcessSourceMap(input));
    expect(out.x_google_ignoreList).toEqual([2]);
  });

  test('ignored 항목 0 → x_google_ignoreList 추가 안 함', () => {
    const input = JSON.stringify({ version: 3, sources: ['src/app.ts'] });
    const out = JSON.parse(postProcessSourceMap(input));
    expect('x_google_ignoreList' in out).toBe(false);
    expect('ignoreList' in out).toBe(false);
  });

  test('zntc internal source (`zntc:` prefix) — x_google_ignoreList 에 추가 (#2605)', () => {
    const input = JSON.stringify({
      version: 3,
      sources: ['src/app.ts', 'zntc:runtime/spread-array', 'zntc:runtime/class-call-check'],
    });
    const out = JSON.parse(postProcessSourceMap(input));
    expect(out.x_google_ignoreList).toEqual([1, 2]);
  });

  test('NAPI emit 의 leading 공백 (` zntc:runtime/...`) 매칭', () => {
    const input = JSON.stringify({
      version: 3,
      sources: ['src/app.ts', ' zntc:runtime/extends', '\tzntc:runtime/read'],
    });
    const out = JSON.parse(postProcessSourceMap(input));
    expect(out.x_google_ignoreList).toEqual([1, 2]);
  });

  test('Rolldown virtual module null byte prefix (`\\0zntc:runtime/...`) 매칭', () => {
    const NUL = String.fromCharCode(0);
    const input = JSON.stringify({
      version: 3,
      sources: ['src/app.ts', `${NUL}zntc:runtime/spread-array`, `${NUL}zntc:runtime/extends`],
    });
    const out = JSON.parse(postProcessSourceMap(input));
    expect(out.x_google_ignoreList).toEqual([1, 2]);
  });

  test('node_modules + zntc internal 혼재 — 둘 다 x_google_ignoreList', () => {
    const input = JSON.stringify({
      version: 3,
      sources: [
        'src/app.ts',
        '/node_modules/react/index.js',
        'zntc:runtime/foo',
        '/node_modules/.bun/whatever/index.js',
      ],
    });
    const out = JSON.parse(postProcessSourceMap(input));
    expect(out.x_google_ignoreList).toEqual([1, 2, 3]);
  });

  test('Metro ignore 기준 — __prelude__ / ?ctx= / node_modules', () => {
    const input = JSON.stringify({
      version: 3,
      sources: [
        '__prelude__',
        'src/app.ts',
        '/abs/project/app?ctx=src',
        'node_modules/react/index.js',
        'src/node_modules_like/file.ts',
      ],
    });
    const out = JSON.parse(postProcessSourceMap(input));
    expect(out.x_google_ignoreList).toEqual([0, 2, 3]);
  });
});

describe('postProcessSourceMap — path 옵션 통합 (#2605 audit P2)', () => {
  test('opts 없음 — x_google_ignoreList 만 유지', () => {
    const raw = JSON.stringify({
      version: 3,
      sources: ['src/app.ts', '/node_modules/x/y.js'],
    });
    const out = JSON.parse(postProcessSourceMap(raw));
    expect(out.x_google_ignoreList).toEqual([1]);
    expect(out.sourceRoot).toBeUndefined();
  });

  test('x_google_ignoreList + sourceRoot 동시 — round-trip 1회', () => {
    const raw = JSON.stringify({
      version: 3,
      sources: ['src/app.ts', '/node_modules/x/y.js'],
    });
    const out = JSON.parse(postProcessSourceMap(raw, { sourceRoot: '/abs/proj' }));
    expect(out.x_google_ignoreList).toEqual([1]);
    expect(out.sourceRoot).toBe('/abs/proj');
  });

  test('x_google_ignoreList + useAbsolutePath — virtual module skip + framework 표시', () => {
    const NUL = String.fromCharCode(0);
    const raw = JSON.stringify({
      version: 3,
      sources: ['src/app.ts', `${NUL}zntc:runtime/foo`, '/node_modules/x/y.js'],
    });
    const out = JSON.parse(
      postProcessSourceMap(raw, { useAbsolutePath: true, projectRoot: '/abs/proj' }),
    );
    expect(out.x_google_ignoreList).toEqual([1, 2]);
    expect(out.sources).toEqual([
      '/abs/proj/src/app.ts',
      `${NUL}zntc:runtime/foo`,
      '/node_modules/x/y.js',
    ]);
  });

  test('절대 경로는 idempotent (RFC 3986 scheme + path.isAbsolute)', () => {
    const raw = JSON.stringify({
      version: 3,
      sources: [
        '/abs/already.ts',
        'http://cdn.example.com/lib.js',
        'bun:sqlite',
        'data:text/javascript;base64,Zm9v',
      ],
    });
    const out = JSON.parse(
      postProcessSourceMap(raw, { useAbsolutePath: true, projectRoot: '/abs/proj' }),
    );
    expect(out.sources).toEqual([
      '/abs/already.ts',
      'http://cdn.example.com/lib.js',
      'bun:sqlite',
      'data:text/javascript;base64,Zm9v',
    ]);
  });
});
