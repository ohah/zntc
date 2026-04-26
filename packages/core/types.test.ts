/**
 * 타입 노출 / IDE 자동완성 검증.
 *
 * bun test는 컴파일 타임 타입 검사를 하지만, 이 파일의 목적은
 *   - dist/core/index.d.ts가 생성되었는지 (build:dts 산출물)
 *   - browserslist, target 같은 주요 옵션이 타입에 노출되는지
 * 을 **런타임에서** 검증하는 것.
 */

import { describe, test, expect } from 'bun:test';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const DIST = join(import.meta.dir, 'dist');

describe('@zts/core TypeScript declaration', () => {
  test('dist/core/index.d.ts가 존재해야 함 (build:dts 산출물)', () => {
    const dtsPath = join(DIST, 'core/index.d.ts');
    expect(existsSync(dtsPath)).toBe(true);
  });

  test('BuildOptions가 export되고 주요 필드 노출', () => {
    const dts = readFileSync(join(DIST, 'core/index.d.ts'), 'utf8');
    expect(dts).toContain('export type BuildOptions');
    for (const field of [
      'entryPoints',
      'target',
      'browserslist',
      'minify',
      'platform',
      'format',
      'plugins',
    ]) {
      expect(dts).toContain(field);
    }
  });

  test('TranspileOptions가 browserslist 필드 포함', () => {
    const dts = readFileSync(join(DIST, 'shared/index.d.ts'), 'utf8');
    expect(dts).toContain('browserslist');
    expect(dts).toMatch(/browserslist\?:\s*string\s*\|\s*string\[\]/);
  });

  test('transpile/build 함수 선언 export', () => {
    const dts = readFileSync(join(DIST, 'core/index.d.ts'), 'utf8');
    expect(dts).toMatch(/export declare function transpile/);
    expect(dts).toMatch(/export declare function buildSync/);
    expect(dts).toMatch(/export declare function build/);
  });

  test('ZtsPlugin 타입 + 플러그인 훅이 Promise 반환 타입 수용', () => {
    const dts = readFileSync(join(DIST, 'core/index.d.ts'), 'utf8');
    expect(dts).toContain('ZtsPlugin');
    // onLoad / onTransform 등은 async 콜백 지원해야 함 — Promise<...> 타입 포함
    expect(dts).toContain('Promise<');
  });

  test('package.json types 필드가 실제 파일을 가리킴', () => {
    const pkgPath = join(import.meta.dir, 'package.json');
    const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));
    const typesPath = join(import.meta.dir, pkg.types);
    expect(existsSync(typesPath)).toBe(true);
  });

  test('exports.types 역시 실제 파일을 가리킴', () => {
    const pkgPath = join(import.meta.dir, 'package.json');
    const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));
    const typesPath = join(import.meta.dir, pkg.exports['.'].types);
    expect(existsSync(typesPath)).toBe(true);
  });
});
