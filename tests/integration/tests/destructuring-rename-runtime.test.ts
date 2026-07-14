import { describe, test, expect } from 'bun:test';
import { runZntc, createFixture } from './helpers';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

/**
 * 구조분해 리네임 산출물 **실행** 스모크 (#4493).
 *
 * 이 계열은 빌드 exit 0 · 산출물 재파싱 통과 · **모듈 평가까지 통과**한다. 문제의 함수를
 * 실제로 **호출**할 때만 터진다 — 그래서 import 스모크로도 못 잡고, 여기서 직접 돌린다.
 *
 * 루트커즈: `({ options: { stack, stackWeight = 1 } } = box)` 는 cover grammar 로
 * `assignment_target_property_identifier`(left=바인딩, right=기본값) 가 되는데, codegen 이
 * 이걸 longhand `key:value=default` 로 펼칠 때 value 위치를 **원본 span 으로 복사**해
 * mangler rename 을 건너뛰었다. 결과적으로 미선언 전역에 대입(strict ESM → ReferenceError)
 * 되고 진짜 지역 변수는 영영 대입되지 않는다.
 */

function runNode(file: string): { out: string; err: string } {
  const r = spawnSync('node', [file], { encoding: 'utf-8' });
  return { out: r.stdout.trim(), err: r.stderr.trim() };
}

async function buildAndRun(
  entry: string,
  extraArgs: string[] = [],
): Promise<{ out: string; err: string; code: string }> {
  const { dir, cleanup } = await createFixture({ 'entry.js': entry });
  try {
    // ESM(strict) 산출물이어야 미선언 전역 대입이 ReferenceError 로 **크게** 터진다.
    // non-strict 포맷이면 조용히 전역을 만들고 지역 변수는 undefined 로 남는다.
    const outFile = join(dir, 'bundle.mjs');
    const build = await runZntc([
      '--bundle',
      join(dir, 'entry.js'),
      '-o',
      outFile,
      '--minify',
      '--format=esm',
      ...extraArgs,
    ]);
    expect(build.exitCode, `빌드 실패:\n${build.stderr}`).toBe(0);
    const code = await Bun.file(outFile).text();
    return { ...runNode(outFile), code };
  } finally {
    await cleanup();
  }
}

describe('구조분해 rename 산출물 실행 스모크', () => {
  test('#4493 중첩 구조분해 할당의 shorthand+기본값이 rename 을 따라간다 (chart.js buildStacks)', async () => {
    // chart.js@4 core.layouts.js `buildStacks` 의 실제 형태. 차트를 **렌더할 때** 죽었다.
    const entry = `
function buildStacks(boxes) {
  const layoutBoxes = [];
  let box, pos, stack, stackWeight;
  for (let i = 0; i < boxes.length; ++i) {
    box = boxes[i];
    ({ position: pos, options: { stack, stackWeight = 1 } } = box);
    layoutBoxes.push(pos + ":" + stack + ":" + stackWeight);
  }
  return layoutBoxes.join(",");
}
// 모듈 평가만으로는 안 터진다 — 반드시 호출해야 드러난다.
console.log(buildStacks([
  { position: "top", options: { stack: "a" } },
  { position: "left", options: { stack: "b", stackWeight: 3 } },
]));
`;
    const { out, err } = await buildAndRun(entry);
    // 수정 전: `ReferenceError: stackWeight is not defined`
    expect(err, `실행 실패:\n${err}`).toBe('');
    expect(out).toBe('top:a:1,left:b:3');
  }, 120000);

  test('#4493 최상위(비중첩) 구조분해 할당의 shorthand+기본값도 동일', async () => {
    // 중첩은 트리거 조건이 아니다 — 선언(`let {x = 1} = o`)이 아니라 **할당**
    // (`({x = 1} = o)`) 형태이기만 하면 최상위에서도 샌다.
    const entry = `
function pick(o) {
  let stackWeight;
  ({ stackWeight = 1 } = o);
  return stackWeight;
}
console.log(pick({}) + "," + pick({ stackWeight: 9 }));
`;
    const { out, err } = await buildAndRun(entry);
    expect(err, `실행 실패:\n${err}`).toBe('');
    expect(out).toBe('1,9');
  }, 120000);

  test('#4493 es5 다운레벨(transformer 경로)에서도 rename 을 따라간다', async () => {
    // es5 에서는 codegen 이 아니라 transformer 가 구조분해를 풀어낸다. 합성한 대입 타겟에
    // symbol_id 를 물려주지 않아 같은 #4493 이 다른 emit 경로로 재현됐다.
    const entry = `
function buildStacks(box) {
  var pos, stack, stackWeight;
  ({ position: pos, options: { stack, stackWeight = 1 } } = box);
  return pos + ":" + stack + ":" + stackWeight;
}
console.log(buildStacks({ position: "top", options: { stack: "a" } }));
`;
    const { out, err } = await buildAndRun(entry, ['--target=es5']);
    // 수정 전: `ReferenceError: stack is not defined`
    expect(err, `실행 실패:\n${err}`).toBe('');
    expect(out).toBe('top:a:1');
  }, 120000);

  test('#4493 `undefined` 바인딩이 void 0 로 치환돼 SyntaxError 가 되지 않는다', async () => {
    // 대입 대상인데 tag 가 identifier_reference 라, value 위치를 무조건 emitNode 로 태우면
    // `undefined` → `void 0` peephole 이 발동해 `{undefined:void 0=1}` → 번들 전체가
    // SyntaxError. (`({undefined = 1} = o)` 는 문법상 합법 — 런타임 TypeError 일 뿐이다.)
    const entry = `
function f(o) {
  try { ({ undefined = 1 } = o); } catch (e) { return "TypeError"; }
  return "assigned";
}
console.log(f({}));
`;
    const { out, err, code } = await buildAndRun(entry);
    // 파싱 자체가 되어야 한다 — SyntaxError 면 여기서 죽는다.
    expect(err, `실행 실패:\n${err}`).toBe('');
    expect(code).not.toContain('void 0=');
    expect(out).toBe('TypeError');
  }, 120000);

  test('#4493 인접 구조분해 형태 전수 회귀 0 (정상 코드가 깨지지 않는다)', async () => {
    // 고친 분기는 assignment-target 의 shorthand+기본값 하나지만, 같은 프린터
    // (`emitBindingProperty`) 가 선언/할당/rest/배열/computed 를 전부 태운다.
    const entry = `
const results = [];
// 1. 일반 구조분해 (longhand)
let longA;
({ x: longA } = { x: "longhand" });
results.push(longA);
// 2. shorthand, 기본값 없음
let shortNoDefault;
({ shortNoDefault } = { shortNoDefault: "short" });
results.push(shortNoDefault);
// 3. 기본값 있음, shorthand 아님
let longWithDefault;
({ missingKey: longWithDefault = "longDefault" } = {});
results.push(longWithDefault);
// 4. 선언형 shorthand + 기본값
const { declShorthand = "declDefault" } = {};
results.push(declShorthand);
// 5. 선언형 중첩 shorthand + 기본값
const { nest: { deepDecl = "deepDeclDefault" } } = { nest: {} };
results.push(deepDecl);
// 6. 배열 + 기본값
let arrElem;
[arrElem = "arrDefault"] = [];
results.push(arrElem);
// 7. rest (객체/배열)
let restFirst, restOfObj, restOfArr;
({ restFirst = "restDefault", ...restOfObj } = { extraKey: "extra" });
[, ...restOfArr] = [0, "restArr"];
results.push(restFirst + "/" + restOfObj.extraKey + "/" + restOfArr[0]);
// 8. 객체 리터럴의 shorthand ({a}) — 프로퍼티 이름은 보존, 값만 rename
const literalValue = "lit";
results.push(JSON.stringify({ literalValue }));
// 9. computed key + 기본값 (같은 프린터의 computed_property_key 분기)
//    주의: 키가 **식별자**인 computed key({[k]: t = d} = o)는 별개의 선재 버그가 있다 —
//    semantic 이 assignment-target 의 computed key 를 방문하지 않아 그 심볼이
//    DCE/const-inline 되고 키는 원본 이름으로 남는다. #4493 과 루트커즈가 다르므로
//    여기선 리터럴 키만 고정한다.
let computedTarget;
({ ["ck"]: computedTarget = "computedDefault" } = {});
results.push(computedTarget);
// 10. 함수 파라미터 shorthand + 기본값 (중첩)
function paramFn({ opts: { widthPx = 10 } = {} } = {}) { return widthPx; }
results.push(paramFn() + "|" + paramFn({ opts: { widthPx: 2 } }));
// 11. for-of 구조분해 할당 + shorthand 기본값
let loopVar;
const loopAcc = [];
for ({ loopVar = 8 } of [{}, { loopVar: 3 }]) loopAcc.push(loopVar);
results.push(loopAcc.join("-"));
// 12. 깊은 중첩(3단) shorthand + 기본값
let deepAssign;
({ a: { b: { deepAssign = 42 } } } = { a: { b: {} } });
results.push(String(deepAssign));
console.log(results.join(" | "));
`;
    const { out, err, code } = await buildAndRun(entry);
    expect(err, `실행 실패:\n${err}`).toBe('');
    expect(out).toBe(
      [
        'longhand',
        'short',
        'longDefault',
        'declDefault',
        'deepDeclDefault',
        'arrDefault',
        'restDefault/extra/restArr',
        '{"literalValue":"lit"}',
        'computedDefault',
        '10|2',
        '8-3',
        '42',
      ].join(' | '),
    );
    // 객체 리터럴 shorthand 의 **key** 는 프로퍼티 이름이라 rename 되면 안 된다.
    expect(code).toContain('literalValue:');
  }, 120000);

  // ================================================================
  // #4515 — #4493 잔여 4건. 전부 main 에 있던 별개 루트커즈.
  // ================================================================

  test('#4515-1 assignment target 의 computed key 가 DCE 로 사라지지 않는다', async () => {
    // 루트커즈: semantic analyzer 가 패턴 프로퍼티의 computed key(`[k]`)를 **아예 방문하지
    // 않았다**. `k` 에 읽기 참조가 안 잡히니 DCE/const-inline 이 `const k` 를 지우는데,
    // codegen 은 key 를 원본 이름으로 내보낸다 → `ReferenceError: k is not defined`.
    // (object_property(일반 리터럴)는 computed key 를 방문하고 있었고 패턴만 빠져 있었다.)
    const entry = `
const k = "kk";
const d = 42;
const o = { kk: undefined };
let t;
({ [k]: t = d } = o);
console.log(t);
`;
    const { out, err } = await buildAndRun(entry);
    // 수정 전: `ReferenceError: k is not defined`
    expect(err, `실행 실패:\n${err}`).toBe('');
    expect(out).toBe('42');
  }, 120000);

  test('#4515-1 computed key — var/let/const/param/할당 전 형태', async () => {
    // 선언형(`let {[k]: t} = o`)도 같은 구멍이었다. let/const 는 predeclare 경로라
    // registerBinding 을 안 타고 visitBindingPatternExpressions 로 빠지는데 거기에도
    // computed key 방문이 없었다 — 세 walker 전부 막아야 한다.
    const entry = `
const k1 = "a", k2 = "b", k3 = "c", k4 = "d";
const o = { a: 1, b: 2, c: 3, d: 4 };
var { [k1]: v1 } = o;
let { [k2]: v2 } = o;
const { [k3]: v3 } = o;
let v4; ({ [k1]: v4 } = o);
function f({ [k4]: p }) { return p; }
console.log([v1, v2, v3, v4, f(o)].join(","));
`;
    const { out, err } = await buildAndRun(entry);
    expect(err, `실행 실패:\n${err}`).toBe('');
    expect(out).toBe('1,2,3,1,4');
  }, 120000);

  test('#4515-2 `{ undefined }` 객체 리터럴 shorthand 가 SyntaxError 가 되지 않는다', async () => {
    // shorthand 는 노드 하나가 키이자 값이라, 값 쪽 peephole(`undefined` → `void 0`)이 발동하면
    // 키 자리에 `void 0` 이 앉는다 → `{void 0}` → 번들 전체가 SyntaxError.
    // 처방: 치환이 걸리면 longhand(`undefined: void 0`)로 펼쳐 키를 원본 이름으로 고정.
    const entry = `
const o = { undefined };
console.log(Object.keys(o).join(",") + "|" + String(o.undefined));
`;
    const { out, err, code } = await buildAndRun(entry);
    // 수정 전: `SyntaxError: Unexpected token 'void'` (파싱조차 안 됨)
    expect(err, `실행 실패:\n${err}`).toBe('');
    expect(code).not.toContain('{void 0}');
    // 프로퍼티 이름은 반드시 `undefined` 로 보존돼야 한다.
    expect(out).toBe('undefined|undefined');
  }, 120000);

  test('#4515-3 CJS 래퍼의 exports/module 파라미터 재작성이 shorthand 를 커버한다', async () => {
    // __commonJS 래퍼는 `exports`/`module` 파라미터를 짧은 이름(`$e`/`$m`)으로 바꾸고 본문의
    // free 참조도 함께 재작성한다. 그런데 shorthand 자리는 원본 span 을 그대로 복사해서
    // 재작성이 통째로 누락됐다 — `({exports} = o)` 가 그대로 나가 **미선언 전역**에 대입되고
    // 진짜 `$e` 파라미터는 영영 대입되지 않는다 (무성 오염).
    //
    // #4493 이 넣었던 `identifierHasRename` 게이트는 rename 만 봐서 이 경로를 못 잡았다.
    const { dir, cleanup } = await createFixture({
      // .cjs → __commonJS 래퍼로 감싸진다. --minify 라야 파라미터가 실제로 mangle 된다.
      'dep.cjs': `
const src = { exports: 5 };
let viaDefault, viaShorthand, viaLiteral;
({ exports: viaDefault = 1 } = src);   // shorthand + 기본값
({ exports: viaShorthand } = src);     // longhand (대조군)
const held = { exports };              // 객체 리터럴 shorthand — 키는 "exports" 여야 한다
viaLiteral = Object.keys(held).join("");
// 진짜 exports 객체가 살아 있어야 한다 (위 대입들이 그걸 덮어쓰면 안 된다).
module.exports = {
  viaDefault,
  viaShorthand,
  viaLiteral,
  exportsIsObject: typeof held.exports === "object",
};
`,
      'entry.js': `
import d from "./dep.cjs";
console.log([d.viaDefault, d.viaShorthand, d.viaLiteral, d.exportsIsObject].join(","));
`,
    });
    try {
      const outFile = join(dir, 'bundle.mjs');
      const build = await runZntc([
        '--bundle',
        join(dir, 'entry.js'),
        '-o',
        outFile,
        '--minify',
        '--format=esm',
      ]);
      expect(build.exitCode, `빌드 실패:\n${build.stderr}`).toBe(0);
      const { out, err } = runNode(outFile);
      expect(err, `실행 실패:\n${err}`).toBe('');
      // 수정 전: `5,5,$e,true` — 객체 리터럴 키가 `$e` 로 오염됐다.
      expect(out).toBe('5,5,exports,true');
    } finally {
      await cleanup();
    }
  }, 120000);

  test('#4515-3 CJS shorthand 대입이 진짜 exports 파라미터에 꽂힌다', async () => {
    // 위 테스트의 반대편: 대입 대상이 재작성되지 않으면 `$e` 는 그대로고 미선언 전역만
    // 생긴다. 여기서는 exports 를 **직접** 덮어써 그 효과를 관측한다.
    const { dir, cleanup } = await createFixture({
      'dep.cjs': `
const src = { exports: { tag: "REWRITTEN" } };
({ exports } = src);
// 대입이 진짜 exports 파라미터에 꽂혔다면 이 모듈의 exports 는 위 객체가 된다.
`,
      'entry.js': `
import d from "./dep.cjs";
console.log(d && d.tag ? d.tag : "NOT_REWRITTEN");
`,
    });
    try {
      const outFile = join(dir, 'bundle.mjs');
      const build = await runZntc([
        '--bundle',
        join(dir, 'entry.js'),
        '-o',
        outFile,
        '--minify',
        '--format=esm',
      ]);
      expect(build.exitCode, `빌드 실패:\n${build.stderr}`).toBe(0);
      const { out, err } = runNode(outFile);
      expect(err, `실행 실패:\n${err}`).toBe('');
      // 수정 전: `NOT_REWRITTEN` (대입이 미선언 전역으로 샜다)
      expect(out).toBe('REWRITTEN');
    } finally {
      await cleanup();
    }
  }, 120000);

  test('#4515-4 `({[k] = 1} = o)` / `({"s" = 1} = o)` 는 SyntaxError', async () => {
    // CoverInitializedName 의 key 는 문법상 IdentifierReference 뿐이다. computed/string/numeric
    // 키는 대입할 바인딩 이름이 없어 어느 문맥에서도 valid 가 아니다 (V8 도 SyntaxError).
    // 수정 전: 파서가 조용히 수용하고 `({ [k]:[k] =1 } = o)` 같은 invalid JS 를 방출했다.
    for (const src of [
      'const k = "a"; const o = {}; ({ [k] = 1 } = o);',
      'const o = {}; ({ "s" = 1 } = o);',
      'const o = {}; ({ 1 = 1 } = o);',
    ]) {
      const { dir, cleanup } = await createFixture({ 'entry.js': src });
      try {
        const build = await runZntc([
          '--bundle',
          join(dir, 'entry.js'),
          '-o',
          join(dir, 'bundle.mjs'),
          '--format=esm',
        ]);
        expect(build.exitCode, `수용하면 안 된다: ${src}`).not.toBe(0);
      } finally {
        await cleanup();
      }
    }
  }, 120000);

  test('#4515 정상 shorthand 는 그대로 유지된다 (불필요한 longhand 확장 없음)', async () => {
    // 치환이 없으면 shorthand 를 유지해야 한다 — 무조건 펼치면 size 회귀다.
    const entry = `
export function f(o) {
  const { alpha, beta } = o;
  return alpha + beta;
}
console.log(f({ alpha: 1, beta: 2 }));
`;
    const { out, err, code } = await buildAndRun(entry);
    expect(err, `실행 실패:\n${err}`).toBe('');
    expect(out).toBe('3');
    // mangle 되면 `{alpha:a,beta:b}` 로 펼쳐지는 게 정상. 확장 자체는 rename 때문이지
    // 이번 수정 때문이 아니다 — `{undefined:` 같은 헛확장이 없는지만 본다.
    expect(code).not.toContain('undefined:');
  }, 120000);
});
