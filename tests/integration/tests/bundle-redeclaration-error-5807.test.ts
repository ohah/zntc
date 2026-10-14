import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5807: the bundle path dropped the analyzer's redeclaration errors, so a
// program that is a SyntaxError (and never runs) bundled silently into code
// that does run. Single-file transpile and esbuild's bundler reject it. Legal
// redeclarations must keep bundling.
describe('bundle reports redeclaration errors (#5807)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  const invalid: Record<string, Record<string, string>> = {
    'let then var': { 'entry.js': 'let a = 1;\nvar a = 2;\nconsole.log(a);\n' },
    'module duplicate function (imported)': {
      'lib.mjs': 'function f() { return 1; }\nfunction f() { return 2; }\nexport { f };\n',
      'entry.mjs': "import { f } from './lib.mjs';\nconsole.log(f());\n",
    },
    'block var and function': { 'entry.js': '{ var f; function f() {} }\n' },
  };
  for (const [name, files] of Object.entries(invalid)) {
    test(`rejects ${name}`, async () => {
      const created = await createFixture(files);
      cleanup = created.cleanup;
      const entry = Object.keys(files).find((file) => file.startsWith('entry'))!;
      const syntax = spawnSync('node', ['--check', join(created.dir, entry)], { encoding: 'utf8' });
      if (!entry.endsWith('.mjs')) expect(syntax.status).not.toBe(0);
      const result = await runZntc([
        '--bundle',
        join(created.dir, entry),
        '-o',
        join(created.dir, 'out.js'),
      ]);
      expect(result.exitCode, result.stderr).not.toBe(0);
      expect(result.stderr).toContain('has already been declared');
    });
  }

  const valid: Record<string, string> = {
    'var and var': 'var a = 1;\nvar a = 2;\nconsole.log(a);\n',
    'duplicate functions in a script':
      'function f() { return 1; }\nfunction f() { return 2; }\nconsole.log(f());\n',
    'var and function': 'var g = 1;\nfunction g() {}\nconsole.log(typeof g);\n',
    'sloppy block functions':
      '{ function h() { return 1; } }\n{ function h() { return 2; } }\nconsole.log(h());\n',
    'function body duplicates in a module':
      'export {};\nfunction outer() { function f() { return 1; } function f() { return 2; } return f(); }\nconsole.log(outer());\n',
    'strict block function shadows outer':
      "export {};\nfunction dup() { return 'outer'; }\n{ function dup() { return 'inner'; } console.log(dup()); }\nconsole.log(dup());\n",
  };
  for (const [name, source] of Object.entries(valid)) {
    test(`still bundles ${name}`, async () => {
      const file = source.startsWith('export') ? 'entry.mjs' : 'entry.js';
      const created = await createFixture({ [file]: source });
      cleanup = created.cleanup;
      const expected = spawnSync('node', [join(created.dir, file)], { encoding: 'utf8' });
      expect(expected.status, expected.stderr).toBe(0);
      const out = join(created.dir, 'out.js');
      const result = await runZntc(['--bundle', join(created.dir, file), '-o', out]);
      expect(result.exitCode, result.stderr).toBe(0);
      const run = spawnSync('node', [out], { encoding: 'utf8' });
      expect(run.status, run.stderr).toBe(0);
      expect(run.stdout).toBe(expected.stdout);
    });
  }
});
