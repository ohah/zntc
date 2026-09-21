import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { collectAppFiles, isSkippedDirName, requireFromAppOrFallback } from './loader.ts';

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'zntc-loader-'));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe('requireFromAppOrFallback', () => {
  test('app require 성공 시 그 결과', () => {
    const appRequire = mock((s: string) => `app:${s}`);
    const fallback = mock((s: string) => `fallback:${s}`);
    expect(requireFromAppOrFallback(appRequire, fallback, 'x')).toBe('app:x');
    expect(appRequire).toHaveBeenCalledTimes(1);
    expect(fallback).toHaveBeenCalledTimes(0);
  });

  test('app 의 MODULE_NOT_FOUND 시 fallback', () => {
    const appRequire = mock((_s: string) => {
      const err = new Error('missing') as NodeJS.ErrnoException;
      err.code = 'MODULE_NOT_FOUND';
      throw err;
    });
    const fallback = mock((s: string) => `fallback:${s}`);
    expect(requireFromAppOrFallback(appRequire, fallback, 'x')).toBe('fallback:x');
    expect(fallback).toHaveBeenCalledTimes(1);
  });

  test('ERR_MODULE_NOT_FOUND (ESM) 도 fallback', () => {
    const appRequire = mock((_s: string) => {
      const err = new Error('esm missing') as NodeJS.ErrnoException;
      err.code = 'ERR_MODULE_NOT_FOUND';
      throw err;
    });
    const fallback = mock(() => 'fb');
    expect(requireFromAppOrFallback(appRequire, fallback, 'x')).toBe('fb');
  });

  test('그 외 에러는 propagate (fallback 호출 안 함)', () => {
    const appRequire = mock((_s: string) => {
      throw new TypeError('syntax error in app require');
    });
    const fallback = mock(() => 'fb');
    expect(() => requireFromAppOrFallback(appRequire, fallback, 'x')).toThrow(TypeError);
    expect(fallback).toHaveBeenCalledTimes(0);
  });

  test('err.code undefined 도 propagate (silent fallback 회피)', () => {
    const appRequire = mock((_s: string) => {
      throw new Error('plain error');
    });
    const fallback = mock(() => 'fb');
    expect(() => requireFromAppOrFallback(appRequire, fallback, 'x')).toThrow();
    expect(fallback).toHaveBeenCalledTimes(0);
  });
});

describe('collectAppFiles', () => {
  function touch(rel: string, content = ''): string {
    const path = join(dir, rel);
    mkdirSync(join(path, '..'), { recursive: true });
    writeFileSync(path, content);
    return path;
  }

  test('존재하지 않는 디렉토리는 빈 배열', () => {
    expect(collectAppFiles(join(dir, 'nope'))).toEqual([]);
  });

  test('재귀 walk + 모든 파일 수집 (default predicate)', () => {
    touch('a.txt');
    touch('sub/b.txt');
    touch('sub/deep/c.txt');
    const files = collectAppFiles(dir);
    expect(files.sort()).toEqual(
      [join(dir, 'a.txt'), join(dir, 'sub/b.txt'), join(dir, 'sub/deep/c.txt')].sort(),
    );
  });

  test('node_modules 와 .git 은 자동 skip', () => {
    touch('a.ts');
    touch('node_modules/dep/index.js');
    touch('.git/HEAD');
    const files = collectAppFiles(dir);
    expect(files).toEqual([join(dir, 'a.ts')]);
  });

  test('predicate 가 false 인 파일은 제외', () => {
    touch('a.ts');
    touch('b.css');
    touch('sub/c.ts');
    const files = collectAppFiles(dir, {
      predicate: (p) => p.endsWith('.ts'),
    }).sort();
    expect(files).toEqual([join(dir, 'a.ts'), join(dir, 'sub/c.ts')].sort());
  });

  test('#4674 skipDirs — 여러 디렉토리를 한 번에 제외한다', () => {
    mkdirSync(join(dir, 'dist'), { recursive: true });
    mkdirSync(join(dir, '.zntc-dev'), { recursive: true });
    writeFileSync(join(dir, 'a.module.css'), '.a{}');
    writeFileSync(join(dir, 'dist', 'b.module.css'), '.b{}');
    writeFileSync(join(dir, '.zntc-dev', 'c.module.css'), '.c{}');

    const files = collectAppFiles(dir, {
      skipDirs: [join(dir, 'dist'), join(dir, '.zntc-dev')],
      predicate: (p) => p.endsWith('.module.css'),
    });
    expect(files.map((f) => f.replace(dir + '/', ''))).toEqual(['a.module.css']);
  });

  test('skipDir 이 일치하는 sub-tree 는 walk 안 함', () => {
    touch('a.ts');
    touch('dist/out.js');
    touch('dist/inner/x.js');
    const files = collectAppFiles(dir, { skipDir: join(dir, 'dist') });
    expect(files).toEqual([join(dir, 'a.ts')]);
  });

  test('ENOTDIR 같은 IO 에러는 propagate (silent swallow X)', () => {
    touch('not-a-dir.txt');
    expect(() => collectAppFiles(join(dir, 'not-a-dir.txt'))).toThrow();
  });

  test('빈 디렉토리는 빈 배열', () => {
    expect(collectAppFiles(dir)).toEqual([]);
  });
});

describe('isSkippedDirName / 깊이 무관 skip (#4678)', () => {
  /**
   * #4678 — `zntc dev` 의 산출 디렉토리에는 서빙용으로 **소스 CSS 가 그대로 미러**돼
   * 있다. 루트의 `.zntc-dev` 만 제외하면 하위 앱이 dev 를 돌린 `sub/.zntc-dev` 가
   * 새어 들어와 같은 CSS Module 을 두 번 처리한다(실측 +38%).
   */
  test('중첩된 .zntc-dev 안의 파일은 수집되지 않는다', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-skipdir-'));
    try {
      mkdirSync(join(dir, 'src'), { recursive: true });
      mkdirSync(join(dir, 'sub', '.zntc-dev', 'src'), { recursive: true });
      writeFileSync(join(dir, 'src', 'a.module.css'), '.a{color:red}');
      writeFileSync(join(dir, 'sub', '.zntc-dev', 'src', 'mirrored.module.css'), '.m{color:blue}');

      const found = collectAppFiles(dir, { predicate: (p) => p.endsWith('.module.css') });
      expect(found.some((p) => p.endsWith('a.module.css'))).toBe(true);
      // 산출물 미러본은 소스가 아니다.
      expect(found.some((p) => p.includes('mirrored'))).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('이름 규칙은 복사·탐색이 공유한다', () => {
    expect(isSkippedDirName('node_modules')).toBe(true);
    expect(isSkippedDirName('.git')).toBe(true);
    expect(isSkippedDirName('.zntc-dev')).toBe(true);
    // ⚠️ `--outdir` 로 이름을 바꾼 dev 산출물은 못 막는다 — 알려진 한계(#4678).
    expect(isSkippedDirName('.mydev')).toBe(false);
    expect(isSkippedDirName('src')).toBe(false);
  });
});
