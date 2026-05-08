import {
  describe,
  test,
  expect,
  transpile,
  build,
  buildSync,
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';
import type { ZntcPlugin } from './helpers';

describe('@zntc/core browserslist', () => {
  test('browserslist: 모던 브라우저 쿼리는 변환 안 함', () => {
    const src = 'async function f() { return await Promise.resolve(1); }';
    const r = transpile(src, { browserslist: 'last 2 chrome versions' });
    expect(r.code).toContain('async function f');
    expect(r.code).not.toContain('__async');
  });

  test('browserslist: 오래된 브라우저 쿼리는 async 다운레벨', () => {
    const src = 'async function f() { return await Promise.resolve(1); }';
    const r = transpile(src, { browserslist: 'chrome 50, firefox 50' });
    expect(r.code).toContain('__async');
  });

  test('browserslist: 여러 엔진 중 하나라도 미지원이면 다운레벨 (보수적)', () => {
    // chrome 최신은 optional_chaining 지원, safari 12는 미지원 → ?. 제거
    const src = 'const x = a?.b;';
    const r = transpile(src, { browserslist: 'chrome 100, safari 12' });
    expect(r.code).not.toContain('?.');
  });

  test('browserslist: 쿼리 배열 입력', () => {
    const src = 'const x = 1 ** 2;';
    // chrome 40은 exponentiation 미지원, chrome 55는 지원 → union 결과 chrome 40 기준
    const r = transpile(src, { browserslist: ['chrome 40'] });
    expect(r.code).not.toContain('**');
  });

  test('browserslist: ios_saf는 ios 엔진으로 매핑', () => {
    const src = 'async function f() {}';
    // ios 10은 async 미지원 → 변환
    const r = transpile(src, { browserslist: 'ios_saf 10' });
    expect(r.code).toContain('__async');
  });

  test('browserslist: 매핑 불가능한 엔진(samsung)만 있으면 보수적으로 esnext', () => {
    // samsung 브라우저는 ZNTC Engine에 없음 → 빈 engines → 0 (esnext)
    const src = 'async function f() {}';
    const r = transpile(src, { browserslist: 'samsung 20' });
    expect(r.code).toContain('async function');
  });

  test('browserslist는 target보다 우선', () => {
    const src = 'const x = a?.b;';
    // target=es5지만 browserslist=modern → optional chaining 유지
    const r = transpile(src, { target: 'es5', browserslist: 'chrome 100' });
    expect(r.code).toContain('?.');
  });

  test('browserslist: 빈 결과(매칭 없음)도 크래시 없이 처리', () => {
    // 존재하지 않는 버전 규칙 — browserslist가 throw 할 수도 있음
    // 이 경우 사용자 책임 — 우리 코드에서 크래시만 안 나면 됨
    const src = 'const x = 1;';
    expect(() => transpile(src, { browserslist: 'defaults' })).not.toThrow();
  });

  test('browserslist: hermes 매핑 (RN 사용자 대응)', () => {
    // browserslist는 hermes를 모르지만 우리 파서는 수동 매핑 지원
    // 직접 hermes 키워드 쿼리는 browserslist가 모르므로 defaults 사용 예시
    const src = 'async function f() {}';
    // hermes 0.12는 async transform 필요 (kangax fail) → __async 나와야 함
    // 이 테스트는 browserslistToUnsupported 저수준 API 커버
    const { browserslistToUnsupported } = require('../../../shared/index');
    const bits = browserslistToUnsupported(['hermes 0.12']);
    // bit 12 = async_await
    expect(bits & (1 << 12)).not.toBe(0);
    void src;
  });

  test('browserslist: build API도 해석 (BuildOptions.browserslist)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-build-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'export async function run() { return await Promise.resolve(1); }',
    );
    // 오래된 쿼리 → async 다운레벨
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      browserslist: 'chrome 50',
    });
    const code = r.outputFiles[0].text;
    expect(code).toContain('__async');
    rmSync(dir, { recursive: true });
  });

  test('browserslist: build API — 모던 타겟은 async 유지', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-build2-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'export async function run() { return await Promise.resolve(1); }',
    );
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      browserslist: 'last 2 chrome versions',
    });
    const code = r.outputFiles[0].text;
    expect(code).toContain('async function');
    expect(code).not.toContain('__async');
    rmSync(dir, { recursive: true });
  });

  test('browserslist: build API — 여러 엔진 union 중 가장 오래된 기준 (보수적)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-union-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      // optional chaining 사용
      'export const x = (o: any) => o?.a?.b;',
    );
    // chrome 100 (지원) + safari 12 (미지원) → safari 12 기준 다운레벨
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      browserslist: ['chrome 100', 'safari 12'],
    });
    expect(r.outputFiles[0].text).not.toContain('?.');
    rmSync(dir, { recursive: true });
  });

  test('runtimePolyfills auto: used replaceAll is injected before entry execution', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-auto-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), `globalThis.__RESULT__ = "a-a".replaceAll("a", "b");`);
      const r = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['ios_saf 12'] },
      });
      const code = r.outputFiles[0].text;
      expect(code).toContain('es.string.replace-all');

      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __RESULT__?: string } = {};
      vm.runInNewContext(`String.prototype.replaceAll = undefined;\n${code}`, sandbox);
      expect(sandbox.__RESULT__).toBe('b-b');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills auto scans local dependencies and respects modern targets', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-dep-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `import { value } from "./dep"; globalThis.__VALUE__ = value;`,
      );
      writeFileSync(join(dir, 'dep.ts'), `export const value = "a".replaceAll("a", "b");`);

      const oldTarget = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['ios_saf 12'] },
      }).outputFiles[0].text;
      expect(oldTarget).toContain('es.string.replace-all');

      const modernTarget = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['node 18'] },
      }).outputFiles[0].text;
      expect(modernTarget).not.toContain('es.string.replace-all');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills auto scans package exports resolved modules', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-pkg-exports-'));
    try {
      const pkgDir = join(dir, 'node_modules', 'runtime-exports-pkg', 'dist');
      mkdirSync(pkgDir, { recursive: true });
      writeFileSync(
        join(dir, 'node_modules', 'runtime-exports-pkg', 'package.json'),
        JSON.stringify({
          name: 'runtime-exports-pkg',
          type: 'module',
          exports: {
            '.': {
              import: './dist/index.js',
              default: './dist/index.js',
            },
          },
        }),
      );
      writeFileSync(
        join(pkgDir, 'index.js'),
        `
          const cloned = structuredClone({ label: "clone" });
          export const value = [
            ["a", "b"].at(-1),
            Object.hasOwn({ ok: true }, "ok") ? "own" : "missing",
            cloned.label,
          ].join("|");
        `,
      );
      writeFileSync(
        join(dir, 'entry.ts'),
        `import { value } from "runtime-exports-pkg"; globalThis.__VALUE__ = value;`,
      );

      const code = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        platform: 'node',
        runtimePolyfills: { mode: 'auto', targets: ['safari 5'] },
      }).outputFiles[0].text;

      expect(code).toContain('es.array.at');
      expect(code).toContain('es.object.has-own');
      expect(code).toContain('web.structured-clone');

      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __VALUE__?: string } = {};
      vm.runInNewContext(
        `
          Array.prototype.at = undefined;
          Object.hasOwn = undefined;
          globalThis.structuredClone = undefined;
          ${code}
        `,
        sandbox,
      );
      expect(sandbox.__VALUE__).toBe('b|own|clone');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills auto ignores shadowed globals and dynamic computed access', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-negative-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `
          const Map = class LocalMap {};
          const Object = { hasOwn() { return true; } };
          const globalThis = { Set: class LocalSet {} };
          const promiseMethod = "resolve";
          const stringMethod = "replaceAll";
          new Map();
          new globalThis.Set();
          Object.hasOwn({}, "x");
          Promise[promiseMethod](1);
          "a-a"[stringMethod]("a", "b");
        `,
      );

      const code = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['safari 5'] },
      }).outputFiles[0].text;

      expect(code).not.toContain('es.map');
      expect(code).not.toContain('es.set');
      expect(code).not.toContain('es.promise');
      expect(code).not.toContain('es.object.has-own');
      expect(code).not.toContain('es.string.replace-all');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills auto ignores imported runtime global names', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-import-shadow-'));
    try {
      writeFileSync(
        join(dir, 'locals.ts'),
        `
          export class Map {
            kind = "local-map";
          }
          export const Promise = {
            resolve(value: string) {
              return "local-" + value;
            },
          };
          export const Object = {
            hasOwn() {
              return "local-has-own";
            },
          };
        `,
      );
      writeFileSync(
        join(dir, 'entry.ts'),
        `
          import { Map, Promise, Object } from "./locals";
          const structuredClone = (value: string) => "local-" + value;
          globalThis.__VALUE__ = [
            new Map().kind,
            Promise.resolve("promise"),
            Object.hasOwn({}, "x"),
            structuredClone("clone"),
          ].join("|");
        `,
      );

      const code = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['safari 5'] },
      }).outputFiles[0].text;

      expect(code).not.toContain('es.map');
      expect(code).not.toContain('es.promise');
      expect(code).not.toContain('es.object.has-own');
      expect(code).not.toContain('web.structured-clone');

      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __VALUE__?: string } = {};
      vm.runInNewContext(
        `
          globalThis.Map = undefined;
          globalThis.Promise = undefined;
          globalThis.structuredClone = undefined;
          ${code}
        `,
        sandbox,
      );
      expect(sandbox.__VALUE__).toBe('local-map|local-promise|local-has-own|local-clone');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills include covers intentional dynamic computed access', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-computed-include-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `
          const method = "at";
          globalThis.__VALUE__ = ["x", "y"][method](-1);
        `,
      );

      const autoOnly = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['safari 5'] },
      }).outputFiles[0].text;
      expect(autoOnly).not.toContain('es.array.at');

      const included = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: {
          mode: 'auto',
          targets: ['node 18'],
          include: ['es.array.at'],
        },
      }).outputFiles[0].text;
      expect(included).toContain('es.array.at');

      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __VALUE__?: string } = {};
      vm.runInNewContext(`Array.prototype.at = undefined;\n${included}`, sandbox);
      expect(sandbox.__VALUE__).toBe('y');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills auto detects explicit globalThis runtime API usage', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-globalthis-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `
          globalThis.__RESULT__ = [
            typeof globalThis.Map,
            typeof globalThis.Set,
            typeof globalThis.Promise.resolve,
            typeof globalThis.structuredClone,
            globalThis.Object.hasOwn({ ok: true }, "ok"),
          ].join("|");
        `,
      );

      const code = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['safari 5'] },
      }).outputFiles[0].text;

      expect(code).toContain('es.map');
      expect(code).toContain('es.set');
      expect(code).toContain('es.promise');
      expect(code).toContain('web.structured-clone');
      expect(code).toContain('es.object.has-own');

      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __RESULT__?: string } = {};
      vm.runInNewContext(
        `
          globalThis.Map = undefined;
          globalThis.Set = undefined;
          globalThis.Promise = undefined;
          globalThis.structuredClone = undefined;
          globalThis.Object.hasOwn = undefined;
          ${code}
        `,
        sandbox,
      );
      expect(sandbox.__RESULT__).toBe('function|function|function|function|true');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills auto injects expanded core-js built-ins', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-expanded-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `
          const key = {};
          const weak = new WeakMap();
          weak.set(key, 7);
          globalThis.__VALUE__ = [
            Object.values({ label: "value" })[0],
            "7".padStart(2, "0"),
            Math.trunc(1.8),
            Reflect.ownKeys({ own: true })[0],
            [1, 2, 3].findLast((value) => value < 3),
            typeof Symbol === "function",
            weak.get(key),
          ].join("|");
        `,
      );

      const code = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['safari 5'] },
      }).outputFiles[0].text;

      expect(code).toContain('es.object.values');
      expect(code).toContain('es.string.pad-start');
      expect(code).toContain('es.math.trunc');
      expect(code).toContain('es.reflect.own-keys');
      expect(code).toContain('es.array.find-last');
      expect(code).toContain('es.weak-map');
      expect(code).toContain('es.symbol');

      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __VALUE__?: string } = {};
      vm.runInNewContext(
        `
          Object.values = undefined;
          String.prototype.padStart = undefined;
          Math.trunc = undefined;
          Reflect.ownKeys = undefined;
          Array.prototype.findLast = undefined;
          globalThis.WeakMap = undefined;
          globalThis.Symbol = undefined;
          ${code}
        `,
        sandbox,
      );
      expect(sandbox.__VALUE__).toBe('value|07|1|own|2|true|7');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills auto detects usage added by transform plugins', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-transform-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), `globalThis.__VALUE__ = "__ORIGINAL__";`);
      const transformPlugin: ZntcPlugin = {
        name: 'runtime-polyfill-transform',
        setup(build) {
          build.onTransform({ filter: /entry\.ts$/ }, () => ({
            code: `globalThis.__VALUE__ = "a-a".replaceAll("a", "b");`,
          }));
        },
      };

      const result = await build({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['ios_saf 12'] },
        plugins: [transformPlugin],
      });

      expect(result.errors.length).toBe(0);
      const code = result.outputFiles[0].text;
      expect(code).toContain('es.string.replace-all');
      expect(code).not.toContain('__ORIGINAL__');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills include is forced and exclude removes final selected modules', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-include-exclude-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `
          const value = ["a"].at(0);
          globalThis.__VALUE__ = "a-a".replaceAll("a", value ?? "b");
        `,
      );

      const code = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: {
          mode: 'auto',
          targets: ['ios_saf 12'],
          include: ['es.promise'],
          exclude: ['es.string.replace-all'],
        },
      }).outputFiles[0].text;

      expect(code).toContain('es.array.at');
      expect(code).toContain('es.promise');
      expect(code).not.toContain('es.string.replace-all');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills entry and off modes stay separate from usage collection', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-modes-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), `globalThis.__VALUE__ = "a".replaceAll("a", "b");`);

      const entryMode = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'entry', targets: ['safari 5'] },
      }).outputFiles[0].text;
      expect(entryMode).toContain('es.map');
      expect(entryMode).toContain('es.promise');
      expect(entryMode).toContain('es.string.replace-all');

      const offMode = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: 'off',
      }).outputFiles[0].text;
      expect(offMode).not.toContain('es.string.replace-all');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills prelude runs after manual polyfills and before runBeforeMain', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-order-'));
    try {
      const polyfillFile = join(dir, 'manual-polyfill.js');
      const initFile = join(dir, 'init.ts');
      writeFileSync(
        polyfillFile,
        `
          globalThis.__ORDER__ = ["polyfill"];
          String.prototype.replaceAll = undefined;
        `,
      );
      writeFileSync(
        initFile,
        `globalThis.__ORDER__.push("runBeforeMain:" + "a".replaceAll("a", "b"));`,
      );
      writeFileSync(
        join(dir, 'entry.ts'),
        `globalThis.__ORDER__.push("entry:" + "a".replaceAll("a", "c"));`,
      );

      const code = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        polyfills: [polyfillFile],
        runBeforeMain: [initFile],
        runtimePolyfills: { mode: 'auto', targets: ['ios_saf 12'] },
      }).outputFiles[0].text;

      expect(code).toContain('es.string.replace-all');
      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __ORDER__?: string[] } = {};
      vm.runInNewContext(code, sandbox);
      expect(sandbox.__ORDER__).toEqual(['polyfill', 'runBeforeMain:b', 'entry:c']);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills rejects compact target shorthand through build API', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-shorthand-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), `"a".replaceAll("a", "b");`);
      expect(() =>
        buildSync({
          entryPoints: [join(dir, 'entry.ts')],
          runtimePolyfills: { mode: 'auto', targets: ['ios12'] },
        }),
      ).toThrow('Compact runtime target shorthands');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('browserslist: build API — target + browserslist 동시 지정 시 browserslist 우선', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-both-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'export async function run() { return await Promise.resolve(1); }',
    );
    // target=es5(모두 다운레벨)인데 browserslist=modern(esnext) → 변환 안 해야 함
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      target: 'es5',
      browserslist: 'chrome 100',
    });
    expect(r.outputFiles[0].text).not.toContain('__async');
    rmSync(dir, { recursive: true });
  });

  test('browserslist: build API — 매핑 불가능한 엔진만 있으면 esnext', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-unknown-'));
    writeFileSync(join(dir, 'entry.ts'), 'export async function run() { return 1; }');
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      browserslist: 'samsung 20',
    });
    expect(r.outputFiles[0].text).toContain('async function');
    rmSync(dir, { recursive: true });
  });

  test('browserslist: build API — 빈 배열 입력 시 기본 (보수적 esnext)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-empty-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
    // 빈 배열 → browserslist가 default 쿼리로 처리하므로 에러 없어야 함
    expect(() =>
      buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        browserslist: [] as string[],
      }),
    ).not.toThrow();
    rmSync(dir, { recursive: true });
  });

  test('browserslist: build API — ios_saf 버전 매핑 (RN 시나리오)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-ios-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      // ES2020 optional_chaining — ios 13 미만 미지원
      'export const x = (o: any) => o?.a;',
    );
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      browserslist: 'ios_saf 12',
    });
    expect(r.outputFiles[0].text).not.toContain('?.');
    rmSync(dir, { recursive: true });
  });

  test('browserslist: build API — 출력 파일 수 일치 (트랜스파일 결과 누락 방지)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-outfiles-'));
    writeFileSync(join(dir, 'a.ts'), 'export const A = 1;');
    writeFileSync(join(dir, 'b.ts'), 'export const B = 2;');
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { A } from './a';\nimport { B } from './b';\nconsole.log(A, B);",
    );
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      browserslist: 'last 2 chrome versions',
    });
    expect(r.outputFiles.length).toBeGreaterThan(0);
    expect(r.outputFiles[0].text).toContain('1');
    expect(r.outputFiles[0].text).toContain('2');
    rmSync(dir, { recursive: true });
  });

  test('browserslist: build API — minify 동시 적용', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-minify-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'export const longVariableName = 42;\nconsole.log(longVariableName);',
    );
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      browserslist: 'chrome 100',
      minify: true,
    });
    // minify 적용 확인: 공백 압축
    expect(r.outputFiles[0].text.length).toBeLessThan(100);
    rmSync(dir, { recursive: true });
  });

  test('browserslist: 같은 엔진의 여러 버전 — 가장 낮은 버전 기준', () => {
    const { browserslistToUnsupported } = require('../../../shared/index');
    // chrome 40(미지원) + chrome 100(지원) 동시 전달 — 40 때문에 async_await unsupported
    const bits = browserslistToUnsupported(['chrome 40', 'chrome 100']);
    expect(bits & (1 << 12)).not.toBe(0);
  });

  // ─── tsconfigPath (NAPI 에서 tsconfig.json 자동 로드) ───
  describe('tsconfigPath', () => {
    test('tsconfigPath=<file>: verbatimModuleSyntax 가 적용되어 미사용 import 보존', () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-tscpath-file-'));
      writeFileSync(
        join(dir, 'tsconfig.json'),
        '{"compilerOptions":{"verbatimModuleSyntax":true}}',
      );
      const r = transpile('import { foo } from "./bar";', {
        filename: 'input.ts',
        tsconfigPath: join(dir, 'tsconfig.json'),
      });
      expect(r.code).toContain('import { foo } from "./bar"');
      rmSync(dir, { recursive: true });
    });

    test('tsconfigPath=<dir>: 디렉토리 내 tsconfig.json 자동 탐지', () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-tscpath-dir-'));
      writeFileSync(
        join(dir, 'tsconfig.json'),
        '{"compilerOptions":{"verbatimModuleSyntax":true}}',
      );
      const r = transpile('import { foo } from "./bar";', {
        filename: 'input.ts',
        tsconfigPath: dir,
      });
      expect(r.code).toContain('import { foo } from "./bar"');
      rmSync(dir, { recursive: true });
    });

    test('JS 옵션이 tsconfig 보다 우선 — 명시적 false 로 tsconfig true override', () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-tscpath-prio-'));
      writeFileSync(
        join(dir, 'tsconfig.json'),
        '{"compilerOptions":{"verbatimModuleSyntax":true}}',
      );
      const r = transpile('import { foo } from "./bar";', {
        filename: 'input.ts',
        tsconfigPath: dir,
        verbatimModuleSyntax: false,
      });
      expect(r.code).toBe('');
      rmSync(dir, { recursive: true });
    });

    test('tsconfigPath 없으면 기본 동작 (elide)', () => {
      const r = transpile('import { foo } from "./bar";', { filename: 'input.ts' });
      expect(r.code).toBe('');
    });

    test('build API 도 tsconfigPath 옵션을 받음 (no-throw)', () => {
      // 참고: build 의 verbatim 은 tree-shaker 와 상호작용하므로 표면 효과는 번들 구성에 따라
      // 다르다 — 여기서는 옵션 통과 경로만 검증 (no throw + 출력 생성).
      const dir = mkdtempSync(join(tmpdir(), 'zntc-tscpath-build-'));
      writeFileSync(
        join(dir, 'tsconfig.json'),
        '{"compilerOptions":{"verbatimModuleSyntax":true}}',
      );
      writeFileSync(join(dir, 'entry.ts'), 'console.log(42);');
      const r = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        tsconfigPath: join(dir, 'tsconfig.json'),
      });
      expect(r.outputFiles[0].text).toContain('console.log(42)');
      rmSync(dir, { recursive: true });
    });
  });

  // ─── profile / profileLevel / profileFormat options (PR 2) ───
  //
  // CLI `--profile*` 와 동일한 의미의 NAPI 옵션. 이 PR 에서는 옵션 파싱 / 프로세스
  // 전역 profile 모듈 상태 조작만 검증. 실제 phase 수치는 PR 3+ 에서 hot-path timer
  // 가 삽입된 뒤부터 기록된다.
  describe('profile options (PR 2 — entry point integration)', () => {
    test('BundleOptions.profile 을 받아들인다 (no throw)', () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-profile-'));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
      const r = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        profile: ['all'],
      });
      expect(r.outputFiles[0].text).toContain('const x = 1');
      rmSync(dir, { recursive: true });
    });

    test('BundleOptions.profileLevel 을 받아들인다 (no throw)', () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-profile-lvl-'));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
      const r = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        profile: ['parse', 'transform'],
        profileLevel: 'detailed',
      });
      expect(r.outputFiles[0].text).toContain('const x = 1');
      rmSync(dir, { recursive: true });
    });

    test('BundleOptions.profileFormat 은 타입에 존재 (향후 결과 노출용)', () => {
      // PR 10 에서 build/buildSync 결과에 profile report 를 실제 포함시킬 예정.
      // PR 2 는 옵션 파싱만 검증.
      const dir = mkdtempSync(join(tmpdir(), 'zntc-profile-fmt-'));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
      const r = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        profile: ['all'],
        profileFormat: 'json',
      });
      expect(r.outputFiles[0].text).toContain('const x = 1');
      rmSync(dir, { recursive: true });
    });

    test('잘못된 profileLevel 은 무시 (graceful degrade)', () => {
      // Level.fromString 이 null 반환 → profile 모듈이 level 변경 안 함. build 는 성공.
      const dir = mkdtempSync(join(tmpdir(), 'zntc-profile-bad-'));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
      const r = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        profile: ['all'],
        // @ts-expect-error — runtime 허용성 검증
        profileLevel: 'bogus',
      });
      expect(r.outputFiles[0].text).toContain('const x = 1');
      rmSync(dir, { recursive: true });
    });

    test('profile 미지정 시 빌드는 정상 동작 (default: 비활성)', () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-noprofile-'));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
      const r = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
      });
      expect(r.outputFiles[0].text).toContain('const x = 1');
      rmSync(dir, { recursive: true });
    });
  });
});

// ─── plugin lifecycle hooks (#2156) ───
