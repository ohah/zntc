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
import { waitForHmrBroadcast } from './hmr-wait';

interface UpdateModule {
  id: string;
  code: string;
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
      const { received: jsReceived, result: jsDone } = await waitForHmrBroadcast(
        port,
        () => writeFileSync(join(dir, 'src', 'greet.ts'), origGreet.replace('hello', 'hi')),
        (m) => m.type === 'update-done',
      );
      expect(jsDone).toBeDefined();
      const jsTypes = jsReceived.map((m) => m.type);
      expect(jsTypes).toEqual(expect.arrayContaining(['update-start', 'update', 'update-done']));
      const updateMsg = jsReceived.find((m) => m.type === 'update');
      const updateModules = updateMsg?.modules as UpdateModule[] | undefined;
      expect(updateModules?.length ?? 0).toBeGreaterThan(0);
      expect(updateModules![0].code.length).toBeGreaterThan(0);
      // PR #3799 — sourceMappingURL 주석 append
      expect(updateModules![0].code).toMatch(/\/\/# sourceMappingURL=\/__zntc_hmr_map\//);
      // sourcemap endpoint route 응답 (200 또는 404 둘 다 valid — sourcemap enable 여부 dependent)
      const smId = updateModules![0].id;
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
      const { result: graphResult } = await waitForHmrBroadcast(
        port,
        () =>
          writeFileSync(
            join(dir, 'src', 'main.ts'),
            `${origMain}\nimport { x } from "./added.ts";\nconsole.log(x);`,
          ),
        (m) => m.type === 'full-reload' || m.type === 'update-done',
      );
      expect(['full-reload', 'update-done']).toContain(graphResult?.type);

      // 원복
      writeFileSync(join(dir, 'src', 'main.ts'), origMain);
      try {
        unlinkSync(join(dir, 'src', 'added.ts'));
      } catch {}
      await sleep(500);

      // ───── 시나리오 4: HTML 변경 → fallback FullReload (#3797 drain else) ─────
      const origHtml = readFileSync(join(dir, 'index.html'), 'utf8');
      const { result: htmlResult } = await waitForHmrBroadcast(
        port,
        () =>
          writeFileSync(
            join(dir, 'index.html'),
            origHtml.replace('<body>', '<body><meta name="v" content="2">'),
          ),
        (m) => m.type === 'full-reload',
      );
      expect(htmlResult?.type).toBe('full-reload');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 30000);
});
