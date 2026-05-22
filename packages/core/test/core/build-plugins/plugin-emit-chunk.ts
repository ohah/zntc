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

  test('코드에 import 없는 신규 모듈을 emit chunk 로 별도 chunk 분리한다 (B-ii)', async () => {
    let refId: unknown = 'unset';
    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-chunk-new-'));
    const workerPath = join(dir, 'worker.ts');
    const plugin: ZntcPlugin = {
      name: 'emit-chunk-new-module',
      setup(build) {
        build.onTransform(
          { filter: /main\.ts$/ },
          async function (this: RollupPluginContext, args: { path: string }) {
            // worker 는 main 이 정적/동적 import 안 함 → graph 에 없음(신규). this.resolve 로 abs id.
            const r = await this.resolve('./worker.ts', args.path);
            refId = this.emitFile({ type: 'chunk', id: r!.id });
            return null;
          },
        );
      },
    };
    try {
      writeFileSync(workerPath, 'export const w = 99;\nconsole.log("worker-side-effect");\n');
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n'); // worker 미참조
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
        splitting: true,
      });
      expect(result.errors.length).toBe(0);
      expect(typeof refId).toBe('string');
      // worker 가 신규 entry 로 graph 에 추가되고 tree-shaking 생존 → 별도 chunk 로 출력.
      const workerChunk = result.outputFiles.find((f) => f.path.includes('worker'));
      expect(workerChunk).toBeDefined();
      expect(workerChunk!.text).toContain('99');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('chunk emit 후 generateBundle 의 this.getFileName 이 최종 파일명을 반환한다 (PR7-2c)', async () => {
    let chunkRef = '';
    let resolvedName: string | undefined;
    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-chunk-getname-'));
    const workerPath = join(dir, 'worker.ts');
    const plugin: ZntcPlugin = {
      name: 'chunk-getfilename',
      setup(build) {
        build.onTransform(
          { filter: /main\.ts$/ },
          async function (this: RollupPluginContext, args: { path: string }) {
            const r = await this.resolve('./worker.ts', args.path);
            chunkRef = this.emitFile({ type: 'chunk', id: r!.id, name: 'myworker' }) as string;
            return null;
          },
        );
        // generateBundle 은 청킹 후 → getFileName 이 back-fill 된 최종 파일명 반환.
        build.onGenerateBundle(function (this: RollupPluginContext) {
          resolvedName = this.getFileName(chunkRef);
        });
      },
    };
    try {
      writeFileSync(workerPath, 'export const w = 99;\nconsole.log("wk");\n');
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
        splitting: true,
      });
      expect(result.errors.length).toBe(0);
      // name:'myworker' 가 [name] 으로 반영된 최종 chunk 파일명 + 실제 output 과 일치.
      expect(resolvedName).toBeDefined();
      expect(resolvedName).toContain('myworker');
      expect(result.outputFiles.find((f) => f.path === resolvedName)).toBeDefined();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('resolve 불가능한 id 의 chunk emit 은 build 진단', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-chunk-ghost-'));
    const plugin: ZntcPlugin = {
      name: 'emit-chunk-ghost',
      setup(build) {
        build.onTransform({ filter: /main\.ts$/ }, function (this: RollupPluginContext) {
          this.emitFile({ type: 'chunk', id: join(dir, 'ghost.ts') }); // 파일 없음 → graph 추가 실패
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
