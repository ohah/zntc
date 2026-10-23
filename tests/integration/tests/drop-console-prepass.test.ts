import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, runNode, ZNTC_BIN } from './helpers';

describe('drop console graph pre-pass gate', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  async function bundle(source: string) {
    const fixture = await createFixture({ 'input.js': source });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'output.cjs');
    const result = spawnSync(
      ZNTC_BIN,
      [
        '--bundle',
        join(fixture.dir, 'input.js'),
        '-o',
        output,
        '--platform=node',
        '--format=cjs',
        '--drop=console',
      ],
      {
        cwd: fixture.dir,
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      },
    );
    expect(result.status, result.stderr).toBe(0);
    const code = readFileSync(output, 'utf8');
    const execution = await runNode(output);
    expect(execution.stderr).toBe('');
    return { code, stderr: result.stderr, stdout: execution.stdout };
  }

  test('module without a static console call skips the graph pre-pass', async () => {
    const result = await bundle('const answer = 41; process.stdout.write(String(answer + 1));');
    expect(result.stderr).not.toContain('zntc: symbol-identity-prepass-mode ');
    expect(result.stdout).toBe('42');
  });

  test('module with a static console call keeps the pre-pass and removes it', async () => {
    const result = await bundle(
      "console.log('remove me'); const answer = 41; process.stdout.write(String(answer + 1));",
    );
    expect(result.stderr).toContain('zntc: symbol-identity-prepass-mode ');
    expect(result.code).not.toContain('console.log');
    expect(result.stdout).toBe('42');
  });

  test('unresolved global console literal calls keep the retained graph', async () => {
    const result = await bundle(
      'console.log("remove me", 1, true); const answer = 41; process.stdout.write(String(answer + 1));',
    );
    expect(result.stderr).toContain('zntc: symbol-identity-prepass-mode ');
    expect(result.code).not.toContain('console.log');
    expect(result.stdout).toBe('42');
  });

  test('static computed console string calls keep the retained graph', async () => {
    const local = await bundle(
      'const console = {}; console["log"]("remove me", 1, true); const answer = 41; process.stdout.write(String(answer + 1));',
    );
    expect(local.stderr).toContain('zntc: symbol-identity-prepass-mode ');
    expect(local.code).not.toContain('console["log"]');
    expect(local.stdout).toBe('42');

    const unresolved = await bundle(
      'console[\'log\']("remove me", 1, true); const answer = 41; process.stdout.write(String(answer + 1));',
    );
    expect(unresolved.stderr).toContain('zntc: symbol-identity-prepass-mode ');
    expect(unresolved.code).not.toContain("console['log']");
    expect(unresolved.stdout).toBe('42');
  });

  test('no-substitution template keys and arguments keep the retained graph', async () => {
    const local = await bundle(
      'const console = {}; console[`log`](`remove me`); const answer = 41; process.stdout.write(String(answer + 1));',
    );
    expect(local.stderr).toContain('semantic_graph=retained');
    expect(local.code).not.toContain('console[`log`]');
    expect(local.stdout).toBe('42');

    const unresolved = await bundle(
      'console[`log`](`remove me`, 1, true); const answer = 41; process.stdout.write(String(answer + 1));',
    );
    expect(unresolved.stderr).toContain('semantic_graph=retained');
    expect(unresolved.code).not.toContain('console[`log`]');
    expect(unresolved.stdout).toBe('42');

    const dynamic_key = await bundle(
      'const console = { log(value) { process.stdout.write(value); } }; const prefix = ""; console[`${prefix}log`]("keep"); process.stdout.write("42");',
    );
    expect(dynamic_key.code).toContain('console');
    expect(dynamic_key.stderr).not.toContain('symbol-identity-prepass-mode');
    expect(dynamic_key.stdout).toBe('keep42');

    const dynamic_argument = await bundle(
      'const console = {}; function evaluate() { process.stdout.write("unexpected"); return 1; } console.log(`value ${evaluate()}`); process.stdout.write("42");',
    );
    expect(dynamic_argument.stderr).toContain('semantic_graph=reanalyzed');
    expect(dynamic_argument.stdout).toBe('42');
  });
});
