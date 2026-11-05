import { describe, test, expect } from 'bun:test';
import { createFixture, runZntc } from '../helpers';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

// #1802 B2 리뷰 중 surface 된 케이스 회귀 방지.
//
// `ts_import_equals_declaration` 은 audit 스크립트에 "cosmetic" 으로 보이지만
// (layout=.extra, parser stored=.binary), 실제로는 transformer 가
// `data.binary.left/right` 를 읽어서 `const X = require("...")` 런타임 코드를
// 생성한다 → strip target 이 아님. parser 를 empty `.extra` 로 바꾸면
// silent failure (`const <none> = <none>` emit 또는 visitNode(.none) crash).
//
// audit 이 codegen 만 스캔하고 transformer 는 안 보는 한계 때문에 놓치기 쉬운
// 케이스 — 통합 테스트로 고정.

describe('TSC: import-equals declaration (#1802 follow-up)', () => {
  test("import X = require('fs') emit 에서 binary.left(name) / binary.right(value) 보존", async () => {
    // transformer 가 빈 `.extra` 를 받으면 `const <none> = <none>` 이 찍혀 emit 에
    // `= require` 자체가 누락되거나 변수명이 사라진다. 이 테스트는 emit 문자열로
    // 해당 silent failure 를 고정 (런타임 실행은 이후 Namespace 테스트가 커버).
    const { dir, cleanup } = await createFixture({
      'index.ts': `
        import Fs = require("fs");
        console.log(typeof Fs);
      `,
    });
    const outFile = join(dir, 'out.js');
    const transpile = await runZntc([join(dir, 'index.ts'), '-o', outFile]);
    expect(transpile.exitCode).toBe(0);

    const out = readFileSync(outFile, 'utf-8');
    // 변수명 + require 호출 + specifier 모두 살아있어야 한다.
    expect(out).toMatch(/(?:const|var)\s+Fs\s*=\s*require\s*\(\s*["']fs["']\s*\)/);
    await cleanup();
  });

  test('import X = Namespace.Member → const X = Namespace.Member', async () => {
    const { dir, cleanup } = await createFixture({
      'index.ts': `
        namespace NS {
          export const value = 42;
          export namespace Inner {
            export const nested = 7;
          }
        }
        import Root = NS;
        import Deep = NS.Inner;
        console.log(Root.value, Deep.nested);
      `,
    });
    const outFile = join(dir, 'out.js');
    const transpile = await runZntc([join(dir, 'index.ts'), '-o', outFile]);
    expect(transpile.exitCode).toBe(0);

    const out = readFileSync(outFile, 'utf-8');
    // transformer 가 binary.left(name) / binary.right(value) 를 읽어 const 선언 생성.
    // empty `.extra` 로 치환되면 `const <none> = <none>` 또는 crash.
    expect(out).toContain('Root');
    expect(out).toContain('Deep');
    expect(out).toContain('NS.Inner');
    await cleanup();
  });

  test('exported namespace import-equals references resolve through the namespace object', async () => {
    const cases = [
      {
        name: 'function body',
        declarations: 'export function read() { return NestedAlias.value; }',
        expression: 'Container.read()',
        expected: '43',
      },
      {
        name: 'arrow body',
        declarations: 'export const read = () => NestedAlias.value;',
        expression: 'Container.read()',
        expected: '43',
      },
      {
        name: 'nested closure',
        declarations:
          'export function read() { function inner() { return NestedAlias.value; } return inner(); }',
        expression: 'Container.read()',
        expected: '43',
      },
      {
        name: 'object value',
        declarations: 'export const result = { value: NestedAlias.value };',
        expression: 'Container.result.value',
        expected: '43',
      },
      {
        name: 'object shorthand',
        declarations: 'export const result = { NestedAlias };',
        expression: 'Container.result.NestedAlias.value',
        expected: '43',
      },
      {
        name: 'class method',
        declarations: 'export class Reader { read() { return NestedAlias.value; } }',
        expression: 'new Container.Reader().read()',
        expected: '43',
      },
      {
        name: 'member write',
        declarations: 'export function read() { NestedAlias.value = 44; return Nested.value; }',
        expression: 'Container.read()',
        expected: '44',
      },
      {
        name: 'argument value',
        declarations:
          'function getValue(value) { return value.value; } export function read() { return getValue(NestedAlias); }',
        expression: 'Container.read()',
        expected: '43',
      },
      {
        name: 'conditional branch',
        declarations: 'export function read(flag) { return flag ? NestedAlias.value : 0; }',
        expression: 'Container.read(true)',
        expected: '43',
      },
      {
        name: 'computed member',
        declarations: 'export function read(key) { return NestedAlias[key]; }',
        expression: "Container.read('value')",
        expected: '43',
      },
    ];

    for (const fixture of cases) {
      const { dir, cleanup } = await createFixture({
        'index.ts': `namespace Container { export namespace Nested { export let value = 43; } export import NestedAlias = Nested; ${fixture.declarations} } console.log(${fixture.expression});`,
      });
      const input = join(dir, 'index.ts');
      const outFile = join(dir, 'out.js');
      try {
        const transpile = await runZntc([input, '--target=es5', '-o', outFile]);
        expect(transpile.exitCode, fixture.name).toBe(0);

        const actual = spawnSync('node', [outFile], { encoding: 'utf8' });
        expect(actual.status, `${fixture.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, fixture.name).toBe(`${fixture.expected}\n`);
        expect(actual.stderr, fixture.name).toBe('');
      } finally {
        await cleanup();
      }
    }
  });

  test('exported namespace require import-equals references resolve through the namespace object', async () => {
    const { dir, cleanup } = await createFixture({
      'index.ts': `
        namespace Container {
          export import Assert = require('node:assert/strict');
          export function check() {
            Assert.equal(40 + 2, 42);
            return 42;
          }
        }
        console.log(Container.check());
      `,
    });
    const input = join(dir, 'index.ts');
    const outFile = join(dir, 'out.js');
    try {
      const transpile = await runZntc([input, '--target=es5', '-o', outFile]);
      expect(transpile.exitCode).toBe(0);

      const actual = spawnSync('node', [outFile], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe('42\n');
      expect(actual.stderr).toBe('');
    } finally {
      await cleanup();
    }
  });

  test("import X = require('fs') 가 ESM import 가 아닌 const 로 emit", async () => {
    const { dir, cleanup } = await createFixture({
      'index.ts': `
        import Fs = require("fs");
        console.log(typeof Fs);
      `,
    });
    const outFile = join(dir, 'out.js');
    const transpile = await runZntc([join(dir, 'index.ts'), '-o', outFile]);
    expect(transpile.exitCode).toBe(0);

    const out = readFileSync(outFile, 'utf-8');
    // TS CJS 호환 구문이라 ESM import 로 변환되면 안 된다.
    expect(out).not.toContain('import Fs from "fs"');
    // const 선언 + require 호출이 있어야 한다.
    expect(out).toMatch(/(?:const|var)\s+Fs\s*=/);
    expect(out).toMatch(/require\s*\(\s*["']fs["']\s*\)/);
    await cleanup();
  });
});
