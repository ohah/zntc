import { describe, test, expect, beforeAll, afterAll, afterEach } from 'bun:test';
import { join } from 'node:path';
import { writeFileSync, readFileSync, readdirSync } from 'node:fs';
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

  // (#4541) **raw `require("./x.cjs")`** 한 CJS 가 common chunk 에 안착하면, 소비자 청크가 그
  // `require_x()` 썽크를 import 없이 참조했다(provider 는 export 안 함, 소비자는 side-effect import
  // 만) → `ReferenceError: require_x is not defined`. import binding 이 없는 raw require 라 기존
  // cross-chunk 심볼 기계가 못 봤다. 이제 provider 가 썽크를 export, 소비자가 import 한다
  // (esbuild/rolldown 동형). 빌드 green·파싱 통과·실행만 실패라 node 로 돌려야만 잡힌다.
  const RAW_REQUIRE_COMMON: Files = {
    'shared.cjs': 'exports.s = function(){ return "SHARED"; };',
    'a.js': 'const sh = require("./shared.cjs");\nexport const a = "A:" + sh.s();',
    'b.js': 'const sh = require("./shared.cjs");\nexport const b = "B:" + sh.s();',
    'entry.js':
      'Promise.all([import("./a.js"), import("./b.js")]).then(([m1, m2]) =>\n' +
      '  console.log("RESULT", m1.a, m2.b));',
  };
  for (const { name, minify } of MATRIX) {
    for (const format of ['esm', 'cjs'] as const) {
      test(`#4541 ${format}/${name}: raw require() 한 common-chunk CJS 썽크가 cross-chunk 노출된다`, async () => {
        // 버그 시: ReferenceError: require_shared is not defined
        expect(await buildAndRun(RAW_REQUIRE_COMMON, { minify, format })).toBe(
          'RESULT A:SHARED B:SHARED',
        );
      });
    }
  }

  // (#4541 후속, #4526 계열) cjs 소비자는 cross-chunk 썽크를 **구조분해하면 안 된다**
  // (`const{require_X}=require(...)`는 로드 시점 스냅샷 → CJS↔CJS cross-chunk 순환에서 provider 의
  // `exports.require_X` 미할당 시점을 박제 → TypeError). require_X 는 함수라 **호출 시점 조회
  // (lazy forwarding)**로 지연 복원한다. ⚠️ 구조적 가드 — 순환은 청커가 상호의존 모듈을 같은
  // 청크로 합쳐 재현이 불안정하므로, 방출된 소비자 청크가 forwarding(`.apply(this, arguments)`)을
  // 쓰고 eager 구조분해(`const { require_`)를 안 쓰는지 직접 확인해 r0 revert 를 잡는다.
  test('#4541 cjs: cross-chunk 썽크 소비자가 eager 구조분해 대신 lazy forwarding 을 쓴다', async () => {
    const { dir, cleanup } = await createFixture(RAW_REQUIRE_COMMON);
    try {
      const outDir = join(dir, 'dist');
      const res = await runZntc([
        '--bundle',
        join(dir, 'entry.js'),
        '--splitting',
        '--outdir',
        outDir,
        '--format=cjs',
      ]);
      expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);
      // 소비자 청크(shared.cjs 를 raw-require 한 a/b) 를 찾는다.
      const jsFiles = readdirSync(outDir).filter((f) => f.endsWith('.js'));
      const consumer = jsFiles
        .map((f) => readFileSync(join(outDir, f), 'utf8'))
        .find((c) => c.includes('require_shared') && !c.includes('exports.require_shared'));
      expect(consumer, '소비자 청크(require_shared 참조)를 못 찾음').toBeDefined();
      // lazy forwarding: 호출 시점 조회 `require("...").require_shared.apply(...)`.
      expect(consumer!).toContain('.apply(this, arguments)');
      // eager 구조분해(로드 시점 스냅샷)를 쓰면 안 된다.
      expect(consumer!).not.toContain('const { require_shared }');
      // 그리고 실제로 실행돼야 한다.
      const { stdout } = await runNode(join(outDir, 'entry.js'));
      expect(stdout.trim()).toBe('RESULT A:SHARED B:SHARED');
    } finally {
      await cleanup();
    }
  });

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

  test('#4522 code-split 된 동적 CJS import 도 named 멤버를 노출한다 (인라인과 같은 값)', async () => {
    // CJS 는 정적 export 가 없어 named 멤버를 ESM `export` 문법으로 표현할 수 없다. 그래서
    // 동적 CJS entry 청크는 **namespace 통째**를 `default` 슬롯에 실어 보내고, 소비자가
    // `.default` 로 한 겹 벗긴다. 예전엔 `default` **값 하나**만 내보내서 named 가 유실됐고,
    // 그 결과 **같은 소스가 청킹에 따라 런타임 값이 갈렸다**(인라인=정상 / splitting=TypeError).
    //
    // 정본: node 는 `import('./x.cjs')` 에서 named 를 노출한다(cjs-module-lexer).
    // rolldown / rspack 도 code-split 상태에서 노출한다 — esbuild 만 예외.
    const files = {
      'legacy.cjs': 'module.exports = { foo() { return "FOO"; }, bar: 42 };',
      'entry.js':
        'import("./legacy.cjs").then((m) => {\n' +
        '  console.log("keys:" + Object.keys(m).sort().join(",") + "|foo:" + (typeof m.foo === "function" ? m.foo() : "MISSING") + "|default:" + (m.default ? m.default.bar : "MISSING"));\n' +
        '});',
    };

    // splitting 과 인라인이 **같은 값**을 내야 한다.
    const { dir, cleanup } = await createFixture(files);
    try {
      const outDir = join(dir, 'dist');
      const split = await runZntc([
        '--bundle',
        join(dir, 'entry.js'),
        '--splitting',
        '--outdir',
        outDir,
        '--format=esm',
      ]);
      expect(split.exitCode, `빌드 실패:\n${split.stderr}`).toBe(0);
      writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));
      const splitOut = await runNode(join(outDir, 'entry.js'));

      const inlineFile = join(dir, 'inline.mjs');
      const inline = await runZntc([
        '--bundle',
        join(dir, 'entry.js'),
        '-o',
        inlineFile,
        '--format=esm',
      ]);
      expect(inline.exitCode, `빌드 실패:\n${inline.stderr}`).toBe(0);
      const inlineOut = await runNode(inlineFile);

      // 버그 시 splitting: `keys:default|foo:MISSING|default:42`
      expect(splitOut.stdout.trim()).toBe('keys:bar,default,foo|foo:FOO|default:42');
      expect(splitOut.stdout.trim()).toBe(inlineOut.stdout.trim());
    } finally {
      await cleanup();
    }
  });
  test('#4522 후속: 문자열 리터럴이 앞서 나와도 import() specifier 가 청크로 치환된다', async () => {
    // 소비자 재작성을 `rewriteImportCallToWrapper`(첫 indexOf 1회) 로 하면 앞선 문자열
    // 리터럴 occurrence 를 잡고 실패해 **specifier 가 통째로 미치환** → ERR_MODULE_NOT_FOUND.
    // `rewriteImportSpecifier` 와 같은 positional walk 를 써야 한다(#4295 가 고쳤던 그 버그).
    const { dir, cleanup } = await createFixture({
      'legacy.cjs': 'module.exports = { foo() { return "FOO"; } };',
      'entry.js':
        'const label = "./legacy.cjs";\n' +
        'console.log("label:" + label);\n' +
        'import("./legacy.cjs").then((m) => console.log("foo:" + m.foo()));',
    });
    try {
      const outDir = join(dir, 'dist');
      const res = await runZntc([
        '--bundle',
        join(dir, 'entry.js'),
        '--splitting',
        '--outdir',
        outDir,
        '--format=esm',
      ]);
      expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);
      writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      // 버그 시: ERR_MODULE_NOT_FOUND (./legacy.cjs 를 dist 에서 찾음)
      expect(stderr).not.toContain('ERR_MODULE_NOT_FOUND');
      expect(stdout.trim().split('\n').pop()).toBe('foo:FOO');
    } finally {
      await cleanup();
    }
  });

  test('#4522 후속: import attributes 가 붙어도 specifier 가 청크로 치환된다', async () => {
    // `import("./x.cjs", { with: {} })` — 닫는 quote 뒤가 `,` 라, `)` 만 허용하는 재작성기는
    // specifier 를 미치환으로 남긴다(#4295 회귀).
    const { dir, cleanup } = await createFixture({
      'legacy.cjs': 'module.exports = { foo() { return "FOO"; } };',
      'entry.js':
        'import("./legacy.cjs", { with: {} }).then((m) => console.log("foo:" + m.foo()));',
    });
    try {
      const outDir = join(dir, 'dist');
      const res = await runZntc([
        '--bundle',
        join(dir, 'entry.js'),
        '--splitting',
        '--outdir',
        outDir,
        '--format=esm',
      ]);
      expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);
      writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));
      const { stdout, stderr } = await runNode(join(outDir, 'entry.js'));
      expect(stderr).not.toContain('ERR_MODULE_NOT_FOUND');
      expect(stdout.trim()).toBe('foo:FOO');
    } finally {
      await cleanup();
    }
  });

  test('#4522 후속: __esModule CJS 도 default / named 가 모두 맞는다 (이중 interop 없음)', async () => {
    // 청크가 namespace 를 싣고 소비자가 한 겹 벗기므로 `__toESM` 이 두 번 걸리면 안 된다.
    // rolldown 과 같은 값이 나와야 한다.
    const { dir, cleanup } = await createFixture({
      'legacy.cjs':
        'Object.defineProperty(exports, "__esModule", { value: true });\n' +
        'exports.default = { kind: "REAL_DEFAULT" };\n' +
        'exports.named = "NAMED";',
      'entry.js':
        'import("./legacy.cjs").then((m) => {\n' +
        '  console.log("keys:" + Object.keys(m).sort().join(",") + "|default:" + (m.default && m.default.kind) + "|named:" + m.named);\n' +
        '});',
    });
    try {
      const outDir = join(dir, 'dist');
      const res = await runZntc([
        '--bundle',
        join(dir, 'entry.js'),
        '--splitting',
        '--outdir',
        outDir,
        '--format=esm',
      ]);
      expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);
      writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));
      const { stdout } = await runNode(join(outDir, 'entry.js'));
      expect(stdout.trim()).toBe('keys:default,named|default:REAL_DEFAULT|named:NAMED');
    } finally {
      await cleanup();
    }
  });

  // (#4537) **CJS-wrapped entry** + `--splitting`. entry 가 `require()` 를 써서 `__commonJS`
  // 로 래핑되면 `var require_entry = __commonJS(...)` **선언만** 나오고 아무도 `require_entry()`
  // 를 안 불러 entry 본문이 통째로 미실행이었다(splitting 만; 단일번들은 끝에서 호출). 빌드
  // exit 0 · 파싱 통과 · 실행만 무동작(stdout 빈 문자열)이라 node 로 돌려야만 잡힌다.
  //
  // ⚠️ minify 변형 필수(이 파일 규약, l.17): 호출은 `appendModuleCall` 이 rename_table 로
  // 이름을 푸는데, minify 는 래퍼명(`require_entry`→`o`)을 한 번 더 바꾼다. 선언과 호출이
  // 다른 이름으로 풀리면 `ReferenceError: <name> is not defined` — minify 에서만 터진다.
  for (const format of ['esm', 'cjs'] as const) {
    for (const { name, minify } of MATRIX) {
      test(`#4537 ${format}/${name}: --splitting 에서 CJS-wrapped entry 본문이 실행된다`, async () => {
        const { dir, cleanup } = await createFixture({
          'legacy.cjs': 'exports.foo = function(){ return "FOO"; };',
          'other.js': 'export const val = "OTHER";',
          'entry.js':
            'function load(){ return require("./legacy.cjs").foo(); }\n' +
            'import("./other.js").then((m) => console.log(load() + m.val));',
        });
        try {
          const outDir = join(dir, 'dist');
          const args = [
            '--bundle',
            join(dir, 'entry.js'),
            '--splitting',
            '--outdir',
            outDir,
            `--format=${format}`,
          ];
          if (minify) args.push('--minify');
          const res = await runZntc(args);
          expect(res.exitCode, `빌드 실패:\n${res.stderr}`).toBe(0);
          if (format === 'esm')
            writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));

          // 실제로 청크가 쪼개졌는지(cross-chunk 경계 존재) — 청킹 휴리스틱이 바뀌어 단일
          // 청크로 합쳐지면 splitting entry 경로를 안 밟아 이 가드가 진공이 된다.
          const jsFiles = readdirSync(outDir).filter((f) => f.endsWith('.js'));
          expect(jsFiles.length).toBeGreaterThan(1);

          // non-vacuity: entry 가 **자기 자신의** `__commonJS` 래퍼(`require_entry`)로 래핑되고
          // **그 래퍼가 호출**되는지 — plain 에서 구조로 직접 확인한다(minify 는 이름을 mangle
          // 하므로 `$c`/`__commonJS` 만 보면 helper 정의·`require_legacy` 형제 래퍼와도 매칭돼
          // scope-hoist entry 를 진공 통과시킨다). #4537 회귀 시(선언만·호출없음, 또는 scope-hoist
          // 로 래퍼 소멸) plain 변형이 이 두 assert 로 잡는다. minify 변형은 stdout 으로 rename
          // 일치까지 검증(불일치면 ReferenceError → 빈 stdout).
          const entryCode = readFileSync(join(outDir, 'entry.js'), 'utf8');
          if (!minify) {
            expect(entryCode).toContain('var require_entry =');
            expect(entryCode).toContain('require_entry();');
          }

          const { stdout } = await runNode(join(outDir, 'entry.js'));
          // 버그 시: 빈 문자열(본문 미실행 — exit 0). minify rename 불일치 회귀 시: node 가
          // `ReferenceError` 로 non-zero exit → `runNode` 가 throw(빈 stdout 아님).
          expect(stdout.trim()).toBe('FOOOTHER');
        } finally {
          await cleanup();
        }
      });
    }
  }
});
