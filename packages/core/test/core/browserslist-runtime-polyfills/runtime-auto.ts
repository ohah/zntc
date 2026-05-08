import {
  describe,
  test,
  expect,
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

describe('@zntc/core runtimePolyfills > auto detection', () => {
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
});
