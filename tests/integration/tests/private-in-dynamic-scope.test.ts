import { describe, expect, test } from 'bun:test';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { bundleAndRun, runNode } from './helpers';

describe('private-in receiver isolation from direct eval', () => {
  const fixtures = [
    {
      name: 'instance method brand',
      source:
        "class C { #m() {} static check(name) { const result = #m in new C(); try { eval('_' + name); return result + ':visible'; } catch (error) { return result + ':' + error.name; } } } console.log(C.check('a'));",
    },
    {
      name: 'instance field brand',
      source:
        "class C { #m = 1; static check(name) { const result = #m in new C(); try { eval('_' + name); return result + ':visible'; } catch (error) { return result + ':' + error.name; } } } console.log(C.check('a'));",
    },
    {
      name: 'static field brand',
      source:
        "class C { static #m = 1; static check(name) { const result = #m in C; try { eval('_' + name); return result + ':visible'; } catch (error) { return result + ':' + error.name; } } } console.log(C.check('a'));",
    },
    {
      name: 'static private method brand',
      source:
        "class C { static #m() {} static check(name) { const result = #m in C; try { eval('_' + name); return result + ':visible'; } catch (error) { return result + ':' + error.name; } } } console.log(C.check('a'));",
    },
    {
      name: 'isolated parameter avoids generated private storage names',
      source:
        "class C { #zntcPrivateInValue() {} static check(name) { const result = #zntcPrivateInValue in new C(); try { eval('_' + name); return result + ':visible'; } catch (error) { return result + ':' + error.name; } } } console.log(C.check('a'));",
    },
    {
      name: 'nested class keeps outer private storage reference distinct',
      source:
        "class Outer { #zntcPrivateInValue() {} check(name, value) { class Inner { static check(name, candidate) { const result = #zntcPrivateInValue in candidate; try { eval('_' + name); return result + ':visible'; } catch (error) { return result + ':' + error.name; } } } return Inner.check(name, value); } } console.log(new Outer().check('a', new Outer()));",
    },
    {
      name: 'private accessor brand',
      source:
        "class C { get #m() { return 1; } static check(name) { const result = #m in new C(); try { eval('_' + name); return result + ':visible'; } catch (error) { return result + ':' + error.name; } } } console.log(C.check('a'));",
    },
    {
      name: 'static private accessor brand',
      source:
        "class C { static get #m() { return 1; } static check(name) { const result = #m in C; try { eval('_' + name); return result + ':visible'; } catch (error) { return result + ':' + error.name; } } } console.log(C.check('a'));",
    },
    {
      name: 'eval in nested closure',
      source:
        "class C { #m() {} static check(name) { const probe = () => eval('_' + name); const result = #m in new C(); try { probe(); return result + ':visible'; } catch (error) { return result + ':' + error.name; } } } console.log(C.check('a'));",
    },
    {
      name: 'eval in the RHS before capture',
      source:
        "class C { #m() {} static check(name) { try { return #m in (eval('_' + name), new C()) ? 'true' : 'false'; } catch (error) { return error.name; } } } console.log(C.check('a'));",
    },
    {
      name: 'second generated capture name',
      source:
        "class C { #m() {} static check(name) { const first = #m in new C(); const second = #m in new C(); try { eval('_' + name); return first + ':' + second + ':visible'; } catch (error) { return first + ':' + second + ':' + error.name; } } } console.log(C.check('b'));",
    },
    {
      name: 'awaited RHS',
      args: ['--target=es2020'],
      source:
        "class C { #m() {} static async check(name) { const result = #m in await Promise.resolve(new C()); try { eval('_' + name); return result + ':visible'; } catch (error) { return result + ':' + error.name; } } } C.check('a').then(console.log);",
    },
  ];

  test('hostile brand-check forms keep generated receiver names out of eval scope', async () => {
    for (const fixture of fixtures) {
      const result = await bundleAndRun(
        { 'index.ts': fixture.source },
        'index.ts',
        fixture.args ?? ['--target=es2015'],
      );
      try {
        expect(result.exitCode, fixture.name).toBe(0);
        expect(result.runOutput, fixture.name).toBe(
          fixture.name === 'eval in the RHS before capture'
            ? 'ReferenceError'
            : fixture.name === 'second generated capture name'
              ? 'true:true:ReferenceError'
              : 'true:ReferenceError',
        );
      } finally {
        await result.cleanup();
      }
    }
  });

  test('the regression stays fixed with minification enabled', async () => {
    const result = await bundleAndRun(
      {
        'index.ts':
          "class C { #m() {} static check(name) { const result = #m in new C(); try { eval('_' + name); return result + ':visible'; } catch (error) { return result + ':' + error.name; } } } console.log(C.check('a'));",
      },
      'index.ts',
      ['--target=es2015', '--minify'],
    );
    try {
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe('true:ReferenceError');
    } finally {
      await result.cleanup();
    }
  });

  test('ten compileable caller-temp mutants are rejected by the runtime oracle', async () => {
    const result = await bundleAndRun(
      {
        'index.ts':
          "class C { #m() {} static check(name) { const result = #m in new C(); try { eval('_' + name); return result + ':visible'; } catch (error) { return result + ':' + error.name; } } } console.log(C.check('a'));",
      },
      'index.ts',
      ['--target=es2015'],
    );
    const dir = mkdtempSync(join(tmpdir(), 'zntc-private-in-eval-mutants-'));
    const mutantFile = join(dir, 'mutant.cjs');
    try {
      expect(result.runOutput).toBe('true:ReferenceError');
      for (const letter of 'abcdefghij') {
        const evalCall = 'eval("_" + name);';
        let mutant = result.bundleOutput.replace(evalCall, `var _${letter} = new C(); ${evalCall}`);
        mutant = mutant.replace('C.check("a")', `C.check("${letter}")`);
        expect(mutant, `caller binding mutant _${letter}`).not.toBe(result.bundleOutput);
        writeFileSync(mutantFile, mutant);
        const actual = await runNode(mutantFile);
        expect(actual.stdout, `caller binding mutant _${letter}`).toBe('true:visible');
      }
    } finally {
      await result.cleanup();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
