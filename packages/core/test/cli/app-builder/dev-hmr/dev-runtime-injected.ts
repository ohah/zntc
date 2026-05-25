// #3793 회귀 가드 — `zntc dev` 가 dev mode 로 빌드해 HMR 런타임을 inject.
// 가드 전: `appCommand === 'dev'` 가 opts.devMode 를 set 안 함 → initial bundle 이 production
// 모드 (no __zntc_apply_update / no __esm register) → broadcast 된 Update 가 client 에서
// undefined 분기로 location.reload() fallback. 모든 incremental HMR 이 무효화.
// 회귀 시 broadcast WS 시퀀스 자체는 정상이라 broadcast 단위 테스트 (hmr-rebuild-broadcast.test.ts)
// 로는 잡히지 않음 — bundle 내용 자체를 검증.

import {
  CLI,
  RUNTIME,
  describe,
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
  waitForServer,
  writeFileSync,
} from '../helpers';

describe('CLI: Vite-style app builder > dev HMR > dev runtime injected', () => {
  test('zntc dev 빌드 결과는 dev runtime token 을 포함 (#3793)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-runtime-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log("hello");');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    try {
      // dev server 의 outdir 인 .zntc-dev/ 의 bundle.js 가 dev runtime literal 을 포함해야 함.
      // - __esm: ES module factory wrapper (dev mode 에서 모듈 register 용)
      // - __zntc_register 또는 globalThis.__zntc_g: dev runtime global registry
      // pre-fix (production mode default) 에서는 이 토큰들이 누락돼 incremental HMR client 의
      // __zntc_apply_update 가 평가할 모듈 factory 를 찾지 못함.
      const bundle = readFileSync(join(dir, '.zntc-dev', 'bundle.js'), 'utf8');
      expect(bundle).toContain('__esm');
      expect(bundle).toMatch(/__zntc_register|__zntc_g/);
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
