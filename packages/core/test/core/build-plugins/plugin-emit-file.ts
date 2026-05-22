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

// #1880 PR5/6 — this.emitFile({ type: 'asset', fileName | name, source }) → referenceId +
// this.getFileName(referenceId). emit 된 asset 은 build 의 메인 스레드(TSFN callJsCallback)에서 단일
// EmitStore 에 직렬 수집 → result.outputFiles 로 노출(asset_outputs 경유). name-only 는 source hash
// 파일명 자동 생성(file-loader 와 동일 패턴). type:'chunk' 는 아직 throw(follow-up).
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

  test('name-only asset 은 source hash 파일명으로 emit 되고 stem/ext 를 보존한다', async () => {
    let fileName: string | undefined;
    const plugin: ZntcPlugin = {
      name: 'emit-name-only',
      setup(build) {
        build.onTransform({ filter: /main\.ts$/ }, function (this: RollupPluginContext) {
          const ref = this.emitFile({ type: 'asset', name: 'logo.png', source: 'PNGDATA' });
          fileName = this.getFileName(ref);
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
      expect(result.errors.length).toBe(0);
      // 기본 assetNames "[name]-[hash]" → "logo-XXXXXXXX.png"
      expect(fileName).toMatch(/^logo-[0-9a-f]{8}\.png$/);
      const asset = result.outputFiles.find((f) => f.path === fileName);
      expect(asset).toBeDefined();
      expect(asset!.text).toBe('PNGDATA');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('this.getFileName 은 명시 fileName asset 의 파일명을 그대로 반환한다', async () => {
    let resolved: string | undefined;
    const plugin: ZntcPlugin = {
      name: 'emit-getfilename',
      setup(build) {
        build.onTransform({ filter: /main\.ts$/ }, function (this: RollupPluginContext) {
          const ref = this.emitFile({ type: 'asset', fileName: 'styles/app.css', source: 'a{}' });
          resolved = this.getFileName(ref);
          return null;
        });
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-getname-'));
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
      });
      expect(result.errors.length).toBe(0);
      expect(resolved).toBe('styles/app.css');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('this.getFileName(미등록 id) 은 plugin failure', async () => {
    const plugin: ZntcPlugin = {
      name: 'emit-getfilename-unknown',
      setup(build) {
        build.onTransform({ filter: /main\.ts$/ }, function (this: RollupPluginContext) {
          this.getFileName('asset-does-not-exist');
          return null;
        });
      },
    };

    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-getname-unknown-'));
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
