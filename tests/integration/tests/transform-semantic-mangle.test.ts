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
  'helper_symbol_mismatch',
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

  test('type-erased TypeScript class lowering reuses the edited semantic graph', async () => {
    const fixture = await createFixture({
      'input.ts': `
        class Base {
          constructor(public value: number) {}
          read(): number { return this.value; }
        }
        class Box extends Base {
          amount: number = 2;
          read(): number { return super.read() + this.amount; }
        }
        function calculate(argument: number): number {
          const local = new Box(argument);
          return local.read() + argument;
        }
        function createGeneratedClass(args: number) {
          return class extends Base { amount: number = args; };
        }
        const Generated = createGeneratedClass(5);
        console.log(calculate(3) + new Generated(2).amount);
      `,
      'reference.js': `
        class Base {
          constructor(value) { this.value = value; }
          read() { return this.value; }
        }
        class Box extends Base {
          constructor(value) { super(value); this.amount = 2; }
          read() { return super.read() + this.amount; }
        }
        function calculate(argument) {
          const local = new Box(argument);
          return local.read() + argument;
        }
        function createGeneratedClass(args) {
          return class extends Base {
            constructor(value) { super(value); this.amount = args; }
          };
        }
        const Generated = createGeneratedClass(5);
        console.log(calculate(3) + new Generated(2).amount);
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.ts');
    const reference = await runNode(join(fixture.dir, 'reference.js'));
    expect(reference.stdout.trim()).toBe('13');

    for (const target of ['es5', 'es2015', 'es2017', 'es2022', 'esnext']) {
      const output = join(fixture.dir, `output-${target}.js`);
      const result = await runZntc(
        [input, '-o', output, `--target=${target}`, '--minify-identifiers'],
        { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
      );
      expect(result.exitCode, `${target}: ${result.stderr}`).toBe(0);
      expect(result.stderr).toMatch(/symbol-coverage .*missing=0 wrong=0/);
      const identity = result.stderr
        .split(/\r?\n/)
        .find((line) => line.includes('zntc: symbol-identity '));
      expect(identity).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(identity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
      }
      const transformed = await runNode(output);
      expect(transformed.stderr, target).toBe('');
      expect(transformed.stdout.trim(), target).toBe(reference.stdout.trim());
    }
  });

  test('private-field lowering registers generated super-rest symbols and avoids captured-name collisions', async () => {
    const fixture = await createFixture({
      'input.ts': `
        class Base { constructor(public value: number) {} }
        function create(_args: number) {
          return class extends Base {
            #hidden = 1;
            amount: number = _args;
          };
        }
        const Generated = create(5);
        console.log(new Generated(2).amount);
      `,
      'reference.js': `
        class Base { constructor(value) { this.value = value; } }
        function create(_args) {
          return class extends Base {
            #hidden = 1;
            amount = _args;
          };
        }
        const Generated = create(5);
        console.log(new Generated(2).amount);
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.ts');
    const output = join(fixture.dir, 'output-es2021.js');
    const reference = await runNode(join(fixture.dir, 'reference.js'));
    expect(reference.stdout.trim()).toBe('5');

    const result = await runZntc([input, '-o', output, '--target=es2021', '--minify-identifiers'], {
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
    const transformed = await runNode(output);
    expect(transformed.stderr).toBe('');
    expect(transformed.stdout.trim()).toBe(reference.stdout.trim());
  });

  test('type-erased TypeScript static blocks reuse the edited semantic graph', async () => {
    const fixture = await createFixture({
      'input.ts': `
        function run(value: number): number {
          const outer = value + 1;
          class Box {
            static {
              const outer = 99;
              Box.result = outer + value;
            }
          }
          return Box.result + outer;
        }
        class Parent { static base = 3; }
        function make(value: number) {
          return class Generated extends Parent {
            static {
              this.value = eval('value');
              Generated.next = this.value + super.base;
            }
          };
        }
        const Generated = make(11);
        console.log(run(4), Generated.next);
      `,
      'reference.js': `
        function run(value) {
          const outer = value + 1;
          class Box {
            static {
              const outer = 99;
              Box.result = outer + value;
            }
          }
          return Box.result + outer;
        }
        class Parent { static base = 3; }
        function make(value) {
          return class Generated extends Parent {
            static {
              this.value = eval('value');
              Generated.next = this.value + super.base;
            }
          };
        }
        const Generated = make(11);
        console.log(run(4), Generated.next);
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.ts');
    const reference = await runNode(join(fixture.dir, 'reference.js'));
    expect(reference.stdout.trim()).toBe('108 14');

    for (const target of ['es5', 'es2015', 'es2017', 'es2021', 'es2022', 'esnext']) {
      const output = join(fixture.dir, `output-${target}.js`);
      const result = await runZntc(
        [input, '-o', output, `--target=${target}`, '--minify-identifiers'],
        { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
      );
      expect(result.exitCode, `${target}: ${result.stderr}`).toBe(0);
      expect(result.stderr).toMatch(/symbol-coverage .*missing=0 wrong=0/);
      const identity = result.stderr
        .split(/\r?\n/)
        .find((line) => line.includes('zntc: symbol-identity '));
      expect(identity).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(identity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
      }
      const transformed = await runNode(output);
      expect(transformed.stderr, target).toBe('');
      expect(transformed.stdout.trim(), target).toBe(reference.stdout.trim());
    }
  });

  test('type-erased TypeScript private elements reuse the edited semantic graph', async () => {
    const fixture = await createFixture({
      'input.ts': `
        class Base { baseValue(): number { return 7; } }
        function make(value: number) {
          const args = value + 1;
          return class Generated extends Base {
            #state = args;
            static #count = 0;
            constructor(offset: number) {
              super();
              this.#state += offset;
              Generated.#count++;
            }
            #read(delta: number): number {
              return this.#state + delta + super.baseValue();
            }
            get value(): number {
              const args = 1000;
              return this.#read(2) + args;
            }
            evaluated(): number { return eval('args'); }
            hasState(target: object): boolean { return #state in target; }
            static count(): number { return Generated.#count; }
            static hasCount(target: object): boolean { return #count in target; }
          };
        }
        const Generated = make(5);
        const first = new Generated(3);
        const second = new Generated(0);
        console.log(first.value, second.value, Generated.count(), first.evaluated(), first.hasState(second), first.hasState({}), Generated.hasCount(Generated), Generated.hasCount({}));
      `,
      'reference.js': `
        class Base { baseValue() { return 7; } }
        function make(value) {
          const args = value + 1;
          return class Generated extends Base {
            #state = args;
            static #count = 0;
            constructor(offset) {
              super();
              this.#state += offset;
              Generated.#count++;
            }
            #read(delta) {
              return this.#state + delta + super.baseValue();
            }
            get value() {
              const args = 1000;
              return this.#read(2) + args;
            }
            evaluated() { return eval('args'); }
            hasState(target) { return #state in target; }
            static count() { return Generated.#count; }
            static hasCount(target) { return #count in target; }
          };
        }
        const Generated = make(5);
        const first = new Generated(3);
        const second = new Generated(0);
        console.log(first.value, second.value, Generated.count(), first.evaluated(), first.hasState(second), first.hasState({}), Generated.hasCount(Generated), Generated.hasCount({}));
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.ts');
    const reference = await runNode(join(fixture.dir, 'reference.js'));
    expect(reference.stdout.trim()).toBe('1018 1015 2 6 true false true false');

    for (const target of ['es5', 'es2015', 'es2017', 'es2021', 'es2022', 'esnext']) {
      const output = join(fixture.dir, `output-${target}.js`);
      const result = await runZntc(
        [input, '-o', output, `--target=${target}`, '--minify-identifiers'],
        { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
      );
      expect(result.exitCode, `${target}: ${result.stderr}`).toBe(0);
      expect(result.stderr).toMatch(/symbol-coverage .*missing=0 wrong=0/);
      const identity = result.stderr
        .split(/\r?\n/)
        .find((line) => line.includes('zntc: symbol-identity '));
      expect(identity).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(identity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
      }
      const transformed = await runNode(output);
      expect(transformed.stderr, target).toBe('');
      expect(transformed.stdout.trim(), target).toBe(reference.stdout.trim());
    }
  });

  test('type-erased TypeScript auto-accessors reuse the edited semantic graph', async () => {
    const fixture = await createFixture({
      'input.ts': `
        class Parent { baseValue(): number { return 4; } }
        function make(value: number) {
          const outer = value + 1;
          return class Generated extends Parent {
            accessor value: number = outer;
            static accessor count = 0;
            get alias(): number { return this.value; }
            set alias(value: number) { this.value = value; }
            constructor(delta: number) {
              super();
              this.value += delta;
              Generated.count++;
            }
            total(): number {
              const value = 1000;
              return this.value + super.baseValue() + value;
            }
            captured(): number { return eval('outer'); }
          };
        }
        const Generated = make(5);
        const first = new Generated(3);
        const second = new Generated(0);
        first.alias = first.alias;
        console.log(first.total(), second.total(), Generated.count, first.captured());
      `,
      'reference.js': `
        class Parent { baseValue() { return 4; } }
        function make(value) {
          const outer = value + 1;
          return class Generated extends Parent {
            #value = outer;
            static #count = 0;
            constructor(delta) {
              super();
              this.value += delta;
              Generated.count++;
            }
            get value() { return this.#value; }
            set value(value) { this.#value = value; }
            static get count() { return Generated.#count; }
            static set count(value) { Generated.#count = value; }
            get alias() { return this.value; }
            set alias(value) { this.value = value; }
            total() {
              const value = 1000;
              return this.value + super.baseValue() + value;
            }
            captured() { return eval('outer'); }
          };
        }
        const Generated = make(5);
        const first = new Generated(3);
        const second = new Generated(0);
        first.alias = first.alias;
        console.log(first.total(), second.total(), Generated.count, first.captured());
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.ts');
    const reference = await runNode(join(fixture.dir, 'reference.js'));
    expect(reference.stdout.trim()).toBe('1013 1010 2 6');

    for (const target of ['es5', 'es2015', 'es2017', 'es2021', 'es2022', 'esnext']) {
      const output = join(fixture.dir, `output-${target}.js`);
      const result = await runZntc(
        [input, '-o', output, `--target=${target}`, '--minify-identifiers'],
        { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
      );
      expect(result.exitCode, `${target}: ${result.stderr}`).toBe(0);
      expect(result.stderr).toMatch(/symbol-coverage .*missing=0 wrong=0/);
      const identity = result.stderr
        .split(/\r?\n/)
        .find((line) => line.includes('zntc: symbol-identity '));
      expect(identity).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(identity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
      }
      const emitted = readFileSync(output, 'utf8');
      if (target === 'es5') {
        expect(emitted).not.toContain('accessor value');
        expect(emitted).not.toContain('static accessor count');
        const transformed = await runNode(output);
        expect(transformed.stderr, target).toBe('');
        expect(transformed.stdout.trim(), target).toBe(reference.stdout.trim());
      } else {
        // Current class lowering only expands auto-accessors on the ES5 path.
        // Keep higher-target syntax intact; Node does not parse this proposal yet.
        expect(emitted).toMatch(/\baccessor\s+value/);
        expect(emitted).toMatch(/\bstatic\s+accessor\s+count/);
      }
    }
  });

  test('type-erased TypeScript Stage 3 decorators reuse the edited semantic graph', async () => {
    const fixture = await createFixture({
      'input.ts': `
        const _classThis = 11, _method_decorators = 13, _metadata = 17;
        function identity(method: any, _context: any) { return method; }
        function create(value: number) {
          const outer = value + 4;
          return class Generated {
            @identity
            method(value: number) { return eval('outer') + value; }
          };
        }
        const Generated = create(6);
        console.log(new Generated().method(3), _classThis, _method_decorators, _metadata);
      `,
      'reference.js': `
        const _classThis = 11, _method_decorators = 13, _metadata = 17;
        function create(value) {
          const outer = value + 4;
          return class Generated {
            method(value) { return eval('outer') + value; }
          };
        }
        const Generated = create(6);
        console.log(new Generated().method(3), _classThis, _method_decorators, _metadata);
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.ts');
    const reference = await runNode(join(fixture.dir, 'reference.js'));
    expect(reference.stdout.trim()).toBe('13 11 13 17');

    for (const target of ['es5', 'es2015', 'es2017', 'es2021', 'es2022', 'esnext']) {
      const output = join(fixture.dir, `output-${target}.js`);
      const result = await runZntc(
        [input, '-o', output, `--target=${target}`, '--minify-identifiers'],
        { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
      );
      expect(result.exitCode, `${target}: ${result.stderr}`).toBe(0);
      expect(result.stderr).toMatch(/symbol-coverage .*missing=0 wrong=0/);
      const identity = result.stderr
        .split(/\r?\n/)
        .find((line) => line.includes('zntc: symbol-identity '));
      expect(identity).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(identity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
      }
      const transformed = await runNode(output);
      expect(transformed.stderr, target).toBe('');
      expect(transformed.stdout.trim(), target).toBe(reference.stdout.trim());
    }
  });

  test('type-erased Stage 3 decorated class declarations keep outer exports separate from class self', async () => {
    const fixture = await createFixture({
      'input.mts': `
        const _classThis = 11, _method_decorators = 13, _field_decorators = 17;
        const _field_initializers = 19, _field_extraInitializers = 23, _metadata = 29;
        function identity(value: any, _context: any) { return value; }
        @identity
        export class Service {
          @identity field = 10;
          @identity method(value: number) { return this.field + value; }
          static self() { return Service; }
        }
        console.log(new Service().method(3), Service.self() === Service,
          _classThis, _method_decorators, _field_decorators,
          _field_initializers, _field_extraInitializers, _metadata);
      `,
      'reference.mjs': `
        const _classThis = 11, _method_decorators = 13, _field_decorators = 17;
        const _field_initializers = 19, _field_extraInitializers = 23, _metadata = 29;
        class Service {
          field = 10;
          method(value) { return this.field + value; }
          static self() { return Service; }
        }
        console.log(new Service().method(3), Service.self() === Service,
          _classThis, _method_decorators, _field_decorators,
          _field_initializers, _field_extraInitializers, _metadata);
        export { Service };
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.mts');
    const reference = await runNode(join(fixture.dir, 'reference.mjs'));
    expect(reference.stdout.trim()).toBe('13 true 11 13 17 19 23 29');

    for (const target of ['es5', 'es2015', 'es2017', 'es2021', 'es2022', 'esnext']) {
      const output = join(fixture.dir, `output-${target}.mjs`);
      const result = await runZntc(
        [input, '-o', output, `--target=${target}`, '--minify-identifiers'],
        { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
      );
      expect(result.exitCode, `${target}: ${result.stderr}`).toBe(0);
      expect(result.stderr).toMatch(/symbol-coverage .*missing=0 wrong=0/);
      const identity = result.stderr
        .split(/\r?\n/)
        .find((line) => line.includes('zntc: symbol-identity '));
      expect(identity).toBeDefined();
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(identity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
      }
      const transformed = await runNode(output);
      expect(transformed.stderr, target).toBe('');
      expect(transformed.stdout.trim(), target).toBe(reference.stdout.trim());
    }
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

  test('inline async helper symbols stay distinct from a colliding user binding', async () => {
    const fixture = await createFixture({
      'input.mjs': `
        const __generator = 'user-generator';
        async function run(value) { return await value; }
        run(Promise.resolve(7)).then((value) => console.log(__generator, value));
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.mjs');
    const output = join(fixture.dir, 'output.mjs');
    const result = await runZntc([input, '-o', output, '--target=es5'], {
      env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
    });
    expect(result.exitCode, result.stderr).toBe(0);
    const identity = result.stderr
      .split(/\r?\n/)
      .find((line) => line.includes('zntc: symbol-identity '));
    expect(identity).toBeDefined();
    expect(identity).toMatch(/helper_symbol_mismatch=0(?:\s|$)/);
    const emitted = readFileSync(output, 'utf8');
    expect(emitted).toMatch(/var __generator\d+\s*=/);
    const transformed = await runNode(output);
    expect(transformed.stderr).toBe('');
    expect(transformed.stdout.trim()).toBe('user-generator 7');
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

  test('type-erased Flow scripts reuse the transform semantic graph', async () => {
    const fixture = await createFixture({
      'input.js': `
        // @flow
        import type { Numeric } from './types.js';
        const _state: Numeric = 3;
        function calculate(_argument: Numeric = _state): Numeric {
          const local: Numeric = _argument + _state;
          return Number(eval('local'));
        }
        console.log(calculate(4), _state);
      `,
      'reference.js': `
        const state = 3;
        function calculate(argument = state) {
          const local = argument + state;
          return Number(eval('local'));
        }
        console.log(calculate(4), state);
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.js');
    const output = join(fixture.dir, 'output.js');
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
    expect(emitted).not.toContain('type Numeric');
    expect(emitted).not.toContain(': Numeric');
    const reference = await runNode(join(fixture.dir, 'reference.js'));
    const transformed = await runNode(output);
    expect(reference.stdout.trim()).toBe('7 3');
    expect(transformed.stdout).toBe(reference.stdout);
  });

  test('Flow match lowering keeps generated callback identities under minification', async () => {
    const fixture = await createFixture({
      'input.js': `
        // @flow
        function classify(value) {
          return match (value) {
            1 => 'one',
            2 => 'two',
            _ => 'other',
          };
        }
        console.log([classify(1), classify(2), classify(3)].join(','));
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.js');
    const output = join(fixture.dir, 'output.js');
    const result = await runZntc([input, '-o', output, '--minify-identifiers', '--flow'], {
      env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
    });
    expect(result.exitCode, result.stderr).toBe(0);
    const identity = result.stderr
      .split(/\r?\n/)
      .find((line) => line.includes('zntc: symbol-identity '));
    expect(identity).toBeDefined();
    for (const counter of EXACT_ZERO_COUNTERS) {
      expect(identity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
    }
    const transformed = await runNode(output);
    expect(transformed.stderr).toBe('');
    expect(transformed.stdout.trim()).toBe('one,two,other');
  });

  test('bundler keeps the edited Flow match graph only for the syntax-local path', async () => {
    const fixture = await createFixture({
      'match.mjs': `
        // @flow
        const _fallback = 'outer';
        const _m = 'user-m';
        const _m2 = 'user-m2';
        export function classify(value) {
          return match (value) {
            { kind: 1, payload: const payload } if (payload > 0) => payload,
            0 => 'zero',
            _ => _fallback,
          };
        }
        console.log(classify({ kind: 1, payload: 4 }), classify(0), classify(9), _m, _m2);
      `,
      'array-pattern.mjs': `
        // @flow
        function classify(value) {
          return match (value) { [const first] => first, _ => 0 };
        }
        console.log(classify([4]));
      `,
      'object-rest.mjs': `
        // @flow
        function classify(value) {
          return match (value) { { kind: 1, ...const rest } => Object.keys(rest).length, _ => 0 };
        }
        console.log(classify({ kind: 1, extra: true }));
      `,
      'array-shadow.mjs': `
        // @flow
        function classify(value) {
          const Array = { isArray: () => false };
          const matched = match (value) { [const first] => first, _ => 0 };
          return [matched, Array.isArray([])].join(' ');
        }
        console.log(classify([4]));
      `,
      'object-rest-shadow.mjs': `
        // @flow
        function classify(value) {
          const Object = {
            keys: value => globalThis.Object.keys(value),
            assign: () => { throw new Error('shadowed Object.assign'); },
          };
          return match (value) { { kind: 1, ...const rest } => Object.keys(rest).length, _ => 0 };
        }
        console.log(classify({ kind: 1, extra: true }));
      `,
      'array-rest.mjs': `
        // @flow
        function classify(value) {
          return match (value) { [const first, ...const rest] => [first, rest.length].join(':'), _ => 'none' };
        }
        console.log(classify([4, 5, 6]));
      `,
      'typed.mjs': `
        // @flow
        type Box<T> = { value: T };
        interface Options { enabled: boolean }
        opaque type Score = number;
        const Box = 7;
        function read<T>(value: Box<T>): T { return (value.value: T); }
        const result: number = read({ value: Box });
        const score: Score = 5;
        console.log(result, (score: number));
      `,
      'typed-import.mjs': `
        // @flow
        import type { Item } from './types.mjs';
        const item: Item = { value: 3 };
        console.log(item.value);
      `,
      'with-import.mjs': `
        // @flow
        import { base } from './dependency.mjs';
        function classify(value) {
          return match (value) { 0 => base, _ => value };
        }
        console.log(classify(0));
      `,
      'with-eval.mjs': `
        // @flow
        function classify(value) {
          const dynamic = eval('value');
          return match (dynamic) { 0 => 'zero', _ => dynamic };
        }
        console.log(classify(0));
      `,
      'dependency.mjs': 'export const base = 5;',
      'types.mjs': 'export type Item = { value: number };',
    });
    cleanup = fixture.cleanup;

    async function bundle(entry: string, suffix: string, extraArgs: string[] = []) {
      const output = join(fixture.dir, `${suffix}.mjs`);
      const result = await runZntc(
        [
          '--bundle',
          join(fixture.dir, entry),
          '-o',
          output,
          '--platform=node',
          '--format=esm',
          '--target=esnext',
          '--flow',
          '--minify-identifiers',
          ...extraArgs,
        ],
        { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
      );
      expect(result.exitCode, `${entry}: ${result.stderr}`).toBe(0);
      return { output, stderr: result.stderr };
    }

    const kept = await bundle('match.mjs', 'match-kept');
    const prepassIdentity = kept.stderr
      .split(/\r?\n/)
      .find((line) => line.includes('zntc: symbol-identity-prepass '));
    expect(prepassIdentity).toBeDefined();
    expect(prepassIdentity).toMatch(/clean=1(?:\s|$)/);
    for (const counter of EXACT_ZERO_COUNTERS) {
      expect(prepassIdentity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
    }
    const emitted = await runNode(kept.output);
    expect(emitted.stderr).toBe('');
    expect(emitted.stdout.trim()).toBe('4 zero outer user-m user-m2');

    for (const [entry, suffix, extraArgs, keepsGraph, expected] of [
      ['array-pattern.mjs', 'match-array-kept', [], true, '4'],
      ['object-rest.mjs', 'match-object-rest-kept', [], true, '1'],
      ['array-rest.mjs', 'match-array-rest-kept', [], true, '4:2'],
      ['array-shadow.mjs', 'match-array-shadow-kept', [], true, '4 false'],
      ['object-rest-shadow.mjs', 'match-object-rest-shadow-kept', [], true, '1'],
      ['array-shadow.mjs', 'match-array-shadow-es5-fallback', ['--target=es5'], false, '4 false'],
      [
        'object-rest-shadow.mjs',
        'match-object-rest-shadow-es5-fallback',
        ['--target=es5'],
        false,
        '1',
      ],
      ['array-pattern.mjs', 'match-array-es5-fallback', ['--target=es5'], false, '4'],
      ['object-rest.mjs', 'match-object-rest-es5-fallback', ['--target=es5'], false, '1'],
      ['typed.mjs', 'flow-types-kept', [], true, '7 5'],
      ['typed-import.mjs', 'flow-type-import-fallback', [], false, '3'],
      ['with-import.mjs', 'match-import-fallback', [], false, '5'],
      ['with-eval.mjs', 'match-eval-fallback', [], false, 'zero'],
      ['match.mjs', 'match-es5-fallback', ['--target=es5'], false, '4 zero outer user-m user-m2'],
      [
        'match.mjs',
        'match-minify-syntax-fallback',
        ['--minify-syntax'],
        false,
        '4 zero outer user-m user-m2',
      ],
    ] as const) {
      const result = await bundle(entry, suffix, [...extraArgs]);
      if (keepsGraph) {
        const identity = result.stderr
          .split(/\r?\n/)
          .find((line) => line.includes('zntc: symbol-identity-prepass '));
        expect(identity, suffix).toBeDefined();
        const hasExternalShadow = suffix.includes('-shadow-kept');
        expect(identity, suffix).toMatch(
          new RegExp(`shadowed_external_reference=${hasExternalShadow ? 1 : 0}(?:\\s|$)`),
        );
        expect(identity, suffix).toMatch(new RegExp(`clean=${hasExternalShadow ? 0 : 1}(?:\\s|$)`));
        for (const counter of EXACT_ZERO_COUNTERS.filter(
          (name) => name !== 'shadowed_external_reference',
        )) {
          expect(identity, `${suffix}: ${counter}`).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
        }
      } else {
        expect(result.stderr, suffix).not.toContain('symbol-identity-prepass');
      }
      const transformed = await runNode(result.output);
      expect(transformed.stderr, suffix).toBe('');
      expect(transformed.stdout.trim(), suffix).toBe(expected);
    }
  });

  test('Flow enum bindings and codegen globals keep distinct symbols when mangled', async () => {
    const fixture = await createFixture({
      'input.js': `
        // @flow
        const require = () => 'user-require';
        const Symbol = () => 'user-Symbol';
        enum LongColor { Red, Blue }
        function read() { return LongColor.Red; }
        console.log(typeof read(), read().description, require(), Symbol());
      `,
      'node_modules/flow-enums-runtime/index.js': `
        function make(values) { return values; }
        make.Mirrored = (names) => make(Object.fromEntries(names.map((name) => [name, name])));
        module.exports = make;
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.js');
    for (const target of ['es5', 'es2015', 'es2017', 'es2022', 'esnext']) {
      for (const minifySyntax of [false, true]) {
        const output = join(fixture.dir, `flow-enum-${target}-${minifySyntax}.js`);
        const result = await runZntc(
          [
            input,
            '-o',
            output,
            `--target=${target}`,
            '--flow',
            '--minify-identifiers',
            ...(minifySyntax ? ['--minify-syntax'] : []),
          ],
          { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
        );
        expect(result.exitCode, `${target} minifySyntax=${minifySyntax}: ${result.stderr}`).toBe(0);
        expect(result.stderr).toMatch(/symbol-coverage .*missing=0 wrong=0/);
        const identity = result.stderr
          .split(/\r?\n/)
          .find((line) => line.includes('zntc: symbol-identity '));
        expect(identity).toBeDefined();
        expect(identity).toMatch(/clean=1(?:\s|$)/);
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(identity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
        }
        const emitted = readFileSync(output, 'utf8');
        expect(emitted).not.toContain('LongColor');
        const transformed = await runNode(output);
        expect(transformed.stderr, `${target} minifySyntax=${minifySyntax}`).toBe('');
        expect(transformed.stdout.trim(), `${target} minifySyntax=${minifySyntax}`).toBe(
          'symbol Red user-require user-Symbol',
        );
      }
    }
  });

  test('Flow ref-component helper avoids user-name collisions in every target and mangle mode', async () => {
    const fixture = await createFixture({
      'input.js': `
        // @flow
        const LongCard_withRef = 'user-binding';
        const LongCard_withRef2 = 'user-binding-2';
        const React = { forwardRef: (fn) => fn };
        component LongCard(ref?: mixed, ...props: { label?: string }) {
          return props.label;
        }
        function renderLocal() {
          const LocalCard_withRef = 'nested-binding';
          const LocalCard_withRef2 = 'nested-binding-2';
          component LocalCard(ref?: mixed, ...props: { label?: string }) {
            return props.label;
          }
          return [LocalCard({ label: 'nested' }), LocalCard_withRef, LocalCard_withRef2].join(' ');
        }
        console.log(LongCard({ label: 'ok' }), LongCard_withRef, LongCard_withRef2, renderLocal());
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.js');
    for (const target of ['es5', 'es2015', 'es2017', 'es2022', 'esnext']) {
      for (const minifyIdentifiers of [false, true]) {
        for (const minifySyntax of [false, true]) {
          const output = join(
            fixture.dir,
            `flow-component-${target}-${minifyIdentifiers}-${minifySyntax}.js`,
          );
          const result = await runZntc(
            [
              input,
              '-o',
              output,
              `--target=${target}`,
              '--flow',
              ...(minifyIdentifiers ? ['--minify-identifiers'] : []),
              ...(minifySyntax ? ['--minify-syntax'] : []),
            ],
            { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
          );
          const context = `${target} minifyIdentifiers=${minifyIdentifiers} minifySyntax=${minifySyntax}`;
          expect(result.exitCode, `${context}: ${result.stderr}`).toBe(0);
          expect(result.stderr, context).toMatch(/symbol-coverage .*missing=0 wrong=0/);
          const identity = result.stderr
            .split(/\r?\n/)
            .find((line) => line.includes('zntc: symbol-identity '));
          expect(identity, context).toBeDefined();
          expect(identity, context).toMatch(/clean=1(?:\s|$)/);
          for (const counter of EXACT_ZERO_COUNTERS) {
            expect(identity, `${context}: ${counter}: ${identity}`).toMatch(
              new RegExp(`${counter}=0(?:\\s|$)`),
            );
          }
          const emitted = readFileSync(output, 'utf8');
          if (!minifyIdentifiers) {
            expect(emitted, context).toContain('LongCard_withRef3');
            expect(emitted, context).toContain('LocalCard_withRef3');
          }
          const transformed = await runNode(output);
          expect(transformed.stderr, context).toBe('');
          expect(transformed.stdout.trim(), context).toBe(
            'ok user-binding user-binding-2 nested nested-binding nested-binding-2',
          );
        }
      }
    }
  });

  test('exported Flow ref-component preserves export identity and exact symbols', async () => {
    const fixture = await createFixture({
      'input.mjs': `
        // @flow
        const LongCard_withRef = 'user-binding';
        const React = { forwardRef: (fn) => fn };
        export component LongCard(ref?: mixed, ...props: { label?: string }) {
          return props.label;
        }
        console.log(LongCard({ label: 'ok' }), LongCard_withRef);
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.mjs');
    for (const minifyIdentifiers of [false, true]) {
      const output = join(fixture.dir, `exported-flow-component-${minifyIdentifiers}.mjs`);
      const result = await runZntc(
        [
          input,
          '-o',
          output,
          '--target=es2022',
          '--flow',
          ...(minifyIdentifiers ? ['--minify-identifiers'] : []),
        ],
        { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
      );
      expect(result.exitCode, `minifyIdentifiers=${minifyIdentifiers}: ${result.stderr}`).toBe(0);
      expect(result.stderr).toMatch(/symbol-coverage .*missing=0 wrong=0/);
      const identity = result.stderr
        .split(/\r?\n/)
        .find((line) => line.includes('zntc: symbol-identity '));
      expect(identity).toBeDefined();
      expect(identity).toMatch(/clean=1(?:\s|$)/);
      for (const counter of EXACT_ZERO_COUNTERS) {
        expect(identity, `${counter}: ${identity}`).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
      }
      expect(readFileSync(output, 'utf8')).toMatch(/export (?:var|let|const) LongCard\s*=/);
      const transformed = await runNode(output);
      expect(transformed.stderr).toBe('');
      expect(transformed.stdout.trim()).toBe('ok user-binding');
    }
  });

  test('Flow match pattern bindings keep exact IDs through minified lowering across targets', async () => {
    const fixture = await createFixture({
      'input.js': `
        // @flow
        const _m = 'outer-m';
        function classify(_a, input, expected) {
          return match (input) {
            { kind: expected, payload: const payload, ...const details } if (payload > 0) => payload + Object.keys(details).length,
            [const first, ...const rest] => first + rest.length,
            const item if (item > 2) => item,
            { fallback: const item } => item,
            _ => _a,
          };
        }
        function fallback(input) {
          return match (input) { 0 => 'zero', _ => _m };
        }
        console.log([
          classify(99, { kind: 1, payload: 4, extra: true }, 1),
          classify(99, [2, 3], 1),
          classify(99, 5, 1),
          classify(99, 1, 1),
          fallback(0),
          fallback(1),
        ].join(','));
      `,
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.js');
    for (const target of ['es5', 'es2015', 'es2017', 'es2022', 'esnext']) {
      for (const minifySyntax of [false, true]) {
        const output = join(fixture.dir, `output-${target}-${minifySyntax}.js`);
        const result = await runZntc(
          [
            input,
            '-o',
            output,
            `--target=${target}`,
            '--minify-identifiers',
            ...(minifySyntax ? ['--minify-syntax'] : []),
            '--flow',
          ],
          { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
        );
        expect(result.exitCode, `${target} minifySyntax=${minifySyntax}: ${result.stderr}`).toBe(0);
        const identity = result.stderr
          .split(/\r?\n/)
          .find((line) => line.includes('zntc: symbol-identity '));
        expect(identity).toBeDefined();
        for (const counter of EXACT_ZERO_COUNTERS) {
          expect(identity).toMatch(new RegExp(`${counter}=0(?:\\s|$)`));
        }
        const transformed = await runNode(output);
        expect(transformed.stderr, `${target} minifySyntax=${minifySyntax}`).toBe('');
        expect(transformed.stdout.trim(), `${target} minifySyntax=${minifySyntax}`).toBe(
          '5,3,5,99,zero,outer-m',
        );
      }
    }
  });
});
