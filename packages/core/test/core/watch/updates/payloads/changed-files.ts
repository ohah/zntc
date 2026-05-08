import {
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  watch,
  writeFileSync,
} from '../helpers';

describe('watch() > rebuild updates > payloads > changed files', () => {
  test('changed 배열에 변경된 파일 경로 포함', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    const entryPath = join(dir, 'entry.ts');
    writeFileSync(entryPath, 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      changed?: string[];
    }>();

    const handle = watch({
      entryPoints: [entryPath],
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });

    await readyP;

    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(entryPath, 'export const x = 2;');

    const event = await rebuildP;
    expect(event.changed).toBeDefined();
    expect(event.changed!.length).toBeGreaterThan(0);
    const hasEntry = event.changed!.some((p) => p.includes('entry.ts'));
    expect(hasEntry).toBe(true);
    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);
});
