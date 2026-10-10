import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

describe('generator state parameter symbols (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  test('standalone callbacks get final names per exact SymbolId and keep their references', async () => {
    const fixture = await createFixture({
      'input.js': `
function* first(value) { yield value; }
function* second(value) { yield value + 1; }
async function asyncCall(value) { await value; return value + 2; }
const asyncArrow = async value => { await value; return value + 4; };
class Box { async method(value) { await value; return value + 3; } }
Promise.all([
  Promise.resolve(first(10).next().value),
  Promise.resolve(second(20).next().value),
  asyncCall(30),
  new Box().method(40),
  asyncArrow(50),
]).then(values => console.log(...values));
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
    const stateNames = [...code.matchAll(/function\((_state\d*)\)\s*\{/g)].map((match) => match[1]);
    expect(stateNames).toEqual(['_state', '_state2', '_state3', '_state4', '_state5']);
    expect(code).toContain('switch (_state.label)');
    expect(code).toContain('switch (_state2.label)');

    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe('10 21 32 43 54\n');
  });

  test('direct eval string identifiers stay reserved in the conservative path', async () => {
    const fixture = await createFixture({
      'input.js': `
var _state = 'outer';
function* dynamic() { yield eval('typeof _state2'); }
console.log(dynamic().next().value);
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
    expect(code).toMatch(/function\(_state3\)\s*\{/);

    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe('undefined\n');
  });
});
