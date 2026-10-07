import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import ts from 'typescript';
import { createFixture, runZntcInDir, ZNTC_BIN } from './helpers';

// Return-type metadata currently emits Object for every method. Explicit any
// keeps this helper-linkage fixture inside that supported serialization case.
const source = `
const events: string[] = [];
(Reflect as any).metadata = function (key: string, value: any) {
  return function (_target: any, property?: string) {
    const names = Array.isArray(value) ? value.map(item => item.name).join(',') : value.name;
    events.push((property || 'class') + ':' + key + ':' + names);
  };
};
function decorated(_target: any, property?: string) {
  events.push('decorate:' + (property || 'class'));
}
@decorated
class Service {
  constructor(value: number) {}
  @decorated method(value: string): any { return value.length; }
}
console.log(JSON.stringify([new Service(1).method('abc'), events]));
`;

// ES5 class lowering currently loses typed method/constructor parameter
// metadata. This variant still exercises __metadata for a decorated method,
// without treating that separate serialization gap as helper linkage.
const es5MetadataSource = source
  .replace('  constructor(value: number) {}\n', '')
  .replace(
    '@decorated method(value: string): any { return value.length; }',
    '@decorated method(): any { return 3; }',
  )
  .replace("new Service(1).method('abc')", 'new Service().method()');

describe('legacy runtime helper symbols (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  test('standalone ES5 extends preamble uses the collision-free helper SymbolId name', async () => {
    const fixture = await createFixture({
      'input.ts': `
var __extends = 40;
class Base {}
class Child extends Base {}
console.log(__extends, new Child() instanceof Base);
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, ['input.ts', '--target=es5', '-o', output]);
    expect(result.exitCode, result.stderr).toBe(0);

    const code = readFileSync(output, 'utf8');
    expect(code).toMatch(/var __extends2 = function/);
    expect(code).toMatch(/__extends2\(Child, _super\)/);
    expect(code).not.toMatch(/__extends\(Child, _super\)/);

    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe('40 true\n');
  });

  test('standalone minified ES5 extends preamble uses the collision-free helper SymbolId name', async () => {
    const fixture = await createFixture({
      'input.ts': `
var $eX = 40;
class Base {}
class Child extends Base {}
console.log($eX, new Child() instanceof Base);
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, [
      'input.ts',
      '--target=es5',
      '--minify-whitespace',
      '-o',
      output,
    ]);
    expect(result.exitCode, result.stderr).toBe(0);

    const code = readFileSync(output, 'utf8');
    expect(code).toMatch(/var \$eX2=function/);
    expect(code).toMatch(/\$eX2\(Child,_super\)/);
    expect(code).not.toMatch(/\$eX\(Child,_super\)/);

    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe('40 true\n');
  });

  test('standalone ES5 generator preamble uses the collision-free helper SymbolId name', async () => {
    const fixture = await createFixture({
      'input.ts': `
var __generator = 40;
function* values() { yield 7; }
var iterator = values();
console.log(__generator, iterator.next().value, iterator.next().done);
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, ['input.ts', '--target=es5', '-o', output]);
    expect(result.exitCode, result.stderr).toBe(0);

    const code = readFileSync(output, 'utf8');
    expect(code).toMatch(/var __generator2 = function\(\)/);
    expect(code).toMatch(/return __generator2\(/);
    expect(code).not.toMatch(/return __generator\(/);

    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe('40 7 true\n');
  });

  test('standalone minified ES5 generator preamble uses the collision-free helper SymbolId name', async () => {
    const fixture = await createFixture({
      'input.ts': `
var $gn = 40;
function* values() { yield 7; }
var iterator = values();
console.log($gn, iterator.next().value, iterator.next().done);
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, [
      'input.ts',
      '--target=es5',
      '--minify-whitespace',
      '-o',
      output,
    ]);
    expect(result.exitCode, result.stderr).toBe(0);

    const code = readFileSync(output, 'utf8');
    const emittedHelper = code.match(/var (\$g[a-zA-Z0-9_$]*)=function\(\)/)?.[1];
    expect(emittedHelper).toBeDefined();
    expect(emittedHelper).not.toBe('$gn');
    expect(code).toContain(`return ${emittedHelper}(`);
    expect(code).not.toMatch(/return \$gn\(/);

    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe('40 7 true\n');
  });

  test('standalone ES5 rest preamble uses the collision-free helper SymbolId name', async () => {
    const fixture = await createFixture({
      'input.ts': `
var __rest = 40;
const { a, ...copy } = { a: 1, b: 2 };
console.log(__rest, copy.b);
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, ['input.ts', '--target=es5', '-o', output]);
    expect(result.exitCode, result.stderr).toBe(0);

    const code = readFileSync(output, 'utf8');
    expect(code).toMatch(/var __rest2 = function\(s, e\)/);
    expect(code).toMatch(/__rest2\(/);
    expect(code).not.toMatch(/\b__rest\(/);

    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe('40 2\n');
  });

  test('standalone minified ES5 rest preamble uses the collision-free helper SymbolId name', async () => {
    const fixture = await createFixture({
      'input.ts': `
var $rs = 40;
const { a, ...copy } = { a: 1, b: 2 };
console.log($rs, copy.b);
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, [
      'input.ts',
      '--target=es5',
      '--minify-whitespace',
      '-o',
      output,
    ]);
    expect(result.exitCode, result.stderr).toBe(0);

    const code = readFileSync(output, 'utf8');
    const emittedHelper = code.match(/var (\$rs[a-zA-Z0-9_$]*)=function\(s,e\)/)?.[1];
    expect(emittedHelper).toBeDefined();
    expect(emittedHelper).not.toBe('$rs');
    expect(code).toContain(`${emittedHelper}(`);

    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe('40 2\n');
  });

  test('standalone ES5 tagged template preamble uses the collision-free helper SymbolId name', async () => {
    const fixture = await createFixture({
      'input.ts': `
var __taggedTemplateLiteral = 40;
function tag(parts) { return parts[0] + ':' + parts.raw[0]; }
console.log(__taggedTemplateLiteral, tag\`hello\`);
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, ['input.ts', '--target=es5', '-o', output]);
    expect(result.exitCode, result.stderr).toBe(0);

    const code = readFileSync(output, 'utf8');
    expect(code).toMatch(/var __taggedTemplateLiteral2 = function\(cooked, raw\)/);
    expect(code).toMatch(/__taggedTemplateLiteral2\(/);
    expect(code).not.toMatch(/\b__taggedTemplateLiteral\(/);

    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe('40 hello:hello\n');
  });

  test('standalone minified ES5 tagged template preamble uses the collision-free helper SymbolId name', async () => {
    const fixture = await createFixture({
      'input.ts': `
var $tt = 40;
function tag(parts) { return parts[0] + ':' + parts.raw[0]; }
console.log($tt, tag\`hello\`);
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, [
      'input.ts',
      '--target=es5',
      '--minify-whitespace',
      '-o',
      output,
    ]);
    expect(result.exitCode, result.stderr).toBe(0);

    const code = readFileSync(output, 'utf8');
    const emittedHelper = code.match(/var (\$tt[a-zA-Z0-9_$]*)=function\(cooked,raw\)/)?.[1];
    expect(emittedHelper).toBeDefined();
    expect(emittedHelper).not.toBe('$tt');
    expect(code).toContain(`${emittedHelper}(`);

    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe('40 hello:hello\n');
  });

  for (const variant of [
    {
      target: 'es5',
      minify: false,
      sourceName: '__async',
      declaration: /var (__async\d*) = function\(fn\)/,
    },
    {
      target: 'es5',
      minify: true,
      sourceName: '$aS',
      declaration: /var (\$aS[a-zA-Z0-9_$]*)=function\(fn\)/,
    },
    {
      target: 'es2015',
      minify: false,
      sourceName: '__async',
      declaration: /var (__async\d*) = \(fn\) =>/,
    },
    {
      target: 'es2015',
      minify: true,
      sourceName: '$aS',
      declaration: /var (\$aS[a-zA-Z0-9_$]*)=\(fn\)=>/,
    },
  ] as const) {
    test(`standalone ${variant.minify ? 'minified ' : ''}${variant.target} async preamble uses the collision-free helper SymbolId name`, async () => {
      const fixture = await createFixture({
        'input.ts': `
var ${variant.sourceName} = 40;
async function getValue() { return 7; }
getValue().then(value => console.log(${variant.sourceName}, value));
`,
      });
      cleanup = fixture.cleanup;
      const output = join(fixture.dir, 'out.js');
      const result = await runZntcInDir(fixture.dir, [
        'input.ts',
        `--target=${variant.target}`,
        ...(variant.minify ? ['--minify-whitespace'] : []),
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const code = readFileSync(output, 'utf8');
      const emittedHelper = code.match(variant.declaration)?.[1];
      expect(emittedHelper).toBeDefined();
      expect(emittedHelper).not.toBe(variant.sourceName);
      expect(code).toContain(`${emittedHelper}(`);
      expect(code).not.toContain(`${variant.sourceName}(`);

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe('40 7\n');
    });
  }

  for (const minify of [false, true]) {
    test(`standalone ${minify ? 'minified ' : ''}ES2017 async-generator helper family uses collision-free SymbolId names`, async () => {
      const awaitSourceName = '__await';
      const asyncGeneratorSourceName = '__asyncGenerator';
      const yieldStarSourceName = minify ? '$yS' : '__yieldStar';
      const fixture = await createFixture({
        'input.ts': `
var ${awaitSourceName} = 101;
var ${asyncGeneratorSourceName} = 102;
var ${yieldStarSourceName} = 103;
async function* delegated() { yield 4; yield 5; }
async function* values() {
  yield await Promise.resolve(3);
  yield* delegated();
}
function collect(iterator: AsyncGenerator<number>, result: number[]): Promise<void> {
  return iterator.next().then(function (step) {
    if (step.done) {
      console.log(result.join(','), ${awaitSourceName}, ${asyncGeneratorSourceName}, ${yieldStarSourceName});
      return;
    }
    result.push(step.value);
    return collect(iterator, result);
  });
}
collect(values(), []);
`,
      });
      cleanup = fixture.cleanup;
      const output = join(fixture.dir, 'out.js');
      const result = await runZntcInDir(fixture.dir, [
        'input.ts',
        '--target=es2017',
        ...(minify ? ['--minify-whitespace'] : []),
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const code = readFileSync(output, 'utf8');
      const awaitHelper = code.match(
        minify
          ? /var (__await[a-zA-Z0-9_$]*)=function\(v,s\)/
          : /var (__await\w*) = function\(v, s\)/,
      )?.[1];
      const asyncGeneratorHelper = code.match(
        minify
          ? /var (__asyncGenerator[a-zA-Z0-9_$]*)=function\(thisArg,_arguments,generator\)/
          : /var (__asyncGenerator\w*) = function\(thisArg, _arguments, generator\)/,
      )?.[1];
      const yieldStarHelper = code.match(
        minify
          ? /var (\$yS[a-zA-Z0-9_$]*)=function\(value\)/
          : /var (__yieldStar\w*) = function\(value\)/,
      )?.[1];
      expect(awaitHelper).toBeDefined();
      expect(asyncGeneratorHelper).toBeDefined();
      expect(yieldStarHelper).toBeDefined();
      expect(awaitHelper).not.toBe(awaitSourceName);
      expect(asyncGeneratorHelper).not.toBe(asyncGeneratorSourceName);
      expect(yieldStarHelper).not.toBe(yieldStarSourceName);
      expect(code).toContain(`this instanceof ${awaitHelper}`);
      expect(code).toContain(`r.value instanceof ${awaitHelper}`);
      expect(code).toContain(`${awaitHelper}(new Promise`);
      expect(code).toContain(`${asyncGeneratorHelper}(this`);
      expect(code).toContain(`${yieldStarHelper}(delegated())`);

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe('3,4,5 101 102 103\n');
    });
  }

  for (const minify of [false, true]) {
    test(`standalone ${minify ? 'minified ' : ''}ES5 values preamble uses the collision-free helper SymbolId name`, async () => {
      const fixture = await createFixture({
        'input.ts': `
var __values = 40;
var total = 0;
for (var value of [7]) total += value;
console.log(__values, total);
`,
      });
      cleanup = fixture.cleanup;
      const output = join(fixture.dir, 'out.js');
      const result = await runZntcInDir(fixture.dir, [
        'input.ts',
        '--target=es5',
        ...(minify ? ['--minify-whitespace'] : []),
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const code = readFileSync(output, 'utf8');
      expect(code).toMatch(/var __values2\s*=\s*function\(o\)/);
      expect(code).toContain('__values2(');
      expect(code).not.toMatch(/\b__values\(/);

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe('40 7\n');
    });
  }

  for (const minify of [false, true]) {
    test(`standalone ${minify ? 'minified ' : ''}async-values fallback follows the direct values helper SymbolId`, async () => {
      const fixture = await createFixture({
        'input.ts': `
var __values = 40;
async function process() {
  var total = 0;
  for (var value of [7]) total += value;
  for await (var asyncValue of [8]) total += asyncValue;
  return total;
}
process().then(total => console.log(__values, total));
`,
      });
      cleanup = fixture.cleanup;
      const output = join(fixture.dir, 'out.js');
      const result = await runZntcInDir(fixture.dir, [
        'input.ts',
        '--target=es5',
        ...(minify ? ['--minify-whitespace'] : []),
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const code = readFileSync(output, 'utf8');
      expect(code).toMatch(/var __values2\s*=\s*function\(o\)/);
      expect(code).toMatch(/typeof __values2\s*===\s*["']function["']\s*\?\s*__values2\(o\)/);
      expect(code).not.toMatch(/typeof __values\s*===\s*["']function["']\s*\?\s*__values\(o\)/);

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe('40 15\n');
    });
  }

  for (const minify of [false, true]) {
    test(`standalone ${minify ? 'minified ' : ''}ES5 async-values preamble uses the collision-free helper SymbolId name`, async () => {
      const sourceName = minify ? '$aV' : '__asyncValues';
      const fixture = await createFixture({
        'input.ts': `
var __values = 30;
var ${sourceName} = 40;
async function sum() {
  var total = 0;
  for (var syncValue of [1]) total += syncValue;
  for await (var value of [7]) total += value;
  return total;
}
sum().then(total => console.log(${sourceName}, __values, total));
`,
      });
      cleanup = fixture.cleanup;
      const output = join(fixture.dir, 'out.js');
      const result = await runZntcInDir(fixture.dir, [
        'input.ts',
        '--target=es5',
        ...(minify ? ['--minify-whitespace'] : []),
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const code = readFileSync(output, 'utf8');
      const emittedHelper = minify
        ? code.match(/var (\$aV[a-zA-Z0-9_$]*)=function\(o\)/)?.[1]
        : code.match(/var (__asyncValues\d*) = function\(o\)/)?.[1];
      expect(emittedHelper).toBeDefined();
      expect(emittedHelper).not.toBe(sourceName);
      expect(code).toContain(`${emittedHelper}([7])`);
      expect(code).toMatch(/var __values2\s*=\s*function\(o\)/);
      expect(code).toMatch(/typeof __values2\s*===\s*["']function["']\s*\?\s*__values2\(o\)/);
      expect(code).not.toMatch(/typeof __values\s*===\s*["']function["']\s*\?\s*__values\(o\)/);

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe('40 30 8\n');
    });
  }

  for (const minify of [false, true]) {
    test(`standalone ${minify ? 'minified ' : ''}ES5 read preamble uses the collision-free helper SymbolId name`, async () => {
      const sourceName = minify ? '$rd' : '__read';
      const fixture = await createFixture({
        'input.ts': `
var ${sourceName} = 40;
const [first, second] = [7, 8];
console.log(${sourceName}, first, second);
`,
      });
      cleanup = fixture.cleanup;
      const output = join(fixture.dir, 'out.js');
      const result = await runZntcInDir(fixture.dir, [
        'input.ts',
        '--target=es5',
        ...(minify ? ['--minify-whitespace'] : []),
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const code = readFileSync(output, 'utf8');
      const emittedHelper = minify
        ? code.match(/var (\$rd[a-zA-Z0-9_$]*)=function\(o,n\)/)?.[1]
        : code.match(/var (__read\d*) = function\(o, n\)/)?.[1];
      expect(emittedHelper).toBeDefined();
      expect(emittedHelper).not.toBe(sourceName);
      expect(code).toContain(`${emittedHelper}(`);

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe('40 7 8\n');
    });
  }

  for (const minify of [false, true]) {
    test(`standalone ${minify ? 'minified ' : ''}ES5 public-field preamble uses the collision-free helper SymbolId name`, async () => {
      const sourceName = minify ? '$pb' : '__publicField';
      const fixture = await createFixture({
        'input.ts': `
var ${sourceName} = 40;
class C { value = 7; }
console.log(${sourceName}, new C().value);
`,
      });
      cleanup = fixture.cleanup;
      const output = join(fixture.dir, 'out.js');
      const result = await runZntcInDir(fixture.dir, [
        'input.ts',
        '--target=es5',
        ...(minify ? ['--minify-whitespace'] : []),
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const code = readFileSync(output, 'utf8');
      const emittedHelper = minify
        ? code.match(/var (\$pb[a-zA-Z0-9_$]*)=function\(obj,key,value\)/)?.[1]
        : code.match(/var (__publicField\d*) = function\(obj, key, value\)/)?.[1];
      expect(emittedHelper).toBeDefined();
      expect(emittedHelper).not.toBe(sourceName);
      expect(code).toContain(`${emittedHelper}(this`);

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe('40 7\n');
    });
  }

  for (const minify of [false, true]) {
    test(`standalone ${minify ? 'minified ' : ''}ES5 parameter-TDZ preamble uses the collision-free helper SymbolId name`, async () => {
      const sourceName = minify ? '$td' : '__tdz';
      const fixture = await createFixture({
        'input.ts': `
var ${sourceName} = 40;
function f(a = b, b = 2) { return a; }
try { f(); } catch (error) { console.log(${sourceName}, error instanceof ReferenceError); }
`,
      });
      cleanup = fixture.cleanup;
      const output = join(fixture.dir, 'out.js');
      const result = await runZntcInDir(fixture.dir, [
        'input.ts',
        '--target=es5',
        ...(minify ? ['--minify-whitespace'] : []),
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const code = readFileSync(output, 'utf8');
      const emittedHelper = minify
        ? code.match(/var (\$td[a-zA-Z0-9_$]*)=function\(name\)/)?.[1]
        : code.match(/var (__tdz\d*) = function\(name\)/)?.[1];
      expect(emittedHelper).toBeDefined();
      expect(emittedHelper).not.toBe(sourceName);
      expect(code).toContain(`${emittedHelper}("b")`);

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe('40 true\n');
    });
  }

  for (const minify of [false, true]) {
    test(`standalone ${minify ? 'minified ' : ''}ES5 class-call-check preamble uses the collision-free helper SymbolId name`, async () => {
      const sourceName = minify ? '$cC' : '__classCallCheck';
      const fixture = await createFixture({
        'input.ts': `
var ${sourceName} = 40;
class C {}
console.log(${sourceName}, new C() instanceof C);
`,
      });
      cleanup = fixture.cleanup;
      const output = join(fixture.dir, 'out.js');
      const result = await runZntcInDir(fixture.dir, [
        'input.ts',
        '--target=es5',
        ...(minify ? ['--minify-whitespace'] : []),
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const code = readFileSync(output, 'utf8');
      const emittedHelper = minify
        ? code.match(/var (\$cC[a-zA-Z0-9_$]*)=function\(instance,Constructor\)/)?.[1]
        : code.match(/var (__classCallCheck\d*) = function\(instance, Constructor\)/)?.[1];
      expect(emittedHelper).toBeDefined();
      expect(emittedHelper).not.toBe(sourceName);
      expect(code).toContain(minify ? `${emittedHelper}(this,C)` : `${emittedHelper}(this, C)`);

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe('40 true\n');
    });
  }

  for (const minify of [false, true]) {
    test(`standalone ${minify ? 'minified ' : ''}ES5 private-method-init preamble uses the collision-free helper SymbolId name`, async () => {
      const sourceName = minify ? '$pI' : '__classPrivateMethodInit';
      const fixture = await createFixture({
        'input.ts': `
var ${sourceName} = 40;
class C { #m() { return 7; } run() { return this.#m(); } }
console.log(${sourceName}, new C().run());
`,
      });
      cleanup = fixture.cleanup;
      const output = join(fixture.dir, 'out.js');
      const result = await runZntcInDir(fixture.dir, [
        'input.ts',
        '--target=es5',
        ...(minify ? ['--minify-whitespace'] : []),
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const code = readFileSync(output, 'utf8');
      const emittedHelper = minify
        ? code.match(/var (\$pI[a-zA-Z0-9_$]*)=function\(obj,privateSet\)/)?.[1]
        : code.match(/var (__classPrivateMethodInit\d*) = function\(obj, privateSet\)/)?.[1];
      expect(emittedHelper).toBeDefined();
      expect(emittedHelper).not.toBe(sourceName);
      expect(code).toContain(minify ? `${emittedHelper}(this,_m)` : `${emittedHelper}(this, _m)`);

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe('40 7\n');
    });
  }

  for (const minify of [false, true]) {
    test(`standalone ${minify ? 'minified ' : ''}ES5 private-method-get preamble uses the collision-free helper SymbolId name`, async () => {
      const sourceName = minify ? '$pG' : '__classPrivateMethodGet';
      const fixture = await createFixture({
        'input.ts': `
var ${sourceName} = 40;
class C { #m() { return 7; } run() { return this.#m(); } }
console.log(${sourceName}, new C().run());
`,
      });
      cleanup = fixture.cleanup;
      const output = join(fixture.dir, 'out.js');
      const result = await runZntcInDir(fixture.dir, [
        'input.ts',
        '--target=es5',
        ...(minify ? ['--minify-whitespace'] : []),
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const code = readFileSync(output, 'utf8');
      const emittedHelper = minify
        ? code.match(/var (\$pG[a-zA-Z0-9_$]*)=function\(receiver,privateSet,fn\)/)?.[1]
        : code.match(
            /var (__classPrivateMethodGet\d*) = function\(receiver, privateSet, fn\)/,
          )?.[1];
      expect(emittedHelper).toBeDefined();
      expect(emittedHelper).not.toBe(sourceName);
      expect(code).toContain(
        minify ? `${emittedHelper}(this,_m,_m_fn)` : `${emittedHelper}(this, _m, _m_fn)`,
      );

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe('40 7\n');
    });
  }

  for (const minify of [false, true]) {
    test(`standalone ${minify ? 'minified ' : ''}ES5 private-field-set preamble uses the collision-free helper SymbolId name`, async () => {
      // Plain output isolates the tslib UMD alias used by this inline helper.
      const sourceName = minify ? '$pF' : '__zntcClassPrivateFieldSet';
      const fixture = await createFixture({
        'input.ts': `
var ${sourceName} = 40;
class Box {
  #value = 0;
  write(value) { return this.#value = value; }
  read() { return this.#value; }
}
var box = new Box();
console.log(${sourceName}, box.write(7), box.read());
`,
      });
      cleanup = fixture.cleanup;
      const output = join(fixture.dir, 'out.js');
      const result = await runZntcInDir(fixture.dir, [
        'input.ts',
        '--target=es5',
        ...(minify ? ['--minify-whitespace'] : []),
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const code = readFileSync(output, 'utf8');
      const emittedHelper = minify
        ? code.match(/var (\$pF[a-zA-Z0-9_$]*)=function\(wm,obj,value\)/)?.[1]
        : code.match(/var (__zntcClassPrivateFieldSet\d*) = function\(wm, obj, value\)/)?.[1];
      expect(emittedHelper).toBeDefined();
      expect(emittedHelper).not.toBe(sourceName);
      expect(code).toContain(
        minify ? `${emittedHelper}(_value,this,value)` : `${emittedHelper}(_value, this, value)`,
      );

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe('40 7 7\n');
    });
  }

  for (const minify of [false, true]) {
    test(`standalone ${minify ? 'minified ' : ''}ES5 keep-names preamble uses the collision-free helper SymbolId name`, async () => {
      const sourceName = minify ? '$nm' : '__name';
      const fixture = await createFixture({
        'input.ts': `
var x = 3, ${sourceName} = 40;
function f(value = x) { var x = function() {}; return [value, x.name]; }
console.log(JSON.stringify([f(7), ${sourceName}]));
`,
      });
      cleanup = fixture.cleanup;
      const output = join(fixture.dir, 'out.js');
      const result = await runZntcInDir(fixture.dir, [
        'input.ts',
        '--target=es5',
        ...(minify ? ['--minify-whitespace'] : []),
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const code = readFileSync(output, 'utf8');
      const emittedHelper = minify
        ? code.match(/var (\$nm[a-zA-Z0-9_$]*)=\(function\(d\)/)?.[1]
        : code.match(/var (__name\d*) = \(function\(defineProperty\)/)?.[1];
      expect(emittedHelper).toBeDefined();
      expect(emittedHelper).not.toBe(sourceName);
      expect(code).toContain(
        minify ? `${emittedHelper}(function(){},"x")` : `${emittedHelper}(function()`,
      );

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe('[[7,"x"],40]\n');
    });
  }

  for (const minify of [false, true]) {
    test(`standalone ${minify ? 'minified ' : ''}ES5 wrap-regexp preamble uses the collision-free helper SymbolId name`, async () => {
      const sourceName = minify ? '$wR' : '__wrapRegExp';
      const fixture = await createFixture({
        'input.ts': `
var ${sourceName} = 40;
var match = 'item-7'.match(/(?<kind>[a-z]+)-(?<count>\\d+)/);
console.log(${sourceName}, match.groups.kind, match.groups.count);
`,
      });
      cleanup = fixture.cleanup;
      const output = join(fixture.dir, 'out.js');
      const result = await runZntcInDir(fixture.dir, [
        'input.ts',
        '--target=es5',
        ...(minify ? ['--minify-whitespace'] : []),
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const code = readFileSync(output, 'utf8');
      const emittedHelper = minify
        ? code.match(/var (\$wR[a-zA-Z0-9_$]*)=function\(\)/)?.[1]
        : code.match(/var (__wrapRegExp\d*) = function\(\)/)?.[1];
      expect(emittedHelper).toBeDefined();
      expect(emittedHelper).not.toBe(sourceName);
      expect(code).toContain(
        minify ? `${emittedHelper}=function(re,groups)` : `${emittedHelper} = function(re, groups)`,
      );
      expect(code).toContain(`match(${emittedHelper}(`);

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe('40 item 7\n');
    });
  }

  for (const minify of [false, true]) {
    test(`standalone ${minify ? 'minified ' : ''}ES5 call-super preamble uses the collision-free helper SymbolId name`, async () => {
      const sourceName = minify ? '$cS' : '__callSuper';
      const fixture = await createFixture({
        'input.ts': `
var ${sourceName} = 40;
class Base { constructor(value) { this.value = value; } }
class Child extends Base { constructor(value) { super(value); this.ready = true; } }
var child = new Child(7);
console.log(${sourceName}, child.value, child.ready);
`,
      });
      cleanup = fixture.cleanup;
      const output = join(fixture.dir, 'out.js');
      const result = await runZntcInDir(fixture.dir, [
        'input.ts',
        '--target=es5',
        ...(minify ? ['--minify-whitespace'] : []),
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const code = readFileSync(output, 'utf8');
      const emittedHelper = minify
        ? code.match(/var (\$cS[a-zA-Z0-9_$]*)=function\(Parent,args,NewTarget\)/)?.[1]
        : code.match(/var (__callSuper\d*) = function\(Parent, args, NewTarget\)/)?.[1];
      expect(emittedHelper).toBeDefined();
      expect(emittedHelper).not.toBe(sourceName);
      expect(code).toContain(
        minify
          ? `${emittedHelper}(_super,[value],_newTarget)`
          : `${emittedHelper}(_super, [value], _newTarget)`,
      );

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe('40 7 true\n');
    });
  }

  for (const minify of [false, true]) {
    test(`standalone ${minify ? 'minified ' : ''}ES5 super-get preamble uses the collision-free helper SymbolId name`, async () => {
      const sourceName = minify ? '$sPg' : '__superGet';
      const fixture = await createFixture({
        'input.ts': `
var ${sourceName} = 40;
class Base { get value() { return this._value; } }
class Child extends Base { read() { return super.value; } }
var child = new Child();
child._value = 7;
console.log(${sourceName}, child.read());
`,
      });
      cleanup = fixture.cleanup;
      const output = join(fixture.dir, 'out.js');
      const result = await runZntcInDir(fixture.dir, [
        'input.ts',
        '--target=es5',
        ...(minify ? ['--minify-whitespace'] : []),
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const code = readFileSync(output, 'utf8');
      const emittedHelper = minify
        ? code.match(/var (\$sPg[a-zA-Z0-9_$]*)=function\(parent,prop,receiver\)/)?.[1]
        : code.match(/var (__superGet\d*) = function\(parent, prop, receiver\)/)?.[1];
      expect(emittedHelper).toBeDefined();
      expect(emittedHelper).not.toBe(sourceName);
      expect(code).toContain(
        minify
          ? `${emittedHelper}(_super.prototype,"value",this)`
          : `${emittedHelper}(_super.prototype, "value", this)`,
      );

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe('40 7\n');
    });
  }

  for (const minify of [false, true]) {
    test(`standalone ${minify ? 'minified ' : ''}ES5 super-set preamble uses the collision-free helper SymbolId name`, async () => {
      const sourceName = minify ? '$sPs' : '__superSet';
      const fixture = await createFixture({
        'input.ts': `
var ${sourceName} = 40;
class Base {
  get value() { return this._value; }
  set value(value) { this._value = value; }
}
class Child extends Base { write(value) { return super.value = value; } }
var child = new Child();
console.log(${sourceName}, child.write(7), child.value);
`,
      });
      cleanup = fixture.cleanup;
      const output = join(fixture.dir, 'out.js');
      const result = await runZntcInDir(fixture.dir, [
        'input.ts',
        '--target=es5',
        ...(minify ? ['--minify-whitespace'] : []),
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const code = readFileSync(output, 'utf8');
      const emittedHelper = minify
        ? code.match(/var (\$sPs[a-zA-Z0-9_$]*)=function\(parent,prop,value,receiver\)/)?.[1]
        : code.match(/var (__superSet\d*) = function\(parent, prop, value, receiver\)/)?.[1];
      expect(emittedHelper).toBeDefined();
      expect(emittedHelper).not.toBe(sourceName);
      expect(code).toContain(
        minify
          ? `${emittedHelper}(_super.prototype,"value",value,this)`
          : `${emittedHelper}(_super.prototype, "value", value, this)`,
      );

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe('40 7 7\n');
    });
  }

  for (const target of ['es5', 'es2020'] as const) {
    for (const metadata of [false, true]) {
      for (const mode of ['single', 'bundle', 'split'] as const) {
        for (const minify of [false, true]) {
          test(`${target}, ${metadata ? 'metadata' : 'decorator'}: ${mode}, ${minify ? 'minify' : 'plain'}`, async () => {
            const fixtureSource = target === 'es5' && metadata ? es5MetadataSource : source;
            const reference = ts.transpileModule(fixtureSource, {
              compilerOptions: {
                experimentalDecorators: true,
                emitDecoratorMetadata: metadata,
                target: target === 'es5' ? ts.ScriptTarget.ES5 : ts.ScriptTarget.ES2020,
                module: ts.ModuleKind.ESNext,
              },
            }).outputText;
            const fixture = await createFixture({
              'input.ts': fixtureSource,
              'entry.ts': "import('./input');",
              'package.json': '{"type":"module"}',
              'reference.mjs': reference,
              'tsconfig.json': JSON.stringify({
                compilerOptions: {
                  experimentalDecorators: true,
                  emitDecoratorMetadata: metadata,
                },
              }),
            });
            cleanup = fixture.cleanup;
            const native = spawnSync('node', [join(fixture.dir, 'reference.mjs')], {
              encoding: 'utf8',
            });
            expect(native.status).toBe(0);
            expect(native.stdout.trim().length).toBeGreaterThan(0);
            const out = join(fixture.dir, mode === 'split' ? 'dist/entry.js' : 'out.cjs');
            const result = await runZntcInDir(fixture.dir, [
              ...(mode === 'single' ? [] : ['--bundle']),
              mode === 'split' ? 'entry.ts' : 'input.ts',
              `--target=${target}`,
              ...(minify ? ['--minify-identifiers', '--minify-syntax'] : []),
              ...(mode === 'single' ? [] : ['--platform=node']),
              ...(mode === 'split'
                ? ['--format=esm', '--splitting', '--outdir', 'dist']
                : [...(mode === 'bundle' ? ['--format=cjs'] : []), '-o', out]),
            ]);
            expect(result.exitCode, result.stderr).toBe(0);
            const runtime = spawnSync('node', [out], { encoding: 'utf8' });
            expect(runtime.status).toBe(0);
            expect(runtime.stdout).toBe(native.stdout);
          });
        }
      }
    }
  }

  test('metadata references retain nested classes and shadowed built-ins in the transform graph', async () => {
    const metadataSource = `
import type { Phantom } from './types';
import { type Phantom as a } from './types';
const events: string[] = [];
function decorate(): any { return () => {}; }
function build(Number: any, Object: any) {
  class LocalType { static marker = 'local-type'; }
  const expectedNumber = Number;
  const expectedObject = Object;
  const expectedLocalType = LocalType;
  (Reflect as any).metadata = (key: string, value: any) => (_target: any, property?: string) => {
    if (key !== 'design:paramtypes') return;
    const names = value.map((item: any) =>
      item === expectedNumber ? 'shadowed-number' :
      item === expectedObject ? 'shadowed-object' :
      item === expectedLocalType ? 'local-class' :
      item === globalThis.Object ? 'global-object' : 'other');
    events.push((property ?? 'class') + ':' + names.join(','));
  };
  @decorate()
  class Service {
    constructor(number: number, local: LocalType, phantom: Phantom, inlinePhantom: a) {}
    @decorate() method(local: LocalType) { return local; }
  }
  return Service;
}
class ShadowNumber {}
class ShadowObject {}
const Service = build(ShadowNumber, ShadowObject);
new Service(ShadowNumber, ShadowObject, Service).method(Service);
console.log(events.join('|'));
`;
    const fixture = await createFixture({
      'input.ts': metadataSource,
      'tsconfig.json': JSON.stringify({
        compilerOptions: { experimentalDecorators: true, emitDecoratorMetadata: true },
      }),
    });
    cleanup = fixture.cleanup;

    const reference = ts.transpileModule(metadataSource, {
      compilerOptions: {
        experimentalDecorators: true,
        emitDecoratorMetadata: true,
        target: ts.ScriptTarget.ES2020,
        module: ts.ModuleKind.CommonJS,
      },
    }).outputText;
    writeFileSync(join(fixture.dir, 'reference.js'), reference);
    const native = spawnSync('node', [join(fixture.dir, 'reference.js')], { encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);

    const output = join(fixture.dir, 'out.js');
    const proc = spawnSync(
      ZNTC_BIN,
      ['input.ts', '--minify-identifiers', '--minify-syntax', '-o', output],
      {
        cwd: fixture.dir,
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      },
    );
    expect(proc.status, proc.stderr).toBe(0);
    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe(native.stdout);

    const exact = proc.stderr
      .split('\n')
      .find((line) => line.includes('zntc: symbol-identity input.ts:'));
    expect(exact).toContain('shadowed_external_reference=0');
    expect(exact).toContain('missing_binding=0');
    expect(exact).toContain('identity_mismatch=0');
    expect(exact).toContain('clean=1');
    expect(proc.stderr).toMatch(
      /symbol-identity-post-minify .* missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 clean=1/,
    );
  });

  for (const minify of [false, true]) {
    test(`type-only metadata ignores same-named globals and retains lexical classes: ${minify ? 'minify' : 'plain'}`, async () => {
      const metadataSource = `
import type DefaultType from './types';
import type * as Types from './types';
import type { Phantom, Object, Number, Symbol, BigInt } from './types';
import { type Phantom as Alias } from './types';
(globalThis as any).Phantom = class GlobalPhantom {};
(globalThis as any).Alias = class GlobalAlias {};
(globalThis as any).DefaultType = class GlobalDefault {};
(globalThis as any).Types = { Member: class GlobalMember {} };
const events: string[] = [];
const localTypes: any[] = [];
function decorate(): any { return () => {}; }
(Reflect as any).metadata = (key: string, value: any) => (_target: any, property?: string) => {
  if (key !== 'design:paramtypes') return;
  const names = value.map((item: any) =>
    item === globalThis.Object ? 'object' :
    item === globalThis.Number ? 'number' :
    item === globalThis.Symbol ? 'symbol' :
    item === globalThis.BigInt ? 'bigint' :
    localTypes.includes(item) ? 'local-class' : 'unexpected');
  events.push(property + ':' + names.join(','));
};
class Imported {
  @decorate() imported(named: Phantom, inline: Alias, defaultType: DefaultType,
    qualified: Types.Member, count: number, object: Object, symbol: symbol, bigint: bigint) {}
}
function buildLocal() {
  class Phantom {}
  localTypes.push(Phantom);
  class Local { @decorate() local(value: Phantom) {} }
  return Local;
}
buildLocal();
console.log(events.join('|'));
`;
      const reference = ts.transpileModule(metadataSource, {
        compilerOptions: {
          experimentalDecorators: true,
          emitDecoratorMetadata: true,
          target: ts.ScriptTarget.ES2020,
          module: ts.ModuleKind.CommonJS,
        },
      }).outputText;
      const fixture = await createFixture({
        'input.ts': metadataSource,
        'reference.js': reference,
        'tsconfig.json': JSON.stringify({
          compilerOptions: { experimentalDecorators: true, emitDecoratorMetadata: true },
        }),
      });
      cleanup = fixture.cleanup;
      const native = spawnSync('node', [join(fixture.dir, 'reference.js')], { encoding: 'utf8' });
      expect(native.status, native.stderr).toBe(0);
      expect(native.stdout.trim()).toBe(
        'imported:object,object,object,object,number,object,symbol,bigint|local:local-class',
      );

      const output = join(fixture.dir, 'out.js');
      const proc = spawnSync(
        ZNTC_BIN,
        ['input.ts', ...(minify ? ['--minify-identifiers', '--minify-syntax'] : []), '-o', output],
        {
          cwd: fixture.dir,
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
          encoding: 'utf8',
        },
      );
      expect(proc.status, proc.stderr).toBe(0);
      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe(native.stdout);
      const exact = proc.stderr
        .split('\n')
        .find((line) => line.includes('zntc: symbol-identity input.ts:'));
      expect(exact).toContain('unclassified_reference=0');
      expect(exact).toContain('shadowed_external_reference=0');
      expect(exact).toContain('clean=1');
      if (minify) {
        expect(proc.stderr).toMatch(
          /symbol-identity-post-minify .* missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 clean=1/,
        );
      }
    });
  }

  const qualifiedMetadataSource = `
const events: string[] = [];
function decorate(): any { return () => {}; }
(Reflect as any).metadata = (key: string, value: any) => (_target: any, property?: string) => {
  if (key !== 'design:paramtypes') return;
  const names = value.map((item: any) =>
    item === rootLocal ? 'root-local' :
    item === rootGeneric ? 'root-generic' :
    item === shadowLocal ? 'shadow-local' :
    item === globalThis.Array ? 'array' :
    item === globalThis.Object ? 'object' :
    'other');
  events.push((property ?? 'class') + ':' + names.join(','));
};
namespace Types { export class Local {} export class Generic<T> {} }
const rootLocal = Types.Local;
const rootGeneric = Types.Generic;
class ShadowLocal {}
let shadowLocal: any;
function build(Types: any) {
  shadowLocal = Types.Local;
  class ShadowBox { @decorate() method(value: Types.Local) {} }
  return ShadowBox;
}
@decorate()
class RootBox {
  @decorate() local(value: Types.Local) {}
  @decorate() generic(value: Types.Generic<string>) {}
  @decorate() array(value: Types.Local[]) {}
  @decorate() union(value: Types.Local | null) {}
}
const ShadowBox = build({ Local: ShadowLocal });
new RootBox().local(rootLocal);
new RootBox().generic(rootGeneric);
new RootBox().array([rootLocal]);
new RootBox().union(rootLocal);
new ShadowBox().method(shadowLocal);
console.log(events.join('|'));
`;

  test('qualified metadata refs retain lexical base symbols', async () => {
    const fixture = await createFixture({
      'input.ts': qualifiedMetadataSource,
      'tsconfig.json': JSON.stringify({
        compilerOptions: { experimentalDecorators: true, emitDecoratorMetadata: true },
      }),
    });
    cleanup = fixture.cleanup;

    const reference = ts.transpileModule(qualifiedMetadataSource, {
      compilerOptions: {
        experimentalDecorators: true,
        emitDecoratorMetadata: true,
        target: ts.ScriptTarget.ES2020,
        module: ts.ModuleKind.CommonJS,
      },
    }).outputText;
    const referencePath = join(fixture.dir, 'reference.js');
    writeFileSync(referencePath, reference);
    const native = spawnSync('node', [referencePath], { encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);

    const output = join(fixture.dir, 'out.js');
    const proc = spawnSync(
      ZNTC_BIN,
      ['input.ts', '--target=es2020', '--minify-identifiers', '--minify-syntax', '-o', output],
      {
        cwd: fixture.dir,
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      },
    );
    expect(proc.status, proc.stderr).toBe(0);
    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe(native.stdout);

    const exact = proc.stderr
      .split('\n')
      .find((line) => line.includes('zntc: symbol-identity input.ts:'));
    expect(exact).toContain('missing_binding=0');
    expect(exact).toContain('shadowed_external_reference=0');
    expect(exact).toContain('clean=1');
    expect(proc.stderr).toMatch(
      /symbol-identity-post-minify .* missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 clean=1/,
    );
  });
});
