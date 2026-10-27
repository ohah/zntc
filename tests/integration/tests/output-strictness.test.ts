import { afterEach, describe, expect, test } from 'bun:test';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, runNode, runZntc } from './helpers';

// #5455: the output's strictness must match the bundled modules. A file-level
// "use strict" for cjs output would turn a sloppy CommonJS dependency strict
// (esbuild/rolldown never force it), and ESM output cannot contain `with`
// (esbuild reports the same build error).
describe('bundle output strictness (#5455)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  test('cjs output keeps a sloppy CommonJS dependency sloppy', async () => {
    const fixture = await createFixture({
      'dep.cjs': 'with ({ v: 1 }) { module.exports = v; }',
      'entry.mjs': "import v from './dep.cjs'; console.log(v);",
    });
    cleanup = fixture.cleanup;
    const out = join(fixture.dir, 'out.cjs');
    const result = await runZntc([
      '--bundle',
      join(fixture.dir, 'entry.mjs'),
      '--format=cjs',
      '-o',
      out,
    ]);
    expect(result.exitCode, result.stderr).toBe(0);
    expect(readFileSync(out, 'utf8').startsWith('"use strict"')).toBe(false);
    expect((await runNode(out)).stdout.trim()).toBe('1');
  });

  test('cjs output of only strict modules keeps the directive', async () => {
    const fixture = await createFixture({
      'a.mjs': 'export const f = function () { return this === undefined; };',
      'entry.mjs': "import { f } from './a.mjs'; console.log(f());",
    });
    cleanup = fixture.cleanup;
    const out = join(fixture.dir, 'out.cjs');
    const result = await runZntc([
      '--bundle',
      join(fixture.dir, 'entry.mjs'),
      '--format=cjs',
      '-o',
      out,
    ]);
    expect(result.exitCode, result.stderr).toBe(0);
    expect(readFileSync(out, 'utf8').startsWith('"use strict"')).toBe(true);
    expect((await runNode(out)).stdout.trim()).toBe('true');
  });

  test('esm output warns about a with statement', async () => {
    const fixture = await createFixture({
      'dep.cjs': 'with ({ v: 1 }) { module.exports = v; }',
      'entry.mjs': "import v from './dep.cjs'; console.log(v);",
    });
    cleanup = fixture.cleanup;
    const result = await runZntc([
      '--bundle',
      join(fixture.dir, 'entry.mjs'),
      '--format=esm',
      '-o',
      join(fixture.dir, 'out.mjs'),
    ]);
    expect(result.exitCode, result.stderr).toBe(0);
    expect(result.stderr).toContain('ZNTC0800');
    expect(result.stderr).toContain('With statements cannot be used with the "esm" output format');
  });
});

describe('standalone CJS output strictness', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  test('module input stays strict after conversion to CJS', async () => {
    const fixture = await createFixture({ 'input.mjs': '' });
    const runtimeFile = join(fixture.dir, 'runtime.json');
    writeFileSync(
      join(fixture.dir, 'input.mjs'),
      `"use client";
export {};
function f({...props}) {
  try { return [this === undefined, arguments.callee]; }
  catch (e) { return [this === undefined, e.name]; }
}
const result = f({});
console.log(JSON.stringify(result));
require('node:fs').writeFileSync(${JSON.stringify(runtimeFile)}, JSON.stringify(result));
`,
    );
    cleanup = fixture.cleanup;
    const out = join(fixture.dir, 'out.cjs');
    const result = await runZntc(['--format=cjs', join(fixture.dir, 'input.mjs'), '-o', out]);
    expect(result.exitCode, result.stderr).toBe(0);
    expect(readFileSync(out, 'utf8').startsWith('"use client";\n"use strict";')).toBe(true);
    await runNode(out);
    expect(readFileSync(join(fixture.dir, 'runtime.json'), 'utf8')).toBe('[true,"TypeError"]');
  });

  test('explicit strict directive is not duplicated and stays after the hashbang', async () => {
    const fixture = await createFixture({
      'input.mjs':
        '#!/usr/bin/env node\n"use strict";\nexport {};\nfunction f(){return this===undefined}\n',
    });
    cleanup = fixture.cleanup;
    const out = join(fixture.dir, 'out.cjs');
    const result = await runZntc(['--format=cjs', join(fixture.dir, 'input.mjs'), '-o', out]);
    expect(result.exitCode, result.stderr).toBe(0);
    const generated = readFileSync(out, 'utf8');
    expect(generated.startsWith('#!/usr/bin/env node\n"use strict";')).toBe(true);
    expect(generated.match(/"use strict"/g)).toHaveLength(1);
  });

  test('strict directive stays ahead of a late keep-names helper', async () => {
    const fixture = await createFixture({ 'input.mjs': '' });
    const runtimeFile = join(fixture.dir, 'runtime.json');
    writeFileSync(
      join(fixture.dir, 'input.mjs'),
      `export {};
const Original = function() { return this === undefined; };
const result = [Original.name, Original()];
require('node:fs').writeFileSync(${JSON.stringify(runtimeFile)}, JSON.stringify(result));
`,
    );
    cleanup = fixture.cleanup;
    const out = join(fixture.dir, 'out.cjs');
    const result = await runZntc([
      '--format=cjs',
      '--keep-names',
      '--minify-identifiers',
      join(fixture.dir, 'input.mjs'),
      '-o',
      out,
    ]);
    expect(result.exitCode, result.stderr).toBe(0);
    const generated = readFileSync(out, 'utf8');
    expect(generated.startsWith('"use strict";')).toBe(true);
    expect(generated.indexOf('var __name')).toBeGreaterThan(generated.indexOf('"use strict";'));
    await runNode(out);
    expect(readFileSync(runtimeFile, 'utf8')).toBe('["Original",true]');
  });

  test('minified CJS keeps module input strict', async () => {
    const fixture = await createFixture({ 'input.mjs': '' });
    const runtimeFile = join(fixture.dir, 'runtime.json');
    writeFileSync(
      join(fixture.dir, 'input.mjs'),
      `export {};
function f() { return this === undefined; }
const result = f();
require('node:fs').writeFileSync(${JSON.stringify(runtimeFile)}, JSON.stringify(result));
`,
    );
    cleanup = fixture.cleanup;
    const out = join(fixture.dir, 'out.cjs');
    const result = await runZntc([
      '--format=cjs',
      '--minify',
      join(fixture.dir, 'input.mjs'),
      '-o',
      out,
    ]);
    expect(result.exitCode, result.stderr).toBe(0);
    expect(readFileSync(out, 'utf8').startsWith('"use strict";')).toBe(true);
    await runNode(out);
    expect(readFileSync(runtimeFile, 'utf8')).toBe('true');
  });

  test('TypeScript script input stays strict without module syntax', async () => {
    const fixture = await createFixture({ 'input.ts': '' });
    const runtimeFile = join(fixture.dir, 'runtime.json');
    writeFileSync(
      join(fixture.dir, 'input.ts'),
      `function f() { return this === undefined; }
const result = f();
require('node:fs').writeFileSync(${JSON.stringify(runtimeFile)}, JSON.stringify(result));
`,
    );
    cleanup = fixture.cleanup;
    const out = join(fixture.dir, 'out.cjs');
    const result = await runZntc(['--format=cjs', join(fixture.dir, 'input.ts'), '-o', out]);
    expect(result.exitCode, result.stderr).toBe(0);
    expect(readFileSync(out, 'utf8').startsWith('"use strict";')).toBe(true);
    await runNode(out);
    expect(readFileSync(runtimeFile, 'utf8')).toBe('true');
  });

  test('script input remains sloppy after conversion to CJS', async () => {
    const fixture = await createFixture({ 'input.cjs': '' });
    const runtimeFile = join(fixture.dir, 'runtime.json');
    writeFileSync(
      join(fixture.dir, 'input.cjs'),
      `function f() { return [this === undefined, typeof arguments.callee]; }
const result = f();
console.log(JSON.stringify(result));
require('node:fs').writeFileSync(${JSON.stringify(runtimeFile)}, JSON.stringify(result));
`,
    );
    cleanup = fixture.cleanup;
    const out = join(fixture.dir, 'out.cjs');
    const result = await runZntc(['--format=cjs', join(fixture.dir, 'input.cjs'), '-o', out]);
    expect(result.exitCode, result.stderr).toBe(0);
    expect(readFileSync(out, 'utf8').startsWith('"use strict"')).toBe(false);
    await runNode(out);
    expect(readFileSync(join(fixture.dir, 'runtime.json'), 'utf8')).toBe('[false,"function"]');
  });
});
