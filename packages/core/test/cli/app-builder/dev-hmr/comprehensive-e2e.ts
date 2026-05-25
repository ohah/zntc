// 종합 E2E — PR #3779 부터 #3826 까지의 dev HMR 파이프라인을 한 dev server 인스턴스 안에서
// 시나리오 순서대로 검증. 개별 가드 test (dev-runtime-injected / outdir-custom / non-graph-reload
// / new-css-import / sourcemap-endpoint) 가 각 fix 의 단위 검증을 담당하지만, 본 케이스는
// *한 process 안에서 cold-start → JS edit incremental → graph change → HTML edit fallback* 의
// 흐름을 통째로 확인 — 시나리오 간 상태 전이 (latch / outdir owner / broadcast queue) 의 회귀
// 가드.

import {
  CLI,
  RUNTIME,
  describe,
  existsSync,
  expect,
  findFreePort,
  join,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  spawn,
  test,
  tmpdir,
  unlinkSync,
  waitForServer,
  writeFileSync,
} from '../helpers';

interface HmrMessage {
  type: string;
  modules?: Array<{ id: string; code: string }>;
}

/**
 * WebSocket 으로 `/__hmr` 에 연결한 뒤 `predicate` 가 true 를 반환할 때까지 메시지 수집.
 * connected 메시지는 자동 무시. 받은 메시지 전체를 `received` 로 반환해 시퀀스 검증에 사용.
 */
function listen(
  port: number,
  predicate: (msg: HmrMessage) => boolean,
  timeoutMs = 8000,
): Promise<{ result?: HmrMessage; received: HmrMessage[] }> {
  return new Promise((resolve) => {
    const received: HmrMessage[] = [];
    const ws = new WebSocket(`ws://localhost:${port}/__hmr`);
    const t = setTimeout(() => resolve({ received }), timeoutMs);
    ws.onmessage = (event) => {
      const msg = JSON.parse(String(event.data)) as HmrMessage;
      if (msg.type === 'connected') return;
      received.push(msg);
      if (predicate(msg)) {
        clearTimeout(t);
        ws.close();
        resolve({ result: msg, received });
      }
    };
    ws.onerror = () => {
      clearTimeout(t);
      resolve({ received });
    };
  });
}

async function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

describe('CLI: Vite-style app builder > dev HMR > 종합 E2E (#3779 → #3826)', () => {
  test('cold-start + JS incremental + graph change + HTML fallback 의 시퀀스', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-e2e-comprehensive-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<!doctype html><html><body><div id="root"></div><script type="module" src="/src/main.ts"></script></body></html>',
    );
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      'import { greet } from "./greet.ts";\ndocument.getElementById("root")!.textContent = greet("world");\n',
    );
    writeFileSync(
      join(dir, 'src', 'greet.ts'),
      'export function greet(name: string): string {\n  return `hello ${name}`;\n}\n',
    );

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);

    try {
      // ───── 시나리오 1: cold-start ─────
      // PR #3796/#3798 — watch.onReady 까지 HTTP listen wait. listening 시점에 outdir 채워진 상태.
      expect(existsSync(join(dir, '.zntc-dev', 'bundle.js'))).toBe(true);
      const httpStatus = await fetch(`http://localhost:${port}/bundle.js`).then((r) => r.status);
      expect(httpStatus).toBe(200);
      // PR #3793 — devMode auto-set 으로 HMR runtime token 주입
      const bundle = readFileSync(join(dir, '.zntc-dev', 'bundle.js'), 'utf8');
      expect(bundle).toContain('__esm');
      // PR #3795 — outdir mis-routing 없음 (cwd 의 root 에 누출 없음)
      expect(existsSync(join(dir, 'bundle.js'))).toBe(false);

      // ───── 시나리오 2: JS module 변경 → incremental Update sequence ─────
      // PR #3779 — broadcast 시퀀스. PR #3825 — multi-error root-cause (success 유지).
      // PR #3799 — sourceMappingURL append.
      const origGreet = readFileSync(join(dir, 'src', 'greet.ts'), 'utf8');
      const jsEditP = listen(port, (m) => m.type === 'update-done');
      await sleep(300);
      writeFileSync(join(dir, 'src', 'greet.ts'), origGreet.replace('hello', 'hi'));
      const { received: jsReceived, result: jsDone } = await jsEditP;
      expect(jsDone).toBeDefined();
      const jsTypes = jsReceived.map((m) => m.type);
      expect(jsTypes).toEqual(expect.arrayContaining(['update-start', 'update', 'update-done']));
      const updateMsg = jsReceived.find((m) => m.type === 'update');
      expect(updateMsg?.modules?.length ?? 0).toBeGreaterThan(0);
      expect(updateMsg!.modules![0].code.length).toBeGreaterThan(0);
      // PR #3799 — sourceMappingURL 주석 append
      expect(updateMsg!.modules![0].code).toMatch(/\/\/# sourceMappingURL=\/__zntc_hmr_map\//);
      // sourcemap endpoint route 응답 (200 또는 404 둘 다 valid — sourcemap enable 여부 dependent)
      const smId = updateMsg!.modules![0].id;
      const smResp = await fetch(
        `http://localhost:${port}/__zntc_hmr_map/${encodeURIComponent(smId)}`,
      );
      expect([200, 404]).toContain(smResp.status);

      // 원복
      writeFileSync(join(dir, 'src', 'greet.ts'), origGreet);
      await sleep(500);

      // ───── 시나리오 3: graph change (새 import) → FullReload 또는 Update ─────
      // PR #3779 broadcastRebuildEvent — graphChanged → FullReload. 단 native incremental
      // bundler 가 새 module path 를 항상 graphChanged=true 로 trigger 하지 않을 수 있음
      // (#3813 limitation) → update-done 도 acceptable.
      const origMain = readFileSync(join(dir, 'src', 'main.ts'), 'utf8');
      writeFileSync(join(dir, 'src', 'added.ts'), 'export const x = "new";\n');
      const graphP = listen(port, (m) => m.type === 'full-reload' || m.type === 'update-done');
      await sleep(300);
      writeFileSync(
        join(dir, 'src', 'main.ts'),
        `${origMain}\nimport { x } from "./added.ts";\nconsole.log(x);`,
      );
      const { result: graphResult } = await graphP;
      expect(['full-reload', 'update-done']).toContain(graphResult?.type);

      // 원복
      writeFileSync(join(dir, 'src', 'main.ts'), origMain);
      try {
        unlinkSync(join(dir, 'src', 'added.ts'));
      } catch {}
      await sleep(500);

      // ───── 시나리오 4: HTML 변경 → fallback FullReload (#3797 drain else) ─────
      const origHtml = readFileSync(join(dir, 'index.html'), 'utf8');
      const htmlP = listen(port, (m) => m.type === 'full-reload');
      await sleep(300);
      writeFileSync(
        join(dir, 'index.html'),
        origHtml.replace('<body>', '<body><meta name="v" content="2">'),
      );
      const { result: htmlResult } = await htmlP;
      expect(htmlResult?.type).toBe('full-reload');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
