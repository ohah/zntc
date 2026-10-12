import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5570: lowering top-level await split a module into an async IIFE plus the
// export declarations after it. Code before the first await read exports in
// their TDZ, exported functions/classes could not see the wrapped locals
// (`const config = await …; export function useX() { return config.x }`),
// and side effects ran out of order. ESM bundles with async functions now
// evaluate the module in its async `__esm` factory unsplit; other builds keep
// export declarations before the first await ahead of the wrapper.
const sameModule = {
  'export read before the first await': `export const f = async () => await 1;
console.log(await f());`,
  'exported class read before the first await': `export class K { static x = 2; }
console.log(await Promise.resolve(K.x));`,
  'exported let updated before the first await': `export let n = 3;
n++;
console.log(await Promise.resolve(n));`,
  'side effects around an export': `console.log('a');
export const x = (console.log('b'), 1);
console.log(await Promise.resolve(x));
console.log('c');`,
  'exported function reading a local': `const k = 7;
export function g() { return k; }
console.log(await Promise.resolve(g()));`,
  'exported class reading a local': `const k = 7;
export class K { static v = k; }
console.log(await Promise.resolve(K.v));`,
} as const;

// Only async `__esm` factories keep these exact: the IIFE path cannot defer
// an export past the first await or hoist a wrapped function out of it.
const factoryOnly = {
  'export after the first await keeps its side-effect order': `await 0;
console.log('a');
export const y = (console.log('b'), 1);
console.log('c', y);`,
  'export calling a function declared after the first await': `export const x = helper();
await 0;
function helper() { return 3; }
console.log(x);`,
} as const;

const variants = [
  { label: 'esm es2019', args: ['--format=esm', '--target=es2019'], factory: true },
  { label: 'esm es2017', args: ['--format=esm', '--target=es2017'], factory: true },
  {
    label: 'esm es2019 minify',
    args: ['--format=esm', '--target=es2019', '--minify'],
    factory: true,
  },
  { label: 'esm es2016', args: ['--format=esm', '--target=es2016'], factory: false },
  { label: 'cjs es2019', args: ['--format=cjs', '--target=es2019'], factory: false },
  { label: 'iife es2016', args: ['--format=iife', '--target=es2016'], factory: false },
] as const;

describe('top-level await keeps export order and scope (#5570)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  async function run(files: Record<string, string>, entry: string, args: readonly string[]) {
    const created = await createFixture(files);
    cleanup = created.cleanup;
    const native = spawnSync('node', [join(created.dir, entry)], { encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);
    const out = join(created.dir, args[0] === '--format=esm' ? 'out.mjs' : 'out.cjs');
    const result = await runZntc(['--bundle', join(created.dir, entry), ...args, '-o', out]);
    expect(result.exitCode, result.stderr).toBe(0);
    const bundled = spawnSync('node', [out], { encoding: 'utf8' });
    expect(bundled.status, bundled.stderr).toBe(0);
    expect(bundled.stdout).toBe(native.stdout);
    return out;
  }

  for (const variant of variants) {
    const cases = variant.factory ? { ...sameModule, ...factoryOnly } : sameModule;
    for (const [name, source] of Object.entries(cases)) {
      test(`${name}, ${variant.label}`, async () => {
        await run({ 'entry.mjs': source }, 'entry.mjs', variant.args);
      });
    }
  }

  for (const variant of variants.filter((v) => v.factory)) {
    test(`a dependency's exports read its awaited locals, ${variant.label}`, async () => {
      await run(
        {
          'config.mjs': `const config = await Promise.resolve({ x: 1 });
export function useX() { return config.x; }
export class Svc { get() { return config.x; } }
console.log('config ready');`,
          'entry.mjs': `import { useX, Svc } from './config.mjs';
console.log(useX(), new Svc().get());`,
        },
        'entry.mjs',
        variant.args,
      );
    });

    // The bundle targets an engine without top-level await: the entry starts
    // its async init without awaiting it at the top level.
    test(`no top-level await in a wrapped bundle, ${variant.label}`, async () => {
      const out = await run(
        {
          'dep.mjs': 'export const v = { n: await Promise.resolve(41) };',
          'entry.mjs': "import { v } from './dep.mjs';\nconsole.log(v.n + 1);",
        },
        'entry.mjs',
        variant.args,
      );
      const code = await Bun.file(out).text();
      for (const line of code.split('\n')) {
        if (line.length === 0 || line[0] === ' ' || line[0] === '\t') continue;
        expect(line).not.toMatch(/(^|;)await /);
      }
    });
  }
});
