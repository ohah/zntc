import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

describe('JSX runtime helper name collisions', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const mode of ['automatic', 'automatic-dev'] as const) {
    test(`${mode} keeps generated helpers distinct from user bindings`, async () => {
      const fx = await createFixture({
        'app.tsx': `
const _jsx = () => 'user jsx';
const _jsxs = () => 'user jsxs';
const _jsxDEV = () => 'user jsxDEV';
const _Fragment = () => 'user Fragment';
const _createElement = () => 'user createElement';
const props = { id: 'x' };
export const single = <p>single</p>;
export const multiple = <><p>one</p><p>two</p></>;
export const fallback = <p {...props} key="late" />;
export const users = [_jsx(), _jsxs(), _jsxDEV(), _Fragment(), _createElement()];
`,
      });
      cleanup = fx.cleanup;
      const out = join(fx.dir, 'out.js');
      const result = await runZntcInDir(fx.dir, ['app.tsx', '-o', out, `--jsx=${mode}`]);
      expect(result.exitCode).toBe(0);
      const code = await readFile(out, 'utf8');
      const runtimeModule = mode === 'automatic' ? 'react/jsx-runtime' : 'react/jsx-dev-runtime';
      // standalone JSX imports now come from the edited AST; the legacy string prefix must
      // not duplicate either generated import, including the createElement spread fallback.
      expect([...code.matchAll(new RegExp(`from "${runtimeModule}"`, 'g'))]).toHaveLength(1);
      expect([...code.matchAll(/from "react"/g)]).toHaveLength(1);
      const imports =
        mode === 'automatic'
          ? ['jsx', 'jsxs', 'Fragment', 'createElement']
          : ['jsxDEV', 'Fragment', 'createElement'];
      for (const imported of imports) {
        const local = `_${imported}`;
        expect(code).toContain(`${imported} as ${local}2`);
        if (imported === 'Fragment') {
          // One occurrence is the import; another must be the JSX fragment argument.
          expect([...code.matchAll(/\b_Fragment2\b/g)].length).toBeGreaterThanOrEqual(2);
        } else {
          expect(code).toMatch(new RegExp(`\\b${local}2\\(`));
        }
        expect(code).toContain(`${local}()`);
      }
    });
  }

  test('standalone automatic JSX late naming preserves an unresolved global', async () => {
    const fx = await createFixture({
      'node_modules/react/package.json': JSON.stringify({
        exports: { './jsx-runtime': './jsx-runtime.mjs' },
      }),
      'node_modules/react/jsx-runtime.mjs': `
export function jsx(type, props) { return { type, props }; }
export function jsxs(type, props) { return { type, props }; }
export const Fragment = Symbol.for('fragment');
`,
      'app.tsx': `
globalThis._jsx = 40;
const element = <div />;
console.log(_jsx, element.type);
`,
    });
    cleanup = fx.cleanup;
    const out = join(fx.dir, 'out.mjs');
    const result = await runZntcInDir(fx.dir, ['app.tsx', '-o', out, '--jsx=automatic']);
    expect(result.exitCode, result.stderr).toBe(0);

    const code = await readFile(out, 'utf8');
    expect(code).toContain('jsx as _jsx2');
    expect(code).toMatch(/_jsx2\(/);

    const runtime = spawnSync('node', [out], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe('40 div\n');
  });

  test('standalone automatic JSX keeps an unshadowed runtime import spelling', async () => {
    const fx = await createFixture({
      'app.tsx': 'export const element = <div />;\n',
    });
    cleanup = fx.cleanup;
    const out = join(fx.dir, 'out.js');
    const result = await runZntcInDir(fx.dir, ['app.tsx', '-o', out, '--jsx=automatic']);
    expect(result.exitCode, result.stderr).toBe(0);

    const code = await readFile(out, 'utf8');
    expect(code).toContain('jsx as _jsx');
    expect(code).toMatch(/_jsx\(/);
    expect(code).not.toContain('jsx as _jsx2');
  });
});
