import { afterEach, describe, expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

describe('JSX runtime helper name collisions', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const mode of ['automatic', 'automatic-dev'] as const) {
    test(`${mode} keeps generated helpers distinct from user bindings`, async () => {
      const fx = await createFixture({
        'app.tsx': `
const _jsx = () => 'user jsx';
const _jsxs = () => 'user jsxs';
const _jsxDEV = () => 'user jsxDEV';
const _Fragment = () => 'user Fragment';
const _createElement = () => 'user createElement';
const props = { id: 'x' };
export const single = <p>single</p>;
export const multiple = <><p>one</p><p>two</p></>;
export const fallback = <p {...props} key="late" />;
export const users = [_jsx(), _jsxs(), _jsxDEV(), _Fragment(), _createElement()];
`,
      });
      cleanup = fx.cleanup;
      const out = join(fx.dir, 'out.js');
      const result = await runZntcInDir(fx.dir, ['app.tsx', '-o', out, `--jsx=${mode}`]);
      expect(result.exitCode).toBe(0);
      const code = await readFile(out, 'utf8');
      const imports =
        mode === 'automatic'
          ? ['jsx', 'jsxs', 'Fragment', 'createElement']
          : ['jsxDEV', 'Fragment', 'createElement'];
      for (const imported of imports) {
        const local = `_${imported}`;
        expect(code).toContain(`${imported} as ${local}2`);
        expect(code).toContain(`${local}2`);
        expect(code).toContain(`${local}()`);
      }
    });
  }
});
