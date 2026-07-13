import { test, expect } from '@playwright/test';
import { spawnSync } from 'node:child_process';
import { mkdtemp, rm, writeFile, mkdir } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { PNG } from 'pngjs';
import pixelmatch from 'pixelmatch';
import { serve, closeServer } from './serve';

/**
 * 렌더 패리티 게이트 — "빌드 green + 파싱 green" 을 통과하고도 **런타임에서만** 죽는
 * 결함, 그리고 **에러 없이 결과만 다른** 무성 오컴파일을 잡는다.
 *
 * ## 왜 필요한가 (기존 게이트로는 못 잡는 것)
 *
 * 번들러 결함은 네 층에 걸쳐 있고, **위 층 통과가 아래 층을 보장하지 않는다.**
 *
 *   1층 빌드 exit code       — #4472·#4481·#4482·#4491·#4492·#4493 전부 exit 0 으로 통과했다.
 *   2층 산출물 재파싱         — `tests/integration/tests/output-parsable.test.ts` (#4472·#4481·#4482).
 *   3층 모듈 평가            — 문법은 유효한데 평가 중 죽는다. 2층은 통과한다.
 *                              예: #4491 `TypeError: $m is not a function` (highlight.js),
 *                                  #4492 크로스-모듈 바인딩 미링크 (mermaid).
 *   4층 렌더 + 기준 대조      — 평가까지 통과하고 **API 를 실제로 호출해야** 죽는다.
 *                              예: #4493 `ReferenceError: stackWeight is not defined` (chart.js).
 *                                  `import * as X from "chart.js"` 는 성공한다. `new Chart()` 를
 *                                  **그려봐야** 터진다. 1~3층 전부 통과한다.
 *
 * 이 파일이 3층·4층을 담당한다.
 *
 * ## 기존 browser-smoke 와 다른 점
 *
 * `browser-smoke.test.ts` 는 `--bundle`(단일 파일·minify 없음·스플리팅 없음) 로 작은 스니펫의
 * console 출력을 본다. 위 결함들은 **app 빌드 + `--minify` + 코드 스플리팅** 경로에 살기 때문에
 * 그 경로를 밟지 않는다. (highlight.js 케이스도 `lib/core` 서브셋이라 #4491 을 유발하는
 * 190개 CJS 언어 모듈 경로를 비껴간다.)
 *
 * 여기서는 **`zntc build --entry-html … --minify`** 로 짓고, **실제로 렌더**한 뒤
 * **기준 번들러(Vite) 산출물과 픽셀을 비교**한다.
 *
 * ## 기준 번들러 대조가 "에러 0" 보다 강한 이유
 *
 * "에러가 없다" 는 침묵의 증거일 뿐이다. 기준 번들러(Vite)와 **같은 결과**가 나온다는 건
 * **번들러가 의미를 바꾸지 않았다**는 증거다. 무성 오컴파일은 이 층에서만 잡힌다.
 *
 * 대조 방식은 케이스마다 둘 중 하나다.
 *   - **픽셀** — 시각적 라이브러리(react-dom · chart.js · d3 · highlight.js).
 *   - **의미**(`semantic`) — 자체 레이아웃 엔진을 가진 무거운 컴포넌트(monaco). 토크나이저
 *     출력 · diff 계산 결과 · 진단 메시지를 문자열로 정확 대조한다. 무성 오컴파일에는
 *     픽셀보다 오히려 **더 예민하다** (#4503 도 결국 DOM 문자열 대조로 정체가 드러났다).
 *
 * ## 결정론 (오탐 방지) — 개발 중 실제로 밟은 함정들
 *
 * **flaky 한 게이트는 없느니만 못하다.** 그래서 아래를 코드에 못박았다.
 *
 *   - **뷰포트를 앱 폭에 맞춘다.** 좁은 뷰포트로 넓은 앱을 찍으면 클리핑으로 0px 이 아닌
 *     차이가 나온다 → 케이스마다 `width`/`height` 명시.
 *   - **`waitForFunction(fn, arg, options)`** — 두 번째 인자는 `arg` 다. `{timeout}` 을 거기
 *     넘기면 무제한 대기가 되어 실패 케이스가 테스트 예산을 통째로 태운다(10분을 태웠다)
 *     → `EVAL_TIMEOUT_MS` 명시.
 *   - **`stableScreenshot`** — 고정 sleep 은 부하에 취약하다. 연속 두 장이 바이트 동일할
 *     때까지 기다린다. `animations: 'disabled'` · `caret: 'hide'` 도 함께.
 *   - **픽셀이 안 맞는 컴포넌트는 픽셀로 재지 않는다.** monaco 는 CI 병렬 부하에서 픽셀이
 *     2/8 로 흔들렸다(단독 실행은 8/8 이 0px). **임계값을 올려 덮는 대신** 의미 대조로 바꿨고,
 *     workers=4 부하에서 8/8 안정을 확인했다.
 *   - 임계값 `PIXEL_TOLERANCE` 는 **0 이 정상**이다. 값을 올려야 한다면 그건 결정론이 깨졌다는
 *     신호지 임계값을 올릴 이유가 아니다.
 */

const REPO_ROOT = resolve(__dirname, '../../..');
const ZNTC_CLI = join(REPO_ROOT, 'packages/core/bin/zntc.mjs');
const VITE_BIN = resolve(__dirname, '../node_modules/vite/bin/vite.js');

/** 픽셀 차이 허용치(전체 대비 %). 0 이 정상. */
const PIXEL_TOLERANCE = 0.1;

/**
 * 3층(모듈 평가) 대기 상한.
 *
 * **반드시 명시해야 한다.** Playwright 러너에서 액션 기본 타임아웃은 테스트 타임아웃에
 * 종속되므로, 여기서 상한을 주지 않으면 **평가에 실패한 케이스가 테스트 예산을 통째로
 * 소진**한다(개발 중 실제로 10분을 태웠다). 3층 실패는 **빨리** 실패해야 한다.
 */
const EVAL_TIMEOUT_MS = 15_000;

interface RenderCase {
  name: string;
  /** npm install 인자. */
  pkg: string;
  /** 렌더 앱 소스. `globalThis.__ready = true` 로 완료를 알린다. */
  entry: string;
  /** 앱 폭·높이. **뷰포트가 여기에 맞춰진다** — 어긋나면 클리핑 오탐. */
  width: number;
  height: number;
  /** 렌더 완료 대기(ms). 워커·워밍업이 필요한 케이스는 넉넉히. */
  settleMs: number;
  /** 렌더 결과가 비어 있지 않은지 보는 최소 조건(고유 색 수). */
  minColors: number;
  /**
   * 이 케이스가 과거에 잡은 결함. 회귀 시 어디를 볼지 남긴다.
   */
  guards: string;
  /**
   * **픽셀 대신 "계산 결과"를 대조하는 케이스.** 페이지 안에서 평가돼 문자열을 돌려주는
   * 코드이며, zntc/vite 산출물의 반환값을 **정확히** 비교한다.
   *
   * 왜 필요한가: 픽셀 대조는 시각적 라이브러리엔 훌륭하지만, **자체 레이아웃 엔진을 가진
   * 무거운 컴포넌트**(monaco 등)에는 부적합하다. 내부 렌더 경합 때문에 부하가 걸리면 안정된
   * 상태가 두 갈래로 갈려 flaky 해진다(실제로 monaco 가 CI 병렬 부하에서 2/8 로 흔들렸다 —
   * 단독 실행에선 8/8 이 0px 였다).
   *
   * **임계값을 올려 덮는 것은 금지다.** 그건 게이트가 잡아야 할 진짜 차이까지 눈감는 짓이다.
   * 대신 그런 케이스는 **의미(계산 결과)를 본다** — 토크나이저 출력·diff 계산 결과·진단 메시지처럼
   * 번들러가 의미를 바꿨다면 반드시 달라지는 값들이다. 무성 오컴파일에는 픽셀보다 오히려 더 예민하다
   * (#4503 도 결국 DOM 문자열 대조로 정체가 드러났다).
   *
   * 이 값이 있으면 픽셀 대조는 건너뛴다.
   */
  semantic?: string;
  /**
   * **아직 열린 결함이라 현재는 실패가 정상**인 경우, 그 이슈 번호.
   *
   * `test.fail()` 로 표시한다 — CI 를 red 로 만들지 않되, **결함이 고쳐지면 테스트가
   * 통과해버려서 오히려 실패**한다("expected to fail but passed"). 그때가 이 마커를
   * 떼는 시점이다. 게이트를 먼저 들이고 수정과 함께 해제하기 위한 장치이며, 결함이
   * 조용히 잊히지 않는다.
   *
   * 실제로 이 장치가 동작했다 — #4493·#4503 이 수정되자 두 케이스가 통과해버려 CI 가
   * 알려줬고, 그래서 마커를 뗐다. 새 결함을 게이트에 먼저 들일 때 다시 쓴다.
   */
  knownBroken?: string;
}

const cases: RenderCase[] = [
  {
    name: 'react-dom',
    pkg: 'react@^19 react-dom@^19',
    width: 400,
    height: 260,
    settleMs: 400,
    minColors: 10,
    guards: 'sanity — DOM 렌더 경로',
    entry: `
import React from "react";
import { createRoot } from "react-dom/client";
const Row = ({ i }) =>
  React.createElement("div", { style: { padding: "4px 8px", background: i % 2 ? "#eef" : "#dfd", fontFamily: "monospace", fontSize: 14 } }, "row " + i + " — " + i * i);
const App = () =>
  React.createElement("div", { style: { width: 380 } }, [
    React.createElement("h2", { key: "h", style: { fontFamily: "monospace" } }, "React"),
    ...Array.from({ length: 8 }, (_, i) => React.createElement(Row, { key: i, i })),
  ]);
createRoot(document.getElementById("root")).render(React.createElement(App));
setTimeout(() => { globalThis.__ready = true; }, 200);
`,
  },
  {
    name: 'chart.js',
    pkg: 'chart.js@^4',
    width: 400,
    height: 260,
    settleMs: 700,
    minColors: 20,
    guards:
      '#4493(수정됨) — 중첩 shorthand+기본값 리네임 누락(ReferenceError: stackWeight). ' +
      'import 만으로는 통과하고 new Chart() 를 **그려야** 터졌다. 1~3층 전부 통과하던 결함이라, ' +
      '이 케이스가 회귀를 막는 유일한 그물이다.',
    entry: `
import { Chart, BarController, BarElement, CategoryScale, LinearScale } from "chart.js";
Chart.register(BarController, BarElement, CategoryScale, LinearScale);
const c = document.createElement("canvas");
c.width = 380; c.height = 220;
document.getElementById("root").appendChild(c);
new Chart(c, {
  type: "bar",
  data: { labels: ["a","b","c","d","e"], datasets: [{ label: "v", data: [12,19,7,15,9], backgroundColor: "#36a" }] },
  options: { animation: false, responsive: false, plugins: { legend: { display: false } } },
});
setTimeout(() => { globalThis.__ready = true; }, 400);
`,
  },
  {
    name: 'highlight.js',
    pkg: 'highlight.js@^11 marked@^18',
    width: 400,
    height: 260,
    settleMs: 500,
    minColors: 10,
    guards:
      '#4503(수정됨) — dead-store 제거가 클로저 읽기를 놓쳐 대입문 삭제 → **무성 오컴파일**. ' +
      '에러 0 · 파싱 0 · 평가 0 인데 하이라이팅 결과만 틀렸다(`functionfunction f f(a)`). ' +
      '**이 게이트가 실제로 찾아낸 결함**이며, 픽셀 대조 없이는 관측 자체가 불가능했다. ' +
      '더불어 #4491(CJS 래퍼 $e/$m 섀도잉)도 이 경로가 지킨다. ' +
      '**full `highlight.js` 를 써야 한다** — `lib/core` 서브셋은 190개 CJS 언어 모듈 경로를 비껴가서 둘 다 못 잡는다.',
    entry: `
import { marked } from "marked";
import hljs from "highlight.js";
const md = "# Title\\n\\nSome **bold** text.\\n\\n\\\`\\\`\\\`js\\nconst x = 1;\\nfunction f(a) { return a + x; }\\n\\\`\\\`\\\`\\n";
const el = document.getElementById("root");
el.innerHTML = marked.parse(md);
el.style.width = "380px";
el.style.fontFamily = "monospace";
el.querySelectorAll("pre code").forEach((b) => {
  b.innerHTML = hljs.highlight(b.textContent, { language: "javascript" }).value;
});
setTimeout(() => { globalThis.__ready = true; }, 300);
`,
  },
  {
    name: 'd3',
    pkg: 'd3@^7',
    width: 400,
    height: 260,
    settleMs: 500,
    minColors: 10,
    guards:
      '#4482 — 단항 토큰 병합(d3-ease 의 `tpmt(-(--t))` → `---t`). ' +
      'scaleTime().ticks() 로 d3-time 바인딩(크로스-모듈) 경로도 함께 밟는다.',
    entry: `
import * as d3 from "d3";
const svg = d3.select("#root").append("svg").attr("width", 380).attr("height", 220);
const t = d3.scaleTime()
  .domain([new Date(Date.UTC(2020, 0, 1, 0, 0, 0)), new Date(Date.UTC(2020, 0, 1, 0, 1, 0))])
  .range([30, 350]);
svg.append("g").attr("transform", "translate(0,180)").call(d3.axisBottom(t).ticks(5));
const y = d3.scaleLinear().domain([0, 10]).range([170, 20]);
svg.selectAll("rect").data([3, 7, 2, 9, 5]).enter().append("rect")
  .attr("x", (d, i) => 40 + i * 64).attr("y", (d) => y(d))
  .attr("width", 44).attr("height", (d) => 170 - y(d)).attr("fill", "#a33");
setTimeout(() => { globalThis.__ready = true; }, 300);
`,
  },
  {
    name: 'codemirror',
    pkg: 'codemirror@^6 @codemirror/lang-javascript@^6',
    width: 400,
    height: 260,
    settleMs: 700,
    minColors: 30,
    guards: '#4481 — `if(c) ({…}=o)` → `c&&{…}=o` (`&&` 폴딩 시 필수 괄호 소실).',
    entry: `
import { EditorView, basicSetup } from "codemirror";
import { javascript } from "@codemirror/lang-javascript";
new EditorView({
  doc: "function hello(name) {\\n  const greeting = \\\`hi \\\${name}\\\`;\\n  return greeting.toUpperCase();\\n}\\n",
  extensions: [basicSetup, javascript()],
  parent: document.getElementById("root"),
});
setTimeout(() => { globalThis.__ready = true; }, 500);
`,
  },
  {
    // Monaco 는 이 게이트의 **최대 커버리지 케이스**다 — 다른 어떤 케이스도 동시에
    // 밟지 못하는 표면을 한 번에 지난다:
    //   · 코드 스플리팅 (청크 100+개)
    //   · 모듈 워커 5종 (editor/ts/json/css/html) — `new Worker(new URL(…, import.meta.url))`
    //   · CSS `url()` 자산 (codicon 폰트)  ← #4466
    //   · CJS interop (번들된 TypeScript 컴파일러)  ← #4472·#4481
    // 실제로 #4466·#4472·#4481·#4483 이 전부 monaco 번들에서 처음 드러났다.
    name: 'monaco',
    pkg: 'monaco-editor@^0.55',
    width: 900,
    height: 300,
    settleMs: 800,
    minColors: 100,
    guards:
      '#4472·#4481(코드젠 괄호) · #4483(new URL 워커 지정자) · #4466(CSS url 자산=codicon) · #4503(무성 오컴파일). ' +
      '워커·스플리팅·자산·CJS interop 을 한 케이스로 덮는다. ' +
      '**픽셀이 아니라 의미로 본다**(아래 semantic) — monaco 는 자체 레이아웃 엔진 때문에 CI 병렬 부하에서 ' +
      '픽셀이 흔들린다(2/8 flake, 단독 실행에선 8/8 이 0px). 임계값을 올려 덮는 대신 계산 결과를 대조한다.',
    // 토크나이저 출력 · diff 계산 결과 · TS 진단 — 번들러가 의미를 바꿨다면 반드시 달라지는 값들.
    semantic: `async () => {
  const m = window.monaco;
  const SAMPLES = {
    javascript: 'const a = 1;\\nfunction f(x) { return "v" + x; }\\nclass K { #p = 2; get v(){ return this.#p } }\\n',
    typescript: 'interface I<T> { x: T }\\nenum E { A = 1, B }\\n',
    json: '{"a":1,"b":[true,null,"s"],"c":{"d":1.5e3}}',
    css: '.a { color: #f00; } @media (min-width: 10px) { .b::after { content: "x" } }',
    html: '<div class="a"><!-- c --><span>t</span></div>',
    python: 'def f(a, *args, **kw):\\n    return [x for x in args if x]\\n',
    rust: 'fn main() { let v: Vec<i32> = vec![1,2]; match v.first() { Some(&x) => {}, None => {} } }',
    go: 'func main() { ch := make(chan int, 1); go func(){ ch <- 1 }() }',
    java: 'public class A { private static final int X = 1; }',
    cpp: 'template<typename T> T add(T a, T b) { return a + b; }',
    sql: 'SELECT a.id, COUNT(*) FROM t a WHERE a.x > 1 GROUP BY a.id;',
    yaml: 'a: 1\\nb:\\n  - x\\n',
    markdown: '# H\\n\\n**b** _i_\\n',
    shell: 'for f in *.txt; do echo "x"; done',
    xml: '<?xml version="1.0"?><r a="1"><c/></r>',
    php: '<?php function f(int $a): string { return "v"; } ?>',
  };
  const out = { colorize: {} };
  // ① Monarch 토크나이저: 언어별 구문강조 결과 HTML
  for (const [lang, src] of Object.entries(SAMPLES)) {
    try { out.colorize[lang] = await m.editor.colorize(src, lang, {}); }
    catch (e) { out.colorize[lang] = 'ERR:' + String(e).slice(0, 60); }
  }
  // ② editor.worker 의 diff 계산 결과
  const o = m.editor.createModel('a\\nb\\nc\\nd\\ne\\n', 'plaintext');
  const n = m.editor.createModel('a\\nX\\nc\\nd\\nY\\nZ\\n', 'plaintext');
  const h = document.createElement('div'); h.style.cssText = 'width:600px;height:200px'; document.body.appendChild(h);
  const de2 = m.editor.createDiffEditor(h, { automaticLayout: false });
  de2.setModel({ original: o, modified: n });
  for (let i = 0; i < 60; i++) { if (de2.getLineChanges()) break; await new Promise((r) => setTimeout(r, 100)); }
  out.diff = JSON.stringify(de2.getLineChanges());
  // ③ ts.worker 의 진단 결과
  const bad = m.editor.createModel('const q: number = 1;\\nq.nope();\\n', 'javascript');
  m.editor.create(document.createElement('div'), { model: bad });
  let mk = [];
  for (let i = 0; i < 60; i++) {
    mk = m.editor.getModelMarkers({ resource: bad.uri });
    if (mk.length) break;
    await new Promise((r) => setTimeout(r, 100));
  }
  out.markers = JSON.stringify(mk.map((k) => [k.startLineNumber, k.startColumn, String(k.message)]).sort());
  return JSON.stringify(out);
}`,
    entry: `
import * as monaco from "monaco-editor";
self.MonacoEnvironment = {
  getWorker(_, label) {
    if (label === "typescript" || label === "javascript")
      return new Worker(new URL("monaco-editor/esm/vs/language/typescript/ts.worker.js", import.meta.url), { type: "module" });
    if (label === "json")
      return new Worker(new URL("monaco-editor/esm/vs/language/json/json.worker.js", import.meta.url), { type: "module" });
    if (label === "css" || label === "scss" || label === "less")
      return new Worker(new URL("monaco-editor/esm/vs/language/css/css.worker.js", import.meta.url), { type: "module" });
    if (label === "html" || label === "handlebars" || label === "razor")
      return new Worker(new URL("monaco-editor/esm/vs/language/html/html.worker.js", import.meta.url), { type: "module" });
    return new Worker(new URL("monaco-editor/esm/vs/editor/editor.worker.js", import.meta.url), { type: "module" });
  },
};
// 샘플에 백틱/템플릿리터럴을 쓰지 않는다 — 이 파일 자체가 템플릿 리터럴이라 이스케이프가 겹친다.
const ORIG = 'function greet(name) {\\n  const msg = "hello " + name;\\n  return msg;\\n}\\n';
const MOD  = 'function greet(name, punct = "!") {\\n  const msg = "hello " + name + punct;\\n  return msg.toUpperCase();\\n}\\n';

// Monaco 는 컨테이너에 **명시적 높이**가 없으면 접힌다(공통 index.html 은 높이를 주지 않는다).
const root = document.getElementById("root");
root.style.width = "880px";
root.style.height = "270px";

// **비결정적 요소를 끈다.** 오버뷰 룰러는 editor.worker 의 diff 계산이 끝나야 그려지는데,
// 그 페인트 타이밍이 스크린샷과 경합해 flaky 를 만든다(임계값을 올려 덮지 않고 원인을 없앤다).
// 미니맵·스크롤바도 같은 이유로 끈다. 검사 대상(라인/문자 diff·구문강조·codicon)은 그대로 남는다.
const de = monaco.editor.createDiffEditor(root, {
  automaticLayout: false, renderSideBySide: false, fontSize: 12,
  minimap: { enabled: false }, scrollBeyondLastLine: false, theme: "vs",
  renderOverviewRuler: false, overviewRulerLanes: 0,
  scrollbar: { vertical: "hidden", horizontal: "hidden", verticalScrollbarSize: 0, horizontalScrollbarSize: 0 },
  // 커서 깜빡임은 시간에 따라 픽셀이 변한다 — 스크린샷 위상이 어긋나면 간헐 차이가 난다.
  cursorBlinking: "solid", renderLineHighlight: "none",
});
de.setModel({
  original: monaco.editor.createModel(ORIG, "javascript"),
  modified: monaco.editor.createModel(MOD, "javascript"),
});

// semantic 프로브가 페이지 안에서 monaco API 를 부른다 — 노출해 둔다.
window.monaco = monaco;

// **고정 sleep 금지.** diff 는 editor.worker 가 비동기로 계산한다. 데코레이션이 실제로
// DOM 에 나타난 뒤에 __ready 를 세워야 스크린샷이 결정론적이다.
(async () => {
  for (let i = 0; i < 150; i++) {
    if (document.querySelectorAll(".line-insert, .line-delete, .char-insert, .char-delete").length > 0) break;
    await new Promise((r) => setTimeout(r, 100));
  }
  await new Promise((r) => setTimeout(r, 500)); // 오버뷰 룰러 페인트 여유
  globalThis.__ready = true;
})();
`,
  },
];

/** 앱 fixture 를 만들고 zntc / vite 두 벌로 빌드한다. */
async function buildBoth(caseDir: string, c: RenderCase) {
  await mkdir(join(caseDir, 'src'), { recursive: true });
  await writeFile(
    join(caseDir, 'package.json'),
    JSON.stringify({ name: `rp-${c.name}`, private: true, type: 'module' }),
  );

  const install = spawnSync('npm', ['install', ...c.pkg.split(/\s+/), '--no-audit', '--no-fund'], {
    cwd: caseDir,
    stdio: 'pipe',
    timeout: 180_000,
  });
  expect(
    install.status,
    `npm install ${c.pkg} 실패: ${install.stderr?.toString().slice(0, 300)}`,
  ).toBe(0);

  await writeFile(join(caseDir, 'src/main.js'), c.entry.trim() + '\n');
  await writeFile(
    join(caseDir, 'index.html'),
    `<!DOCTYPE html><html><head><meta charset="utf-8"><style>` +
      `*{margin:0;padding:0;animation:none!important;transition:none!important}` +
      `body{background:#fff;width:${c.width}px;font-family:monospace}` +
      `#root{padding:8px}` +
      `</style></head><body><div id="root"></div>` +
      `<script type="module" src="/src/main.js"></script></body></html>\n`,
  );

  // ── zntc: app 빌드 + minify (결함이 사는 경로)
  const z = spawnSync(
    'node',
    [ZNTC_CLI, 'build', '.', '--entry-html', 'index.html', '--outdir', 'out-zntc', '--minify'],
    { cwd: caseDir, stdio: 'pipe', timeout: 300_000 },
  );
  expect(z.status, `zntc build 실패: ${z.stderr?.toString().slice(0, 400)}`).toBe(0);

  // ── vite: 기준 번들러
  await writeFile(
    join(caseDir, 'vite.config.js'),
    `export default { root: ".", build: { outDir: "out-vite", emptyOutDir: true, rollupOptions: { input: "index.html" } }, logLevel: "error" };\n`,
  );
  const v = spawnSync('node', [VITE_BIN, 'build', '--config', 'vite.config.js'], {
    cwd: caseDir,
    stdio: 'pipe',
    timeout: 300_000,
  });
  expect(v.status, `vite build 실패(기준 번들러): ${v.stderr?.toString().slice(0, 400)}`).toBe(0);
}

/**
 * **화면이 안정될 때까지 기다렸다가** 찍는다 — 연속 두 장이 바이트 동일해야 확정.
 *
 * 왜 필요한가: 고정 sleep 은 **부하에 취약하다**. CI 는 테스트를 병렬로 돌리므로 CPU 경합이
 * 생기고, 그러면 페인트가 덜 끝난 상태로 찍혀 간헐적 픽셀 차이가 난다(개발 중 monaco 케이스가
 * 부하 하에서만 275px 로 흔들렸다 — 단독 실행에선 8/8 이 0px 였다).
 *
 * 이걸 **임계값을 올려서 덮으면 안 된다.** 그건 게이트가 잡아야 할 진짜 차이까지 같이
 * 눈감는 짓이다. 원인(페인트 미완)을 없앤다.
 *
 * `animations: 'disabled'` — CSS 애니메이션/트랜지션을 끝 상태로 고정.
 * `caret: 'hide'` — 텍스트 캐럿은 깜빡여서 시간에 따라 픽셀이 변한다.
 */
async function stableScreenshot(page: import('@playwright/test').Page): Promise<Buffer> {
  const opts = { type: 'png', animations: 'disabled', caret: 'hide' } as const;
  let prev = await page.screenshot(opts);
  for (let i = 0; i < 12; i++) {
    await page.waitForTimeout(250);
    const next = await page.screenshot(opts);
    if (next.equals(prev)) return next;
    prev = next;
  }
  // 3초를 기다려도 안 굳으면 페이지 자체가 비결정적이다 — 케이스를 고쳐야 한다.
  throw new Error(
    '렌더가 안정되지 않는다(연속 스크린샷이 계속 달라짐). 케이스에 시간 의존 요소가 남아 있다 — ' +
      '커서 깜빡임 · 애니메이션 · 오버뷰 룰러 같은 비결정 요소를 끄거나, 완료 조건을 __ready 에 넣어라.',
  );
}

/** 산출물을 띄워 렌더하고 스크린샷 + 진단을 돌려준다. */
async function render(page: import('@playwright/test').Page, dir: string, c: RenderCase) {
  const { server, port } = await serve(dir);
  const errors: string[] = [];
  const missing: string[] = [];
  page.on('pageerror', (e) => errors.push(e.message.split('\n')[0]));
  page.on('response', (r) => {
    if (r.status() === 404 && !r.url().endsWith('/favicon.ico'))
      missing.push(new URL(r.url()).pathname);
  });
  try {
    // 뷰포트 = 앱 폭. 어긋나면 클리핑으로 픽셀 오탐이 난다.
    await page.setViewportSize({ width: c.width, height: c.height });
    await page.goto(`http://localhost:${port}/`, { waitUntil: 'networkidle' });
    // 3층: 엔트리 모듈이 **끝까지** 평가됐는가.
    // 시그니처 주의: waitForFunction(fn, arg, options) — 두 번째 인자는 `arg` 다.
    // `waitForFunction(fn, { timeout })` 로 쓰면 timeout 이 arg 로 먹혀 기본 타임아웃이
    // 적용된다(실제로 이 함정을 밟았다). 반드시 arg 자리에 undefined 를 넣는다.
    const evaluated = await page
      .waitForFunction(() => (globalThis as Record<string, unknown>).__ready === true, undefined, {
        timeout: EVAL_TIMEOUT_MS,
      })
      .then(() => true)
      .catch(() => false);
    // 폰트가 로드되기 전에 찍으면 글리프가 폴백 폰트로 그려져 차이가 난다(codicon 등).
    await page.evaluate(() => document.fonts.ready).catch(() => {});
    await page.waitForTimeout(c.settleMs);

    // 의미 대조 케이스는 픽셀을 찍지 않는다(그 이유는 RenderCase.semantic 주석 참고).
    if (c.semantic) {
      const semantic = await page
        .evaluate(`(${c.semantic})()`)
        .catch((e) => 'PROBE-ERR:' + String(e).slice(0, 120));
      return {
        shot: null,
        semantic,
        errors: [...new Set(errors)],
        missing: [...new Set(missing)],
        evaluated,
      };
    }

    const shot = await stableScreenshot(page);
    return {
      shot,
      semantic: null,
      errors: [...new Set(errors)],
      missing: [...new Set(missing)],
      evaluated,
    };
  } finally {
    await closeServer(server);
  }
}

/** 스크린샷의 고유 색 수 — 백지 렌더 탐지용. */
function colorCount(buf: Buffer): number {
  const p = PNG.sync.read(buf);
  const seen = new Set<number>();
  for (let i = 0; i < p.data.length; i += 4) {
    seen.add((p.data[i] << 16) | (p.data[i + 1] << 8) | p.data[i + 2]);
  }
  return seen.size;
}

let fixtureRoot: string;

test.beforeAll(async () => {
  fixtureRoot = await mkdtemp(join(tmpdir(), 'zntc-render-parity-'));
  // 기준 번들러가 없으면 4층 자체가 성립하지 않는다 — 조용히 skip 하지 말고 크게 실패시킨다.
  expect(
    () => readFileSync(VITE_BIN),
    'vite(기준 번들러)가 tests/e2e devDependency 에 있어야 한다',
  ).not.toThrow();
});

test.afterAll(async () => {
  await rm(fixtureRoot, { recursive: true, force: true });
});

for (const c of cases) {
  test(`render-parity: ${c.name}`, async ({ page }) => {
    // 케이스마다 npm install + zntc/vite 두 번 빌드 + 두 번 렌더다. 기본 30s 로는
    // 큰 라이브러리(chart.js·codemirror)가 설치 단계에서 넘긴다. `test.slow()`(3배)
    // 로도 부족해 명시 timeout 을 준다 — 여기서 타임아웃이 나면 결함이 아니라
    // 환경 문제이므로, 애매한 실패로 신뢰를 깎지 않도록 넉넉히 잡는다.
    test.setTimeout(4 * 60_000);

    if (c.knownBroken) {
      // 아직 열린 결함이다. 지금은 실패가 **정상** — CI 를 red 로 만들지 않는다.
      // 결함이 고쳐지면 이 테스트가 통과해버려 "expected to fail but passed" 로 실패하고,
      // 그게 이 마커를 떼라는 신호다.
      test.fail(
        true,
        `${c.knownBroken} 이 열려 있는 동안은 실패가 정상이다. 수정되면 이 마커를 제거할 것.`,
      );
    }

    const caseDir = join(fixtureRoot, c.name.replace(/[^\w.-]/g, '_'));
    await buildBoth(caseDir, c);

    const z = await render(page, join(caseDir, 'out-zntc'), c);
    const v = await render(page, join(caseDir, 'out-vite'), c);

    // ── 3층: 모듈 평가 ───────────────────────────────────────────────
    expect(z.errors, `[3층] zntc 산출물이 런타임 에러를 냈다 (${c.guards})`).toEqual([]);
    expect(z.missing, `[3층] zntc 산출물이 참조하는 자산이 404 다`).toEqual([]);
    expect(
      z.evaluated,
      `[3층] 엔트리 모듈이 끝까지 평가되지 않았다 — globalThis.__ready 미도달 (${c.guards})`,
    ).toBe(true);

    // 기준 번들러가 먼저 통과해야 비교가 의미 있다. 여기서 실패하면 zntc 가 아니라
    // 케이스/환경이 깨진 것이다.
    expect(v.errors, `기준(vite) 산출물이 실패했다 — 케이스 또는 환경 문제`).toEqual([]);
    expect(v.evaluated, `기준(vite) 산출물이 평가되지 않았다 — 케이스 또는 환경 문제`).toBe(true);

    // ── 4층(a): 의미 대조 — 픽셀이 부적합한 케이스(monaco 등) ─────────
    if (c.semantic) {
      expect(
        String(z.semantic).startsWith('PROBE-ERR:'),
        `[4층] zntc 의미 프로브 실패: ${z.semantic}`,
      ).toBe(false);
      expect(
        String(v.semantic).startsWith('PROBE-ERR:'),
        `기준(vite) 의미 프로브 실패 — 케이스/환경 문제: ${v.semantic}`,
      ).toBe(false);
      expect(
        z.semantic,
        `[4층] 기준 번들러(vite)와 **계산 결과가 다르다**. ` +
          `에러 없이 결과만 다르면 **무성 오컴파일**이다 — 번들러가 의미를 바꿨다. (${c.guards})`,
      ).toEqual(v.semantic);
      return;
    }

    // ── 4층(b): 실제 렌더 + 픽셀 대조 ────────────────────────────────
    const zColors = colorCount(z.shot!);
    expect(zColors, `[4층] zntc 렌더가 사실상 백지다 (색 ${zColors}종)`).toBeGreaterThanOrEqual(
      c.minColors,
    );

    const zp = PNG.sync.read(z.shot!);
    const vp = PNG.sync.read(v.shot!);
    expect({ w: zp.width, h: zp.height }, '스크린샷 크기가 다르다 — 뷰포트 설정 확인').toEqual({
      w: vp.width,
      h: vp.height,
    });

    const diffPng = new PNG({ width: zp.width, height: zp.height });
    const diffPixels = pixelmatch(zp.data, vp.data, diffPng.data, zp.width, zp.height, {
      threshold: 0.12,
    });
    const diffPct = (diffPixels / (zp.width * zp.height)) * 100;

    if (diffPct > PIXEL_TOLERANCE) {
      await test.info().attach(`${c.name}-zntc.png`, { body: z.shot!, contentType: 'image/png' });
      await test.info().attach(`${c.name}-vite.png`, { body: v.shot!, contentType: 'image/png' });
      await test
        .info()
        .attach(`${c.name}-diff.png`, { body: PNG.sync.write(diffPng), contentType: 'image/png' });
    }
    expect(
      diffPct,
      `[4층] 기준 번들러(vite)와 렌더가 다르다 — ${diffPixels}px (${diffPct.toFixed(3)}%). ` +
        `**에러 없이 결과만 다르면 무성 오컴파일이다.** 첨부된 zntc/vite/diff 이미지를 볼 것. (${c.guards})`,
    ).toBeLessThanOrEqual(PIXEL_TOLERANCE);
  });
}
