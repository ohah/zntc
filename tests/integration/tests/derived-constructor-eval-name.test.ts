import { afterEach, describe, expect, test } from 'bun:test';
import { join } from 'node:path';
import { createFixture, runNode, runZntc } from './helpers';

describe('generated derived constructor names and direct eval', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  test('field initializer eval keeps access to outer names after class lowering', async () => {
    const evalForms = [
      "'args'",
      '"args"',
      "'arg\\u0073'",
      "'ar' + 'gs'",
      '`args`',
      "'(args)'",
      "'args /* comment */'",
      "'args;'",
      "'\\nargs'",
      "'args\\n'",
    ];
    const generatedFields = evalForms
      .map(
        (expression, index) =>
          `class Generated${index} extends Base { value = eval(${expression}); }`,
      )
      .join('\n');
    const generatedReads = [
      ...evalForms.map((_, index) => `new Generated${index}().value`),
      'new GeneratedArgs2().value',
      'new GeneratedArgs3().value',
    ].join(', ');
    const fieldSource = `
      globalThis.args = 41;
      globalThis.args2 = 42;
      globalThis.args3 = 43;
      class Base {}
      ${generatedFields}
      class GeneratedArgs2 extends Base { value = eval('args2'); }
      class GeneratedArgs3 extends Base { value = eval('args3'); }
      console.log(${generatedReads});
    `;
    const cases: Array<{
      file: string;
      target: string;
      source: string;
      nativeFile?: string;
      expected: string;
    }> = [
      {
        file: 'es2015.js',
        target: 'es2015',
        source: fieldSource,
        expected: [...Array(10).fill(41), 42, 43].join(' '),
      },
      {
        file: 'es5.js',
        target: 'es5',
        source: fieldSource,
        expected: [...Array(10).fill(41), 42, 43].join(' '),
      },
      {
        file: 'private-es2015.js',
        target: 'es2015',
        source: `
          globalThis.args = 41;
          class Base {}
          class Derived extends Base { #value = eval('args'); value = this.#value; }
          console.log(new Derived().value);
        `,
        expected: '41',
      },
      {
        file: 'stage3-es5.ts',
        target: 'es5',
        nativeFile: 'stage3-reference.js',
        expected: '41 42',
        source: `
          globalThis.args = 41;
          globalThis.args2 = 42;
          function dec(value) { return value; }
          class Base {}
          @dec class First extends Base { @dec value = eval('args'); }
          @dec class Second extends Base { @dec value = eval('args2'); }
          console.log(new First().value, new Second().value);
        `,
      },
    ];
    const fixture = await createFixture({
      ...Object.fromEntries(cases.map(({ file, source }) => [file, source])),
      'stage3-reference.js': `
        globalThis.args = 41;
        globalThis.args2 = 42;
        class Base {}
        class First extends Base { value = eval('args'); }
        class Second extends Base { value = eval('args2'); }
        console.log(new First().value, new Second().value);
      `,
    });
    cleanup = fixture.cleanup;

    for (const item of cases) {
      const input = join(fixture.dir, item.file);
      const output = join(fixture.dir, `${item.file}.out.js`);
      const result = await runZntc([input, '-o', output, `--target=${item.target}`]);
      expect(result.exitCode, `${item.file}: ${result.stderr}`).toBe(0);
      const native = await runNode(join(fixture.dir, item.nativeFile ?? item.file));
      const transformed = await runNode(output);
      expect(native.stderr, item.file).toBe('');
      expect(transformed.stderr, item.file).toBe('');
      expect(transformed.stdout, item.file).toBe(native.stdout);
      expect(native.stdout, item.file).toBe(item.expected);
    }
  });
});
