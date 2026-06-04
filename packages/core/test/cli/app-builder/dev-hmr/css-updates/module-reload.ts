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
} from '../../helpers';
import { waitForHmrBroadcast } from '../hmr-wait';

describe('CLI: Vite-style app builder > dev HMR CSS updates > module reload', () => {
  test('dev .module.scss edit triggers full reload (not css-update fast-path)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-module-scss-reload-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      'import s from "./card.module.scss"; console.log(s.card);',
    );
    writeFileSync(join(dir, 'src', 'card.module.scss'), '.card { color: rgb(1, 2, 3); }');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    try {
      const { result } = await waitForHmrBroadcast(
        port,
        () => writeFileSync(join(dir, 'src', 'card.module.scss'), '.card { color: rgb(7, 8, 9); }'),
        (m) => m.type === 'css-update' || m.type === 'full-reload',
      );
      expect(result?.type).toBe('full-reload');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 20000);
});
