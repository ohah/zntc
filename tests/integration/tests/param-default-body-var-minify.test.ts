import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5652: a parameter default reads the outer binding even when the body
// declares a same-named `var` — the parameter list has its own environment.
// The transformer copied the retained (non-simple) parameter list without its
// scope owner, so the output walk resolved the default in the body scope and
// rebound it to the body `var`. Identifier minification then renamed the two
// apart (`function f(n = t) { var t }` → ReferenceError) and bundling dropped
// the outer declaration. Node prints the expected output.
const wrap = (body: string) => `export function make() {
  var outerLongName = 3;
${body}
}
Promise.resolve(make()).then((r) => console.log(JSON.stringify(r)));`;

const cases = {
  'function declaration': wrap(
    "  function f(value = outerLongName) { var outerLongName = 'inner'; return [value, outerLongName]; }\n  return f();",
  ),
  'object method': wrap(
    "  const o = { m(value = outerLongName) { var outerLongName = 'inner'; return [value, outerLongName]; } };\n  return o.m();",
  ),
  'class constructor': wrap(
    "  class K { constructor(value = outerLongName) { var outerLongName = 'inner'; this.r = [value, outerLongName]; } }\n  return new K().r;",
  ),
  'destructuring default': wrap(
    "  function f({ value = outerLongName } = {}) { var outerLongName = 'inner'; return [value, outerLongName]; }\n  return f();",
  ),
  'default with a rest parameter': wrap(
    "  function f(value = outerLongName, ...rest) { var outerLongName = 'inner'; return [value, outerLongName]; }\n  return f(undefined, 1);",
  ),
  'async function': wrap(
    "  async function f(value = outerLongName) { var outerLongName = 'inner'; return [value, outerLongName]; }\n  return f();",
  ),
  'block let in the body': wrap(
    "  function f(value = outerLongName) { let outerLongName = 'inner'; return [value, outerLongName]; }\n  return f();",
  ),
} as const;

describe('parameter defaults keep the outer binding under minification (#5652)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  const modes: { label: string; args: string[] }[] = [
    { label: 'es2015, minify identifiers', args: ['--target=es2015', '--minify-identifiers'] },
    { label: 'esnext, minify', args: ['--target=esnext', '--minify'] },
    { label: 'es5, minify', args: ['--target=es5', '--minify'] },
    { label: 'bundle, minify', args: ['--bundle', '--format=esm', '--minify'] },
  ];
  for (const { label, args } of modes) {
    for (const [name, source] of Object.entries(cases)) {
      test(`${name}, ${label}`, async () => {
        const created = await createFixture({ 'entry.mjs': source });
        cleanup = created.cleanup;
        const out = join(created.dir, 'out.mjs');
        const result = await runZntc([join(created.dir, 'entry.mjs'), ...args, '-o', out]);
        expect(result.exitCode, result.stderr).toBe(0);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe('[3,"inner"]\n');
      });
    }
  }
});
