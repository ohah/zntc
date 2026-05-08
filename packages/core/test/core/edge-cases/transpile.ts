import {
  describe,
  test,
  expect,
  transpile,
  buildSync,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from '../helpers';

describe('@zntc/core edge cases: transpile', () => {
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
});
