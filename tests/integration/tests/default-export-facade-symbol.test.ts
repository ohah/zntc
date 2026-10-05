import { afterEach, describe, expect, test } from 'bun:test';
import { join } from 'node:path';
import { createFixture, runNode, runZntc } from './helpers';

describe('#4819 default export facade SymbolId', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const flags of [[], ['--minify-identifiers'], ['--minify-identifiers', '--minify-syntax']]) {
    test(`keeps a source _default separate from an anonymous default facade (${flags.length ? flags.join(' ') : 'plain'})`, async () => {
      const fixture = await createFixture({
        'entry.mjs': `
import value, { _default as local } from './dep.mjs';
console.log(JSON.stringify([value, local]));
`,
        'dep.mjs': `
const _default = 'source';
export { _default };
export default 42;
`,
      });
      cleanup = fixture.cleanup;

      const entry = join(fixture.dir, 'entry.mjs');
      const output = join(fixture.dir, 'bundle.mjs');
      const native = await runNode(entry);
      expect(native.stderr).toBe('');
      expect(native.stdout.trim()).toBe('[42,"source"]');

      const result = await runZntc(['--bundle', entry, '-o', output, '--format=esm', ...flags]);
      expect(result.exitCode, result.stderr).toBe(0);

      const bundled = await runNode(output);
      expect(bundled.stderr).toBe('');
      expect(bundled.stdout).toBe(native.stdout);
    });
  }

  for (const flags of [[], ['--minify-identifiers'], ['--minify-identifiers', '--minify-syntax']]) {
    test(`keeps a named source _default when default exports that local (${flags.length ? flags.join(' ') : 'plain'})`, async () => {
      const fixture = await createFixture({
        'entry.mjs': `
import value, { _default as local } from './dep.mjs';
console.log(JSON.stringify([value, local]));
`,
        'dep.mjs': `
const _default = 'source';
export { _default };
export default _default;
`,
      });
      cleanup = fixture.cleanup;

      const entry = join(fixture.dir, 'entry.mjs');
      const output = join(fixture.dir, 'bundle.mjs');
      const native = await runNode(entry);
      expect(native.stderr).toBe('');
      expect(native.stdout.trim()).toBe('["source","source"]');

      const result = await runZntc(['--bundle', entry, '-o', output, '--format=esm', ...flags]);
      expect(result.exitCode, result.stderr).toBe(0);

      const bundled = await runNode(output);
      expect(bundled.stderr).toBe('');
      expect(bundled.stdout).toBe(native.stdout);
    });
  }

  for (const flags of [[], ['--minify-identifiers'], ['--minify-identifiers', '--minify-syntax']]) {
    test(`keeps a colliding source _default separate from a default re-export bridge (${flags.length ? flags.join(' ') : 'plain'})`, async () => {
      const fixture = await createFixture({
        'entry.mjs': `
import value, { _default as local } from './barrel.mjs';
console.log(JSON.stringify([value, local]));
`,
        'barrel.mjs': `
const _default = 'barrel local';
export { _default };
export { default } from './dep.mjs';
`,
        'dep.mjs': `export default 42;`,
      });
      cleanup = fixture.cleanup;

      const entry = join(fixture.dir, 'entry.mjs');
      const output = join(fixture.dir, 'bundle.mjs');
      const native = await runNode(entry);
      expect(native.stderr).toBe('');
      expect(native.stdout.trim()).toBe('[42,"barrel local"]');

      const result = await runZntc(['--bundle', entry, '-o', output, '--format=esm', ...flags]);
      expect(result.exitCode, result.stderr).toBe(0);

      const bundled = await runNode(output);
      expect(bundled.stderr).toBe('');
      expect(bundled.stdout).toBe(native.stdout);
    });
  }
});
