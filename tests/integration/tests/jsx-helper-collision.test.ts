import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createFixture, runZntc, runZntcInDir } from './helpers';

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

  for (const [target, extraArgs] of [
    ['ESNext', []],
    ['ES5', ['--target=es5']],
    ['identifier minify', ['--minify-identifiers']],
  ] as const) {
    test(`bundled automatic JSX keeps helper identities distinct (${target})`, async () => {
      const fx = await createFixture({
        'node_modules/react/package.json': JSON.stringify({
          name: 'react',
          exports: {
            '.': './index.cjs',
            './jsx-runtime': './jsx-runtime.cjs',
          },
        }),
        'node_modules/react/index.cjs': `
function createElement(type, props) { return { type, props }; }
module.exports = { createElement };
`,
        'node_modules/react/jsx-runtime.cjs': `
function jsx(type, props) { return { type, props }; }
function jsxs(type, props) { return { type, props }; }
module.exports = { jsx, jsxs, Fragment: 'fragment' };
`,
        'app.tsx': `
const _jsx = () => 'user-jsx';
const _jsxs = () => 'user-jsxs';
const _Fragment = () => 'user-fragment';
const _createElement = () => 'user-createElement';
const plain = <p id="plain" />;
const many = <><p>one</p><p>two</p></>;
const fallback = <p {...{ id: 'spread' }} key="late" />;
console.log([
  _jsx(), _jsxs(), _Fragment(), _createElement(),
  plain.type, many.type, fallback.type, fallback.props.id, fallback.props.key,
].join('|'));
`,
      });
      cleanup = fx.cleanup;
      const out = join(fx.dir, 'out.cjs');
      const result = await runZntc(
        [
          '--bundle',
          join(fx.dir, 'app.tsx'),
          '-o',
          out,
          '--platform=node',
          '--format=cjs',
          '--packages=external',
          '--jsx=automatic',
          ...extraArgs,
        ],
        { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
      );
      expect(result.exitCode, result.stderr).toBe(0);
      expect(result.stderr).toMatch(
        /symbol-identity-prepass .*generated_bindings=[1-9]\d* generated_references=[1-9]\d*/,
      );
      expect(result.stderr).toMatch(/missing_binding=0/);
      expect(result.stderr).toMatch(/identity_mismatch=0/);
      expect(result.stderr).toMatch(/unclassified_reference=0/);
      expect(result.stderr).toMatch(/clean=1/);

      const code = await readFile(out, 'utf8');
      if (target === 'identifier minify') {
        const jsxAlias = code.match(
          /var ([A-Za-z_$][\w$]*) = require\("react\/jsx-runtime"\)\.jsx;/,
        )?.[1];
        expect(jsxAlias).toMatch(/^[a-z]$/);
        expect(code).toContain(`${jsxAlias}("p"`);
      } else {
        for (const [imported, local, specifier] of [
          ['jsx', '_jsx', 'react/jsx-runtime'],
          ['jsxs', '_jsxs', 'react/jsx-runtime'],
          ['Fragment', '_Fragment', 'react/jsx-runtime'],
          ['createElement', '_createElement', 'react'],
        ]) {
          const alias = `${local}$1`;
          expect(code).toContain(`var ${alias} = require("${specifier}").${imported};`);
          expect(code).toContain(alias);
        }
      }

      const runtime = spawnSync('node', [out], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe(
        'user-jsx|user-jsxs|user-fragment|user-createElement|p|fragment|p|spread|late\n',
      );
    });
  }

  test('bundled automatic JSX keeps the preferred helper spelling without collisions', async () => {
    const fx = await createFixture({
      'node_modules/react/package.json': JSON.stringify({
        name: 'react',
        exports: { './jsx-runtime': './jsx-runtime.cjs' },
      }),
      'node_modules/react/jsx-runtime.cjs': `
function jsx(type, props) { return { type, props }; }
module.exports = { jsx };
`,
      'app.tsx': `
const element = <p id="plain" />;
console.log(element.type);
`,
    });
    cleanup = fx.cleanup;
    const out = join(fx.dir, 'out.cjs');
    const result = await runZntc([
      '--bundle',
      join(fx.dir, 'app.tsx'),
      '-o',
      out,
      '--platform=node',
      '--format=cjs',
      '--packages=external',
      '--jsx=automatic',
    ]);
    expect(result.exitCode, result.stderr).toBe(0);
    const code = await readFile(out, 'utf8');
    expect(code).toContain('var _jsx = require("react/jsx-runtime").jsx;');
    expect(code).toMatch(/_jsx\("p"/);

    const runtime = spawnSync('node', [out], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe('p\n');
  });

  test('preserve-modules keeps generated imports paired with helper references', async () => {
    const fx = await createFixture({
      'package.json': '{"type":"module"}',
      'node_modules/react/package.json': JSON.stringify({
        name: 'react',
        exports: { './jsx-runtime': './jsx-runtime.cjs' },
      }),
      'node_modules/react/jsx-runtime.cjs': `
function jsx(type, props) { return { type, props }; }
module.exports = { jsx };
`,
      'app.tsx': `
const _jsx = () => 'user-jsx';
const element = <p id="plain" />;
console.log(_jsx(), element.type);
`,
    });
    cleanup = fx.cleanup;
    const outdir = join(fx.dir, 'dist');
    const result = await runZntc([
      '--bundle',
      join(fx.dir, 'app.tsx'),
      '--outdir',
      outdir,
      '--preserve-modules',
      `--preserve-modules-root=${fx.dir}`,
      '--platform=node',
      '--format=esm',
      '--packages=external',
      '--jsx=automatic',
      '--minify-identifiers',
    ]);
    expect(result.exitCode, result.stderr).toBe(0);
    const out = join(outdir, 'app.js');
    const code = await readFile(out, 'utf8');
    expect(code).toContain('import { jsx as _jsx$1 } from "react/jsx-runtime";');
    expect(code).toContain('_jsx$1("p"');
    expect(code).toContain('_jsx()');

    // Preserve-modules currently adds a redundant package side-effect import
    // using a non-portable absolute path. Normalize only that specifier in a
    // temporary runtime copy so the oracle exercises the generated binding and
    // call names above against the fixture's local React package.
    const runtimeOut = join(outdir, 'app-runtime.js');
    const runtimeCode = code.replace(
      /^import "(?:\.\.\/)+react\/jsx-runtime\.js";\n/m,
      'import "react/jsx-runtime";\n',
    );
    expect(runtimeCode).not.toBe(code);
    await writeFile(runtimeOut, runtimeCode);
    const runtime = spawnSync('node', [runtimeOut], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe('user-jsx p\n');
  });

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
