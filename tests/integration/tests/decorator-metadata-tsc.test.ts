import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

// #5587: emitDecoratorMetadata serializes types of decorated declarations to
// values (`__metadata("design:paramtypes", [Service])`). zntc dropped imports
// used only in those type positions (DI received `Object`), read the type of
// a parameter property / decorated parameter as `Object`, emitted method-shaped
// metadata for properties and accessors, always `Object` as the return type,
// and no class metadata on ES5. Expected outputs are tsc's (5.x, commonjs).
const svc = `export class Service { }
export class Repo<T> { }
export namespace ns { export class Inner { } }
console.log('svc loaded');`;

const tsconfig = '{"compilerOptions":{"experimentalDecorators":true,"emitDecoratorMetadata":true}}';

const cases: Record<string, { entry: string; expected: string }> = {
  'parameter property (NestJS style)': {
    entry:
      'import { Service } from \'./svc\';\nconst meta: string[] = [];\n(Reflect as any).metadata = (k: string, v: any) => (t: any, key?: any) => { meta.push((key || "ctor") + ":" + k.replace("design:", "") + "=" + (Array.isArray(v) ? v.map((x: any) => x && x.name).join(",") : v && v.name)); };\nfunction Dec(): any { return () => {}; }\nfunction P(): any { return () => {}; }\n@Dec() class C { constructor(private s: Service) {} }\nconsole.log("meta:", meta.join(" | "));\n',
    expected: 'svc loaded\nmeta: ctor:paramtypes=Service\n',
  },
  'decorated constructor parameter only': {
    entry:
      'import { Service } from \'./svc\';\nconst meta: string[] = [];\n(Reflect as any).metadata = (k: string, v: any) => (t: any, key?: any) => { meta.push((key || "ctor") + ":" + k.replace("design:", "") + "=" + (Array.isArray(v) ? v.map((x: any) => x && x.name).join(",") : v && v.name)); };\nfunction Dec(): any { return () => {}; }\nfunction P(): any { return () => {}; }\nclass C { constructor(@P() s: Service) {} }\nconsole.log("meta:", meta.join(" | "));\n',
    expected: 'svc loaded\nmeta: ctor:paramtypes=Service\n',
  },
  'decorated method with generic parameter and return types': {
    entry:
      'import { Repo } from \'./svc\';\nconst meta: string[] = [];\n(Reflect as any).metadata = (k: string, v: any) => (t: any, key?: any) => { meta.push((key || "ctor") + ":" + k.replace("design:", "") + "=" + (Array.isArray(v) ? v.map((x: any) => x && x.name).join(",") : v && v.name)); };\nfunction Dec(): any { return () => {}; }\nfunction P(): any { return () => {}; }\nclass C { @Dec() m(r: Repo<number>): Repo<string> { return null as any; } }\nconsole.log("meta:", meta.join(" | "));\n',
    expected: 'svc loaded\nmeta: m:returntype=Repo | m:paramtypes=Repo | m:type=Function\n',
  },
  'undecorated class keeps the import elided': {
    entry:
      'import { Service } from \'./svc\';\nconst meta: string[] = [];\n(Reflect as any).metadata = (k: string, v: any) => (t: any, key?: any) => { meta.push((key || "ctor") + ":" + k.replace("design:", "") + "=" + (Array.isArray(v) ? v.map((x: any) => x && x.name).join(",") : v && v.name)); };\nfunction Dec(): any { return () => {}; }\nfunction P(): any { return () => {}; }\nclass C { constructor(s: Service) {} }\nconsole.log("meta:", meta.join(" | "));\n',
    expected: 'meta: \n',
  },
  'qualified namespace type': {
    entry:
      'import { ns } from \'./svc\';\nconst meta: string[] = [];\n(Reflect as any).metadata = (k: string, v: any) => (t: any, key?: any) => { meta.push((key || "ctor") + ":" + k.replace("design:", "") + "=" + (Array.isArray(v) ? v.map((x: any) => x && x.name).join(",") : v && v.name)); };\nfunction Dec(): any { return () => {}; }\nfunction P(): any { return () => {}; }\n@Dec() class C { constructor(s: ns.Inner) {} }\nconsole.log("meta:", meta.join(" | "));\n',
    expected: 'svc loaded\nmeta: ctor:paramtypes=Inner\n',
  },
  'constructor with class and builtin types': {
    entry:
      'import { Service } from \'./svc\';\nconst meta: string[] = [];\n(Reflect as any).metadata = (k: string, v: any) => (t: any, key?: any) => { meta.push((key || "ctor") + ":" + k.replace("design:", "") + "=" + (Array.isArray(v) ? v.map((x: any) => x && x.name).join(",") : v && v.name)); };\nfunction Dec(): any { return () => {}; }\nfunction P(): any { return () => {}; }\n@Dec() class C { constructor(s: Service, n: number, x?: string) {} }\nconsole.log("meta:", meta.join(" | "));\n',
    expected: 'svc loaded\nmeta: ctor:paramtypes=Service,Number,String\n',
  },
  'decorated property type': {
    entry:
      'import { Service } from \'./svc\';\nconst meta: string[] = [];\n(Reflect as any).metadata = (k: string, v: any) => (t: any, key?: any) => { meta.push((key || "ctor") + ":" + k.replace("design:", "") + "=" + (Array.isArray(v) ? v.map((x: any) => x && x.name).join(",") : v && v.name)); };\nfunction Dec(): any { return () => {}; }\nclass C { @Dec() prop!: Service; }\nconsole.log("meta:", meta.join(" | "));\n',
    expected: 'svc loaded\nmeta: prop:type=Service\n',
  },
  'decorated method without a return type': {
    entry:
      'import { Service } from \'./svc\';\nconst meta: string[] = [];\n(Reflect as any).metadata = (k: string, v: any) => (t: any, key?: any) => { meta.push((key || "ctor") + ":" + k.replace("design:", "") + "=" + (Array.isArray(v) ? v.map((x: any) => x && x.name).join(",") : v && v.name)); };\nfunction Dec(): any { return () => {}; }\nclass C { @Dec() m(a: Service, b: number) {} }\nconsole.log("meta:", meta.join(" | "));\n',
    expected:
      'svc loaded\nmeta: m:returntype=undefined | m:paramtypes=Service,Number | m:type=Function\n',
  },
  'getter and setter': {
    entry:
      'import { Service } from \'./svc\';\nconst meta: string[] = [];\n(Reflect as any).metadata = (k: string, v: any) => (t: any, key?: any) => { meta.push((key || "ctor") + ":" + k.replace("design:", "") + "=" + (Array.isArray(v) ? v.map((x: any) => x && x.name).join(",") : v && v.name)); };\nfunction Dec(): any { return () => {}; }\nclass C { @Dec() get g(): Service { return null as any; } @Dec() set s(v: Service) {} }\nconsole.log("meta:", meta.join(" | "));\n',
    expected:
      'svc loaded\nmeta: g:paramtypes= | g:type=Service | s:paramtypes=Service | s:type=Service\n',
  },
  'async method, array/union/optional properties': {
    entry:
      'import { Service } from \'./svc\';\nconst meta: string[] = [];\n(Reflect as any).metadata = (k: string, v: any) => (t: any, key?: any) => { meta.push((key || "ctor") + ":" + k.replace("design:", "") + "=" + (Array.isArray(v) ? v.map((x: any) => x && x.name).join(",") : v && v.name)); };\nfunction Dec(): any { return () => {}; }\nclass C { @Dec() async am(x: number): Promise<number> { return 1; } @Dec() arr: Service[] = []; @Dec() u!: Service | null; @Dec() opt?: string; }\nconsole.log("meta:", meta.join(" | "));\n',
    expected:
      'meta: am:returntype=Promise | am:paramtypes=Number | am:type=Function | arr:type=Array | u:type=Object | opt:type=String\n',
  },
  'function-typed parameter and array return': {
    entry:
      'import { Service } from \'./svc\';\nconst meta: string[] = [];\n(Reflect as any).metadata = (k: string, v: any) => (t: any, key?: any) => { meta.push((key || "ctor") + ":" + k.replace("design:", "") + "=" + (Array.isArray(v) ? v.map((x: any) => x && x.name).join(",") : v && v.name)); };\nfunction Dec(): any { return () => {}; }\nclass C { @Dec() m(cb: (x: number) => void, s: Service): Service[] { return []; } @Dec() n(): void {} }\nconsole.log("meta:", meta.join(" | "));\n',
    expected:
      'svc loaded\nmeta: m:returntype=Array | m:paramtypes=Function,Service | m:type=Function | n:returntype=undefined | n:paramtypes= | n:type=Function\n',
  },
};

describe('emitDecoratorMetadata matches tsc (#5587)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['esnext', 'es5']) {
    for (const [name, { entry, expected }] of Object.entries(cases)) {
      test(`${name}, ${target}`, async () => {
        const created = await createFixture({
          'svc.ts': svc,
          'entry.ts': entry,
          'tsconfig.json': tsconfig,
        });
        cleanup = created.cleanup;
        const out = join(created.dir, 'out.cjs');
        const result = await runZntcInDir(created.dir, [
          '--bundle',
          'entry.ts',
          `--target=${target}`,
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
