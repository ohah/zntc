import { afterEach, describe, expect, test } from 'bun:test';
import { writeFileSync } from 'node:fs';
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

  test('anonymous default class keeps its facade identity through ES5 reanalysis', async () => {
    const fixture = await createFixture({
      'entry.mjs':
        "import DefaultClass, { _default as local } from './dep.mjs';\n" +
        'console.log(JSON.stringify([new DefaultClass().value(), local]));\n',
      'dep.mjs':
        "const _default = 'source';\n" +
        'export { _default };\n' +
        'export default class { value() { return _default; } }\n',
    });
    cleanup = fixture.cleanup;

    const entry = join(fixture.dir, 'entry.mjs');
    const output = join(fixture.dir, 'bundle.mjs');
    const native = await runNode(entry);
    expect(native.stderr).toBe('');
    expect(native.stdout.trim()).toBe('["source","source"]');

    const result = await runZntc(
      [
        '--bundle',
        entry,
        '-o',
        output,
        '--format=esm',
        '--target=es5',
        '--minify-identifiers',
        '--minify-syntax',
      ],
      {
        env: {
          ...process.env,
          ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
        },
      },
    );
    expect(result.exitCode, result.stderr).toBe(0);

    const lines = result.stderr.split(/\r?\n/);
    const mode = lines.find(
      (line) => line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('dep.mjs'),
    );
    const identity = lines.find(
      (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('dep.mjs'),
    );
    expect(mode, result.stderr).toContain('semantic_graph=reanalyzed');
    expect(identity, result.stderr).toMatch(/clean=1(?:\s|$)/);
    expect(identity).toMatch(/missing_binding=0(?:\s|$)/);
    expect(identity).toMatch(/declaration_identity_mismatch=0(?:\s|$)/);
    expect(identity).toMatch(/declaration_anchor_mismatch=0(?:\s|$)/);
    expect(identity).toMatch(/scope_owner_mismatch=0(?:\s|$)/);

    const bundled = await runNode(output);
    expect(bundled.stderr).toBe('');
    expect(bundled.stdout).toBe(native.stdout);
  });

  for (const flags of [[], ['--minify-whitespace'], ['--minify-syntax']]) {
    test(
      'keeps the default re-export bridge identity in preserve-modules (' +
        (flags.length ? flags.join(' ') : 'plain') +
        ')',
      async () => {
        const fixture = await createFixture({
          'entry.js':
            "import value, { _default as local } from './barrel.js';\nconsole.log(JSON.stringify([value, local]));\n",
          'barrel.js':
            "const _default = 'barrel local';\nexport { _default };\nexport { default } from './dep.js';\n",
          'dep.js': 'export default 42;',
        });
        cleanup = fixture.cleanup;

        const entry = join(fixture.dir, 'entry.js');
        const outDir = join(fixture.dir, 'out');
        writeFileSync(join(fixture.dir, 'package.json'), JSON.stringify({ type: 'module' }));
        const native = await runNode(entry);
        expect(native.stderr).toBe('');
        expect(native.stdout.trim()).toBe('[42,\"barrel local\"]');

        const result = await runZntc([
          '--bundle',
          entry,
          '--preserve-modules',
          '--preserve-modules-root=' + fixture.dir,
          '--outdir',
          outDir,
          '--format=esm',
          ...flags,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);

        writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));
        const bundled = await runNode(join(outDir, 'entry.js'));
        expect(bundled.stderr).toBe('');
        expect(bundled.stdout).toBe(native.stdout);
      },
    );
  }

  test('keeps a default re-export bridge shared by entry and dynamic chunk', async () => {
    const fixture = await createFixture({
      'entry.js':
        "import value, { _default as local } from './barrel.js';\n" +
        'console.log(JSON.stringify([value, local]));\n' +
        "import('./lazy.js').then(({ read }) => console.log(read()));\n",
      'lazy.js':
        "import value, { _default as local } from './barrel.js';\n" +
        'export function read() { return JSON.stringify([value, local]); }\n',
      'barrel.js':
        "const _default = 'barrel local';\n" +
        'export { _default };\n' +
        "export { default } from './dep.js';\n",
      'dep.js': 'export default 42;',
    });
    cleanup = fixture.cleanup;

    const entry = join(fixture.dir, 'entry.js');
    const outDir = join(fixture.dir, 'out');
    writeFileSync(join(fixture.dir, 'package.json'), JSON.stringify({ type: 'module' }));
    const native = await runNode(entry);
    expect(native.stderr).toBe('');
    expect(native.stdout.trim().split('\n')).toEqual([
      '[42,\"barrel local\"]',
      '[42,\"barrel local\"]',
    ]);

    const result = await runZntc([
      '--bundle',
      entry,
      '--splitting',
      '--outdir',
      outDir,
      '--format=esm',
      '--platform=node',
    ]);
    expect(result.exitCode, result.stderr).toBe(0);

    writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));
    const bundled = await runNode(join(outDir, 'entry.js'));
    expect(bundled.stderr).toBe('');
    expect(bundled.stdout).toBe(native.stdout);
  });
});
