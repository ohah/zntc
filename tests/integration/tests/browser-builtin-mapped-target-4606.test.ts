import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #4606: with --platform=browser a Node builtin that fails to resolve becomes
// an empty "(disabled)" module. That also swallowed an explicit
// `--fallback:crypto=crypto-browserify` / `--alias:crypto=...` whose target was
// missing, so the build passed and the shim was undefined at runtime. esbuild,
// rspack and rolldown fail the build. The resolver now records the mapped
// target failure where it applies the mapping.
describe('browser builtin with a missing mapped target (#4606)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  const build = async (source: string, flags: string[], withShim = false) => {
    const created = await createFixture({ 'src/main.ts': source });
    cleanup = created.cleanup;
    if (withShim) {
      const dir = join(created.dir, 'node_modules', 'crypto-browserify');
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, 'package.json'), '{"name":"crypto-browserify","main":"index.js"}');
      writeFileSync(join(dir, 'index.js'), 'module.exports = { shim: "ok" };');
    }
    const out = join(created.dir, 'out.js');
    const result = await runZntc([
      '--bundle',
      join(created.dir, 'src/main.ts'),
      '-o',
      out,
      '--platform=browser',
      ...flags,
    ]);
    return { result, out };
  };

  const plain = 'import c from "crypto";\nconsole.log(JSON.stringify(c));\n';

  for (const flag of [
    '--fallback:crypto=crypto-browserify',
    '--alias:crypto=crypto-browserify',
    '--alias:crypto=./missing-shim.js',
  ]) {
    test(`fails the build for ${flag}`, async () => {
      const { result } = await build(plain, [flag]);
      expect(result.exitCode, result.stderr).not.toBe(0);
      expect(result.stderr).toContain('ZNTC0100');
    });
  }

  for (const flag of ['--fallback:crypto=crypto-browserify', '--alias:crypto=crypto-browserify']) {
    test(`uses the installed target for ${flag}`, async () => {
      const { result, out } = await build(plain, [flag], true);
      expect(result.exitCode, result.stderr).toBe(0);
      const run = spawnSync('node', [out], { encoding: 'utf8' });
      expect(run.stdout).toBe('{"shim":"ok"}\n');
    });
  }

  test('an unmapped builtin and an explicit false mapping still become empty modules', async () => {
    for (const flags of [[], ['--fallback:crypto=false']]) {
      const { result, out } = await build(plain, flags);
      expect(result.exitCode, result.stderr).toBe(0);
      const run = spawnSync('node', [out], { encoding: 'utf8' });
      expect(run.stdout).toBe('{}\n');
    }
  });

  test('an optional require of a mapped builtin stays a warning', async () => {
    const { result } = await build(
      'let c;\ntry { c = require("crypto"); } catch (e) {}\nconsole.log(typeof c);\n',
      ['--fallback:crypto=crypto-browserify'],
    );
    expect(result.exitCode, result.stderr).toBe(0);
    expect(result.stderr).toContain('Optional dependency not resolved');
  });
});
