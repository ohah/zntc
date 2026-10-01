import { afterEach, describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, runNode, runZntc } from './helpers';

const EXACT_ZERO_COUNTERS = [
  'invalid_id',
  'invalid_reference_node',
  'unreachable_reference',
  'ambiguous_ast_parent',
  'shadowed_external_reference',
  'duplicate_reference',
  'identity_mismatch',
  'binding_scope_mismatch',
  'binding_scope_unknown',
  'invalid_scope',
  'reference_scope_mismatch',
  'scope_map_mismatch',
  'scope_owner_mismatch',
  'scope_resolution_mismatch',
  'invisible_reference',
  'reference_count_mismatch',
  'write_count_mismatch',
  'missing_binding',
  'missing_reference',
  'unclassified_reference',
];

describe('#4819 transform semantic graph for JavaScript mangling', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  async function expectNativeParity(source: string, expected: string) {
    const fixture = await createFixture({ 'input.js': source });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.js');
    const output = join(fixture.dir, 'output.js');
    const result = await runZntc([input, '-o', output, '--minify-identifiers']);
    expect(result.exitCode).toBe(0);
    expect(result.stderr).toBe('');
    const native = await runNode(input);
    const transformed = await runNode(output);
    expect(native.stdout).toBe(expected);
    expect(transformed.stdout).toBe(native.stdout);
  }

  async function expectEs5Parity(source: string, expected: string, minifySyntax = false) {
    const fixture = await createFixture({ 'input.js': source });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.js');
    const output = join(fixture.dir, 'output.js');
    const result = await runZntc(
      [
        input,
        '-o',
        output,
        '--target=es5',
        '--minify-identifiers',
        ...(minifySyntax ? ['--minify-syntax'] : []),
      ],
      { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
    );
    expect(result.exitCode).toBe(0);
    expect(result.stderr).toMatch(/symbol-coverage .*missing=0 wrong=0/);
    const identity = result.stderr
      .split(/\r?\n/)
      .find((line) => line.includes('zntc: symbol-identity '));
    expect(identity).toBeDefined();
    for (const counter of EXACT_ZERO_COUNTERS) {
      expect(identity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
    }
    const emitted = readFileSync(output, 'utf8');
    expect(emitted).not.toMatch(/\b(?:const|let)\s|\bfunction\s*\*|=>|\?\?|\?\.|\.\.\./);
    expect(emitted).not.toContain('class Base');
    expect(emitted).not.toContain('class Box');
    expect(emitted).not.toContain('#count');
    expect(emitted).not.toContain('#value');
    const native = await runNode(input);
    const transformed = await runNode(output);
    expect(native.stdout).toBe(expected);
    expect(transformed.stdout).toBe(native.stdout);
  }

  test('ESM imports, named exports, and default exports keep one semantic graph', async () => {
    const fixture = await createFixture({
      'dependency.mjs': 'export const value = 8;',
      'input.mjs': `
        import { value as _loop } from './dependency.mjs';
        const _state = 3;
        const calculate = (local = _loop) => local + _state;
        export const result = calculate();
        const _default = calculate(9);
        export default _default;
        console.log(result, _default, _loop);
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.mjs');
    const output = join(fixture.dir, 'output.mjs');
    const result = await runZntc([input, '-o', output, '--minify-identifiers'], {
      env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
    });
    expect(result.exitCode).toBe(0);
    expect(result.stderr).toMatch(/symbol-coverage .*missing=0 wrong=0/);
    const identity = result.stderr
      .split(/\r?\n/)
      .find((line) => line.includes('zntc: symbol-identity '));
    expect(identity).toBeDefined();
    for (const counter of EXACT_ZERO_COUNTERS) {
      expect(identity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
    }
    const native = await runNode(input);
    const transformed = await runNode(output);
    expect(native.stdout).toBe('11 12 8');
    expect(transformed.stdout).toBe(native.stdout);
  });

  test('type-erased TypeScript imports and bindings reuse one semantic graph', async () => {
    const fixture = await createFixture({
      'dependency.mjs': `
        export const value = 8;
        export const extra = 5;
        export const Shape = {};
        export default 11;
      `,
      'input.ts': `
        import fallback, { value as _loop, type Shape as _Shape } from './dependency.mjs';
        import * as _namespace from './dependency.mjs';
        type Alias = number;
        interface Value extends _Shape { amount: Alias }
        const _state: Alias = 3;
        function calculate<T extends Value>(entry: T, initial: Alias = _loop): Alias {
          const local: Alias = entry.amount + initial + _state + fallback + _namespace.extra;
          return Number(eval('local'));
        }
        export const result: Alias = calculate({ amount: 2 });
        console.log(result, _state, _loop);
      `,
      'reference.mjs': `
        import fallback, { value as loop } from './dependency.mjs';
        import * as namespace from './dependency.mjs';
        const state = 3;
        const local = 2 + loop + state + fallback + namespace.extra;
        console.log(Number(eval('local')), state, loop);
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.ts');
    const output = join(fixture.dir, 'output.mjs');
    const result = await runZntc([input, '-o', output, '--minify-identifiers'], {
      env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
    });
    expect(result.exitCode, result.stderr).toBe(0);
    expect(result.stderr).toMatch(/symbol-coverage .*missing=0 wrong=0/);
    const identity = result.stderr
      .split(/\r?\n/)
      .find((line) => line.includes('zntc: symbol-identity '));
    expect(identity).toBeDefined();
    for (const counter of EXACT_ZERO_COUNTERS) {
      expect(identity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
    }
    const emitted = readFileSync(output, 'utf8');
    expect(emitted).not.toContain('interface Value');
    expect(emitted).not.toContain('type Alias');
    expect(emitted).not.toContain('_Shape');
    const reference = await runNode(join(fixture.dir, 'reference.mjs'));
    const transformed = await runNode(output);
    expect(reference.stdout).toBe('29 3 8');
    expect(transformed.stdout).toBe(reference.stdout);
  });

  test('type-erased TypeScript CommonJS output reserves wrapper names', async () => {
    const fixture = await createFixture({
      'dependency.cjs': 'exports.value = 8;\n',
      'input.ts': `
        import { value as dependencyValue } from './dependency.cjs';
        const exports: number = 1;
        const module: number = 2;
        const require: number = 3;
        const Object: number = 4;
        const __filename = 'f';
        const __dirname = 'd';
        function calculate(extra: number): number {
          return exports + module + require + Object + __filename.length + __dirname.length + extra + dependencyValue;
        }
        export const result: number = calculate(5);
        console.log(result, exports, module, require, Object, __filename, __dirname, dependencyValue);
      `,
      'reference.mjs': `
        import { value as dependencyValue } from './dependency.cjs';
        const exports = 1;
        const module = 2;
        const require = 3;
        const Object = 4;
        const __filename = 'f';
        const __dirname = 'd';
        function calculate(extra) {
          return exports + module + require + Object + __filename.length + __dirname.length + extra + dependencyValue;
        }
        const result = calculate(5);
        console.log(result, exports, module, require, Object, __filename, __dirname, dependencyValue);
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.ts');
    const output = join(fixture.dir, 'output.cjs');
    const result = await runZntc([input, '-o', output, '--format=cjs', '--minify-identifiers'], {
      env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
    });
    expect(result.exitCode, result.stderr).toBe(0);
    expect(result.stderr).toMatch(/symbol-coverage .*missing=0 wrong=0/);
    const identity = result.stderr
      .split(/\r?\n/)
      .find((line) => line.includes('zntc: symbol-identity '));
    expect(identity).toBeDefined();
    for (const counter of EXACT_ZERO_COUNTERS) {
      expect(identity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
    }
    const emitted = readFileSync(output, 'utf8');
    expect(emitted).toMatch(/exports\.result/);
    expect(emitted).not.toMatch(/\bvar exports\s*=/);
    const reference = await runNode(join(fixture.dir, 'reference.mjs'));
    const transformed = await runNode(output);
    expect(reference.stdout).toBe('25 1 2 3 4 f d 8');
    expect(transformed.stdout).toBe(reference.stdout);
  });

  test('copied declarations retain their binding and nested scope', async () => {
    await expectNativeParity(
      `
        const outside = 17;
        function calculate(argument) {
          const local = argument + outside;
          function capture(argument) { return local + argument; }
          return capture(5);
        }
        console.log(calculate(3));
      `,
      '25',
    );
  });

  test('unresolved globals and shadowed names keep their meaning', async () => {
    await expectNativeParity(
      `
        const values = new Map([['x', 7]]);
        function lookup(MapValue) {
          let values = MapValue + 2;
          return values;
        }
        console.log(values.get('x') + lookup(3));
      `,
      '12',
    );
  });

  test('downlevel loop closures and default parameters use the edited scope graph', async () => {
    await expectEs5Parity(
      `
        const _loop = 7;
        const _a = 40;
        function collect(values) {
          const readers = [];
          for (let index = 0; index < values.length; index++) {
            let _a = index;
            readers.push((fallback = _loop) => () => _a + fallback);
          }
          return readers.map((makeReader) => makeReader()()).join(',');
        }
        console.log(collect([1, 2, 3]), _a);
      `,
      '7,8,9 40',
    );
  });

  test('downlevel generator state and destructuring temps keep colliding source names', async () => {
    await expectEs5Parity(
      `
        const _state = 3;
        const _loop = 7;
        function* read(input = _state) {
          const { value = _loop, ...rest } = input ?? {};
          yield value;
          yield rest.extra ?? _state;
        }
        const first = Array.from(read({ value: 9, extra: 5 }));
        const second = Array.from(read(null));
        console.log(first.concat(second).join(','), _state, _loop);
      `,
      '9,5,7,3 3 7',
    );
  });

  test('downlevel classes keep private state, class self names, and shadowed helpers', async () => {
    await expectEs5Parity(
      `
        const _Class = 11;
        const _super = 13;
        class Base {
          read() { return this.value; }
        }
        class Box extends Base {
          static #count = 0;
          #value;
          constructor(value) {
            super();
            this.value = value;
            this.#value = value;
            Box.#count++;
          }
          read() { return this.#value + super.read() + _Class + _super; }
          static count() { return Box.#count; }
        }
        const first = new Box(2);
        const second = new Box(3);
        console.log(first.read(), second.read(), Box.count(), _Class, _super);
      `,
      '28 30 2 11 13',
    );
  });

  test('assignment class fields reuse edited symbol scopes after downleveling', async () => {
    const fixture = await createFixture({
      'input.js': `
        const _a = 39;
        class Base {
          set value(value) { this.stored = value; }
        }
        class Box extends Base {
          value = (() => {
            const _a = 2;
            return _a + 1;
          })();
          read() { return this.stored + ':' + _a; }
        }
        console.log(new Box().read());
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.js');

    for (const minify of [false, true]) {
      const output = join(fixture.dir, minify ? 'minified.js' : 'plain.js');
      const result = await runZntc(
        [
          input,
          '-o',
          output,
          '--target=es5',
          '--use-define-for-class-fields=false',
          ...(minify ? ['--minify-identifiers'] : []),
        ],
        { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
      );
      expect(result.exitCode, result.stderr).toBe(0);
      if (minify) {
        expect(result.stderr).toMatch(/symbol-coverage .*missing=0 wrong=0/);
        const identity = result.stderr
          .split(/\r?\n/)
          .find((line) => line.includes('zntc: symbol-identity '));
        expect(identity).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(identity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
        }
      }
      const transformed = await runNode(output);
      expect(transformed.stdout).toBe('3:39');
    }
  });

  test('syntax minification reads the edited loop and closure scopes', async () => {
    await expectEs5Parity(
      `
        const _loop = 7;
        const _a = 40;
        function collect(values) {
          const readers = [];
          for (let index = 0; index < values.length; index++) {
            readers.push(() => values[index] + index + _loop);
          }
          return readers.map((read) => read()).join(',');
        }
        console.log(collect([1, 2, 3]), _a);
      `,
      '8,10,12 40',
      true,
    );
  });

  test('syntax folds keep renamed symbols when expression slots adopt identifier children', async () => {
    const fixture = await createFixture({
      'input.js': `
        const holder = { n() { return 1; } };
        console.log(
          typeof (0, holder).n,
          (true ? holder : null).n(),
          (true && holder).n(),
          (false || holder).n(),
          (null ?? holder).n(),
        );
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.js');
    const output = join(fixture.dir, 'output.js');
    const result = await runZntc(
      [input, '-o', output, '--minify-identifiers', '--minify-whitespace', '--minify-syntax'],
      { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
    );
    expect(result.exitCode).toBe(0);
    expect(result.stderr).toMatch(/symbol-coverage .*missing=0 wrong=0/);
    const identity = result.stderr
      .split(/\r?\n/)
      .find((line) => line.includes('zntc: symbol-identity '));
    expect(identity).toBeDefined();
    for (const counter of EXACT_ZERO_COUNTERS) {
      expect(identity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
    }
    expect(readFileSync(output, 'utf8')).not.toContain('holder');
    const native = await runNode(input);
    const transformed = await runNode(output);
    expect(native.stdout).toBe('function 1 1 1 1');
    expect(transformed.stdout).toBe(native.stdout);
  });

  test('drop-console and drop-debugger remove only their emitted references', async () => {
    const fixture = await createFixture({
      'input.js': `
        const _a = 40;
        let result = 0;
        function calculate(value) {
          console.log('discarded', value);
          debugger;
          result = value + _a;
        }
        calculate(2);
        process.stdout.write(String(result));
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.js');
    const output = join(fixture.dir, 'output.js');
    const result = await runZntc(
      [
        input,
        '-o',
        output,
        '--target=es5',
        '--minify-identifiers',
        '--drop=console',
        '--drop=debugger',
      ],
      { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
    );
    expect(result.exitCode).toBe(0);
    expect(result.stderr).toMatch(/symbol-coverage .*missing=0 wrong=0/);
    const identity = result.stderr
      .split(/\r?\n/)
      .find((line) => line.includes('zntc: symbol-identity '));
    expect(identity).toBeDefined();
    for (const counter of EXACT_ZERO_COUNTERS) {
      expect(identity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
    }
    const transformed = await runNode(output);
    expect(transformed.stdout).toBe('42');
  });

  test('defined external names stay reserved after transform editing', async () => {
    const fixture = await createFixture({
      'input.js': `
        globalThis.e = 40;
        function calculate() {
          const first = 1;
          const second = 2;
          const third = 3;
          const fourth = 4;
          return first + second + third + fourth + __VALUE__;
        }
        console.log(calculate());
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.js');
    const output = join(fixture.dir, 'output.js');
    const result = await runZntc(
      [input, '-o', output, '--minify-identifiers', '--define:__VALUE__=e'],
      { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
    );
    expect(result.exitCode).toBe(0);
    expect(result.stderr).toMatch(/symbol-coverage .*missing=0 wrong=0/);
    const identity = result.stderr
      .split(/\r?\n/)
      .find((line) => line.includes('zntc: symbol-identity '));
    expect(identity).toBeDefined();
    for (const counter of EXACT_ZERO_COUNTERS) {
      expect(identity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
    }
    const emitted = readFileSync(output, 'utf8');
    expect(emitted).not.toMatch(/\bvar e\b/);
    const transformed = await runNode(output);
    expect(transformed.stdout).toBe('50');
  });

  test('automatic JSX runtime import aliases track their generated references', async () => {
    const fixture = await createFixture({
      'node_modules/react/package.json': JSON.stringify({
        exports: { './jsx-runtime': './jsx-runtime.mjs' },
      }),
      'node_modules/react/jsx-runtime.mjs': `
        export function jsx(type, props) { return { type, props }; }
        export function jsxs(type, props) { return { type, props }; }
        export const Fragment = Symbol.for('fragment');
      `,
      'input.jsx': `
        const _jsx = 99;
        const _jsxs = 100;
        const value = 3;
        const element = <div data-x={value}><span>{_jsx}</span><span>{_jsxs}</span></div>;
        console.log(element.type, element.props['data-x'], element.props.children.map((child) => child.props.children).join(','), _jsx, _jsxs);
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.jsx');
    const output = join(fixture.dir, 'output.mjs');
    const result = await runZntc([input, '-o', output, '--jsx=automatic', '--minify-identifiers'], {
      env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
    });
    expect(result.exitCode).toBe(0);
    expect(result.stderr).toMatch(/symbol-coverage .*missing=0 wrong=0/);
    const identity = result.stderr
      .split(/\r?\n/)
      .find((line) => line.includes('zntc: symbol-identity '));
    expect(identity).toBeDefined();
    for (const counter of EXACT_ZERO_COUNTERS) {
      expect(identity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
    }
    const transformed = await runNode(output);
    expect(transformed.stdout).toBe('div 3 99,100 99 100');
  });

  test('CommonJS codegen globals do not capture minified source bindings', async () => {
    const fixture = await createFixture({
      'dependency.cjs': `
        exports.value = 8;
        exports.other = 10;
      `,
      'input.mjs': `
        import { value as _value } from './dependency.cjs';
        const require = 5;
        const module = 6;
        const exports = 7;
        const Object = 9;
        const __filename = 11;
        const __dirname = 13;
        function collect(values) {
          const readers = [];
          for (let index = 0; index < values.length; index++) {
            let _a = index;
            readers.push(() => _a + _value);
          }
          return readers.map((read) => read()).join(',');
        }
        export const result = _value + require + module + exports + Object + __filename + __dirname;
        export * from './dependency.cjs';
        export default result;
        console.log(result, _value, require, module, exports, Object, __filename, __dirname, collect([1, 2]), import.meta.url.startsWith('file:'));
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.mjs');
    const output = join(fixture.dir, 'output.cjs');
    const result = await runZntc(
      [
        input,
        '-o',
        output,
        '--format=cjs',
        '--platform=node',
        '--target=es5',
        '--minify-identifiers',
        '--minify-syntax',
      ],
      { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
    );
    expect(result.exitCode, result.stderr).toBe(0);
    expect(result.stderr).toMatch(/symbol-coverage .*missing=0 wrong=0/);
    const identity = result.stderr
      .split(/\r?\n/)
      .find((line) => line.includes('zntc: symbol-identity '));
    expect(identity).toBeDefined();
    for (const counter of EXACT_ZERO_COUNTERS) {
      expect(identity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
    }
    const native = await runNode(input);
    const transformed = await runNode(output);
    expect(native.stdout).toBe('59 8 5 6 7 9 11 13 8,9 true');
    expect(transformed.stdout).toBe(native.stdout);
  });

  test('CommonJS class lowering keeps generated Object global under a source shadow', async () => {
    const fixture = await createFixture({
      'input.mjs': `
        const Object = 9;
        class Base {
          set value(value) { this.stored = value; }
        }
        class Box extends Base {
          value = 3;
          read() { return this.stored; }
        }
        console.log(new Box().read(), Object);
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.mjs');
    const output = join(fixture.dir, 'output.cjs');
    const result = await runZntc(
      [
        input,
        '-o',
        output,
        '--format=cjs',
        '--platform=node',
        '--target=es5',
        '--use-define-for-class-fields=false',
        '--minify-identifiers',
      ],
      { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
    );
    expect(result.exitCode, result.stderr).toBe(0);
    // This audit runs before final names are assigned. It reports the two deliberate
    // transform-generated Object globals as shadowed, while the CJS reservation makes
    // the source binding take another name before codegen.
    expect(result.stderr).toMatch(/symbol-coverage .*missing=2 wrong=0/);
    expect(result.stderr).toContain('missing Object(identifier_reference) x2');
    const identity = result.stderr
      .split(/\r?\n/)
      .find((line) => line.includes('zntc: symbol-identity '));
    expect(identity).toBeDefined();
    expect(identity).toMatch(/shadowed_external_reference=2(?:\s|$)/);
    for (const counter of EXACT_ZERO_COUNTERS.filter(
      (name) => name !== 'shadowed_external_reference',
    )) {
      expect(identity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
    }
    const emitted = readFileSync(output, 'utf8');
    expect(emitted).toContain('Object.setPrototypeOf');
    expect(emitted).not.toMatch(/\bvar Object\s*=/);
    const transformed = await runNode(output);
    expect(transformed.stdout).toBe('3 9');
  });

  test('CommonJS script mangling preserves direct eval and with lookup names', async () => {
    const fixture = await createFixture({
      'input.cjs': `
        const value = 'outer';
        function read(object) {
          const local = 'lexical';
          const viaEval = eval('local');
          with (object) {
            return viaEval + ':' + value + ':' + dynamic;
          }
        }
        console.log(read({ value: 'object', dynamic: 'with' }));
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.cjs');
    const output = join(fixture.dir, 'output.cjs');
    const result = await runZntc([input, '-o', output, '--format=cjs', '--minify-identifiers'], {
      env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
    });
    expect(result.exitCode, result.stderr).toBe(0);
    expect(result.stderr).toMatch(/symbol-coverage .*missing=0 wrong=0/);
    const identity = result.stderr
      .split(/\r?\n/)
      .find((line) => line.includes('zntc: symbol-identity '));
    expect(identity).toBeDefined();
    // `dynamic` intentionally has no stable SymbolId inside `with`.
    expect(identity).toMatch(/unclassified_reference=1(?:\s|$)/);
    for (const counter of EXACT_ZERO_COUNTERS.filter((name) => name !== 'unclassified_reference')) {
      expect(identity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
    }
    const native = await runNode(input);
    const transformed = await runNode(output);
    expect(native.stdout).toBe('lexical:object:with');
    expect(transformed.stdout).toBe(native.stdout);
  });

  test('standalone downlevel helpers avoid user bindings in normal and minified output', async () => {
    const cases = [
      {
        helper: '__extends',
        reserved: '__extends2',
        alias: '__extends3',
        options: [] as string[],
        userValues: 'user-long reserved-long',
      },
      {
        helper: '$eX',
        reserved: '$eX2',
        alias: '$eX3',
        options: ['--minify-whitespace'],
        userValues: 'user-short reserved-short',
      },
    ];
    const files: Record<string, string> = {};
    for (const [index, item] of cases.entries()) {
      files[`input-${index}.mjs`] = `
        const ${item.helper} = '${index === 0 ? 'user-long' : 'user-short'}';
        const ${item.reserved} = '${index === 0 ? 'reserved-long' : 'reserved-short'}';
        const marker = '${item.helper} ${item.reserved}';
        class Base { value() { return 1; } }
        export class Child extends Base { read() { return super.value() + 1; } }
        console.log(${item.helper}, ${item.reserved}, new Child().read(), marker);
      `;
    }
    const fixture = await createFixture(files);
    cleanup = fixture.cleanup;

    for (const [index, item] of cases.entries()) {
      const input = join(fixture.dir, `input-${index}.mjs`);
      const output = join(fixture.dir, `output-${index}.mjs`);
      const result = await runZntc([input, '-o', output, '--target=es5', ...item.options], {
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
      });
      expect(result.exitCode, result.stderr).toBe(0);
      const emitted = readFileSync(output, 'utf8');
      expect(emitted).toContain(`var ${item.alias}`);
      expect(emitted).toContain(`${item.alias}(Child`);
      // The source literal that mentions both colliding spellings is not rewritten.
      expect(emitted).toContain(`${item.helper} ${item.reserved}`);
      const transformed = await runNode(output);
      expect(transformed.stderr).toBe('');
      expect(transformed.stdout.trim()).toBe(
        `${item.userValues} 2 ${item.helper} ${item.reserved}`,
      );
    }
  });

  test('standalone helper dependencies avoid user bindings in async iterator fallbacks', async () => {
    const fixture = await createFixture({
      'input.mjs': `
        const __values = 'user-values';
        const __values2 = 'reserved-values';
        async function sum(items) {
          let total = 0;
          for await (const item of items) total += item;
          return total;
        }
        sum([2, 3]).then((total) => console.log(__values, __values2, total));
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.mjs');
    const output = join(fixture.dir, 'output.mjs');
    const result = await runZntc([input, '-o', output, '--target=es5']);
    expect(result.exitCode, result.stderr).toBe(0);
    const emitted = readFileSync(output, 'utf8');
    expect(emitted).toContain('var __values3');
    expect(emitted).toContain('typeof __values3');
    const transformed = await runNode(output);
    expect(transformed.stderr).toBe('');
    expect(transformed.stdout.trim()).toBe('user-values reserved-values 5');
  });

  test('standalone helpers do not capture unresolved source globals', async () => {
    const fixture = await createFixture({
      'input.mjs': `
        globalThis.__extends = 'external-value';
        class Base { value() { return 1; } }
        class Child extends Base { read() { return super.value() + 1; } }
        console.log(__extends, new Child().read());
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.mjs');
    const output = join(fixture.dir, 'output.mjs');
    const result = await runZntc([input, '-o', output, '--target=es5']);
    expect(result.exitCode, result.stderr).toBe(0);
    const emitted = readFileSync(output, 'utf8');
    expect(emitted).toContain('var __extends2');
    expect(emitted).toContain('console.log(__extends,');
    const transformed = await runNode(output);
    expect(transformed.stderr).toBe('');
    expect(transformed.stdout.trim()).toBe('external-value 2');
  });
});
