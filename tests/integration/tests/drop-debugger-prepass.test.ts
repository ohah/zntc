import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, runNode, ZNTC_BIN } from './helpers';

function expectCleanPrepassAudit(stderr: string, inputName: string) {
  const lines = stderr.replaceAll('\0', '\n').split(/\r?\n/);
  const mode = lines.find(
    (line) => line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes(inputName),
  );
  expect(mode, stderr).toContain('semantic_graph=retained');
  const report = lines.find(
    (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes(inputName),
  );
  expect(report, stderr).toBeDefined();
  for (const counter of [
    'invalid_id',
    'missing_reference',
    'identity_mismatch',
    'scope_map_mismatch',
    'scope_owner_mismatch',
    'scope_owner_parent_mismatch',
    'declaration_identity_mismatch',
  ]) {
    expect(
      Number(report?.match(new RegExp(`(?:^| )${counter}=(\\d+)(?:\\s|$)`))?.[1] ?? -1),
      `${counter}: ${report}`,
    ).toBe(0);
  }
  expect(report).toMatch(/clean=1(?:\s|$)/);
}

describe('drop debugger graph pre-pass gate', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  async function bundle(source: string, extraArgs: string[] = [], filename = 'input.js') {
    const fixture = await createFixture({ [filename]: source });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'output.cjs');
    const input = join(fixture.dir, filename);
    const result = spawnSync(
      ZNTC_BIN,
      [
        '--bundle',
        input,
        '-o',
        output,
        '--platform=node',
        '--format=cjs',
        '--drop=debugger',
        ...extraArgs,
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

  test('module without debugger skips the graph pre-pass', async () => {
    const result = await bundle('console.log(42);');
    expect(result.stderr).not.toContain('zntc: symbol-identity-prepass-mode ');
    expect(result.stdout).toBe('42');
  });

  test('debugger module keeps the graph pre-pass and removes the statement', async () => {
    const result = await bundle('debugger; console.log(42);');
    expect(result.stderr).toContain('zntc: symbol-identity-prepass-mode ');
    expect(result.code).not.toContain('debugger');
    expect(result.stdout).toBe('42');
  });

  test('dropping debugger retains exact identities visible to direct eval', async () => {
    const result = await bundle(
      'function read() { const _a = 40; debugger; return eval("_a + 2"); } console.log(read());',
      ['--minify-identifiers'],
    );
    expect(result.stderr).toContain('semantic_graph=retained');
    expect(result.stderr).toMatch(/zntc: symbol-identity-prepass .* clean=1(?:\s|$)/);
    expect(result.code).not.toContain('debugger');
    expect(result.stdout).toBe('42');
  });

  test('class lowering retains the exact graph and eval-visible class name', async () => {
    const result = await bundle(
      'class Counter { value() { return 40; } } debugger; process.stdout.write(String(eval("new Counter().value() + 2")));',
      ['--target=es5', '--minify-identifiers'],
    );
    expectCleanPrepassAudit(result.stderr, 'input.js');
    expect(result.code).toMatch(/var Counter =/);
    expect(result.code).toContain('eval("new Counter().value() + 2")');
    expect(result.stdout).toBe('42');
  });

  test('enum lowering retains the exact graph and eval-visible binding names', async () => {
    const result = await bundle(
      'enum Kind { A = 1 } const _a = 40; debugger; process.stdout.write(String(eval("_a + 2") + Kind.A));',
      ['--minify-identifiers'],
      'input.ts',
    );
    expectCleanPrepassAudit(result.stderr, 'input.ts');
    expect(result.code).toContain('var Kind;');
    expect(result.code).toContain('const _a = 40;');
    expect(result.code).toContain('eval("_a + 2")');
    expect(result.stdout).toBe('43');
  });
});
