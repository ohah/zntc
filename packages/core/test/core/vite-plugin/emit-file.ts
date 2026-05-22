import {
  build,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  vitePlugin,
  writeFileSync,
} from './helpers';
import type { RollupPlugin } from './helpers';

// #1880 PR7 — vitePlugin() 어댑터에서도 this.emitFile / this.getFileName 동작. 어댑터는 자체
// context 를 쓰지만, native 디스패처가 transform/load/resolveId hook 에 주입한 emit 슬롯을
// 핸들러(this)에서 어댑터 context 로 전달한다(forwardEmitContext).
describe('vitePlugin 어댑터 - this.emitFile / getFileName', () => {
  test('transform 에서 emit 한 asset 이 outputFiles 에 나타나고 getFileName 으로 조회된다', async () => {
    let resolved: string | undefined;
    const plugin: RollupPlugin = {
      name: 'vite-emit-transform',
      transform(code) {
        const ref = this.emitFile({ type: 'asset', fileName: 'vite-extracted.css', source: 'a{}' });
        resolved = this.getFileName(ref);
        return null;
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-vite-emit-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [vitePlugin(plugin)],
      });
      expect(result.errors.length).toBe(0);
      expect(resolved).toBe('vite-extracted.css');
      const asset = result.outputFiles.find((f) => f.path === 'vite-extracted.css');
      expect(asset).toBeDefined();
      expect(asset!.text).toBe('a{}');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('transform emit 후 renderChunk 의 emitFile 은 stale 슬롯으로 새지 않고 throw 한다', async () => {
    // 회귀 가드(PR7 code-review): 어댑터 context 슬롯이 transform 에서 set 된 채 renderChunk 로
    // 남아 emitFile 이 잘못 동작하던 버그. renderChunk 는 emit 미지원이므로 throw 해야 한다.
    const plugin: RollupPlugin = {
      name: 'vite-emit-renderchunk-stale',
      transform() {
        this.emitFile({ type: 'asset', fileName: 'ok-from-transform.txt', source: 'T' });
        return null;
      },
      renderChunk(code) {
        this.emitFile({ type: 'asset', fileName: 'leaked-from-renderchunk.txt', source: 'X' });
        return null;
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-vite-emit-stale-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [vitePlugin(plugin)],
      });
      // renderChunk 의 emitFile 은 stale 슬롯이 clear 돼 throw(renderChunk 실패는 swallow 되어
      // result.errors 로는 안 올라오지만) → 핵심은 그 asset 이 output 에 새지 않는 것.
      expect(
        result.outputFiles.find((f) => f.path === 'leaked-from-renderchunk.txt'),
      ).toBeUndefined();
      // transform 의 정상 emit 은 그대로 노출.
      expect(result.outputFiles.find((f) => f.path === 'ok-from-transform.txt')?.text).toBe('T');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('name-only asset 도 vitePlugin 에서 source hash 파일명으로 emit 된다', async () => {
    let fileName: string | undefined;
    const plugin: RollupPlugin = {
      name: 'vite-emit-name-only',
      load() {
        const ref = this.emitFile({ type: 'asset', name: 'icon.svg', source: '<svg/>' });
        fileName = this.getFileName(ref);
        return null;
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-vite-emit-name-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [vitePlugin(plugin)],
      });
      expect(result.errors.length).toBe(0);
      expect(fileName).toMatch(/^icon-[0-9a-f]{8}\.svg$/);
      expect(result.outputFiles.find((f) => f.path === fileName)?.text).toBe('<svg/>');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
