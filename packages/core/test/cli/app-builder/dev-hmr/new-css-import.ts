// #3813 가드 (partial) — JS-only 변경이 새 CSS import 추가 시 broadcast 수신 검증.
//
// Limitation: native incremental bundler 가 새 module path 추가를 항상 `graphChanged=true`
// 로 trigger 하지 않음 (changed_files 만 partial rebuild 가능). 그래서 본 PR 의 outdir-scan
// CSS inject 가 `graphChanged=true` 케이스만 활성화. 새 import 가 update-done 시퀀스로
// broadcast 되면 inject 가 호출 안 됨. 완전 fix 는 native bundler 의 graphChanged 정책 변경
// (#3784 / 향후 epic) 와 함께.
//
// 본 가드는 broadcast 자체가 (FullReload 또는 Update sequence) 정상 도착하는지만 검증 —
// inject helper 가 plumbing 상태로 잘 동작하는지는 별도 unit test 로 검증.

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

describe('CLI: Vite-style app builder > dev HMR > new CSS import (#3813)', () => {
  test('JS-only 변경이 새 CSS import 추가 → broadcast 수신 (FullReload 또는 Update)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-new-css-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log("v1");');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    try {
      // JS-only 변경이 새 CSS import 를 추가 → graphChanged 면 FullReload, 아니면 Update 시퀀스.
      // (arm-race 방어/재시도/teardown 은 waitForHmrBroadcast 가 담당 — hmr-wait.ts 참고.)
      const { result } = await waitForHmrBroadcast(
        port,
        (attempt) => {
          writeFileSync(join(dir, 'src', 'styles.css'), 'body { background: lime; }');
          // 새 CSS import 는 첫 write 가 추가(아래 import 줄). 재시도는 console.log 값을 매번
          // 바꿔(`v${attempt+1}`) *fresh* JS diff 를 만든다 — 첫 broadcast 가 fsevents event
          // 분할로 css-update/noop 으로 떨어져도(predicate 불일치) 다음 재시도가 새 update 를
          // 강제해 영구 timeout(동일내용 재시도→diff 0→noop) 을 막는다.
          writeFileSync(
            join(dir, 'src', 'main.ts'),
            `import "./styles.css"; console.log("v${attempt + 1}");`,
          );
        },
        (m) => m.type === 'full-reload' || m.type === 'update-done',
      );
      // broadcast 자체 수신 가드 — pre-#3779 회귀 (silent drop) 방지
      expect(['full-reload', 'update-done']).toContain(result?.type);
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 20000);
});
