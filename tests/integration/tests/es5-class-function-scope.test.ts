import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import ts from 'typescript';
import { createFixture, runZntcInDir } from './helpers';

const cases = {
  'computed method and paired accessors': `
    const key = 'read';
    class Box {
      stamp = 0;
      constructor(source) { this.value = source() ?? 4; }
      [key](source) { return source() ?? this.value; }
      get current() { return this.value ?? 0; }
      set current(source) { this.value = source() ?? 1; }
    }
    const box = new Box(() => null);
    const first = box.read(() => null);
    box.current = () => 7;
    console.log(JSON.stringify([first, box.current, box.read(() => 2)]));
  `,
  'direct class expression constructor': `
    const Direct = class {
      constructor(source) { this.value = source() ?? 3; }
    };
    console.log(JSON.stringify([new Direct(() => null).value, new Direct(() => 8).value]));
  `,
  'uninitialized direct constructor let': `
    class Box {
      constructor(input) {
        let local;
        local = input ?? 7;
        this.value = local;
      }
    }
    console.log(JSON.stringify([new Box().value, new Box(3).value]));
  `,
  'base constructor lexical this-property read': `
    var reads = 0;
    class Box {
      get current() { reads++; return this instanceof Box ? 4 : -1; }
      constructor() { let local = this.current; this.value = local; }
    }
    console.log(new Box().value, reads);
  `,
  'derived constructor post-super lexical this-property read': `
    var reads = 0;
    class Base { get current() { reads++; return this instanceof Box ? 5 : -1; } }
    class Box extends Base {
      constructor() { super(); const local = this.current; this.value = local; }
    }
    console.log(new Box().value, reads);
  `,
  'derived constructor computed super-property lexical read': `
    var reads = 0;
    class Base {
      constructor(value) { this.slot = value; }
      get current() { reads++; return 6; }
    }
    class Box extends Base {
      constructor(key, value) { super(value); const local = super[key]; this.value = local; }
    }
    console.log(new Box('current', 6).value, reads);
  `,
  'derived constructor primitive-literal super-property lexical reads': `
    var reads = 0;
    class Base {
      get current() { reads++; return 7; }
      get true() { reads++; return 9; }
      get null() { reads++; return 10; }
    }
    Object.defineProperty(Base.prototype, '1', { get: function() { reads++; return 8; } });
    class Box extends Base {
      constructor() {
        super();
        const stringValue = super['current'];
        const numberValue = super[1];
        const booleanValue = super[true];
        const nullValue = super[null];
        this.value = stringValue + numberValue + booleanValue + nullValue;
      }
    }
    console.log(new Box().value, reads);
  `,
  'derived constructor computed this-property lexical reads': `
    var reads = 0;
    class Base {
      get current() { reads++; return this instanceof Box ? 5 : -1; }
    }
    Base.prototype[1] = 6;
    Base.prototype['true'] = 7;
    Base.prototype['null'] = 8;
    class Box extends Base {
      constructor(key) {
        super();
        const stringValue = this['current'];
        const numberValue = this[1];
        const booleanValue = this[true];
        const nullValue = this[null];
        const boundValue = this[key];
        this.value = stringValue + numberValue + booleanValue + nullValue + boundValue;
      }
    }
    console.log(new Box('current').value, reads);
  `,
  'derived constructor multi-declarator direct super-property reads': `
    var reads = 0;
    class Base {
      get current() { reads++; return 7; }
      get other() { reads++; return 8; }
    }
    class Box extends Base {
      constructor() {
        super();
        const first = super.current, second = super.other;
        this.value = first + second;
      }
    }
    console.log(new Box().value, reads);
  `,
  'nested closures in computed method': `
    const key = 'make';
    class Box {
      [key](source) {
        const local = source() ?? 5;
        return () => local + (source() ?? 1);
      }
    }
    const box = new Box();
    const read = box.make(() => null);
    console.log(read());
  `,
  // Stage 3 computed-key runtime evaluation has a separate existing defect.
  // The computed owner copies are checked by the semantic tests.
  'decorated async method with field': `
    const calls = [];
    function trace(method, context) {
      calls.push(context.name);
      return function(...args) { return method.apply(this, args); };
    }
    class Box {
      value = 6;
      @trace
      async read(offset) { return this.value + await Promise.resolve(offset); }
    }
    new Box().read(2).then(value => console.log(JSON.stringify([calls, value])));
  `,
} as const;

describe('ES5 class function scope (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, source] of Object.entries(cases)) {
    for (const bundle of [false, true]) {
      for (const minify of [false, true]) {
        test(`${name}, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
          const reference = ts.transpileModule(source, {
            compilerOptions: {
              target: ts.ScriptTarget.ES5,
              module: ts.ModuleKind.ESNext,
            },
          }).outputText;
          const fixture = await createFixture({
            'input.ts': source,
            'package.json': '{"type":"module"}',
            'reference.mjs': reference,
          });
          cleanup = fixture.cleanup;
          const native = spawnSync('node', [join(fixture.dir, 'reference.mjs')], {
            encoding: 'utf8',
          });
          expect(native.status, native.stderr).toBe(0);
          const output = join(fixture.dir, 'out.cjs');
          const result = await runZntcInDir(fixture.dir, [
            ...(bundle ? ['--bundle', '--platform=node', '--format=cjs'] : []),
            'input.ts',
            '--target=es5',
            ...(minify ? ['--minify-identifiers', '--minify-syntax'] : []),
            '-o',
            output,
          ]);
          expect(result.exitCode, result.stderr).toBe(0);
          const runtime = spawnSync('node', [output], { encoding: 'utf8' });
          expect(runtime.status, runtime.stderr).toBe(0);
          expect(runtime.stdout).toBe(native.stdout);
        });
      }
    }
  }

  test('ten compileable output reference mutants are caught by runtime parity', async () => {
    const source = Array.from({ length: 10 }, (_, index) => {
      const local = `mutationLocal${index}`;
      const value = index + 11;
      return `class Box${index} { constructor() { let ${local}; ${local} = ${value}; this.value = ${local}; } } console.log(new Box${index}().value);`;
    }).join('\n');
    const fixture = await createFixture({ 'input.mjs': source });
    cleanup = fixture.cleanup;
    const reference = spawnSync('node', [join(fixture.dir, 'input.mjs')], { encoding: 'utf8' });
    expect(reference.status, reference.stderr).toBe(0);

    const output = join(fixture.dir, 'out.mjs');
    const result = await runZntcInDir(fixture.dir, ['input.mjs', '--target=es5', '-o', output]);
    expect(result.exitCode, result.stderr).toBe(0);
    const emitted = readFileSync(output, 'utf8');
    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe(reference.stdout);

    for (let index = 0; index < 10; index++) {
      const local = `mutationLocal${index}`;
      const referenceIndex = emitted.lastIndexOf(local);
      expect(referenceIndex, `emitted local reference ${local}`).toBeGreaterThanOrEqual(0);
      const mutant = `${emitted.slice(0, referenceIndex)}void 0${emitted.slice(referenceIndex + local.length)}`;
      const mutantPath = join(fixture.dir, `mutant-${index}.mjs`);
      writeFileSync(mutantPath, mutant);
      const syntax = spawnSync('node', ['--check', mutantPath], { encoding: 'utf8' });
      expect(syntax.status, syntax.stderr).toBe(0);
      const mutatedRuntime = spawnSync('node', [mutantPath], { encoding: 'utf8' });
      expect(mutatedRuntime.status, mutatedRuntime.stderr).toBe(0);
      expect(
        mutatedRuntime.stdout,
        `reference mutation ${index} must change runtime output`,
      ).not.toBe(reference.stdout);
    }
  });
});
