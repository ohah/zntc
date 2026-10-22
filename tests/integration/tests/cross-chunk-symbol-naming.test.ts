import { describe, test, expect, beforeAll, afterAll, afterEach } from 'bun:test';
import { join } from 'node:path';
import { realpathSync } from 'node:fs';
import vm from 'node:vm';
import { createFixture } from './helpers';
import { init, close, build } from '../../../packages/core/index';

// ────────────────────────────────────────────────────────────────────────────
// cross-chunk 심볼 네이밍 방어 스위트 (이슈 #4101 lifecycle 재설계 안전망).
//
// 목적: cross-chunk 로 노출/참조되는 심볼의 *이름 일관성* 동작을 고정한다. 전역 심볼
// 네이밍 일관성을 도입하는 lifecycle 변경(이슈 #4101)이 진행될 때, 아래 lock 테스트가
// **현재 정상 동작을 회귀로부터 보호**한다 — 특히:
//   • cross-chunk 로 공유되는 심볼은 provider/consumer 가 *같은 이름*으로 합의해야 한다.
//   • cross-chunk 로 *공유되지 않는* 심볼은 청크별로 *이름을 재사용*해도 된다(번들 크기
//     최적화 — 이게 깨지면 모든 청크가 전역 유니크명을 받아 번들이 비대해진다).
//
// `test.todo` 는 아직 미해결인 #B(같은 이름 cross-chunk 충돌 → 소비자 본문 collapse).
// lifecycle 재설계로 전역 네이밍 일관성이 확보되면 `test` 로 flip 되어 green 가드가 된다.
// ────────────────────────────────────────────────────────────────────────────

describe('cross-chunk 심볼 네이밍 (이슈 #4101 방어 스위트)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  // dev_split lazy 빌드 → entry + 지정 lazy 청크들을 vm 에 로드 → 모듈별 require 헬퍼 반환.
  // 여러 lazy 청크를 동시에 force-parse/로드(독립 청크 이름 재사용 검증용).
  async function loadDevSplit(
    files: Record<string, string>,
    lazyFiles: string[],
  ): Promise<{
    require: (re: RegExp) => Record<string, unknown>;
    chunkText: (re: RegExp) => string;
    entryText: string;
  }> {
    const fixture = await createFixture(files);
    cleanup = fixture.cleanup;
    const dir = realpathSync(fixture.dir);
    const opts = {
      entryPoints: [join(dir, 'entry.ts')],
      platform: 'browser' as const,
      devMode: true,
      splitting: true,
      format: 'iife' as const,
      lazyCompilation: true,
      rootDir: dir,
    };
    const base = await build(opts);
    const seeds = (base.lazySeeds ?? [])
      .filter((s) => lazyFiles.some((f) => s.path.endsWith(f)))
      .map((s) => s.path);
    expect(seeds.length).toBe(lazyFiles.length);
    const r = await build({ ...opts, lazyForceParse: seeds });
    expect(r.errors ?? []).toHaveLength(0);
    const outs = r.outputFiles ?? [];
    const entry = outs.find((o) => o.path.endsWith('entry.js'));
    expect(entry).toBeDefined();
    const lazyChunks = lazyFiles.map((f) => {
      const pre = f.replace(/\.tsx?$/, '') + '-';
      const ch = outs.find((o) => o.path.includes(pre) && o.path.endsWith('.js'));
      expect(ch).toBeDefined();
      return ch!;
    });
    const g: Record<string, unknown> = { console };
    g.globalThis = g;
    const ctx = vm.createContext(g);
    vm.runInContext(entry!.text, ctx);
    for (const ch of lazyChunks) vm.runInContext(ch.text, ctx);
    const mods = g.__zntc_mods as Record<string, unknown>;
    const reqFn = g.__zntc_require as (k: string) => Record<string, unknown>;
    return {
      require: (re: RegExp) => reqFn(Object.keys(mods).find((k) => re.test(k))!),
      chunkText: (re: RegExp) => lazyChunks.find((c) => re.test(c.path))!.text,
      entryText: entry!.text,
    };
  }

  // ── LOCK: 현재 정상 동작 (lifecycle 재설계가 깨면 안 됨) ──────────────────────

  test('lock: 단일 named import cross-chunk', async () => {
    const { require } = await loadDevSplit(
      {
        'dep.ts': "export const foo = 'FOO';",
        'Route.ts': "import { foo } from './dep';\nexport function r(){ return foo; }",
        'entry.ts':
          "import { foo } from './dep';\nglobalThis.E = foo;\nglobalThis.r = () => import('./Route');",
      },
      ['Route.ts'],
    );
    expect((require(/Route/).r as () => string)()).toBe('FOO');
  });

  test('lock: aliased import (import { x as y })', async () => {
    const { require } = await loadDevSplit(
      {
        'dep.ts': "export const x = 'XVAL';",
        'Route.ts': "import { x as y } from './dep';\nexport function r(){ return y; }",
        'entry.ts':
          "import { x } from './dep';\nglobalThis.E = x;\nglobalThis.r = () => import('./Route');",
      },
      ['Route.ts'],
    );
    expect((require(/Route/).r as () => string)()).toBe('XVAL');
  });

  test('lazy cross-chunk aliases of one SymbolId share one provider key across hostile fixtures', async () => {
    const fixtures: {
      label: string;
      shared: string;
      aliases: string[];
      keys?: string[];
      values?: string[];
    }[] = [
      {
        label: 'two aliases in one export clause',
        shared: "const value = () => 'VALUE';\nexport { value as a, value as b };",
        aliases: ['a', 'b'],
      },
      {
        label: 'aliases in separate export clauses',
        shared: "let value = () => 'VALUE';\nexport { value as left };\nexport { value as right };",
        aliases: ['left', 'right'],
      },
      {
        label: 'function declaration aliases',
        shared: "function value() { return 'VALUE'; }\nexport { value as a, value as b };",
        aliases: ['a', 'b'],
      },
      {
        label: 'named function expression aliases',
        shared:
          "const value = function namedValue() { return 'VALUE'; };\nexport { value as a, value as b };",
        aliases: ['a', 'b'],
      },
      {
        label: 'default and named aliases',
        shared: "const value = () => 'VALUE';\nexport { value as default, value as named };",
        aliases: ['default', 'named'],
      },
      {
        label: 'reserved-word export alias',
        shared: "const value = () => 'VALUE';\nexport { value as a, value as delete };",
        aliases: ['a', 'delete'],
      },
      {
        label: 'same binding with a suffix-shaped decoy',
        shared:
          "const value = () => 'VALUE';\nconst value$1 = () => 'DECOY';\nexport { value as a, value as b };",
        aliases: ['a', 'b'],
      },
      {
        label: 'three public aliases',
        shared: "const value = () => 'VALUE';\nexport { value as a, value as b, value as c };",
        aliases: ['a', 'b', 'c'],
      },
      {
        label: 'synthetic-name-shaped public aliases',
        shared: "const value = () => 'VALUE';\nexport { value as _default, value as _default$1 };",
        aliases: ['_default', '_default$1'],
      },
      {
        label: 'same binding plus a second independently exported binding',
        shared:
          "const value = () => 'VALUE';\nconst other = () => 'OTHER';\nexport { value as a, value as b, other as c, other as d };",
        aliases: ['a', 'b', 'c', 'd'],
        keys: ['value', 'value', 'other', 'other'],
        values: ['VALUE', 'VALUE', 'OTHER', 'OTHER'],
      },
    ];

    for (const fixture of fixtures) {
      const importPath = './shared';
      const lazyFiles = fixture.aliases.map((_, i) => `heavy-${i}.ts`);
      const files: Record<string, string> = {
        'shared.ts': fixture.shared,
        'entry.ts':
          `import { ${fixture.aliases[0]} as entryValue } from '${importPath}';\n` +
          `globalThis.entryValue = entryValue();\n` +
          lazyFiles
            .map((file, i) => `globalThis.load${i} = () => import('./${file.slice(0, -3)}');`)
            .join('\n'),
      };
      for (const [i, alias] of fixture.aliases.entries()) {
        files[lazyFiles[i]] =
          `import { ${alias} as imported } from '${importPath}';\n` +
          `export function read() { return imported(); }`;
      }

      const { require, chunkText } = await loadDevSplit(files, lazyFiles);
      try {
        for (const [i] of fixture.aliases.entries()) {
          expect(require(new RegExp(`heavy-${i}`)).read()).toBe(fixture.values?.[i] ?? 'VALUE');
          expect(chunkText(new RegExp(`heavy-${i}`))).toMatch(
            new RegExp(
              `const\\s*\\{\\s*${fixture.keys?.[i] ?? 'value'}(?:\\s*:\\s*\\w+)?\\s*\\}\\s*=\\s*__zntc_require\\("entry\\.js"\\)`,
            ),
          );
          expect(chunkText(new RegExp(`heavy-${i}`))).not.toContain(
            `${fixture.keys?.[i] ?? 'value'}$1`,
          );
        }
      } finally {
        const closeFixture = cleanup;
        cleanup = undefined;
        await closeFixture?.();
      }
    }
  });

  test('lazy cross-chunk same spelling from different provider SymbolIds stays distinct', async () => {
    const { require, chunkText } = await loadDevSplit(
      {
        'source-a.ts': "export const value = () => 'A';",
        'source-b.ts': "export const value = () => 'B';",
        'heavy-a.ts':
          "import { value } from './source-a';\nexport function read() { return value(); }",
        'heavy-b.ts':
          "import { value } from './source-b';\nexport function read() { return value(); }",
        'entry.ts':
          "import { value as eagerA } from './source-a';\n" +
          "import { value as eagerB } from './source-b';\n" +
          'globalThis.eager = eagerA() + eagerB();\n' +
          "globalThis.loadA = () => import('./heavy-a');\n" +
          "globalThis.loadB = () => import('./heavy-b');",
      },
      ['heavy-a.ts', 'heavy-b.ts'],
    );
    expect(require(/heavy-a/).read()).toBe('A');
    expect(require(/heavy-b/).read()).toBe('B');
    expect(chunkText(/heavy-a/)).toMatch(/\{\s*value\s*\}\s*=\s*__zntc_require\("entry\.js"\)/);
    expect(chunkText(/heavy-b/)).toMatch(/\{\s*value\$1\s*\}\s*=\s*__zntc_require\("entry\.js"\)/);
  });

  test('lazy entry export-all keeps re-export spellings out of local bindings', async () => {
    const fixtures: {
      label: string;
      modules: Record<string, string>;
      barrel: string;
      aliases: string[];
      values: string[];
      read?: string;
      forbiddenLocals?: string[];
    }[] = [
      {
        label: 'one renamed alias',
        modules: { 'shared.ts': "const value = () => 'VALUE';\nexport { value as original };" },
        barrel: "export { original as left } from './shared';",
        aliases: ['left'],
        values: ['VALUE'],
        forbiddenLocals: ['original'],
      },
      {
        label: 'same-name re-export',
        modules: { 'shared.ts': "export const value = () => 'VALUE';" },
        barrel: "export { value } from './shared';",
        aliases: ['value'],
        values: ['VALUE'],
      },
      {
        label: 'two aliases in one re-export clause',
        modules: { 'shared.ts': "const value = () => 'VALUE';\nexport { value as original };" },
        barrel: "export { original as left, original as right } from './shared';",
        aliases: ['left', 'right'],
        values: ['VALUE', 'VALUE'],
        forbiddenLocals: ['original'],
      },
      {
        label: 'aliases in separate re-export clauses',
        modules: { 'shared.ts': "const value = () => 'VALUE';\nexport { value as original };" },
        barrel:
          "export { original as left } from './shared';\nexport { original as right } from './shared';",
        aliases: ['left', 'right'],
        values: ['VALUE', 'VALUE'],
        forbiddenLocals: ['original'],
      },
      {
        label: 'two-hop barrel chain',
        modules: {
          'shared.ts': "const value = () => 'VALUE';\nexport { value as original };",
          'middle.ts': "export { original as forwarded } from './shared';",
        },
        barrel: "export { forwarded as finalName } from './middle';",
        aliases: ['finalName'],
        values: ['VALUE'],
        forbiddenLocals: ['original', 'forwarded'],
      },
      {
        label: 'synthetic default export alias',
        modules: { 'shared.ts': "const value = () => 'VALUE';\nexport { value as default };" },
        barrel: "export { default as component } from './shared';",
        aliases: ['component'],
        values: ['VALUE'],
        forbiddenLocals: ['default'],
      },
      {
        label: 'named default declaration alias',
        modules: { 'shared.ts': "export default function Widget() { return 'VALUE'; }" },
        barrel: "export { default as component } from './shared';",
        aliases: ['component'],
        values: ['VALUE'],
        forbiddenLocals: ['default'],
      },
      {
        label: 'reserved-word re-export name',
        modules: { 'shared.ts': "const value = () => 'VALUE';\nexport { value as delete };" },
        barrel: "export { delete as remove } from './shared';",
        aliases: ['remove'],
        values: ['VALUE'],
        forbiddenLocals: ['delete'],
      },
      {
        label: 'suffix-shaped decoy in provider',
        modules: {
          'shared.ts':
            "const value = () => 'VALUE';\nconst value$1 = () => 'DECOY';\nexport { value as original };",
        },
        barrel: "export { original as left } from './shared';",
        aliases: ['left'],
        values: ['VALUE'],
        forbiddenLocals: ['original'],
      },
      {
        label: 'star re-export retains source local exports',
        modules: { 'shared.ts': "export const value = () => 'VALUE';" },
        barrel: "export * from './shared';",
        aliases: ['value'],
        values: ['VALUE'],
      },
      {
        label: 'same local spelling from distinct source symbols',
        modules: {
          'source-a.ts': "const value = () => 'A';\nexport { value as original };",
          'source-b.ts': "const value = () => 'B';\nexport { value as original };",
        },
        barrel:
          "export { original as left } from './source-a';\nexport { original as right } from './source-b';",
        aliases: ['left', 'right'],
        values: ['A', 'B'],
      },
    ];

    for (const [fixtureIndex, fixture] of fixtures.entries()) {
      const files = { ...fixture.modules, 'barrel.ts': fixture.barrel };
      const lazyFiles = fixture.aliases.map((_, i) => `heavy-${fixtureIndex}-${i}.ts`);
      for (const [i, alias] of fixture.aliases.entries()) {
        files[lazyFiles[i]] =
          `import { ${alias} as imported } from './barrel';\n` +
          `export function read() { return ${fixture.read ?? 'imported()'}; }`;
      }
      const eagerRead = (fixture.read ?? 'imported()').replaceAll('imported', 'eager');
      files['entry.ts'] =
        `import { ${fixture.aliases[0]} as eager } from './barrel';\n` +
        `globalThis.eager = ${eagerRead};\n` +
        lazyFiles
          .map((file, i) => `globalThis.load${i} = () => import('./${file.slice(0, -3)}');`)
          .join('\n');

      const { require, entryText } = await loadDevSplit(files, lazyFiles);
      try {
        for (const [i] of fixture.aliases.entries()) {
          expect(require(new RegExp(`heavy-${fixtureIndex}-${i}`)).read()).toBe(fixture.values[i]);
        }
        for (const local of fixture.forbiddenLocals ?? []) {
          expect(entryText).not.toMatch(new RegExp(`exports\\.${local}\\s*=\\s*${local}`));
        }
      } finally {
        const closeFixture = cleanup;
        cleanup = undefined;
        await closeFixture?.();
      }
    }
  });

  test('lock: 함수 + const export 혼합 cross-chunk', async () => {
    const { require } = await loadDevSplit(
      {
        'dep.ts': "export const c = 'C';\nexport function fn(){ return 'FN'; }",
        'Route.ts': "import { c, fn } from './dep';\nexport function r(){ return c + ':' + fn(); }",
        'entry.ts':
          "import { fn } from './dep';\nglobalThis.E = fn();\nglobalThis.r = () => import('./Route');",
      },
      ['Route.ts'],
    );
    expect((require(/Route/).r as () => string)()).toBe('C:FN');
  });

  // ⭐ CRITICAL: cross-chunk 로 *공유되지 않는* 동명 심볼은 청크별로 이름을 재사용해도 된다.
  // 두 lazy 청크가 각각 자기 local `v`('R1'/'R2')를 쓴다 — 서로 안 보이므로 deconflict 불필요.
  // lifecycle 재설계가 이를 전역 유니크명으로 강제하면 번들이 비대해진다(재설계의 anti-goal).
  test('lock: ⭐ 독립 청크의 동명 local 은 이름 재사용 (번들 크기 최적화)', async () => {
    const { require } = await loadDevSplit(
      {
        'r1.ts': "const v = 'R1';\nexport function r(){ return v; }",
        'r2.ts': "const v = 'R2';\nexport function r(){ return v; }",
        'entry.ts': "globalThis.l1 = () => import('./r1');\nglobalThis.l2 = () => import('./r2');",
      },
      ['r1.ts', 'r2.ts'],
    );
    // 값이 섞이지 않아야(독립). 두 청크가 같은 'v' 식별자를 써도 무방.
    expect((require(/r1/).r as () => string)()).toBe('R1');
    expect((require(/r2/).r as () => string)()).toBe('R2');
  });

  // user-local 과 cross-chunk import 가 같은/다른 이름일 때 deconflict.
  test('lock: 소비자 자체 local + cross-chunk import 공존', async () => {
    const { require } = await loadDevSplit(
      {
        'a.ts': "export const v = 'IMPORTED';",
        'Route.ts':
          "import { v } from './a';\nconst v2 = 'LOCAL';\nexport function r(){ return v + ':' + v2; }",
        'entry.ts':
          "import { v } from './a';\nglobalThis.E = v;\nglobalThis.r = () => import('./Route');",
      },
      ['Route.ts'],
    );
    expect((require(/Route/).r as () => string)()).toBe('IMPORTED:LOCAL');
  });

  // 깊은 cross-chunk 체인 (a → mid → Route).
  test('lock: 깊은 cross-chunk re-export 체인', async () => {
    const { require } = await loadDevSplit(
      {
        'a.ts': "export const deep = 'DEEP';",
        'mid.ts': "export { deep } from './a';",
        'Route.ts': "export { deep } from './mid';",
        'entry.ts':
          "import { deep } from './a';\nglobalThis.E = deep;\nglobalThis.r = () => import('./Route');",
      },
      ['Route.ts'],
    );
    expect(require(/Route/).deep).toBe('DEEP');
  });

  // ── TODO: #B 전역 네이밍 일관성 필요 (이슈 #4101) ─────────────────────────────
  // lifecycle 재설계로 cross-chunk 심볼명이 전역 일관되면 `test.todo`→`test` flip.

  // 서로 다른 모듈의 같은 named export 둘을 한 소비자가 import → 본문 참조 collapse.
  test('전역일관성: 다른 모듈의 같은 named export 둘 (va·vb → AB)', async () => {
    const { require } = await loadDevSplit(
      {
        'a.ts': "export const v = 'A';",
        'b.ts': "export const v = 'B';",
        'Route.ts':
          "import { v as va } from './a';\nimport { v as vb } from './b';\nexport function r(){ return va + vb; }",
        'entry.ts':
          "import { v as va } from './a';\nimport { v as vb } from './b';\nglobalThis.E = va + vb;\nglobalThis.r = () => import('./Route');",
      },
      ['Route.ts'],
    );
    expect((require(/Route/).r as () => string)()).toBe('AB');
  });

  // 서로 다른 모듈의 default 둘.
  test('전역일관성: 다른 모듈의 default 둘 (da()·db() → DADB)', async () => {
    const { require } = await loadDevSplit(
      {
        'a.ts': "export default function(){ return 'DA'; }",
        'b.ts': "export default function(){ return 'DB'; }",
        'Route.ts':
          "import da from './a';\nimport db from './b';\nexport function r(){ return da() + db(); }",
        'entry.ts':
          "import da from './a';\nimport db from './b';\nglobalThis.E = da() + db();\nglobalThis.r = () => import('./Route');",
      },
      ['Route.ts'],
    );
    expect((require(/Route/).r as () => string)()).toBe('DADB');
  });

  // 세 모듈의 같은 이름.
  test('전역일관성: 세 모듈의 같은 named export (a+b+c → ABC)', async () => {
    const { require } = await loadDevSplit(
      {
        'a.ts': "export const v = 'A';",
        'b.ts': "export const v = 'B';",
        'c.ts': "export const v = 'C';",
        'Route.ts':
          "import { v as a } from './a';\nimport { v as b } from './b';\nimport { v as c } from './c';\nexport function r(){ return a + b + c; }",
        'entry.ts':
          "import { v as a } from './a';\nimport { v as b } from './b';\nimport { v as c } from './c';\nglobalThis.E = a + b + c;\nglobalThis.r = () => import('./Route');",
      },
      ['Route.ts'],
    );
    expect((require(/Route/).r as () => string)()).toBe('ABC');
  });
});
