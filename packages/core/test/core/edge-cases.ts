import {
  describe,
  test,
  expect,
  init,
  transpile,
  build,
  buildSync,
  close,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('@zntc/core edge cases', () => {
  // transpile 엣지케이스
  test('매우 긴 소스코드 트랜스파일', () => {
    const lines = Array.from({ length: 10000 }, (_, i) => `export const v${i}: number = ${i};`);
    const result = transpile(lines.join('\n'), { filename: 'input.ts' });
    expect(result.code).toContain('v9999 = 9999');
  });

  test('유니코드 소스코드', () => {
    const result = transpile('const 이름: string = "한글 테스트";', { filename: 'input.ts' });
    expect(result.code).toContain('한글 테스트');
  });

  test('빈 인터페이스만 있는 파일', () => {
    const result = transpile('interface Empty {}\n', { filename: 'input.ts' });
    expect(result.code.trim()).toBe('');
  });

  test('타입만 있는 파일', () => {
    const result = transpile('type Foo = string;\ntype Bar = number;\n', { filename: 'input.ts' });
    expect(result.code.trim()).toBe('');
  });

  test('복잡한 제네릭 타입', () => {
    const result = transpile(
      'function identity<T extends Record<string, unknown>>(x: T): T { return x; }',
      { filename: 'input.ts' },
    );
    expect(result.code).toContain('function identity(x)');
    expect(result.code).not.toContain('<T');
  });

  test('enum + namespace 병합', () => {
    const result = transpile('enum Direction { Up, Down }\nconst d: Direction = Direction.Up;', {
      filename: 'input.ts',
    });
    expect(result.code).toContain('Direction');
  });

  test('optional chaining + nullish coalescing', () => {
    const result = transpile("const x = a?.b?.c ?? 'default';");
    expect(result.code).toContain('??');
  });

  test('build target es5 keeps optional chaining temp declarations in nested functions', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-es5-optional-temp-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `
          function createProxy(state: any) {
            state.callbacks.push(function rootDraftCleanup(rootScope: any) {
              rootScope.mapSetPlugin_?.fixSetContents(state);
              const { patchPlugin_ } = rootScope;
              if (state.modified_ && patchPlugin_) {
                patchPlugin_.generatePatches_(state, [], rootScope);
              }
            });
          }

          const calls: string[] = [];
          const state = { callbacks: [] as Function[], modified_: true };
          createProxy(state);
          state.callbacks[0]({
            mapSetPlugin_: { fixSetContents() { calls.push("map"); } },
            patchPlugin_: { generatePatches_() { calls.push("patch"); } },
          });
          globalThis.__VALUE__ = calls.join(",");
        `,
      );

      const result = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        target: 'es5',
      });
      expect(result.errors.length).toBe(0);
      const code = result.outputFiles[0].text;
      expect(code).not.toContain('?.');

      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __VALUE__?: string } = {};
      vm.runInNewContext(code, sandbox);
      expect(sandbox.__VALUE__).toBe('map,patch');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('decorator (experimental)', () => {
    const result = transpile(
      '@sealed\nclass Greeter {\n  greeting: string;\n  constructor(message: string) { this.greeting = message; }\n}',
      { filename: 'input.ts', experimentalDecorators: true },
    );
    expect(result.code).toContain('__decorate');
  });

  test('소스맵 + minify 동시 사용', () => {
    const result = transpile(
      'const longVariableName: number = 42;\nconsole.log(longVariableName);',
      {
        filename: 'input.ts',
        sourcemap: true,
        minify: true,
      },
    );
    expect(result.code.length).toBeLessThan(60);
    expect(result.map).toBeDefined();
    const map = JSON.parse(result.map!);
    expect(map.version).toBe(3);
  });

  // init 엣지케이스
  test('init 전에 transpile 호출 시 에러', () => {
    // 이미 init됨, close 후 테스트
    close();
    expect(() => transpile('const x = 1;')).toThrow('not initialized');
    init(); // 복원
  });

  test('init 전에 buildSync 호출 시 에러', () => {
    close();
    expect(() => buildSync({ entryPoints: ['/nonexistent'] })).toThrow('not initialized');
    init(); // 복원
  });

  test('init 전에 build 호출 시 에러', async () => {
    close();
    await expect(build({ entryPoints: ['/nonexistent'] })).rejects.toThrow('not initialized');
    init(); // 복원
  });

  // buildSync 엣지케이스
  test('buildSync: 빈 entryPoints 에러', () => {
    expect(() => buildSync({ entryPoints: [] })).toThrow('entryPoints is required');
  });

  test('buildSync: 존재하지 않는 파일', () => {
    const result = buildSync({ entryPoints: ['/nonexistent/file.ts'] });
    expect(result.errors.length).toBeGreaterThan(0);
  });

  test('buildSync: 모든 옵션 동시 사용', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-edge-all-opts-'));
    writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');
    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      format: 'esm',
      platform: 'browser',
      minify: true,
      sourcemap: true,
      metafile: true,
      treeShaking: true,
      keepNames: true,
      charsetUtf8: true,
      banner: '/* banner */',
      footer: '/* footer */',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('/* banner */');
    expect(result.outputFiles[0].text).toContain('/* footer */');
    expect(result.metafile).toBeDefined();
    rmSync(dir, { recursive: true, force: true });
  });

  // build async 엣지케이스
  test('build: 빈 entryPoints 에러', async () => {
    await expect(build({ entryPoints: [] })).rejects.toThrow('entryPoints is required');
  });

  test('build: 존재하지 않는 파일', async () => {
    const result = await build({ entryPoints: ['/nonexistent/file.ts'] });
    expect(result.errors.length).toBeGreaterThan(0);
  });

  test('build: 병렬 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-edge-parallel-'));
    writeFileSync(join(dir, 'a.ts'), 'export const a = 1;');
    writeFileSync(join(dir, 'b.ts'), 'export const b = 2;');

    const [resultA, resultB] = await Promise.all([
      build({ entryPoints: [join(dir, 'a.ts')] }),
      build({ entryPoints: [join(dir, 'b.ts')] }),
    ]);
    expect(resultA.errors.length).toBe(0);
    expect(resultB.errors.length).toBe(0);
    expect(resultA.outputFiles[0].text).toContain('a = 1');
    expect(resultB.outputFiles[0].text).toContain('b = 2');
    rmSync(dir, { recursive: true, force: true });
  });

  // 플러그인 엣지케이스
  test('plugin: null 반환 시 기본 동작', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-edge-plugin-null-'));
    writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');

    const noopPlugin: ZntcPlugin = {
      name: 'noop',
      setup(build) {
        build.onLoad({ filter: /never-match/ }, () => null);
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      plugins: [noopPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('x = 1');
    rmSync(dir, { recursive: true, force: true });
  });

  test('plugin: setup에서 아무 훅도 등록하지 않음', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-edge-empty-plugin-'));
    writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      plugins: [{ name: 'empty', setup() {} }],
    });
    expect(result.errors.length).toBe(0);
    rmSync(dir, { recursive: true, force: true });
  });

  test('transpile: 반복 호출 1000회 메모리 안정성', () => {
    for (let i = 0; i < 1000; i++) {
      const result = transpile(`const x${i} = ${i};`);
      expect(result.code).toContain(`x${i} = ${i}`);
    }
  });
});

// ─── 추가 커버리지 테스트 ───
