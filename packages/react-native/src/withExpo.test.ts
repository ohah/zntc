import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { detectExpo, WINTER_POLYFILL_WARNING_PATTERN, withExpo } from './withExpo.ts';

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'zts-rn-withexpo-'));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe('detectExpo', () => {
  test('expo dependency 감지', () => {
    writeFileSync(
      join(dir, 'package.json'),
      JSON.stringify({ dependencies: { expo: '~55.0.15' } }),
    );
    const result = detectExpo(dir);
    expect(result).toEqual({ name: 'expo', version: '~55.0.15' });
  });

  test('expo-router dependency (expo 미선언) 감지', () => {
    writeFileSync(
      join(dir, 'package.json'),
      JSON.stringify({ dependencies: { 'expo-router': '~55.0.12' } }),
    );
    const result = detectExpo(dir);
    expect(result).toEqual({ name: 'expo-router', version: '~55.0.12' });
  });

  test('devDependencies 만 있어도 감지', () => {
    writeFileSync(
      join(dir, 'package.json'),
      JSON.stringify({ devDependencies: { expo: '^55.0.0' } }),
    );
    const result = detectExpo(dir);
    expect(result).toEqual({ name: 'expo', version: '^55.0.0' });
  });

  test('Expo deps 없으면 undefined', () => {
    writeFileSync(
      join(dir, 'package.json'),
      JSON.stringify({ dependencies: { 'react-native': '0.83.4' } }),
    );
    expect(detectExpo(dir)).toBeUndefined();
  });

  test('package.json 없으면 undefined (throw 안 함)', () => {
    expect(detectExpo(dir)).toBeUndefined();
  });

  test('malformed package.json 도 undefined (throw 안 함)', () => {
    writeFileSync(join(dir, 'package.json'), '{ this is not valid json');
    expect(detectExpo(dir)).toBeUndefined();
  });
});

describe('withExpo — config 변형', () => {
  test('resolver.assetExts 에 .heic / .avif / .db 추가 (중복 제거)', () => {
    const config = withExpo({
      root: dir,
      resolver: { assetExts: ['.png', '.avif'] },
    });
    expect(config.resolver?.assetExts).toEqual(['.png', '.avif', '.heic', '.db']);
  });

  test('resolver.assetExts 미지정 시 새로 생성', () => {
    const config = withExpo({ root: dir });
    expect(config.resolver?.assetExts).toEqual(['.heic', '.avif', '.db']);
  });

  test('resolver.blockList 에 .expo/types regex 추가', () => {
    const config = withExpo({ root: dir });
    expect(config.resolver?.blockList?.length).toBe(1);
    const re = config.resolver?.blockList?.[0];
    expect(re instanceof RegExp).toBe(true);
    expect((re as RegExp).source).toBe('\\.expo[\\\\/]types');
  });

  test('기존 blockList 보존 후 append', () => {
    const userPattern = /node_modules\/foo/;
    const config = withExpo({
      root: dir,
      resolver: { blockList: [userPattern] },
    });
    expect(config.resolver?.blockList?.[0]).toBe(userPattern);
    expect(config.resolver?.blockList?.length).toBe(2);
  });

  test('server.silentConsoleErrorPatterns 에 winter polyfill warning 패턴 추가', () => {
    const config = withExpo({ root: dir });
    expect(config.server?.silentConsoleErrorPatterns).toEqual([WINTER_POLYFILL_WARNING_PATTERN]);
  });

  test('기존 silentConsoleErrorPatterns 보존 + winter pattern append', () => {
    const config = withExpo({
      root: dir,
      server: { silentConsoleErrorPatterns: ['^user pattern$'] },
    });
    expect(config.server?.silentConsoleErrorPatterns).toEqual([
      '^user pattern$',
      WINTER_POLYFILL_WARNING_PATTERN,
    ]);
  });

  test('serializer.prelude — expo/winter / metro-runtime 미설치 시 빈 배열 (resolve 실패 → skip)', () => {
    // tmp dir 에 expo 모듈 없으므로 둘 다 resolve 실패 → 사용자 prelude 만 보존.
    const config = withExpo({
      root: dir,
      serializer: { prelude: ['/abs/user-prelude.js'] },
    });
    expect(config.serializer?.prelude).toEqual(['/abs/user-prelude.js']);
  });

  test('config 의 다른 필드는 그대로 통과 (root / entry / dev / minify 등)', () => {
    const config = withExpo({
      root: dir,
      entry: 'index.js',
      dev: true,
      minify: false,
    });
    expect(config.root).toBe(dir);
    expect(config.entry).toBe('index.js');
    expect(config.dev).toBe(true);
    expect(config.minify).toBe(false);
  });

  test('root 미지정 시 process.cwd() 로 fallback', () => {
    const config = withExpo({});
    // tmp dir 안 expo 모듈 없는 cwd 도 throw 안 하고 정상 반환.
    expect(config).toBeDefined();
    expect(config.resolver?.assetExts).toEqual(['.heic', '.avif', '.db']);
  });
});

describe('withExpo — Expo 모듈 resolve (real node_modules)', () => {
  test('expo 패키지가 설치된 root 에선 winter 가 prelude 에 포함', () => {
    // node_modules/expo/src/winter/index.ts (또는 build/winter/index.js) 가 있어야 picked up.
    // tmp 안에 simulate — expo/build/winter/index.js 실파일 생성 + package.json.
    mkdirSync(join(dir, 'node_modules/expo/build/winter'), { recursive: true });
    writeFileSync(join(dir, 'node_modules/expo/package.json'), '{"name":"expo","version":"55.0.0","main":"build/index.js"}');
    writeFileSync(join(dir, 'node_modules/expo/build/winter/index.js'), '// winter');

    const config = withExpo({ root: dir });
    const prelude = config.serializer?.prelude ?? [];
    expect(prelude.some((p) => p.includes('expo/build/winter/index.js'))).toBe(true);
  });
});
