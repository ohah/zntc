import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { collectAppFiles, requireFromAppOrFallback } from './loader.ts';

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'zts-loader-'));
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
