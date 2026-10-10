import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { bundleAndRun, createFixture, ZNTC_BIN } from './helpers';

describe('lexical new.target capture symbols (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  test('direct eval cannot observe the generated lexical capture', async () => {
    const fixture = await createFixture({
      'input.js': `
function Outer(_newTarget, value = eval('typeof _newTarget2')) {
  this.read = () => [new.target === Outer, value, eval('typeof _newTarget2')];
}
console.log(new Outer('parameter').read().join(':'));
`,
    });
    cleanup = fixture.cleanup;
    for (const extraArgs of [[], ['--minify-identifiers']]) {
      const output = join(fixture.dir, `out-${extraArgs.length}.js`);
      const proc = spawnSync(ZNTC_BIN, ['input.js', '--target=es5', ...extraArgs, '-o', output], {
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
      expect(code).not.toMatch(/var _newTarget2\b/);

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe('true:undefined:undefined\n');
    }
  });

  test('each safe function capture receives its own final name', async () => {
    const fixture = await createFixture({
      'input.js': `
var _newTarget = 'outer';
function First() { this.read = () => new.target === First; }
function Second() { this.read = () => new.target === Second; }
console.log(new First().read(), new Second().read(), _newTarget);
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const proc = spawnSync(ZNTC_BIN, ['input.js', '--target=es5', '-o', output], {
      cwd: fixture.dir,
      encoding: 'utf8',
    });
    expect(proc.status, proc.stderr).toBe(0);

    const code = readFileSync(output, 'utf8');
    const names = [...code.matchAll(/var (_newTarget\d*) = this instanceof/g)].map(
      (match) => match[1],
    );
    expect(names).toHaveLength(2);
    expect(new Set(names).size).toBe(2);
    expect(names).not.toContain('_newTarget');

    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe('true true outer\n');
  });

  test('bundle linking preserves lexical new.target capture symbols', async () => {
    const result = await bundleAndRun(
      {
        'index.ts': `
var _newTarget = 'outer';
function First() { this.read = () => new.target === First; }
function Second() { this.read = () => new.target === Second; }
console.log(new First().read(), new Second().read(), _newTarget);
`,
      },
      'index.ts',
      ['--target=es5', '--minify-identifiers'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode, result.runStderr).toBe(0);
    expect(result.runOutput).toBe('true true outer');
  });

  test('bundled direct eval keeps new.target lowering on semantic reanalysis', async () => {
    const result = await bundleAndRun(
      {
        'index.ts': `
function Outer(_newTarget, value = eval('typeof _newTarget2')) {
  this.read = () => [new.target === Outer, value, eval('typeof _newTarget2')];
}
console.log(new Outer('parameter').read().join(':'));
`,
      },
      'index.ts',
      ['--target=es5', '--platform=node', '--format=cjs'],
      { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
    );
    cleanup = result.cleanup;

    expect(result.bundleStderr).toContain('semantic_graph=reanalyzed');
    expect(result.exitCode, result.runStderr).toBe(0);
    expect(result.runOutput).toBe('true:undefined:undefined');
  });
});
