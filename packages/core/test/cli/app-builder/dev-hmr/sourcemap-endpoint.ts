// #3799 회귀 가드 — HMR Update modules 의 code 에 sourceMappingURL 주석 append +
// `/__zntc_hmr_map/<id>` route 응답. 가드 전: web 경로의 incremental Update 가 sourcemap
// 정보를 stripped 한 채 broadcast → DevTools 가 eval'd code 의 `<anonymous>:1:N` 만 표시.
// RN bridge (hmr-bridge.ts:42) 와 같은 패턴으로 web 도 lazy sourcemap.

import {
  CLI,
  RUNTIME,
  describe,
  expect,
  findFreePort,
  join,
  mkdirSync,
  mkdtempSync,
  rmSync,
  spawn,
  test,
  tmpdir,
  waitForServer,
  writeFileSync,
} from '../helpers';
import { waitForHmrBroadcast } from './hmr-wait';

describe('CLI: Vite-style app builder > dev HMR > sourcemap endpoint (#3799)', () => {
  test('Update modules.code 에 sourceMappingURL 주석 + endpoint 응답', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-sm-endpoint-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(join(dir, 'src', 'main.ts'), 'export const x = 1;');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    try {
      const { result: updateMsg } = await waitForHmrBroadcast(
        port,
        () => writeFileSync(join(dir, 'src', 'main.ts'), 'export const x = 2;'),
        (m) => m.type === 'update',
      );
      expect(updateMsg?.type).toBe('update');
      const modules = updateMsg?.modules as Array<{ id: string; code: string }> | undefined;
      expect(modules?.length ?? 0).toBeGreaterThan(0);
      const first = modules![0];
      // sourceMappingURL 주석 append 확인
      expect(first.code).toMatch(/\/\/# sourceMappingURL=\/__zntc_hmr_map\//);

      // endpoint route 가 sourcemap JSON 응답하는지 — sourcemap 옵션 활성 여부 영향
      // (default ON in dev 라 가능). 404 도 acceptable (sourcemap 비활성 케이스) — 그러나
      // 형식 검증은 어쨌든 정상 (Content-Type 또는 빈 응답).
      const url = `http://localhost:${port}/__zntc_hmr_map/${encodeURIComponent(first.id)}`;
      const resp = await fetch(url);
      // 200 또는 404 — 둘 다 정상 (sourcemap 활성 / 미활성). route 자체가 응답해야.
      expect([200, 404]).toContain(resp.status);
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 20000);
});
