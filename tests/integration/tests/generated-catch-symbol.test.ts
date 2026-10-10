import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

describe('generated optional catch binding (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const bundled of [false, true]) {
    test(`${bundled ? 'bundle' : 'single-file'} preserves outer _a through separate catches`, async () => {
      const fixture = await createFixture({
        'input.mjs': `
const _a = 9;
try { throw 1; } catch { console.log('one', _a); }
try { throw 2; } catch { console.log('two', _a); }
`,
      });
      cleanup = fixture.cleanup;
      const out = join(fixture.dir, 'out.cjs');
      const args = [
        ...(bundled ? ['--bundle'] : []),
        'input.mjs',
        '--target=es5',
        '--minify-identifiers',
        '--minify-syntax',
        ...(bundled ? ['--platform=node', '--format=cjs'] : []),
        '-o',
        out,
      ];
      const result = await runZntcInDir(fixture.dir, args);
      expect(result.exitCode).toBe(0);
      const runtime = spawnSync('node', [out], { encoding: 'utf8' });
      expect(runtime.status).toBe(0);
      expect(runtime.stdout.trim()).toBe('one 9\ntwo 9');
    });

    test(`${bundled ? 'bundle' : 'single-file'} does not shadow undeclared global _a`, async () => {
      const fixture = await createFixture({
        'input.mjs': `
globalThis._a = 9;
try { throw 1; } catch { console.log(_a); }
`,
      });
      cleanup = fixture.cleanup;
      const out = join(fixture.dir, 'out.cjs');
      const args = [
        ...(bundled ? ['--bundle'] : []),
        'input.mjs',
        '--target=es5',
        '--minify-identifiers',
        '--minify-syntax',
        ...(bundled ? ['--platform=node', '--format=cjs'] : []),
        '-o',
        out,
      ];
      const result = await runZntcInDir(fixture.dir, args);
      expect(result.exitCode).toBe(0);
      const runtime = spawnSync('node', [out], { encoding: 'utf8' });
      expect(runtime.status).toBe(0);
      expect(runtime.stdout.trim()).toBe('9');
    });
  }

  test('single-file non-minified catch names are selected from final SymbolIds', async () => {
    const fixture = await createFixture({
      'input.mjs': `
const _unused = 9;
const _unused2 = 8;
try { throw 1; } catch { console.log(_unused, _unused2); }
`,
    });
    cleanup = fixture.cleanup;
    const out = join(fixture.dir, 'out.cjs');
    const result = await runZntcInDir(fixture.dir, ['input.mjs', '--target=es5', '-o', out]);
    expect(result.exitCode).toBe(0);
    const output = readFileSync(out, 'utf8');
    expect(output).toMatch(/catch\s*\(_unused3\)/);
    const runtime = spawnSync('node', [out], { encoding: 'utf8' });
    expect(runtime.status).toBe(0);
    expect(runtime.stdout.trim()).toBe('9 8');
  });

  test('each single-file catch gets a distinct late SymbolId name', async () => {
    const fixture = await createFixture({
      'input.mjs': `
try { throw 1; } catch { console.log(1); }
try { throw 2; } catch { console.log(2); }
`,
    });
    cleanup = fixture.cleanup;
    const out = join(fixture.dir, 'out.cjs');
    const result = await runZntcInDir(fixture.dir, ['input.mjs', '--target=es5', '-o', out]);
    expect(result.exitCode).toBe(0);
    const output = readFileSync(out, 'utf8');
    expect(output).toMatch(/catch\s*\(_unused\)/);
    expect(output).toMatch(/catch\s*\(_unused2\)/);
    const runtime = spawnSync('node', [out], { encoding: 'utf8' });
    expect(runtime.status).toBe(0);
    expect(runtime.stdout.trim()).toBe('1\n2');
  });

  test('direct eval string names remain visible across generated catch bindings', async () => {
    const evalExpressions = [
      ['plain', 'eval("_a")'],
      ['escaped', 'eval("\\\\u005fa")'],
    ] as const;
    for (const [label, expression] of evalExpressions) {
      const fixture = await createFixture({
        'input.mjs': `
globalThis["_a"] = 9;
try { throw 1; } catch { console.log(${expression}); }
`,
      });
      cleanup = fixture.cleanup;
      const out = join(fixture.dir, `out-${label}.cjs`);
      const result = await runZntcInDir(fixture.dir, ['input.mjs', '--target=es5', '-o', out]);
      expect(result.exitCode).toBe(0);
      expect(readFileSync(out, 'utf8')).toMatch(/catch\s*\(_b\)/);
      const runtime = spawnSync('node', [out], { encoding: 'utf8' });
      expect(runtime.status).toBe(0);
      expect(runtime.stdout.trim()).toBe('9');
      await cleanup?.();
      cleanup = undefined;
    }
  });

  test('catch lowering preserves dynamic with lookup', async () => {
    const fixture = await createFixture({
      'input.js': `
const object = { _a: 9 };
with (object) {
  try { throw 1; } catch { console.log(_a); }
}
`,
    });
    cleanup = fixture.cleanup;
    const out = join(fixture.dir, 'out.cjs');
    const result = await runZntcInDir(fixture.dir, ['input.js', '--target=es5', '-o', out]);
    expect(result.exitCode).toBe(0);
    const runtime = spawnSync('node', [out], { encoding: 'utf8' });
    expect(runtime.status).toBe(0);
    expect(runtime.stdout.trim()).toBe('9');
  });
});
