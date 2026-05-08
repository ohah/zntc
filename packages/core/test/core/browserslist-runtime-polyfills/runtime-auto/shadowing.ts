import {
  buildSync,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from './helpers';

describe('@zntc/core runtimePolyfills > auto detection > shadowing', () => {
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
});
