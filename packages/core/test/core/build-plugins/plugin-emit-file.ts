import {
  build,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from './helpers';
import type { ZntcPlugin } from './helpers';
import type { RollupPluginContext } from '../../../index';

// #1880 PR5 — this.emitFile({ type: 'asset', fileName, source }) → referenceId. emit 된 asset 은
// build 의 메인 스레드(TSFN callJsCallback)에서 단일 EmitStore 에 직렬 수집 → result.outputFiles 로
// 노출(asset_outputs 경유). MVP 는 명시 fileName 의 asset 만 — chunk / name-only(getFileName) 은 throw.
describe('@zntc/core build + plugins - this.emitFile', () => {
  test('transform 에서 emit 한 asset 이 outputFiles 에 나타난다', async () => {
    let refId: unknown = 'unset';
    const plugin: ZntcPlugin = {
      name: 'emit-asset-transform',
      setup(build) {
        build.onTransform(
          { filter: /main\.ts$/ },
          function (this: RollupPluginContext, args: { code: string }) {
            refId = this.emitFile({
              type: 'asset',
              fileName: 'extracted.css',
              source: 'body{margin:0}',
            });
            return null;
          },
        );
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-transform-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
      });
      expect(result.errors.length).toBe(0);
      expect(typeof refId).toBe('string');
      const asset = result.outputFiles.find((f) => f.path === 'extracted.css');
      expect(asset).toBeDefined();
      expect(asset!.text).toBe('body{margin:0}');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('load hook 에서도 emit 한 asset 이 노출된다', async () => {
    const plugin: ZntcPlugin = {
      name: 'emit-asset-load',
      setup(build) {
        build.onLoad(
          { filter: /main\.ts$/ },
          function (this: RollupPluginContext, _args: { path: string }) {
            this.emitFile({ type: 'asset', fileName: 'data.json', source: '{"a":1}' });
            return null;
          },
        );
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-load-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
      });
      expect(result.errors.length).toBe(0);
      const asset = result.outputFiles.find((f) => f.path === 'data.json');
      expect(asset).toBeDefined();
      expect(asset!.text).toBe('{"a":1}');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('emit 한 referenceId 는 매번 고유하다', async () => {
    const ids: string[] = [];
    const plugin: ZntcPlugin = {
      name: 'emit-asset-multi',
      setup(build) {
        build.onTransform({ filter: /main\.ts$/ }, function (this: RollupPluginContext) {
          ids.push(this.emitFile({ type: 'asset', fileName: 'a.txt', source: 'A' }) as string);
          ids.push(this.emitFile({ type: 'asset', fileName: 'b.txt', source: 'B' }) as string);
          return null;
        });
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-multi-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
      });
      expect(result.errors.length).toBe(0);
      expect(ids.length).toBe(2);
      expect(ids[0]).not.toBe(ids[1]);
      expect(result.outputFiles.find((f) => f.path === 'a.txt')?.text).toBe('A');
      expect(result.outputFiles.find((f) => f.path === 'b.txt')?.text).toBe('B');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('type:chunk 는 아직 미지원 — plugin failure 로 정규화', async () => {
    const plugin: ZntcPlugin = {
      name: 'emit-chunk-unsupported',
      setup(build) {
        build.onTransform({ filter: /main\.ts$/ }, function (this: RollupPluginContext) {
          this.emitFile({ type: 'chunk', id: './other.ts' });
          return null;
        });
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-chunk-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
      });
      expect(result.errors.length).toBeGreaterThan(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('빈 fileName 은 silent null 대신 plugin failure 로 거부된다', async () => {
    const plugin: ZntcPlugin = {
      name: 'emit-empty-filename',
      setup(build) {
        build.onTransform({ filter: /main\.ts$/ }, function (this: RollupPluginContext) {
          this.emitFile({ type: 'asset', fileName: '', source: 'x' });
          return null;
        });
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-empty-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
      });
      expect(result.errors.length).toBeGreaterThan(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('fileName 없는 asset(name-only hash 파일명) 은 아직 미지원 — plugin failure', async () => {
    const plugin: ZntcPlugin = {
      name: 'emit-name-only-unsupported',
      setup(build) {
        build.onTransform({ filter: /main\.ts$/ }, function (this: RollupPluginContext) {
          this.emitFile({ type: 'asset', name: 'logo.png', source: 'PNGDATA' });
          return null;
        });
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-nameonly-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
      });
      expect(result.errors.length).toBeGreaterThan(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
