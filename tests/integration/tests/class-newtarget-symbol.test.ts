import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { bundleAndRun, createFixture, ZNTC_BIN } from './helpers';

describe('ES5 class new.target symbols (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  test('explicit and default derived constructors receive distinct final names', async () => {
    const fixture = await createFixture({
      'input.js': `
var _newTarget = 'outer';
function Base() { this.target = new.target; }
class Explicit extends Base { constructor() { super(); } }
class Default extends Base {}
console.log(new Explicit().target === Explicit, new Default().target === Default, _newTarget);
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const proc = spawnSync(ZNTC_BIN, ['input.js', '--target=es5', '-o', output], {
      cwd: fixture.dir,
      env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
      encoding: 'utf8',
    });
    expect(proc.status, proc.stderr).toBe(0);

    const report = (proc.stderr ?? '')
      .split(/\r?\n/)
      .find((line) => line.startsWith('zntc: symbol-identity ') && line.includes('input.js'));
    expect(report, proc.stderr).toMatch(/clean=1(?:\s|$)/);
    expect(report, proc.stderr).toMatch(/missing_binding=0(?:\s|$)/);
    expect(report, proc.stderr).toMatch(/missing_reference=0(?:\s|$)/);

    const code = readFileSync(output, 'utf8');
    const names = [...code.matchAll(/var (_newTarget\d*) = this\.constructor;/g)].map(
      (match) => match[1],
    );
    expect(names).toHaveLength(2);
    expect(new Set(names).size).toBe(2);
    expect(names).not.toContain('_newTarget');

    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe('true true outer\n');
  });

  test('direct eval cannot observe a generated new.target local', async () => {
    const fixture = await createFixture({
      'input.js': `
var _newTarget = 'outer';
function Base() {}
class Dynamic extends Base {
  constructor(value = eval('typeof _newTarget2')) {
    super();
    this.outer = _newTarget;
    this.seen = value + ':' + eval('typeof _newTarget2');
  }
}
console.log(new Dynamic().outer, new Dynamic().seen, _newTarget);
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const proc = spawnSync(ZNTC_BIN, ['input.js', '--target=es5', '-o', output], {
      cwd: fixture.dir,
      env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
      encoding: 'utf8',
    });
    expect(proc.status, proc.stderr).toBe(0);

    const code = readFileSync(output, 'utf8');
    expect(code).not.toMatch(/var _newTarget2\b/);

    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe('outer undefined:undefined outer\n');
  });

  test('bundled derived constructors keep generated names out of direct eval', async () => {
    const result = await bundleAndRun(
      {
        'index.ts': `
var _newTarget = 'outer';
class Base {}
class Dynamic extends Base {
  constructor(value = eval('typeof _newTarget2')) {
    super();
    this.outer = _newTarget;
    this.seen = value + ':' + eval('typeof _newTarget2');
  }
}
console.log(new Dynamic().outer, new Dynamic().seen, _newTarget);
`,
      },
      'index.ts',
      ['--target=es5'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode, result.runStderr).toBe(0);
    expect(result.runOutput).toBe('outer undefined:undefined outer');
  });
});
