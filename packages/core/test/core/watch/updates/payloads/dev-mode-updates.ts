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

describe('watch() > rebuild updates > payloads > dev mode updates', () => {
  test('devMode에서 moduleCodes diff → updates 전달', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: Array<{ id: string; code: string; map?: string }>;
      graphChanged?: boolean;
    }>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      collectModuleCodes: true,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });

    await readyP;

    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 999;');

    const event = await rebuildP;
    expect(event.graphChanged).toBeFalsy();
    if (event.updates && event.updates.length > 0) {
      expect(event.updates[0].id).toBeDefined();
      expect(event.updates[0].code).toContain('999');
      expect(event.updates[0].map).toBeDefined();
      const map = event.updates[0].map!;
      expect(map).toContain('"version":3');
      expect(map).toContain('"mappings":"');
      expect(map).toContain('"sources":[');
    }
    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);
});
