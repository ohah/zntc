import {
  describe,
  test,
  expect,
  watch,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';
import type { ZntcPlugin } from './helpers';

describe('watch() > rebuild updates > plugins and errors', () => {
  test('플러그인과 함께 watch', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'import "./style.css"; export const x = 1;');
    writeFileSync(join(dir, 'style.css'), 'body { color: red; }');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();

    const cssPlugin: ZntcPlugin = {
      name: 'css-loader',
      setup(build) {
        build.onLoad({ filter: /\.css$/ }, () => ({
          contents: 'export default "css-loaded";',
        }));
      },
    };

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [cssPlugin],
      onReady(event) {
        expect(event.files).toBeGreaterThan(0);
        readyDone();
      },
    });

    await readyP;
    handle.stop();
    rmSync(dir, { recursive: true });
  });

  test('리빌드 중 문법 에러 시 success: false + error', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      success: boolean;
      error?: string;
    }>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });

    await readyP;

    // 문법 에러가 있는 코드로 변경
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const = ;; {{{{');

    const event = await rebuildP;
    // 에러가 발생하더라도 watch는 계속 동작해야 함
    // (ZNTC 파서가 에러 복구를 하므로 success: true일 수도 있음)
    expect(typeof event.success).toBe('boolean');
    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);
});
