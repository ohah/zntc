import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

describe('retained computed class accessor symbols (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  test('escaped static string accessor values retain exact setter identity and runtime behavior', async () => {
    const fixture = await createFixture({
      'input.js': `var _key = 'source-key';
class Box {
  get ['value']() { return this._stored + ':' + _key; }
  set ["v\\u0061lue"](value = 1) { this._stored = value; }
}
const box = new Box();
box.value = undefined;
console.log(box.value, _key);
box.value = null;
console.log(box.value, _key);`,
    });
    cleanup = fixture.cleanup;

    const native = spawnSync('node', ['input.js'], { cwd: fixture.dir, encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);

    const output = join(fixture.dir, 'out.cjs');
    const transformed = spawnSync(
      ZNTC_BIN,
      ['--bundle', 'input.js', '--target=es5', '--platform=node', '--format=cjs', '-o', output],
      {
        cwd: fixture.dir,
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      },
    );
    expect(transformed.status, transformed.stderr).toBe(0);

    const mode = transformed.stderr
      .split(/\r?\n/)
      .find(
        (line) =>
          line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('input.js'),
      );
    expect(mode, transformed.stderr).toContain('semantic_graph=retained');
    const report = transformed.stderr
      .split(/\r?\n/)
      .find(
        (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('input.js'),
      );
    expect(report, transformed.stderr).toMatch(/clean=1(?:\s|$)/);

    const actual = spawnSync('node', [output], { cwd: fixture.dir, encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe(native.stdout);
  });

  test('dynamic class accessor keys preserve evaluation order', async () => {
    const fixture = await createFixture({
      'input.js': `let calls = 0;
function nextKey() { calls++; return 'value'; }
class Box {
  get [nextKey()]() { return this._stored; }
  set [nextKey()](value = 1) { this._stored = value; }
}
const box = new Box();
box.value = undefined;
console.log(calls, box.value);`,
    });
    cleanup = fixture.cleanup;

    const native = spawnSync('node', ['input.js'], { cwd: fixture.dir, encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);

    const output = join(fixture.dir, 'out.cjs');
    const transformed = spawnSync(
      ZNTC_BIN,
      ['--bundle', 'input.js', '--target=es5', '--platform=node', '--format=cjs', '-o', output],
      {
        cwd: fixture.dir,
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      },
    );
    expect(transformed.status, transformed.stderr).toBe(0);

    const actual = spawnSync('node', [output], { cwd: fixture.dir, encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe(native.stdout);
  });

  test('a shadowed Object binding does not capture class accessor helpers', async () => {
    const fixture = await createFixture({
      'input.js': `var Object;
var _key = 'source-key';
class Box {
  get ['value']() { return this._stored + ':' + _key; }
  set ["v\\u0061lue"](value = 1) { this._stored = value; }
}
const box = new Box();
box.value = undefined;
console.log(typeof Object, box.value, _key);`,
    });
    cleanup = fixture.cleanup;

    const native = spawnSync('node', ['input.js'], { cwd: fixture.dir, encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);

    const output = join(fixture.dir, 'out.cjs');
    const transformed = spawnSync(
      ZNTC_BIN,
      ['--bundle', 'input.js', '--target=es5', '--platform=node', '--format=cjs', '-o', output],
      {
        cwd: fixture.dir,
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      },
    );
    expect(transformed.status, transformed.stderr).toBe(0);
    const mode = transformed.stderr
      .split(/\r?\n/)
      .find(
        (line) =>
          line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('input.js'),
      );
    expect(mode, transformed.stderr).toContain('semantic_graph=retained');
    const report = transformed.stderr
      .split(/\r?\n/)
      .find(
        (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('input.js'),
      );
    expect(report, transformed.stderr).toContain('shadowed_external_reference=2');
    expect(report, transformed.stderr).toMatch(/clean=0(?:\s|$)/);
    const observationFields = new Set([
      'generated_bindings',
      'generated_references',
      'generated_scope_owners_checked',
      'external',
      'declaration_anchors_checked',
      'invariant_counter_count',
      'observation_field_count',
      'diagnostic_field_count',
      'shadowed_external_reference',
      'clean',
    ]);
    const nonzeroInvariantFields = Array.from(
      report?.matchAll(/(?:^|\s)([a-z_]+)=([0-9]+)(?=\s|$)/g) ?? [],
    )
      .filter(([, name, value]) => !observationFields.has(name) && Number(value) !== 0)
      .map(([, name, value]) => `${name}=${value}`);
    expect(nonzeroInvariantFields, report).toEqual([]);

    const actual = spawnSync('node', [output], { cwd: fixture.dir, encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe(native.stdout);
  });

  test(
    'buildSync onTransform retains shadowed computed accessor helpers through minification',
    { timeout: 30_000 },
    () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-buildsync-computed-accessor-'));
      const entry = join(dir, 'entry.js');
      const nativeEntry = join(dir, 'native.js');
      const source = `var Object;
var _key = 'source-key';
class Box {
  get ['value']() { return this._stored + ':' + _key; }
  set ["v\\u0061lue"](value = 1) { this._stored = value; }
}
const box = new Box();
box.value = undefined;
console.log(typeof Object, box.value, _key);`;
      writeFileSync(entry, '// buildSync onTransform supplies JavaScript source');
      writeFileSync(nativeEntry, source);
      const reportedEntry = realpathSync(entry);
      const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
      const runner = [
        `import {buildSync} from ${JSON.stringify(coreEntry)};`,
        `const entry=${JSON.stringify(entry)};const source=${JSON.stringify(source)};const calls=[];`,
        `const result=buildSync({entryPoints:[entry],platform:'node',format:'cjs',target:'es5',minifyWhitespace:true,minifySyntax:true,minifyIdentifiers:true,write:false,plugins:[{name:'buildsync-computed-accessor',setup(api){api.onTransform({filter:/entry\\.js$/},args=>{calls.push(args.path);return {code:source};});}}]});`,
        'if(result.errors.length){console.error(JSON.stringify(result.errors));process.exit(1);}',
        'process.stdout.write(JSON.stringify({calls,outputs:result.outputFiles.map(file=>file.text)}));',
      ].join('\n');

      try {
        const run = Bun.spawnSync(['bun', '-e', runner], {
          cwd: join(import.meta.dir, '../../..'),
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        });
        const stderr = run.stderr.toString();
        expect(run.exitCode, stderr).toBe(0);
        const result = JSON.parse(run.stdout.toString()) as {
          calls: string[];
          outputs: string[];
        };
        expect(result.calls).toEqual([reportedEntry]);
        expect(result.outputs).toHaveLength(1);

        const output = join(dir, 'out.cjs');
        writeFileSync(output, result.outputs[0]);
        const native = spawnSync('node', [nativeEntry], { encoding: 'utf8' });
        expect(native.status, native.stderr).toBe(0);
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, actual.stderr).toBe(0);
        expect(actual.stdout).toBe(native.stdout);

        const lines = stderr.split(/\r?\n/);
        const mode = lines.find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes(reportedEntry),
        );
        expect(mode, stderr).toContain('semantic_graph=retained');
        const report = lines.find(
          (line) =>
            line.startsWith('zntc: symbol-identity-prepass ') && line.includes(reportedEntry),
        );
        expect(report, stderr).toContain('shadowed_external_reference=2');
        expect(report, stderr).toMatch(/clean=0(?:\s|$)/);
        const observationFields = new Set([
          'generated_bindings',
          'generated_references',
          'generated_scope_owners_checked',
          'external',
          'declaration_anchors_checked',
          'invariant_counter_count',
          'observation_field_count',
          'diagnostic_field_count',
          'shadowed_external_reference',
          'clean',
        ]);
        const nonzeroInvariantFields = Array.from(
          report?.matchAll(/(?:^|\s)([a-z_]+)=([0-9]+)(?=\s|$)/g) ?? [],
        )
          .filter(([, name, value]) => !observationFields.has(name) && Number(value) !== 0)
          .map(([, name, value]) => `${name}=${value}`);
        expect(nonzeroInvariantFields, report).toEqual([]);
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    },
  );
});
