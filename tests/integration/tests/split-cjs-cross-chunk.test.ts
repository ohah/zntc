import { describe, test, expect, beforeAll, afterAll, afterEach } from 'bun:test';
import { join } from 'node:path';
import { createFixture, runNode, runZntc, writeOutputs } from './helpers';
import { init, close, build } from '../../../packages/core/index';

// code-splitting 산출물을 **실제로 실행**해 값을 검증하는 스모크.
//
// 이 계열의 버그(#4494)는 빌드 exit 0 + 산출물 전부 파싱 통과인데 **실행만** 실패한다
// (미정의 식별자 참조). 즉 재파싱/텍스트 검사만으로는 못 잡는다 — 반드시 node 로 돌려
// stdout 을 비교해야 한다.
//
// ⚠️ 산출물은 반드시 **빈 `dist/`** 로 내보내고 거기서 실행한다. fixture 루트에 덮어쓰면
// 원본 소스(a.js/b.js…)가 그대로 남아, entry 청크가 안 써져도 node 가 *원본* 을 실행해
// 같은 stdout 을 내는 진공(vacuous) 통과가 가능하다.
//
// minify 는 이름을 한 번 더 바꾸므로 항상 on/off 양쪽을 돈다 — 이 계열은 minify 에서만
// 깨지는 변종이 실재한다(CJS 내부 심볼 rename).

const MATRIX = [
  { name: 'plain', minify: false },
  { name: 'minify', minify: true },
] as const;

type Files = Record<string, string>;

describe('code-splitting 런타임 스모크', () => {
  let cleanup: (() => Promise<void>) | undefined;
  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  /// fixture 를 splitting 번들로 빌드해 `dist/` 에 쓰고 `dist/entry.js` 를 실행한 stdout 반환.
  async function buildAndRun(
    files: Files,
    opts: { minify: boolean; format?: 'esm' | 'cjs' },
  ): Promise<string> {
    const fixture = await createFixture(files);
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, 'entry.js')],
      rootDir: fixture.dir,
      platform: 'node',
      splitting: true,
      format: opts.format ?? 'esm',
      minify: opts.minify,
    });
    expect(result.errors ?? []).toHaveLength(0);

    const outs = result.outputFiles!;
    // 전제: 실제로 청크가 쪼개졌다(= cross-chunk 경계가 존재). 청킹 휴리스틱이 바뀌어
    // 모든 게 한 청크로 합쳐지면 이 가드들은 아무것도 검증하지 못한다.
    expect(outs.filter((o) => o.path.endsWith('.js')).length).toBeGreaterThan(2);

    const dist = join(fixture.dir, 'dist');
    writeOutputs(dist, outs);
    const { stdout } = await runNode(join(dist, 'entry.js'));
    return stdout.trim();
  }

  // (#4494) 크로스-청크 CJS import.
  //
  // `single.cjs` 는 공통 청크(same.js + a.js 양쪽에서 도달)에 안착하고, `a.js` 는 그 CJS 를
  // **직접** import 한다 → 소비자 청크(a)가 provider 청크의 `require_single()` 썽크를 참조했다.
  // 썽크는 export 되지도 않고 minify 후엔 이름도 다르다 → `ReferenceError: require_single is
  // not defined`. 이제 provider 가 interop 값을 합성 전역명으로 materialize/export 하고 소비자는
  // 일반 cross-chunk import 로 받는다.
  const CROSS_CHUNK_CJS: Files = {
    'shared/single.cjs': 'module.exports = { tag: "singleton" };',
    'shared/second.cjs': 'exports.named = "named-value";',
    // 공통 청크: 같은 CJS 들을 같은 청크에서 소비(= provider 측 preamble 경로).
    'shared/same.js':
      'import single from "./single.cjs";\n' +
      'import { named } from "./second.cjs";\n' +
      'export const fromSameChunk = single.tag + "/" + named;',
    // 소비자 청크: 같은 CJS 를 **다른 청크에서** 직접 import(cross-chunk).
    'a.js':
      'import single from "./shared/single.cjs";\n' +
      'import { named } from "./shared/second.cjs";\n' +
      'import { fromSameChunk } from "./shared/same.js";\n' +
      'export const a = [single.tag, named, fromSameChunk].join("|");',
    'b.js':
      'import { fromSameChunk } from "./shared/same.js";\nexport const b = "b:" + fromSameChunk;',
    'entry.js':
      'Promise.all([import("./a.js"), import("./b.js")]).then(([m1, m2]) => {\n' +
      '  console.log("RESULT", m1.a, m2.b);\n' +
      '});',
  };
  const CROSS_CHUNK_CJS_EXPECT =
    'RESULT singleton|named-value|singleton/named-value b:singleton/named-value';

  for (const { name, minify } of MATRIX) {
    for (const format of ['esm', 'cjs'] as const) {
      test(`${format}/${name}: 크로스-청크 CJS default/named import 가 실행된다 (#4494)`, async () => {
        expect(await buildAndRun(CROSS_CHUNK_CJS, { minify, format })).toBe(CROSS_CHUNK_CJS_EXPECT);
      });
    }
  }

  // (#4494) CJS 모듈이 export 멤버와 **같은 이름의 내부 심볼**을 가진 경우.
  // provider 는 `var <전역명> = require_lib().tag;` 를 청크 top-level 에 깔아야 하는데,
  // 예전엔 "이 이름의 로컬이 이미 있다"고 오판(그 로컬은 `__commonJS` 클로저 *안*의 `tag` 다)해
  // materialize 를 건너뛰고 클로저 스코프 이름을 그대로 `export { o as tag }` 로 노출했다
  // → minify 에서만 터지는 `SyntaxError: Export 'o' is not defined in module`.
  for (const { name, minify } of MATRIX) {
    test(`${name}: CJS 내부 심볼과 export 멤버명이 같아도 실행된다 (#4494)`, async () => {
      const out = await buildAndRun(
        {
          'shared/lib.cjs': 'function tag() { return "TAG"; }\nmodule.exports = { tag: tag };',
          'shared/same.js':
            'import { tag } from "./lib.cjs";\nexport const fromSameChunk = "same:" + tag();',
          'a.js':
            'import { tag } from "./shared/lib.cjs";\n' +
            'import { fromSameChunk } from "./shared/same.js";\n' +
            'export const a = tag() + "|" + fromSameChunk;',
          'b.js':
            'import { fromSameChunk } from "./shared/same.js";\nexport const b = "b:" + fromSameChunk;',
          'entry.js':
            'Promise.all([import("./a.js"), import("./b.js")]).then(([m1, m2]) =>\n' +
            '  console.log("RESULT", m1.a, m2.b));',
        },
        { minify },
      );
      expect(out).toBe('RESULT TAG|same:TAG b:same:TAG');
    });
  }

  // (#4494) CJS export 멤버명이 **진짜 전역**(Buffer)과 같은 경우. provider 청크 top-level 에
  // `var Buffer = require_lib().Buffer;` 를 깔면 같은 청크의 다른 모듈이 쓰는 Node 전역 Buffer 를
  // 가려버린다(`Buffer.from is not a function`). 공개명을 합성명(`Buffer$lib`)으로 만들어 회피한다.
  for (const { name, minify } of MATRIX) {
    test(`${name}: CJS export 멤버명이 전역(Buffer)과 같아도 전역을 가리지 않는다 (#4494)`, async () => {
      const out = await buildAndRun(
        {
          'shared/lib.cjs': 'exports.Buffer = { fake: true };\nexports.other = "OTHER";',
          'shared/same.js':
            'import d from "./lib.cjs";\n' +
            'export const s = d.other;\n' +
            'export function realBuf() { return Buffer.from("hi").toString(); }',
          'a.js':
            'import { Buffer as FakeBuf } from "./shared/lib.cjs";\n' +
            'import { s, realBuf } from "./shared/same.js";\n' +
            'export const a = FakeBuf.fake + "|" + s + "|" + realBuf();',
          'b.js':
            'import { s, realBuf } from "./shared/same.js";\n' +
            'export const b = "b:" + s + ":" + realBuf();',
          'entry.js':
            'Promise.all([import("./a.js"), import("./b.js")]).then(([m1, m2]) =>\n' +
            '  console.log("RESULT", m1.a, m2.b));',
        },
        { minify },
      );
      expect(out).toBe('RESULT true|OTHER|hi b:OTHER:hi');
    });
  }

  // (#4494) 합성 공개명이 provider 청크의 동명 로컬(`const named = …`)과 부딪히지 않는지.
  // (예전 설계는 멤버명을 그대로 공개명으로 써서 `var named` ↔ `const named` 재선언 SyntaxError.)
  for (const { name, minify } of MATRIX) {
    test(`${name}: CJS export 멤버명이 provider 청크 로컬과 같아도 실행된다 (#4494)`, async () => {
      const out = await buildAndRun(
        {
          'shared/second.cjs': 'exports.named = "from-cjs";',
          'shared/other.js': 'export const named = "LOCAL-CONST";',
          'shared/same.js':
            'import { named as cjsNamed } from "./second.cjs";\n' +
            'import { named } from "./other.js";\n' +
            'export const fromSameChunk = "same:" + named + "/" + cjsNamed;',
          'a.js':
            'import { named } from "./shared/second.cjs";\n' +
            'import { fromSameChunk } from "./shared/same.js";\n' +
            'export const a = named + "|" + fromSameChunk;',
          'b.js':
            'import { fromSameChunk } from "./shared/same.js";\nexport const b = "b:" + fromSameChunk;',
          'entry.js':
            'Promise.all([import("./a.js"), import("./b.js")]).then(([m1, m2]) =>\n' +
            '  console.log("RESULT", m1.a, m2.b));',
        },
        { minify },
      );
      expect(out).toBe('RESULT from-cjs|same:LOCAL-CONST/from-cjs b:same:LOCAL-CONST/from-cjs');
    });
  }

  // (#4494) `__esModule` 마커가 있는 CJS(= __toESM interop 필요) + 크로스-청크 default/named,
  // 그리고 그 import 를 소비자 청크가 그대로 재-export 하는 형태.
  for (const { name, minify } of MATRIX) {
    test(`${name}: __esModule CJS 크로스-청크 + import 재-export 가 실행된다 (#4494)`, async () => {
      const out = await buildAndRun(
        {
          'shared/esm_cjs.cjs':
            'Object.defineProperty(exports, "__esModule", { value: true });\n' +
            'exports.default = "ESM-DEFAULT";\n' +
            'exports.other = "OTHER";',
          'shared/same.js':
            'import d from "./esm_cjs.cjs";\nexport const fromSameChunk = "same:" + d;',
          'a.js':
            'import esmD, { other } from "./shared/esm_cjs.cjs";\n' +
            'import { fromSameChunk } from "./shared/same.js";\n' +
            'export { esmD };\n' +
            'export const a = [esmD, other, fromSameChunk].join("|");',
          'b.js':
            'import { fromSameChunk } from "./shared/same.js";\nexport const b = "b:" + fromSameChunk;',
          'entry.js':
            'Promise.all([import("./a.js"), import("./b.js")]).then(([m1, m2]) =>\n' +
            '  console.log("RESULT", m1.a, m2.b, m1.esmD));',
        },
        { minify },
      );
      expect(out).toBe('RESULT ESM-DEFAULT|OTHER|same:ESM-DEFAULT b:same:ESM-DEFAULT ESM-DEFAULT');
    });
  }
  test('#4510 후속: `import { "default" as d }` 도 CJS default interop 을 탄다', async () => {
    // ES2022 arbitrary module namespace names. binding_scanner 는 AST span 텍스트를 그대로
    // 담아 이름을 **따옴표째** 저장한다(`"\"default\""`). default 판정이 bare `"default"` 와만
    // 비교하면 이 형태가 interop 을 통째로 비껴가 `require_x()["default"]` = **undefined** 가
    // 된다 — 문법은 유효해서 빌드·파싱 다 통과하고 실행만 틀린다.
    //
    // node 정본: `import { "default" as d }` === `import d from` → d = module.exports.
    const { dir, cleanup } = await createFixture({
      'x.cjs': 'module.exports = { a: 1 };',
      'entry.js': 'import { "default" as d } from "./x.cjs";\n' + 'console.log("d.a =", d && d.a);',
    });
    try {
      const outFile = join(dir, 'bundle.mjs');
      const res = await runZntc(['--bundle', join(dir, 'entry.js'), '-o', outFile, '--format=esm']);
      expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);

      const { stdout } = await runNode(outFile);
      // 버그 시: `d.a = undefined`
      expect(stdout.trim()).toBe('d.a = 1');
    } finally {
      await cleanup();
    }
  });
});
