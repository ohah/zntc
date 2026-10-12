import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5601: enum member values tsc and esbuild compute but zntc got wrong.
//   - An auto-increment member after a computed one (`A = 1 << 1, B`) counted
//     from the last integer literal, so `B` was 0 instead of 3.
//   - A merged declaration using an earlier declaration's member by name
//     (`enum E { A = 1 } enum E { B = A + 1 }`) left a bare `A`
//     (ReferenceError); merged const enums left `E.B` undefined.
// Expected output is what tsc and esbuild 0.27.7 print.
const cases = {
  'auto-increment after a computed member': {
    src: 'enum E { A = 1 << 1, B, C = A | B, D }\nconsole.log(E.A, E.B, E.C, E.D, E[3]);',
    expected: '2 3 3 4 C\n',
  },
  'auto-increment after hex and fractional members': {
    src: 'enum H { A = 0x10, B, C = 1.5, D }\nconsole.log(H.A, H.B, H.C, H.D);',
    expected: '16 17 1.5 2.5\n',
  },
  'auto-increment after a unary member': {
    src: 'enum E { A = +0, B, C }\nconsole.log(E.A, E.B, E.C);',
    expected: '0 1 2\n',
  },
  'merged enum reads an earlier declaration by name': {
    src: 'enum E { A = 1, AA }\nenum E { B = A + AA, C }\nenum E { D = B * 10 + C }\nconsole.log(E.A, E.AA, E.B, E.C, E.D, E[34]);',
    expected: '1 2 3 4 34 D\n',
  },
  'merged string enum': {
    src: 'enum S { A = "a", B = A + "b" }\nenum S { C = B + "c" }\nconsole.log(S.A, S.B, S.C);',
    expected: 'a ab abc\n',
  },
  'merged const enum': {
    src: 'const enum E { A = 1 }\nconst enum E { B = A + 1 }\nconsole.log(E.A, E.B);',
    expected: '1 2\n',
  },
} as const;

describe('enum member values match tsc (#5601)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const mode of ['transform', 'bundle']) {
    for (const [name, { src, expected }] of Object.entries(cases)) {
      test(`${name}, ${mode}`, async () => {
        const created = await createFixture({ 'entry.ts': src });
        cleanup = created.cleanup;
        const out = join(created.dir, 'out.js');
        const args = mode === 'bundle' ? ['--bundle'] : [];
        const result = await runZntc([...args, join(created.dir, 'entry.ts'), '-o', out]);
        expect(result.exitCode, result.stderr).toBe(0);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected);
      });
    }
  }
});
