import {
  build,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from './helpers';
import type { ZntcPlugin } from './helpers';

describe('@zntc/core build + plugins - require.context', () => {
  test('onResolveContext: hook 호출 + args 전달 (dir/recursive/filter/flags/importer)', async () => {
    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-rc-'));
    writeFileSync(
      join(entryDir, 'entry.ts'),
      "const ctx = require.context('./pages', true, /\\.tsx?$/, 'sync'); console.log(ctx);",
    );

    let captured: any = null;
    const plugin: ZntcPlugin = {
      name: 'rc-capture',
      setup(build) {
        build.onResolveContext({ filter: /.*/ }, (args) => {
          captured = args;
          return { context: ['./a.tsx', './b.tsx'] };
        });
      },
    };

    await build({
      entryPoints: [join(entryDir, 'entry.ts')],
      plugins: [plugin],
    });

    expect(captured).not.toBeNull();
    expect(captured.dir).toBe('./pages');
    expect(captured.recursive).toBe(true);
    expect(captured.filter).toBe('\\.tsx?$');
    expect(captured.importer).toContain('entry.ts');
    rmSync(entryDir, { recursive: true, force: true });
  });

  test('onResolveContext: plugin 미구현 → require_context_no_handler warning', async () => {
    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-rc-noplug-'));
    writeFileSync(
      join(entryDir, 'entry.ts'),
      "const ctx = require.context('./pages'); console.log(ctx);",
    );

    const result = await build({
      entryPoints: [join(entryDir, 'entry.ts')],
    });

    const allDiags = [...(result.warnings ?? []), ...(result.errors ?? [])];
    const hasNoHandler = allDiags.some(
      (d: any) =>
        (typeof d.text === 'string' && d.text.includes('requires a host plugin')) ||
        (typeof d.message === 'string' && d.message.includes('requires a host plugin')),
    );
    expect(hasNoHandler).toBe(true);
    rmSync(entryDir, { recursive: true, force: true });
  });

  test('onResolveContext: invalid require.context (numeric arg) → require_context_invalid error', async () => {
    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-rc-invalid-'));
    writeFileSync(join(entryDir, 'entry.ts'), 'const ctx = require.context(42); console.log(ctx);');

    const result = await build({
      entryPoints: [join(entryDir, 'entry.ts')],
    });

    const hasInvalid = result.errors.some(
      (d: any) =>
        (typeof d.text === 'string' && d.text.includes('first argument must be a string')) ||
        (typeof d.message === 'string' && d.message.includes('first argument must be a string')),
    );
    expect(hasInvalid).toBe(true);
    rmSync(entryDir, { recursive: true, force: true });
  });

  test('onResolveContext: 빈 매칭 결과 (empty context) — diagnostic 없음', async () => {
    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-rc-empty-'));
    writeFileSync(
      join(entryDir, 'entry.ts'),
      "const ctx = require.context('./nonexistent'); console.log(ctx);",
    );

    const plugin: ZntcPlugin = {
      name: 'rc-empty',
      setup(build) {
        build.onResolveContext({ filter: /.*/ }, () => ({ context: [] }));
      },
    };

    const result = await build({
      entryPoints: [join(entryDir, 'entry.ts')],
      plugins: [plugin],
    });

    const allDiags = [...(result.warnings ?? []), ...(result.errors ?? [])];
    const hasNoHandler = allDiags.some(
      (d: any) =>
        (typeof d.text === 'string' && d.text.includes('requires a host plugin')) ||
        (typeof d.message === 'string' && d.message.includes('requires a host plugin')),
    );
    expect(hasNoHandler).toBe(false);
    rmSync(entryDir, { recursive: true, force: true });
  });
});
