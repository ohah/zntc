import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

describe('ES5 class super parameter symbols (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  test('each class wrapper gets a final name for its exact super parameter symbol', async () => {
    const fixture = await createFixture({
      'input.js': `
var _super = 99;
function Base(value) { this.value = value; }
class First extends Base { constructor(value) { super(value); } }
class Second extends Base { constructor(value) { super(value); } }
const Expression = class extends Base { constructor(value) { super(value); } };
console.log(new First(10).value, new Second(20).value, new Expression(30).value, _super);
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
    const names = [...code.matchAll(/function\s*\((_super\d*)\)\s*\{/g)].map((match) => match[1]);
    expect(names).toEqual(['_super2', '_super3', '_super4']);

    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe('10 20 30 99\n');
  });

  test('direct eval strings reserve class wrapper parameter names', async () => {
    const fixture = await createFixture({
      'input.js': `
var _super = 99;
function Base() {}
class Dynamic extends Base { method() { return eval('typeof _super2'); } }
const DynamicExpression = class extends Base { method() { return eval('typeof _super2'); } };
console.log(new Dynamic().method(), new DynamicExpression().method());
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
    const code = readFileSync(output, 'utf8');
    expect(code).toMatch(/function\s*\((_super3)\)\s*\{/);
    expect(code.match(/function\s*\((_super3)\)\s*\{/g)).toHaveLength(2);

    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe('undefined undefined\n');
  });
});
