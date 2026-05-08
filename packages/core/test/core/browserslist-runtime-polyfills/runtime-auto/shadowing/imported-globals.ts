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
} from '../helpers';

describe('@zntc/core runtimePolyfills > auto detection > shadowing > imported globals', () => {
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
});
