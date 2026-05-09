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
} from '../helpers';
import type { ZntcPlugin } from '../helpers';

function hasHostPluginDiagnostic(diags: any[]): boolean {
  return diags.some(
    (d) =>
      (typeof d.text === 'string' && d.text.includes('requires a host plugin')) ||
      (typeof d.message === 'string' && d.message.includes('requires a host plugin')),
  );
}

describe('@zntc/core build + plugins - require.context diagnostics', () => {
  test('onResolveContext: plugin 미구현 → require_context_no_handler warning', async () => {
    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-rc-noplug-'));
    try {
      writeFileSync(
        join(entryDir, 'entry.ts'),
        "const ctx = require.context('./pages'); console.log(ctx);",
      );

      const result = await build({
        entryPoints: [join(entryDir, 'entry.ts')],
      });

      const allDiags = [...(result.warnings ?? []), ...(result.errors ?? [])];
      expect(hasHostPluginDiagnostic(allDiags)).toBe(true);
    } finally {
      rmSync(entryDir, { recursive: true, force: true });
    }
  });

  test('onResolveContext: invalid require.context (numeric arg) → require_context_invalid error', async () => {
    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-rc-invalid-'));
    try {
      writeFileSync(
        join(entryDir, 'entry.ts'),
        'const ctx = require.context(42); console.log(ctx);',
      );

      const result = await build({
        entryPoints: [join(entryDir, 'entry.ts')],
      });

      const hasInvalid = result.errors.some(
        (d: any) =>
          (typeof d.text === 'string' && d.text.includes('first argument must be a string')) ||
          (typeof d.message === 'string' && d.message.includes('first argument must be a string')),
      );
      expect(hasInvalid).toBe(true);
    } finally {
      rmSync(entryDir, { recursive: true, force: true });
    }
  });

  test('onResolveContext: 빈 매칭 결과 (empty context) — diagnostic 없음', async () => {
    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-rc-empty-'));
    try {
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
      expect(hasHostPluginDiagnostic(allDiags)).toBe(false);
    } finally {
      rmSync(entryDir, { recursive: true, force: true });
    }
  });
});
