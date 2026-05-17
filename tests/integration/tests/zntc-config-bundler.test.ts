/**
 * #2105 — Zig CLI (`zntc-bin`) 의 `applyZntcConfigJson` 이 bundler-only 옵션을
 * `zntc.config.json` 에서 읽어들여 BundleOptions 까지 forward 하는지 검증한다.
 *
 * JS CLI (`zntc.mjs`) 의 동일 동작은 `packages/core/bin/zntc.test.ts` 가 검증.
 */

import { afterEach, describe, expect, test } from 'bun:test';
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

import { createFixture, runZntcInDir, runConfigBundle } from './helpers';

describe('Zig CLI: zntc.config.json bundler-only 옵션 (#2105)', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test('external: bare specifier 가 require/import 로 보존됨', async () => {
    const r = await runConfigBundle({
      files: {
        'index.ts': `import * as fs from "node:fs";\nconsole.log(fs);`,
        'zntc.config.json': JSON.stringify({ external: ['node:fs'] }),
      },
      args: ['--format=esm'],
    });
    cleanup = r.cleanup;

    expect(r.exitCode).toBe(0);
    // external 이면 import 가 보존됨 (인라인 안 됨).
    expect(readFileSync(r.outFile!, 'utf8')).toMatch(/from\s+["']node:fs["']/);
  });

  test('alias: from→to 매핑이 적용됨', async () => {
    const fixture = await createFixture({
      'src/real.ts': `export const tag = "ALIAS_OK";`,
      'index.ts': `import { tag } from "@target";\nconsole.log(tag);`,
      'zntc.config.json': '', // 동적 생성 (절대 경로 필요)
    });
    cleanup = fixture.cleanup;
    writeFileSync(
      join(fixture.dir, 'zntc.config.json'),
      JSON.stringify({ alias: [{ from: '@target', to: join(fixture.dir, 'src/real.ts') }] }),
    );

    const outFile = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, [
      '--bundle',
      join(fixture.dir, 'index.ts'),
      '-o',
      outFile,
    ]);
    expect(result.exitCode).toBe(0);
    expect(readFileSync(outFile, 'utf8')).toContain('ALIAS_OK');
  });

  test('define: 키-값 쌍 → 정적 치환', async () => {
    const r = await runConfigBundle({
      files: {
        'index.ts': `console.log(__VER__);`,
        'zntc.config.json': JSON.stringify({
          define: [{ key: '__VER__', value: '"v1.0.0"' }],
        }),
      },
    });
    cleanup = r.cleanup;

    expect(r.exitCode).toBe(0);
    const out = readFileSync(r.outFile!, 'utf8');
    expect(out).toContain('"v1.0.0"');
    expect(out).not.toContain('__VER__');
  });

  test('banner / footer 가 출력에 포함됨', async () => {
    const r = await runConfigBundle({
      files: {
        'index.ts': "console.log('mid');",
        'zntc.config.json': JSON.stringify({
          banner: '/* banner-line */',
          footer: '/* footer-line */',
        }),
      },
    });
    cleanup = r.cleanup;

    expect(r.exitCode).toBe(0);
    const out = readFileSync(r.outFile!, 'utf8');
    expect(out.indexOf('banner-line')).toBeGreaterThanOrEqual(0);
    expect(out.indexOf('footer-line')).toBeGreaterThanOrEqual(0);
    expect(out.indexOf('banner-line')).toBeLessThan(out.indexOf('mid'));
    expect(out.indexOf('footer-line')).toBeGreaterThan(out.indexOf('mid'));
  });

  test('conditions: package.json exports 분기에 사용', async () => {
    const r = await runConfigBundle({
      files: {
        'node_modules/lib/package.json': JSON.stringify({
          name: 'lib',
          exports: {
            '.': {
              'test-cond': './test.js',
              default: './default.js',
            },
          },
        }),
        'node_modules/lib/test.js': `export const tag = "CONDITION_OK";`,
        'node_modules/lib/default.js': `export const tag = "DEFAULT_FALLBACK";`,
        'index.ts': `import { tag } from "lib";\nconsole.log(tag);`,
        'zntc.config.json': JSON.stringify({ conditions: ['test-cond'] }),
      },
    });
    cleanup = r.cleanup;

    expect(r.exitCode).toBe(0);
    const out = readFileSync(r.outFile!, 'utf8');
    expect(out).toContain('CONDITION_OK');
    expect(out).not.toContain('DEFAULT_FALLBACK');
  });

  test('resolveExtensions: 명시 확장자 우선순위로 resolve', async () => {
    const fixture = await createFixture({
      'src/util.web.ts': `export const tag = "WEB_VARIANT";`,
      'src/util.ts': `export const tag = "DEFAULT_VARIANT";`,
      'index.ts': `import { tag } from "./src/util";\nconsole.log(tag);`,
      'zntc.config.json': JSON.stringify({
        resolveExtensions: ['.web.ts', '.ts'],
      }),
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, [
      '--bundle',
      join(fixture.dir, 'index.ts'),
      '-o',
      outFile,
    ]);
    expect(result.exitCode).toBe(0);
    expect(readFileSync(outFile, 'utf8')).toContain('WEB_VARIANT');
  });

  test('loader: 확장자별 로더 매핑 — file 로더는 URL 문자열 export', async () => {
    const fixture = await createFixture({
      'logo.png': 'fake-png-content',
      'index.ts': `import url from "./logo.png";\nconsole.log(url);`,
      'zntc.config.json': JSON.stringify({
        loader: [{ ext: '.png', loader: 'file' }],
      }),
    });
    cleanup = fixture.cleanup;

    const result = await runZntcInDir(fixture.dir, [
      '--bundle',
      join(fixture.dir, 'index.ts'),
      '--outdir',
      join(fixture.dir, 'dist'),
    ]);
    expect(result.exitCode).toBe(0);
    // file 로더가 활성화되면 빌드 성공 (이전엔 unknown loader 로 실패).
    // 출력 디렉토리에 hash 가 붙은 파일이 emit 됨.
  });

  test('preserveModules: bundler 가 모듈 1개 → 출력 1개로 emit', async () => {
    const fixture = await createFixture({
      'src/a.ts': `export const a = 1;`,
      'src/b.ts': `import { a } from "./a";\nexport const b = a + 1;`,
      'index.ts': `export { b } from "./src/b";`,
      'zntc.config.json': JSON.stringify({ preserveModules: true }),
    });
    cleanup = fixture.cleanup;

    const outDir = join(fixture.dir, 'dist');
    const result = await runZntcInDir(fixture.dir, [
      '--bundle',
      join(fixture.dir, 'index.ts'),
      '--outdir',
      outDir,
      '--format=esm',
    ]);
    expect(result.exitCode).toBe(0);
    // preserveModules 시 a.js, b.js, index.js 등 분리 emit.
    const files = readdirSync(outDir);
    expect(files.length).toBeGreaterThan(1);
  });

  test('CLI flag 가 config 를 override (CLI > config 우선순위)', async () => {
    const fixture = await createFixture({
      'index.ts': "console.log('hi');",
      'zntc.config.json': JSON.stringify({
        banner: '/* FROM_CONFIG */',
      }),
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, [
      '--bundle',
      join(fixture.dir, 'index.ts'),
      '-o',
      outFile,
      '--banner:js=/* FROM_CLI */',
    ]);
    expect(result.exitCode).toBe(0);
    const out = readFileSync(outFile, 'utf8');
    expect(out).toContain('FROM_CLI');
    expect(out).not.toContain('FROM_CONFIG');
  });

  test('config 부재: 기존 동작 회귀 없음', async () => {
    const fixture = await createFixture({
      'index.ts': "console.log('NO_CONFIG');",
      // zntc.config.json 없음
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, [
      '--bundle',
      join(fixture.dir, 'index.ts'),
      '-o',
      outFile,
    ]);
    expect(result.exitCode).toBe(0);
    expect(readFileSync(outFile, 'utf8')).toContain('NO_CONFIG');
  });

  test('manualChunks: record form 매핑 — vendor chunk 분리', async () => {
    // 이전엔 zntc.config.json 의 manualChunks 가 silent 무시됨. record form 매핑 검증.
    const r = await runConfigBundle({
      files: {
        'src/a.ts': 'export const a = "PKG_A";',
        'src/b.ts': 'export const b = "PKG_B";',
        'index.ts':
          'import { a } from "./src/a";\nimport { b } from "./src/b";\nconsole.log(a, b);',
        'zntc.config.json': JSON.stringify({
          manualChunks: [{ name: 'vendor', patterns: ['src/a', 'src/b'] }],
        }),
      },
      outDir: 'dist',
      args: ['--splitting', '--format=esm'],
    });
    cleanup = r.cleanup;

    expect(r.exitCode).toBe(0);
    const files = readdirSync(r.outDir!);
    // manualChunks 가 적용되면 vendor chunk 분리 → 2+ 파일 emit.
    expect(files.length).toBeGreaterThan(1);
    const vendorFile = files.find((f: string) => f.startsWith('vendor'));
    expect(vendorFile).toBeDefined();
    const vendorContents = readFileSync(join(r.outDir!, vendorFile!), 'utf8');
    expect(vendorContents).toContain('PKG_A');
    expect(vendorContents).toContain('PKG_B');
  });

  test('--inline-dynamic-imports CLI flag: dynamic target 이 entry chunk 에 흡수', async () => {
    // 이전엔 config.json `inlineDynamicImports` 만 노출되어 있었음. CLI flag 추가 검증.
    const r = await runConfigBundle({
      files: {
        'entry.ts': `
        async function boot() { const m = await import("./lazy"); console.log(m.v); }
        boot();
      `,
        'lazy.ts': 'export const v = "INLINE_OK";',
      },
      entry: 'entry.ts',
      outDir: 'dist',
      args: ['--splitting', '--inline-dynamic-imports', '--format=esm'],
    });
    cleanup = r.cleanup;

    expect(r.exitCode).toBe(0);
    const files = readdirSync(r.outDir!);
    // inline 적용 시 단일 chunk
    expect(files.length).toBe(1);
    expect(readFileSync(join(r.outDir!, files[0]), 'utf8')).toContain('INLINE_OK');
  });

  test('tsconfigPath: zntc.config.json 의 tsconfigPath 가 정상 적용 (이전엔 silent drop)', async () => {
    // applyZntcConfigJson 이 tsconfigPath 매핑을 누락했던 silent drift 의 fix 검증.
    // tsconfig.json 에 experimentalDecorators=true 명시 → @decorator 구문 파싱 통과.
    const r = await runConfigBundle({
      files: {
        'index.ts':
          "function dec(t:any,k:string){}\nclass A { @dec method(){} }\nconsole.log('TSCONFIG_OK');",
        'tsconfig.custom.json': JSON.stringify({
          compilerOptions: { experimentalDecorators: true, target: 'es2022' },
        }),
        'zntc.config.json': JSON.stringify({ tsconfigPath: 'tsconfig.custom.json' }),
      },
    });
    cleanup = r.cleanup;

    expect(r.exitCode).toBe(0);
    expect(readFileSync(r.outFile!, 'utf8')).toContain('TSCONFIG_OK');
  });

  // ─── Module Federation config 블록 (#3318 P1-0) ──────────────────────────
  // P1-0 은 파싱·검증만 — emit 미연결. 유효 mf 는 빌드 정상(출력 불변),
  // 무효 mf 는 config 검증 경고가 stderr 로 표면화(기존 config-error 정책:
  // non-fatal warn). emit/소비는 P1-1+. mf 는 **record 형태**(public TS
  // 타입·MF2 생태계와 동일, define/alias 의 array 관례와 다름) — zntc DTO
  // 가 std.json.ArrayHashMap 으로 직접 파싱, 변환 계층 없음. 사용자가
  // 문서/타입대로 쓰는 그 경로를 그대로 검증.

  // exposes 동작(container emit)은 P1-3 부터라 mf-container-emit.test.ts 가
  // 전담. 여기선 비-remote 필드(name/remotes/shared/shareScope) 파싱 +
  // host 빌드 출력 불변만(exposes 넣으면 remote→container 경로로 빠짐).
  test('mf: 유효 config 블록(name/remotes/shared/shareScope) 파싱 성공', async () => {
    const r = await runConfigBundle({
      files: {
        'index.ts': `console.log("mf-ok");`,
        'zntc.config.json': JSON.stringify({
          mf: {
            name: 'app',
            remotes: { remoteA: 'remoteA@http://localhost/mf-manifest.json' },
            shared: { react: { singleton: true, requiredVersion: '^18' } },
            shareScope: 'default',
          },
        }),
      },
    });
    cleanup = r.cleanup;

    expect(r.exitCode).toBe(0);
    expect(r.stderr).not.toContain('load failed');
    // exposes 없음(host) — 출력은 일반 번들 그대로
    expect(readFileSync(r.outFile!, 'utf8')).toContain('mf-ok');
  });

  test('mf: exposes 인데 name 없으면 검증 경고(MfNameRequired) 표면화', async () => {
    const r = await runConfigBundle({
      files: {
        'index.ts': `console.log("mf-bad");`,
        'zntc.config.json': JSON.stringify({
          mf: { exposes: { './Widget': './widget.ts' } },
        }),
      },
    });
    cleanup = r.cleanup;

    // 기존 config-error 정책상 non-fatal warn — stderr 로 검증 실패 표면화
    expect(r.stderr).toContain('load failed');
    expect(r.stderr).toContain('MfNameRequired');
  });

  test('mf: shared-only(host) 는 name 없이도 유효', async () => {
    const r = await runConfigBundle({
      files: {
        'index.ts': `console.log("host");`,
        'zntc.config.json': JSON.stringify({
          mf: { shared: { react: { singleton: true } } },
        }),
      },
    });
    cleanup = r.cleanup;

    expect(r.exitCode).toBe(0);
    expect(r.stderr).not.toContain('load failed');
  });

  // P1-2 (#3384): mf.shared → external + 글로벌-파라미터 seam 자동 emit.
  // --external/--globals 플래그 없이 config 만으로 스파이크 S2 메커니즘.
  test('mf.shared: IIFE 글로벌 seam 자동 emit + shared 비번들', async () => {
    const r = await runConfigBundle({
      files: {
        'index.ts': `import { useState } from "react";\nexport function App() { return useState(0); }`,
        'zntc.config.json': JSON.stringify({
          mf: { name: 'app', shared: { react: { singleton: true } } },
        }),
      },
      args: ['--format=iife', '--global-name=__app'],
    });
    cleanup = r.cleanup;

    expect(r.exitCode).toBe(0);
    const out = readFileSync(r.outFile!, 'utf8');
    // container-소유 글로벌 파라미터 seam (P1-3 가 shareScope→이 글로벌 주입)
    expect(out).toContain('((__mf_shared_react) => {');
    expect(out).toContain(')(__mf_shared_react);');
    expect(out).toContain('__mf_shared_react.useState');
    // react 는 번들에 인라인되지 않음(external — shareScope 에서 옴)
    expect(out).not.toMatch(/react\/cjs|node_modules[\\/]react/);
  });
});
