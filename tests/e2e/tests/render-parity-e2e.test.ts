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
 * ## 픽셀 비교가 "에러 0" 보다 강한 이유
 *
 * "에러가 없다" 는 침묵의 증거일 뿐이다. 기준 번들러와 **같은 픽셀** 이 나온다는 건
 * **번들러가 의미를 바꾸지 않았다**는 증거다. 무성 오컴파일은 이 층에서만 잡힌다.
 *
 * ## 결정론 (오탐 방지)
 *
 * 이 게이트가 flaky 하면 없느니만 못하다. 그래서:
 *   - **뷰포트를 앱 폭에 맞춘다.** 좁은 뷰포트로 넓은 앱을 찍으면 클리핑·리플로우로
 *     0px 이 아닌 차이가 나온다(실제로 개발 중 이 오탐을 밟았다).
 *   - 애니메이션 off · 고정 크기 · `deviceScaleFactor: 1` · 폰트는 monospace 고정.
 *   - 임계값은 `PIXEL_TOLERANCE` 하나로 모은다. 0 이 정상이며, 값을 올려야 한다면
 *     그건 결정론이 깨졌다는 신호지 임계값을 올릴 이유가 아니다.
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
   * **아직 열린 결함이라 현재는 실패가 정상**인 경우, 그 이슈 번호.
   *
   * `test.fail()` 로 표시한다 — 지금은 CI 를 red 로 만들지 않고, **결함이 고쳐지면
   * 테스트가 통과해버려서 오히려 실패**한다("expected to fail but passed"). 그때가
   * 이 마커를 떼는 시점이다. 게이트를 먼저 들이고 수정과 함께 해제하기 위한 장치이며,
   * 결함이 조용히 잊히지 않는다.
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
    knownBroken: '#4493',
    guards:
      '#4493 — 중첩 shorthand+기본값 리네임 누락(ReferenceError: stackWeight). ' +
      'import 만으로는 통과하고 new Chart() 를 **그려야** 터진다. 1~3층 전부 통과하는 결함.',
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
    knownBroken: '#4503',
    guards:
      '#4503 — dead-store 제거가 클로저 읽기를 놓쳐 대입문 삭제 → **무성 오컴파일**. ' +
      '에러 0 · 파싱 0 · 평가 0 인데 하이라이팅 결과만 틀리다(`functionfunction f f(a)`). ' +
      '이 게이트가 실제로 잡아낸 결함이며, **픽셀 대조 없이는 관측 자체가 불가능**하다. ' +
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
    await page.waitForTimeout(c.settleMs);
    const shot = await page.screenshot({ type: 'png' });
    return { shot, errors: [...new Set(errors)], missing: [...new Set(missing)], evaluated };
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

    // ── 4층: 실제 렌더 ───────────────────────────────────────────────
    const zColors = colorCount(z.shot);
    expect(zColors, `[4층] zntc 렌더가 사실상 백지다 (색 ${zColors}종)`).toBeGreaterThanOrEqual(
      c.minColors,
    );

    // 기준 번들러가 먼저 통과해야 비교가 의미 있다. 여기서 실패하면 zntc 가 아니라
    // 케이스/환경이 깨진 것이다.
    expect(v.errors, `기준(vite) 산출물이 실패했다 — 케이스 또는 환경 문제`).toEqual([]);
    expect(v.evaluated, `기준(vite) 산출물이 평가되지 않았다 — 케이스 또는 환경 문제`).toBe(true);

    // ── 4층: 기준 번들러와 픽셀 대조 (무성 오컴파일 탐지) ─────────────
    const zp = PNG.sync.read(z.shot);
    const vp = PNG.sync.read(v.shot);
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
      await test.info().attach(`${c.name}-zntc.png`, { body: z.shot, contentType: 'image/png' });
      await test.info().attach(`${c.name}-vite.png`, { body: v.shot, contentType: 'image/png' });
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
