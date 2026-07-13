import { describe, test, expect, beforeAll, afterAll, afterEach } from 'bun:test';
import { join } from 'node:path';
import { createFixture, runNode, writeOutputs } from './helpers';
import { init, close, build } from '../../../packages/core/index';

// splitting 산출물의 **실행** 스모크.
//
// "빌드 exit 0 + 모든 청크 parse 통과 + 런타임 실패" 계열은 산출물 재파싱
// 게이트로 잡히지 않는다. ESM 의 `export { x }` 미선언은 *문법*은 유효하고
// 모듈 **링크** 시점에 node 가 거부한다 (`SyntaxError: Export 'x' is not
// defined in module`). 그래서 여기서는 청크를 디스크에 쓰고 실제로 실행한다.
//
// #4495: 크로스-모듈 const-inline(숫자 상수) 또는 미사용 named import 로
// 소비자 참조가 0 이 되면 tree-shaker 가 provider 의 선언을 DCE 하는데,
// 청크의 크로스-청크 export/import 목록(chunk.exports_to / imports_from)은
// 스캐너 시점 메타데이터로만 만들어져 그 심볼이 그대로 남아 있었다.

describe('split runtime smoke (실행 검증)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  async function buildAndRun(
    files: Record<string, string>,
    opts: Record<string, unknown>,
  ): Promise<{ stdout: string; outs: { path: string; text: string }[] }> {
    const fixture = await createFixture(files);
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'entry.ts')],
      rootDir: fixture.dir,
      platform: 'node',
      splitting: true,
      ...opts,
    });
    expect(result.errors ?? []).toHaveLength(0);
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const entry = outs.find((o) => o.path.includes('entry') && o.path.endsWith('.js'))!;
    expect(entry).toBeDefined();
    const { stdout } = await runNode(join(fixture.dir, entry.path));
    return { stdout, outs };
  }

  /** 모든 청크에서 `export { ... }` 로 노출된 public 이름 목록. */
  function exportedNames(text: string): string[] {
    const names: string[] = [];
    for (const stmt of text.match(/export\s*\{([^}]*)\}/g) ?? []) {
      for (const raw of stmt.replace(/export\s*\{|\}/g, '').split(',')) {
        const s = raw.trim();
        if (!s) continue;
        names.push((s.includes(' as ') ? s.split(' as ')[1] : s).trim());
      }
    }
    return names;
  }

  // #4495 본체: barrel 이 다른 모듈을 re-export 하면서 숫자 const 도 export.
  // 숫자 const 는 크로스-모듈 const-inline 대상이라 a/b 에 리터럴 `1` 로 박히고
  // barrel 의 선언은 DCE 된다. 그런데 barrel 청크는 `export { extra }` 를
  // 그대로 내보내 node 가 모듈 로드를 거부했다.
  const inlineFixture = {
    'prov.ts': `export const second = { label: "second" };`,
    'barrel.ts': `export { second } from "./prov";\nexport const extra = 1;`,
    'a.ts': `import { second, extra } from "./barrel";\nexport const a = second.label + ":" + extra;`,
    'b.ts': `import { second, extra } from "./barrel";\nexport const b = second.label + "/" + extra;`,
    'entry.ts': `Promise.all([import("./a"), import("./b")]).then(([m1, m2]) => console.log("OK", m1.a, m2.b));`,
  };

  // minify 유무 모두 — 숫자 const 인라인(numeric post-pass)은 --minify 없이도 돈다.
  for (const minify of [false, true]) {
    test(`esm: const-inline 된 re-export 가 dangling export 를 남기지 않는다 (#4495, minify=${minify})`, async () => {
      const { stdout, outs } = await buildAndRun(inlineFixture, { format: 'esm', minify });
      expect(stdout.trim()).toBe('OK second:1 second/1');

      // 어떤 청크도 `extra` 를 노출하면 안 된다(선언이 DCE 됐으므로).
      for (const o of outs) {
        if (!o.path.endsWith('.js')) continue;
        expect(exportedNames(o.text)).not.toContain('extra');
        // 소비자 청크의 크로스-청크 import 목록에도 남으면 안 된다.
        expect(/import\s*\{[^}]*\bextra\b[^}]*\}\s*from/.test(o.text)).toBe(false);
      }
    });
  }

  // 같은 루트커즈의 일반형: 인라인이 아니라 **아예 안 쓰는** named import.
  // 참조가 0 → provider 선언 DCE → 목록에만 남아 dangling export.
  test('esm: 미사용 named cross-chunk import 가 dangling export 를 남기지 않는다 (#4495)', async () => {
    const { stdout, outs } = await buildAndRun(
      {
        'prov.ts': `export const second = { label: "second" };`,
        'barrel.ts': `export { second } from "./prov";\nexport const unused = { k: 1 };`,
        'a.ts': `import { second, unused } from "./barrel";\nexport const a = second.label + ":a";`,
        'b.ts': `import { second, unused } from "./barrel";\nexport const b = second.label + "/b";`,
        'entry.ts': `Promise.all([import("./a"), import("./b")]).then(([m1, m2]) => console.log("OK", m1.a, m2.b));`,
      },
      { format: 'esm' },
    );
    expect(stdout.trim()).toBe('OK second:a second/b');
    for (const o of outs) {
      if (!o.path.endsWith('.js')) continue;
      expect(exportedNames(o.text)).not.toContain('unused');
    }
  });

  // 회귀 가드: 인라인되지 **않는** 심볼(string/object/function)의 크로스-청크
  // export/import 는 그대로여야 한다. dead-export 필터가 과잉 동작하면
  // ReferenceError 로 즉시 터진다.
  test('esm: 인라인 안 되는 심볼의 크로스-청크 export/import 는 유지 (#4495 회귀 가드)', async () => {
    const { stdout, outs } = await buildAndRun(
      {
        'prov.ts': `export const second = { label: "second" };`,
        'barrel.ts':
          `export { second } from "./prov";\n` +
          `export const num = 1;\n` +
          `export const str = "S";\n` +
          `export const obj = { k: 2 };\n` +
          `export function fn() { return "fn"; }`,
        'a.ts': `import { second, num, str, obj, fn } from "./barrel";\nexport const a = [second.label, num, str, obj.k, fn()].join("|");`,
        'b.ts': `import { second, num, str, obj, fn } from "./barrel";\nexport const b = [second.label, num, str, obj.k, fn()].join("/");`,
        'entry.ts': `Promise.all([import("./a"), import("./b")]).then(([m1, m2]) => console.log("OK", m1.a, m2.b));`,
      },
      { format: 'esm' },
    );
    expect(stdout.trim()).toBe('OK second|1|S|2|fn second/1/S/2/fn');

    const shared = outs.find(
      (o) => o.path.endsWith('.js') && !/entry|[ab]-/.test(o.path.split('/').pop()!),
    )!;
    expect(shared).toBeDefined();
    const names = exportedNames(shared.text);
    // 인라인 대상(num)만 빠지고 나머지는 전부 크로스-청크 노출 유지.
    for (const n of ['second', 'str', 'obj', 'fn']) expect(names).toContain(n);
    expect(names).not.toContain('num');
  });

  // entry 모듈이 shared 청크 심볼을 dead statement 에서만 참조 — tree-shaker 는
  // entry statement 를 살아있는 것으로 보므로 선언·export 가 유지돼야 한다
  // (dead-export 필터가 entry 를 잘못 죽이면 ReferenceError).
  test('esm: entry 의 dead statement 참조도 크로스-청크 export 유지 (#4495 회귀 가드)', async () => {
    const { stdout } = await buildAndRun(
      {
        'shared.ts': `export const obj = { k: 1 };\nexport const other = { m: 2 };`,
        'a.ts': `import { other } from "./shared";\nexport const a = "a" + other.m;`,
        'b.ts': `import { other } from "./shared";\nexport const b = "b" + other.m;`,
        'entry.ts':
          `import { obj } from "./shared";\n` +
          `const dead = obj.k;\n` +
          `Promise.all([import("./a"), import("./b")]).then(([m1, m2]) => console.log("OK", m1.a, m2.b, typeof dead));`,
      },
      { format: 'esm' },
    );
    expect(stdout.trim()).toBe('OK a2 b2 number');
  });

  // cjs splitting 도 같은 목록을 쓴다 — 실행으로 미바인딩(ReferenceError) 회귀 가드.
  test('cjs: const-inline 된 re-export 청크도 실행 정상 (#4495)', async () => {
    const { stdout } = await buildAndRun(inlineFixture, { format: 'cjs' });
    expect(stdout.trim()).toBe('OK second:1 second/1');
  });

  // 단일 번들(splitting 아님) 경로 불변 — computeCrossChunkLinks 자체를 안 타므로
  // const-inline 결과가 그대로 실행돼야 한다. (dynamic import 는 단일 번들에서
  // 인라인되는데 그 실행 순서는 이 이슈와 무관한 별건이라 정적 import 로 검증.)
  test('esm: 단일 번들은 무변경 (#4495 회귀 가드)', async () => {
    const fixture = await createFixture({
      ...inlineFixture,
      'entry.ts': `import { a } from "./a";\nimport { b } from "./b";\nconsole.log("OK", a, b);`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'entry.ts')],
      rootDir: fixture.dir,
      platform: 'node',
      format: 'esm',
    });
    const outs = result.outputFiles!.filter((o) => o.path.endsWith('.js'));
    expect(outs.length).toBe(1);
    writeOutputs(fixture.dir, result.outputFiles!);
    const { stdout } = await runNode(join(fixture.dir, outs[0].path));
    expect(stdout.trim()).toBe('OK second:1 second/1');
  });
});
