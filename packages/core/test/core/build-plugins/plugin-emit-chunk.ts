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

  test('명시 fileName 의 chunk emit 은 hash/[name] 패턴 없이 그대로 출력된다 (PR7-2d)', async () => {
    // name(→[name]-[hash]) 대조: fileName 은 verbatim. Rollup emitFile chunk fileName 동형.
    let chunkRef = '';
    let resolvedName: string | undefined;
    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-chunk-fname-'));
    const plugin: ZntcPlugin = {
      name: 'chunk-explicit-filename',
      setup(build) {
        build.onTransform(
          { filter: /main\.ts$/ },
          async function (this: RollupPluginContext, args: { path: string }) {
            const r = await this.resolve('./worker.ts', args.path);
            // 서브디렉토리 + 확장자 포함 명시 fileName.
            chunkRef = this.emitFile({
              type: 'chunk',
              id: r!.id,
              fileName: 'workers/sw.js',
            }) as string;
            return null;
          },
        );
        build.onGenerateBundle(function (this: RollupPluginContext) {
          resolvedName = this.getFileName(chunkRef);
        });
      },
    };
    try {
      writeFileSync(join(dir, 'worker.ts'), 'export const w = 99;\nconsole.log("wk");\n');
      writeFileSync(join(dir, 'main.ts'), 'export const x = 1;\n');
      const result = await build({
        entryPoints: [join(dir, 'main.ts')],
        plugins: [plugin],
        splitting: true,
      });
      expect(result.errors.length).toBe(0);
      // 출력 파일명이 정확히 'workers/sw.js' (hash 없음).
      const swChunk = result.outputFiles.find((f) => f.path === 'workers/sw.js');
      expect(swChunk).toBeDefined();
      expect(swChunk!.text).toContain('99');
      // hash 가 붙은 변형이 없어야 한다.
      expect(result.outputFiles.some((f) => /workers\/sw-[0-9a-f]{8}\.js$/.test(f.path))).toBe(
        false,
      );
      // getFileName 도 동일 verbatim 반환(출력과 일치).
      expect(resolvedName).toBe('workers/sw.js');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('상대 specifier 신규 모듈 emit chunk — this.resolve 없이 project_root 기준 resolve (RFC §4.2)', async () => {
    // abs path(this.resolve 결과)뿐 아니라 RFC §4.2 는 resolveThreadSafe 로 상대/bare specifier 도
    // 받도록 명세한다. plugin 이 this.resolve 를 선호출하지 않고 './worker.ts' 를 그대로 emit 해도
    // source_dir(project_root) 기준으로 resolve 되어 별도 chunk 로 나와야 한다(Rollup 동형).
    let refId: unknown = 'unset';
    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-chunk-rel-'));
    const plugin: ZntcPlugin = {
      name: 'emit-chunk-relative',
      setup(build) {
        build.onTransform({ filter: /main\.ts$/ }, function (this: RollupPluginContext) {
          // 미해석 상대 경로 — resolve 는 ZNTC 내부가 담당.
          refId = this.emitFile({ type: 'chunk', id: './worker.ts' });
          return null;
        });
      },
    };
    try {
      // package.json 으로 project_root 를 dir 에 고정 → 상대 './worker.ts' 가 dir 기준 resolve.
      // (project_root 자동탐지가 tmpdir 조상의 package.json 으로 새지 않도록 — 환경 독립 보장.)
      writeFileSync(join(dir, 'package.json'), '{}\n');
      writeFileSync(join(dir, 'worker.ts'), 'export const w = 7;\nconsole.log("rel-worker");\n');
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
      expect(workerChunk!.text).toContain('7');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('emit-within-emit: 신규 모듈의 transform 이 또 emit chunk 하면 fixpoint 로 둘 다 분리', async () => {
    // a.ts 는 plugin 이 emit(신규), 그 a.ts 의 transform 이 b.ts 를 또 emit → 재-discovery
    // fixpoint 가 b.ts 까지 별도 chunk 로 분리해야 한다(RFC §4.3).
    const dir = mkdtempSync(join(tmpdir(), 'zntc-emit-chunk-nested-'));
    const plugin: ZntcPlugin = {
      name: 'emit-chunk-nested',
      setup(build) {
        build.onTransform({ filter: /main\.ts$/ }, function (this: RollupPluginContext) {
          this.emitFile({ type: 'chunk', id: './a.ts' });
          return null;
        });
        build.onTransform({ filter: /a\.ts$/ }, function (this: RollupPluginContext) {
          this.emitFile({ type: 'chunk', id: './b.ts' });
          return null;
        });
      },
    };
    try {
      // project_root 를 dir 에 고정(상대 './a.ts'/'./b.ts' resolve 기준 — 환경 독립).
      writeFileSync(join(dir, 'package.json'), '{}\n');
      writeFileSync(join(dir, 'a.ts'), 'export const a = 11;\nconsole.log("a-side");\n');
      writeFileSync(join(dir, 'b.ts'), 'export const b = 22;\nconsole.log("b-side");\n');
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
