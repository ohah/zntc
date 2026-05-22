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

// #1880 PR7-2b — this.emitFile({ type: 'chunk', id }). B-i 는 id 가 *이미 graph 에 있는*
// 모듈일 때만 별도 chunk 로 분리(federation/dynamic entry 청킹 재사용). B-ii 는 graph 에 없는
// 신규 모듈을 resolution + fixpoint 재-discovery 로 주입 + tree_shaker 생존(정적 import 없어도
// 살아남아 별도 chunk 로 출력). id 누락은 plugin failure.
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

  // === PR7-2b-ii: 신규 모듈(graph 미존재) emit chunk ===

  test('정적 import 없는 신규 모듈을 emit chunk 로 주입 — tree-shaking 생존 + 별도 chunk', async () => {
    // 핵심 end-to-end 증명(RFC §6 invariant 1): worker.ts 는 어디서도 정적/동적 import 되지
    // 않는다. plugin 이 emitFile chunk 로만 추가 → resolution + 재-discovery + tree_shaker
    // entry_set 생존이 모두 맞물려야 별도 output chunk 로 살아남는다(하나라도 빠지면 사라짐).
    let refId: unknown = 'unset';
    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-chunk-new-'));
    const plugin: ZntcPlugin = {
      name: 'emit-chunk-new',
      setup(build) {
        build.onTransform({ filter: /main\.ts$/ }, function (this: RollupPluginContext) {
          // abs path 로 emit (graph 에 없음 → B-ii resolution 경로).
          refId = this.emitFile({ type: 'chunk', id: join(dir, 'worker.ts') });
          return null;
        });
      },
    };
    try {
      // worker 는 main 과 무관 — 정적 import 엣지가 없다.
      writeFileSync(join(dir, 'worker.ts'), 'export const w = 99;\nconsole.log(w);\n');
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
        splitting: true,
      });
      expect(result.errors.length).toBe(0);
      expect(typeof refId).toBe('string');
      // worker 가 별도 chunk 로 출력 + 내용(99) 생존 → tree-shaking 살아남음을 실증.
      const workerChunk = result.outputFiles.find((f) => f.path.includes('worker'));
      expect(workerChunk).toBeDefined();
      expect(workerChunk!.text).toContain('99');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('상대 specifier 신규 모듈 emit chunk 도 project_root 기준 resolve 된다', async () => {
    // id 가 미해석 상대 경로('./worker.ts') — resolveThreadSafe(project_root, ...) 검증.
    let refId: unknown = 'unset';
    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-chunk-rel-'));
    const plugin: ZntcPlugin = {
      name: 'emit-chunk-rel',
      setup(build) {
        build.onTransform({ filter: /main\.ts$/ }, function (this: RollupPluginContext) {
          refId = this.emitFile({ type: 'chunk', id: './worker.ts' });
          return null;
        });
      },
    };
    try {
      writeFileSync(join(dir, 'worker.ts'), 'export const w = 7;\nconsole.log(w);\n');
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
        splitting: true,
      });
      expect(result.errors.length).toBe(0);
      expect(typeof refId).toBe('string');
      const workerChunk = result.outputFiles.find((f) => f.path.includes('worker'));
      expect(workerChunk).toBeDefined();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('해석 불가한 신규 모듈 id 는 진단(에러) — silent drop 아님', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-chunk-unresolved-'));
    const plugin: ZntcPlugin = {
      name: 'emit-chunk-unresolved',
      setup(build) {
        build.onTransform({ filter: /main\.ts$/ }, function (this: RollupPluginContext) {
          this.emitFile({ type: 'chunk', id: './does-not-exist.ts' });
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

  test('emit-within-emit: 신규 모듈의 transform 이 또 emit chunk 하면 fixpoint 로 둘 다 분리', async () => {
    // a.ts 는 plugin 이 emit, a.ts 의 transform 이 b.ts 를 또 emit → 재-discovery fixpoint 검증.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-chunk-nested-'));
    const plugin: ZntcPlugin = {
      name: 'emit-chunk-nested',
      setup(build) {
        build.onTransform({ filter: /main\.ts$/ }, function (this: RollupPluginContext) {
          this.emitFile({ type: 'chunk', id: join(dir, 'a.ts') });
          return null;
        });
        build.onTransform({ filter: /a\.ts$/ }, function (this: RollupPluginContext) {
          this.emitFile({ type: 'chunk', id: join(dir, 'b.ts') });
          return null;
        });
      },
    };
    try {
      writeFileSync(join(dir, 'a.ts'), 'export const a = 11;\nconsole.log(a);\n');
      writeFileSync(join(dir, 'b.ts'), 'export const b = 22;\nconsole.log(b);\n');
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
        splitting: true,
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles.find((f) => f.path.includes('a'))).toBeDefined();
      expect(result.outputFiles.find((f) => f.path.includes('b'))).toBeDefined();
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
