import {
  buildSync,
  describe,
  expect,
  join,
  mkdirSync,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from './helpers';

describe('@zntc/core runtimePolyfills > auto detection > direct dependencies', () => {
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
});
