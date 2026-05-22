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

// #1880 PR7-2b-i — this.emitFile({ type: 'chunk', id }). B-i 는 id 가 *이미 graph 에 있는*
// 모듈일 때만 별도 chunk 로 분리(federation/dynamic entry 청킹 재사용). 신규 모듈(graph 미존재)은
// resolution/discovery 가 필요해 B-ii 대기 → build 진단으로 surfacing. id 누락은 plugin failure.
describe('@zntc/core build + plugins - this.emitFile chunk (PR7-2b-i)', () => {
  test('이미 import 된 모듈을 emit chunk 로 별도 chunk 분리한다', async () => {
    let refId: unknown = 'unset';
    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-chunk-'));
    const depPath = join(dir, 'dep.ts');
    const plugin: ZntcPlugin = {
      name: 'emit-chunk-existing',
      setup(build) {
        build.onTransform(
          { filter: /main\.ts$/ },
          async function (this: RollupPluginContext, args: { path: string }) {
            // dep 는 main 이 정적 import → 이미 graph 에 있음. graph 와 동일한 abs id 를 얻으려고
            // this.resolve 로 해석(B-i 는 emitFile 안에서 resolve 안 하므로 plugin 이 resolved id 전달).
            const r = await this.resolve('./dep.ts', args.path);
            refId = this.emitFile({ type: 'chunk', id: r!.id });
            return null;
          },
        );
      },
    };
    try {
      writeFileSync(depPath, 'export const d = 42;\n');
      writeFileSync(join(dir, 'main.ts'), 'import { d } from "./dep.ts";\nexport const x = d;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
        splitting: true,
      });
      expect(result.errors.length).toBe(0);
      expect(typeof refId).toBe('string');
      // dep 가 별도 chunk 로 분리 → outputFiles 에 dep chunk 파일 존재.
      const depChunk = result.outputFiles.find((f) => f.path.includes('dep'));
      expect(depChunk).toBeDefined();
      expect(depChunk!.text).toContain('42');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('graph 에 없는 신규 모듈 emit chunk 는 B-ii 대기 — build 진단', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-chunk-new-'));
    const plugin: ZntcPlugin = {
      name: 'emit-chunk-new',
      setup(build) {
        build.onTransform({ filter: /main\.ts$/ }, function (this: RollupPluginContext) {
          this.emitFile({ type: 'chunk', id: join(dir, 'ghost.ts') }); // graph 에 없음
          return null;
        });
      },
    };
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
        splitting: true,
      });
      expect(result.errors.length).toBeGreaterThan(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('splitting 없이 chunk emit 은 거부된다 (code splitting 필요)', async () => {
    // emit chunk 는 별도 chunk 분리가 가능한 splitting 모드에서만 의미. 단일파일 모드면 진단.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-chunk-nosplit-'));
    const plugin: ZntcPlugin = {
      name: 'emit-chunk-nosplit',
      setup(build) {
        build.onTransform(
          { filter: /main\.ts$/ },
          async function (this: RollupPluginContext, args: { path: string }) {
            const r = await this.resolve('./dep.ts', args.path);
            this.emitFile({ type: 'chunk', id: r!.id });
            return null;
          },
        );
      },
    };
    try {
      writeFileSync(join(dir, 'dep.ts'), 'export const d = 1;\n');
      writeFileSync(join(dir, 'main.ts'), 'import { d } from "./dep.ts";\nexport const x = d;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
        // splitting 생략 = false (단일파일)
      });
      expect(result.errors.length).toBeGreaterThan(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('id 없는 chunk emit 은 plugin failure', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-chunk-noid-'));
    const plugin: ZntcPlugin = {
      name: 'emit-chunk-noid',
      setup(build) {
        build.onTransform({ filter: /main\.ts$/ }, function (this: RollupPluginContext) {
          this.emitFile({ type: 'chunk' }); // id 누락
          return null;
        });
      },
    };
    try {
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
        splitting: true,
      });
      expect(result.errors.length).toBeGreaterThan(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
