import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5713: with `useDefineForClassFields: false` and native static blocks
// (es2022+), assign-semantics static fields moved after the class while the
// static blocks stayed inside it, so every block ran before every field. Like
// tsc, a static field now becomes `static { this.x = … }` in place. Expected
// values are tsc's output run in Node.
const cases: Record<string, { source: string; expected: string; args?: string[] }> = {
  'fields, computed keys and blocks': {
    source:
      "const log: string[] = [];\nconst k = () => { log.push('k'); return 'kk'; };\nclass A {\n  static a = log.push('a');\n  static { log.push('b:' + (this as any).a); }\n  static [k()] = (() => log.push('arrow:' + typeof this))();\n  static { log.push('b2:' + (this as any).kk); }\n}\nconsole.log(log.join(), Object.keys(A).join());\n",
    expected: 'k,a,b:2,arrow:function,b2:4 a,kk\n',
  },
  'class names, super, setters and class expressions': {
    source:
      "const log: any[] = [];\nclass P { static base = 10; static set y(v: any) { log.push('setter:' + v); } }\nclass A extends P {\n  static x = A.name + super.base;\n  static { log.push('blk:' + A.x); }\n  static y = 5;\n}\nconst C = class { static z = log.push('Cz'); static { log.push('Cblk:' + this.z); } };\nconsole.log(log.join(), A.x, Object.keys(A).join());\n",
    expected: 'blk:A10,setter:5,Cz,Cblk:3 A10 x\n',
  },
  'legacy decorators': {
    source:
      "const log: any[] = [];\nfunction dec(...a: any[]) { log.push('dec:' + (typeof a[0] === 'function' ? a[0].y : String(a[1]))); }\nclass A { @dec m() {} static y = log.push('y'); static { log.push('blk'); } }\n@dec class B { static y = log.push('By'); static { log.push('Bblk:' + B.y); } }\nconsole.log(log.join());\n",
    expected: 'y,blk,dec:m,By,Bblk:4,dec:4\n',
    args: ['--experimental-decorators'],
  },
};

describe('assign-semantics static fields with native static blocks (#5713)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, { source, expected, args: extra = [] }] of Object.entries(cases)) {
    for (const args of [
      ['--target=es2022'],
      ['--target=esnext', '--minify'],
      ['--bundle', '--target=es2022'],
    ]) {
      test(`${name}, ${args.join(' ')}`, async () => {
        const created = await createFixture({ 'entry.ts': source });
        cleanup = created.cleanup;
        const out = join(created.dir, 'out.cjs');
        const result = await runZntc([
          join(created.dir, 'entry.ts'),
          ...args,
          ...extra,
          '--use-define-for-class-fields=false',
          '-o',
          out,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected);
      });
    }
  }
});
