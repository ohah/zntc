import { afterEach, describe, expect, test } from 'bun:test';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #4603: worker chunks were always emitted as classic IIFE scripts, which
// cannot express `import`. An external import in a worker vanished without a
// diagnostic and left a dangling reference (ReferenceError at runtime), even
// for `new Worker(url, { type: 'module' })`. A worker that every reference
// creates as a module worker is now emitted as ESM and keeps the import; a
// classic worker reports a warning instead of dropping it silently.
const worker =
  "import { thing } from 'some-external-pkg';\nself.onmessage = () => { console.log(thing); };\n";

describe('module workers keep external imports (#4603)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  const build = async (main: string, format: string) => {
    const created = await createFixture({ 'src/main.ts': main, 'src/w.ts': worker });
    cleanup = created.cleanup;
    const outDir = join(created.dir, 'dist');
    const result = await runZntc([
      '--bundle',
      join(created.dir, 'src/main.ts'),
      '-o',
      join(outDir, 'out.js'),
      `--format=${format}`,
      '--external',
      'some-external-pkg',
    ]);
    const workerFile = readdirSync(outDir).find((f) => f.startsWith('w-'))!;
    return { result, chunk: readFileSync(join(outDir, workerFile), 'utf8') };
  };

  for (const format of ['esm', 'iife']) {
    test(`module worker is emitted as ESM (${format} parent)`, async () => {
      const { result, chunk } = await build(
        "const w = new Worker(new URL('./w.ts', import.meta.url), { type: 'module' });\nconsole.log(w);\n",
        format,
      );
      expect(result.exitCode, result.stderr).toBe(0);
      expect(chunk).toContain('import { thing } from "some-external-pkg"');
      expect(chunk).not.toContain('(() => {');
    });
  }

  test('a classic worker warns instead of dropping the import silently', async () => {
    const { result, chunk } = await build(
      "const w = new Worker(new URL('./w.ts', import.meta.url));\nconsole.log(w);\n",
      'esm',
    );
    expect(result.exitCode, result.stderr).toBe(0);
    expect(chunk).toContain('(() => {');
    expect(result.stderr).toContain('cannot be emitted in IIFE format');
    expect(result.stderr).toContain("{ type: 'module' }");
  });

  test('a worker also created as a classic worker stays classic', async () => {
    const { chunk } = await build(
      "const a = new Worker(new URL('./w.ts', import.meta.url), { type: 'module' });\nconst b = new Worker(new URL('./w.ts', import.meta.url));\nconsole.log(a, b);\n",
      'esm',
    );
    expect(chunk).toContain('(() => {');
  });
});
