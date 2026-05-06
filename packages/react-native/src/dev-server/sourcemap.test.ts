import { describe, expect, test } from 'bun:test';

import { applyMapPathOptions, postProcessSourceMap } from './sourcemap.ts';

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
  });

  test('기존 x_google_ignoreList 보존 + node_modules 추가 (sort + dedup)', () => {
    const input = JSON.stringify({
      version: 3,
      sources: ['polyfill.js', 'src/app.ts', '/node_modules/react/index.js'],
      x_google_ignoreList: [0],
    });
    const out = JSON.parse(postProcessSourceMap(input));
    expect(out.x_google_ignoreList).toEqual([0, 2]);
  });

  test('중복 인덱스 dedup', () => {
    const input = JSON.stringify({
      version: 3,
      sources: ['/node_modules/x/y.js'],
      x_google_ignoreList: [0],
    });
    const out = JSON.parse(postProcessSourceMap(input));
    expect(out.x_google_ignoreList).toEqual([0]);
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
  });

  test('zts internal source (`zts:` prefix) — DevTools ignoreList 에 추가 (#2605)', () => {
    const input = JSON.stringify({
      version: 3,
      sources: ['src/app.ts', 'zts:runtime/spread-array', 'zts:runtime/class-call-check'],
    });
    const out = JSON.parse(postProcessSourceMap(input));
    expect(out.x_google_ignoreList).toEqual([1, 2]);
  });

  test('NAPI emit 의 leading 공백 (` zts:runtime/...`) 매칭', () => {
    const input = JSON.stringify({
      version: 3,
      sources: ['src/app.ts', ' zts:runtime/extends', '\tzts:runtime/read'],
    });
    const out = JSON.parse(postProcessSourceMap(input));
    expect(out.x_google_ignoreList).toEqual([1, 2]);
  });

  test('Rolldown virtual module null byte prefix (`\\0zts:runtime/...`) 매칭', () => {
    const NUL = String.fromCharCode(0);
    const input = JSON.stringify({
      version: 3,
      sources: ['src/app.ts', `${NUL}zts:runtime/spread-array`, `${NUL}zts:runtime/extends`],
    });
    const out = JSON.parse(postProcessSourceMap(input));
    expect(out.x_google_ignoreList).toEqual([1, 2]);
  });

  test('node_modules + zts internal 혼재 — 둘 다 ignoreList', () => {
    const input = JSON.stringify({
      version: 3,
      sources: [
        'src/app.ts',
        '/node_modules/react/index.js',
        'zts:runtime/foo',
        '/node_modules/.bun/whatever/index.js',
      ],
    });
    const out = JSON.parse(postProcessSourceMap(input));
    expect(out.x_google_ignoreList).toEqual([1, 2, 3]);
  });
});

describe('postProcessSourceMap — path 옵션 통합 (#2605 audit P2)', () => {
  test('opts 없음 — ignoreList 만 (backward-compat)', () => {
    const raw = JSON.stringify({
      version: 3,
      sources: ['src/app.ts', '/node_modules/x/y.js'],
    });
    const out = JSON.parse(postProcessSourceMap(raw));
    expect(out.x_google_ignoreList).toEqual([1]);
    expect(out.sourceRoot).toBeUndefined();
  });

  test('ignoreList + sourceRoot 동시 — round-trip 1회', () => {
    const raw = JSON.stringify({
      version: 3,
      sources: ['src/app.ts', '/node_modules/x/y.js'],
    });
    const out = JSON.parse(postProcessSourceMap(raw, { sourceRoot: '/abs/proj' }));
    expect(out.x_google_ignoreList).toEqual([1]);
    expect(out.sourceRoot).toBe('/abs/proj');
  });

  test('ignoreList + useAbsolutePath — virtual module skip + framework 표시', () => {
    const NUL = String.fromCharCode(0);
    const raw = JSON.stringify({
      version: 3,
      sources: ['src/app.ts', `${NUL}zts:runtime/foo`, '/node_modules/x/y.js'],
    });
    const out = JSON.parse(
      postProcessSourceMap(raw, { useAbsolutePath: true, projectRoot: '/abs/proj' }),
    );
    expect(out.x_google_ignoreList).toEqual([1, 2]);
    expect(out.sources).toEqual([
      '/abs/proj/src/app.ts',
      `${NUL}zts:runtime/foo`,
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

describe('applyMapPathOptions — Metro sourcemap path 옵션 (#2605 audit P2)', () => {
  test('미설정 — raw 그대로 (no-op)', () => {
    const raw = JSON.stringify({ version: 3, sources: ['a.ts'] });
    expect(applyMapPathOptions(raw, {})).toBe(raw);
  });

  test('sourceRoot — Metro sourcemapSourcesRoot 설정', () => {
    const raw = JSON.stringify({ version: 3, sources: ['a.ts'] });
    const out = JSON.parse(applyMapPathOptions(raw, { sourceRoot: '/abs/proj' }));
    expect(out.sourceRoot).toBe('/abs/proj');
  });

  test('sourceRoot — 빈 string 도 valid (Metro 호환)', () => {
    const raw = JSON.stringify({ version: 3, sources: ['a.ts'] });
    const out = JSON.parse(applyMapPathOptions(raw, { sourceRoot: '' }));
    expect(out.sourceRoot).toBe('');
  });

  test('useAbsolutePath — sources 의 상대 경로를 projectRoot 기준 절대화', () => {
    const raw = JSON.stringify({
      version: 3,
      sources: ['src/app.ts', 'src/utils/foo.ts'],
    });
    const out = JSON.parse(
      applyMapPathOptions(raw, { useAbsolutePath: true, projectRoot: '/abs/proj' }),
    );
    expect(out.sources).toEqual(['/abs/proj/src/app.ts', '/abs/proj/src/utils/foo.ts']);
  });

  test('useAbsolutePath — virtual module (`zts:` / NUL prefix) 는 그대로', () => {
    const NUL = String.fromCharCode(0);
    const raw = JSON.stringify({
      version: 3,
      sources: ['src/app.ts', `${NUL}zts:runtime/foo`, 'http://cdn.example.com/lib.js'],
    });
    const out = JSON.parse(
      applyMapPathOptions(raw, { useAbsolutePath: true, projectRoot: '/abs/proj' }),
    );
    expect(out.sources[0]).toBe('/abs/proj/src/app.ts');
    expect(out.sources[1]).toBe(`${NUL}zts:runtime/foo`);
    expect(out.sources[2]).toBe('http://cdn.example.com/lib.js');
  });

  test('useAbsolutePath — 절대 경로는 idempotent', () => {
    const raw = JSON.stringify({ version: 3, sources: ['/abs/already.ts'] });
    const out = JSON.parse(
      applyMapPathOptions(raw, { useAbsolutePath: true, projectRoot: '/abs/proj' }),
    );
    expect(out.sources[0]).toBe('/abs/already.ts');
  });

  test('sourceRoot + useAbsolutePath 둘 다 적용', () => {
    const raw = JSON.stringify({ version: 3, sources: ['src/app.ts'] });
    const out = JSON.parse(
      applyMapPathOptions(raw, {
        sourceRoot: '/root',
        useAbsolutePath: true,
        projectRoot: '/abs/proj',
      }),
    );
    expect(out.sourceRoot).toBe('/root');
    expect(out.sources).toEqual(['/abs/proj/src/app.ts']);
  });

  test('invalid JSON — raw 그대로', () => {
    expect(applyMapPathOptions('not json', { sourceRoot: '/x' })).toBe('not json');
  });

  test('version != 3 — raw 그대로', () => {
    const raw = JSON.stringify({ version: 2 });
    expect(applyMapPathOptions(raw, { sourceRoot: '/x' })).toBe(raw);
  });

  test('non-string source 항목 무시 (절대화 skip)', () => {
    const raw = JSON.stringify({ version: 3, sources: ['src/a.ts', 42, null] });
    const out = JSON.parse(
      applyMapPathOptions(raw, { useAbsolutePath: true, projectRoot: '/abs/proj' }),
    );
    expect(out.sources).toEqual(['/abs/proj/src/a.ts', 42, null]);
  });
});
