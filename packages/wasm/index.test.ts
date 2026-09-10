import { describe, test, expect, beforeAll } from 'bun:test';
import { readFileSync } from 'fs';
import { join } from 'path';
import {
  initSync,
  transpile,
  VirtualFileSystem,
  initBundler,
  bundlerVersion,
  build,
  buildChunks,
  bundlerLastErrorMessage,
} from './index';

beforeAll(() => {
  const wasmPath = join(import.meta.dir, '../../zig-out/bin/zntc.wasm');
  const wasmBytes = readFileSync(wasmPath);
  initSync(wasmBytes);
});

describe('@zntc/wasm', () => {
  test('기본 TypeScript 트랜스파일', () => {
    const result = transpile('const x: number = 1;');
    expect(result.code).toContain('const x = 1;');
    expect(result.map).toBeUndefined();
  });

  test('인터페이스 스트리핑', () => {
    const result = transpile('interface Foo { bar: string; }\nconst x = 1;');
    expect(result.code).not.toContain('interface');
    expect(result.code).toContain('const x = 1;');
  });

  test('타입 어노테이션 제거', () => {
    const result = transpile('function add(a: number, b: number): number { return a + b; }');
    expect(result.code).toContain('function add(a,b)');
    expect(result.code).not.toContain(': number');
  });

  test('enum 변환', () => {
    const result = transpile('enum Color { Red, Green, Blue }');
    expect(result.code).toContain('Color');
  });

  test('JSX 트랜스파일 (classic)', () => {
    const result = transpile('<div className="app">hello</div>', {
      filename: 'app.tsx',
      jsx: 'classic',
    });
    expect(result.code).toContain('React.createElement');
  });

  test('JSX 트랜스파일 (automatic)', () => {
    const result = transpile('<div className="app">hello</div>', {
      filename: 'app.tsx',
      jsx: 'automatic',
    });
    expect(result.code).toContain('jsx');
  });

  test('소스맵 생성', () => {
    const result = transpile('const x: number = 1;', { sourcemap: true });
    expect(result.code).toContain('const x = 1;');
    expect(result.map).toBeDefined();
    const map = JSON.parse(result.map!);
    expect(map.version).toBe(3);
    expect(map.mappings).toBeDefined();
  });

  test('minify', () => {
    const result = transpile('const   x: number   =   1;', {
      minifyWhitespace: true,
    });
    // 공백이 축소되어야 함
    expect(result.code.length).toBeLessThan('const   x   =   1;'.length);
  });

  test('CJS 포맷', () => {
    const result = transpile('export const x = 1; export default "hello";', {
      format: 'cjs',
    });
    expect(result.code).toContain('exports');
  });

  test('빈 소스 에러', () => {
    expect(() => transpile('')).toThrow();
  });

  test('빈 출력도 정상 반환 — TS 타입 전용 파일', () => {
    // `type Foo`/`declare`만 있으면 스트리핑 후 출력이 0바이트.
    // Zig 빈 slice의 `.ptr`이 sentinel이라 u64 packing + BigInt sign-extension 탓에
    // JS에서 outPtr=-1로 나타나 RangeError가 발생하던 회귀 방지.
    expect(transpile('type Foo = string;').code).toBe('');
    expect(transpile('declare const x: number;').code).toBe('');
    expect(transpile('import { foo } from "./bar";', { filename: 'a.ts' }).code).toBe('');
    // whitespace/comment-only 도 내용상 코드가 없음 → 빈 출력.
    expect(transpile('   \n\t').code).toBe('');
    expect(transpile('/* just a block comment */').code).toContain('/* just a block comment */');
  });

  test('파싱 에러', () => {
    // miette 스타일 렌더: "× <message> [ZNTC코드]"
    expect(() => transpile('const = ;')).toThrow(/\[ZNTC\d{4}\]/);
  });

  test('Flow 스트리핑', () => {
    const result = transpile('// @flow\nfunction foo(x: string): number { return 1; }', {
      flow: true,
      filename: 'test.js',
    });
    expect(result.code).not.toContain(': string');
    expect(result.code).not.toContain(': number');
  });

  test('drop console', () => {
    const result = transpile('console.log("hello"); const x = 1;', {
      dropConsole: true,
    });
    expect(result.code).not.toContain('console.log');
    expect(result.code).toContain('const x = 1;');
  });

  test('filename으로 확장자 감지 (.tsx)', () => {
    const result = transpile('const el = <div />;', { filename: 'comp.tsx' });
    expect(result.code).not.toContain('<div');
  });

  test('JSX 트랜스파일 (automatic-dev)', () => {
    const result = transpile('<div className="app">hello</div>', {
      filename: 'app.tsx',
      jsx: 'automatic-dev',
    });
    expect(result.code).toContain('jsxDEV');
  });

  test('minify 단축 옵션 (whitespace + identifiers + syntax)', () => {
    const result = transpile('const   longVariableName: number   =   1;', {
      minify: true,
    });
    expect(result.code.length).toBeLessThan('const longVariableName = 1;'.length);
  });

  test('drop debugger', () => {
    const result = transpile('debugger; const x = 1;', {
      dropDebugger: true,
    });
    expect(result.code).not.toContain('debugger');
    expect(result.code).toContain('const x = 1;');
  });

  test('quotes: single', () => {
    const result = transpile('const x = "hello";', { quotes: 'single' });
    expect(result.code).toContain("'hello'");
  });

  test('ascii only', () => {
    const result = transpile('const x = "한글";');
    const asciiResult = transpile('const x = "한글";', { asciiOnly: true });
    expect(asciiResult.code).toContain('\\u');
    expect(result.code).toContain('한글');
  });

  test('ES5 다운레벨링', () => {
    const result = transpile('const x = () => 1;', { target: 'es5' });
    expect(result.code).not.toContain('=>');
    expect(result.code).toContain('function');
  });

  test('ES2015 다운레벨링 (template literal)', () => {
    const result = transpile('const s = `hello ${name}`;', { target: 'es5' });
    expect(result.code).not.toContain('`');
  });

  test('target esnext (변환 없음)', () => {
    const result = transpile('const x = () => 1;', { target: 'esnext' });
    expect(result.code).toContain('=>');
  });

  test('platform node', () => {
    const result = transpile('const x: number = 1;', { platform: 'node' });
    expect(result.code).toContain('const x = 1;');
  });

  test('jsxFactory 커스텀', () => {
    const result = transpile('<div />', {
      filename: 'app.tsx',
      jsx: 'classic',
      jsxFactory: 'h',
    });
    expect(result.code).toContain('h(');
    expect(result.code).not.toContain('React.createElement');
  });

  test('jsxImportSource 커스텀', () => {
    const result = transpile('<div />', {
      filename: 'app.tsx',
      jsx: 'automatic',
      jsxImportSource: 'preact',
    });
    expect(result.code).toContain('preact');
  });

  test('useDefineForClassFields false', () => {
    const result = transpile('class A { x = 1; }', { useDefineForClassFields: false });
    expect(result.code).toContain('this.x');
  });

  test('initSync 중복 호출은 무시', () => {
    // 이미 초기화됨 — 에러 없이 무시되어야 함
    expect(() => initSync(new ArrayBuffer(0))).not.toThrow();
  });

  test('여러 번 호출해도 메모리 누수 없이 동작', () => {
    for (let i = 0; i < 100; i++) {
      const result = transpile(`const x${i}: number = ${i};`);
      expect(result.code).toContain(`const x${i} = ${i};`);
    }
  });
});

// VirtualFileSystem (#1885 Phase 2 PR 6-2b) — bundler 의 host fs 추상화.
// 단위 테스트는 pure JS (wasm 무관). bundler instance + zntc_fs callback 통합은 PR 6-2c.
describe('VirtualFileSystem', () => {
  test('set / get string content (utf-8 encoded)', () => {
    const vfs = new VirtualFileSystem();
    vfs.set('/index.ts', 'export const x = 1;');
    const data = vfs.get('/index.ts');
    expect(data).toBeDefined();
    expect(new TextDecoder().decode(data!)).toBe('export const x = 1;');
  });

  test('set / get Uint8Array content (binary 보존)', () => {
    const vfs = new VirtualFileSystem();
    const bytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47]); // PNG header
    vfs.set('/image.png', bytes);
    expect(vfs.get('/image.png')).toEqual(bytes);
  });

  test('has / delete / clear', () => {
    const vfs = new VirtualFileSystem();
    vfs.set('/a', '1');
    vfs.set('/b', '2');
    expect(vfs.has('/a')).toBe(true);
    expect(vfs.has('/c')).toBe(false);
    expect(vfs.size()).toBe(2);

    expect(vfs.delete('/a')).toBe(true);
    expect(vfs.delete('/a')).toBe(false);
    expect(vfs.size()).toBe(1);

    vfs.clear();
    expect(vfs.size()).toBe(0);
  });

  test('paths iterator', () => {
    const vfs = new VirtualFileSystem();
    vfs.set('/a.ts', '');
    vfs.set('/b.ts', '');
    vfs.set('/c.ts', '');
    const collected = [...vfs.paths()].sort();
    expect(collected).toEqual(['/a.ts', '/b.ts', '/c.ts']);
  });

  test('재set 시 덮어쓰기', () => {
    const vfs = new VirtualFileSystem();
    vfs.set('/x', 'first');
    vfs.set('/x', 'second');
    expect(new TextDecoder().decode(vfs.get('/x')!)).toBe('second');
    expect(vfs.size()).toBe(1);
  });

  // #4645 — 모듈 해석은 resolver 의 DirEntryCache 를 거치고, 그 캐시는 오직 listDir
  // 결과로만 채워진다. 여기가 비면 relative import 후보가 전부 "없음" 이 된다.
  test('listDir: 바로 아래 파일 + 합성된 하위 디렉토리', () => {
    const vfs = new VirtualFileSystem();
    vfs.set('/src/index.ts', '');
    vfs.set('/src/a.ts', '');
    vfs.set('/src/util/scale.ts', '');

    const entries = vfs.listDir('/src')!;
    expect(entries).not.toBeNull();
    const files = entries
      .filter((e) => e.kind === 0)
      .map((e) => e.name)
      .sort();
    const dirs = entries.filter((e) => e.kind === 1).map((e) => e.name);
    expect(files).toEqual(['a.ts', 'index.ts']);
    // util 은 등록된 적 없는 "합성" 디렉토리 — 경로 접두사로만 존재한다.
    expect(dirs).toEqual(['util']);
  });

  test('listDir: 루트 / 는 최상위 디렉토리를 합성', () => {
    const vfs = new VirtualFileSystem();
    vfs.set('/src/index.ts', '');
    expect(vfs.listDir('/')).toEqual([{ name: 'src', kind: 1 }]);
  });

  test('listDir: cwd 표기 (`.`) 는 선행 / 없는 경로를 본다', () => {
    const vfs = new VirtualFileSystem();
    vfs.set('index.ts', '');
    vfs.set('a.ts', '');
    const names = vfs
      .listDir('.')!
      .map((e) => e.name)
      .sort();
    expect(names).toEqual(['a.ts', 'index.ts']);
  });

  test('listDir: 존재하지 않는 디렉토리는 null (파일 경로도 null)', () => {
    const vfs = new VirtualFileSystem();
    vfs.set('/src/index.ts', '');
    expect(vfs.listDir('/nope')).toBeNull();
    expect(vfs.listDir('/src/index.ts')).toBeNull();
  });

  test('isDir: 등록된 경로가 함의하는 디렉토리만 true', () => {
    const vfs = new VirtualFileSystem();
    vfs.set('/src/util/scale.ts', '');
    expect(vfs.isDir('/src')).toBe(true);
    expect(vfs.isDir('/src/util')).toBe(true);
    expect(vfs.isDir('/')).toBe(true);
    // 파일 자신은 디렉토리가 아니다 — 접두사 오탐(`/src/util/scale.ts` startsWith) 방지.
    expect(vfs.isDir('/src/util/scale.ts')).toBe(false);
    expect(vfs.isDir('/nope')).toBe(false);
  });

  test('isDir: 이름이 겹치는 형제를 디렉토리로 오인하지 않는다', () => {
    const vfs = new VirtualFileSystem();
    vfs.set('/src/util.ts', '');
    // `/src/util` 로 시작하는 경로는 있지만 `/src/util/` 아래엔 아무것도 없다.
    expect(vfs.isDir('/src/util')).toBe(false);
  });
});

// PR 6-2c-2c — bundler.Bundler.init + bundle() 실 호출 + VFS round-trip.
// esm/browser 단일 entry. 출력은 단일 파일 모드 (result.output) — 모듈 wrap + TS strip.
// initBundler 는 첫 호출의 VFS 를 그대로 붙들기 때문에 (instance 당 1회) fixture 를
// 모듈 스코프에 둔다 — 이후 테스트가 파일을 추가해도 같은 VFS 를 본다.
const bundlerFixtureVfs = new VirtualFileSystem();

describe('Bundler (minimal)', () => {
  beforeAll(async () => {
    const wasmPath = join(import.meta.dir, '../../zig-out/bin/zntc-bundler.wasm');
    const wasmBytes = readFileSync(wasmPath);
    bundlerFixtureVfs.set('/index.ts', 'export const x = 42;');
    bundlerFixtureVfs.set('/utils.ts', 'export const greet = (n: string) => `hi ${n}`;');
    await initBundler(bundlerFixtureVfs, wasmBytes);
  });

  test('bundlerVersion = ABI v7 (에러 진단 시 부분 출력 미공개)', () => {
    expect(bundlerVersion()).toBe(7);
  });

  test('build: 단일 entry → bundle 코드 (TS 어노테이션 strip + 모듈 wrap)', () => {
    const result = build('/index.ts');
    expect(result).not.toBeNull();
    // 번들러는 entry 모듈을 wrap 해서 single bundle 로 emit.
    // 정확한 wrap 형식은 bundler 구현에 종속 — 핵심 시맨틱만 검증.
    expect(result?.code).toContain('const x = 42;');
    expect(result?.code).toContain('export { x }');
  });

  test('build: TS 어노테이션 (`: string`) 이 strip 됨', () => {
    const result = build('/utils.ts');
    expect(result).not.toBeNull();
    expect(result?.code).not.toContain(': string');
    expect(result?.code).toContain('greet');
    expect(result?.code).toContain('`hi ${n}`');
  });

  test('build: 존재하지 않는 entry → null', () => {
    const result = build('/nonexistent.ts');
    expect(result).toBeNull();
  });

  test('build: format=cjs 옵션 → CJS prologue (`use strict`) 추가', () => {
    const esmOut = build('/index.ts', { format: 'esm' });
    const cjsOut = build('/index.ts', { format: 'cjs' });
    expect(cjsOut).not.toBeNull();
    // CJS 모드는 `"use strict"` prologue 를 자동 추가 (esm 은 미추가).
    expect(cjsOut?.code).toContain('"use strict"');
    expect(esmOut?.code).not.toContain('"use strict"');
  });

  test('build: minifyWhitespace 옵션 → 공백 압축', () => {
    const baseline = build('/utils.ts');
    const minified = build('/utils.ts', { minifyWhitespace: true });
    expect(baseline).not.toBeNull();
    expect(minified).not.toBeNull();
    // 압축 시 baseline 보다 작거나 같음 (보통 작음).
    expect(minified!.code.length).toBeLessThan(baseline!.code.length);
  });

  test('build: minify shorthand → whitespace + identifiers + syntax 모두 활성', () => {
    const baseline = build('/utils.ts');
    const minified = build('/utils.ts', { minify: true });
    expect(minified).not.toBeNull();
    expect(minified!.code.length).toBeLessThan(baseline!.code.length);
  });

  test('build: 잘못된 옵션 값 (unknown format) → 무시 + 기본값 사용', () => {
    // Zig 측 parseFormat 가 unknown 이면 default (.esm) 유지.
    const result = build('/index.ts', { format: 'made-up' as any });
    expect(result).not.toBeNull();
    expect(result?.code).toContain('export { x }');
  });

  test('build: 미지원 옵션 필드 → ignore (forward compat)', () => {
    // ignore_unknown_fields=true 이라 신규 필드는 silent skip.
    const result = build('/index.ts', { someFutureOption: 42 } as any);
    expect(result).not.toBeNull();
  });

  test('buildChunks: 단일 entry → 한 개 chunk wrap', () => {
    const chunks = buildChunks('/index.ts');
    expect(chunks).not.toBeNull();
    expect(chunks!.length).toBe(1);
    expect(chunks![0].path).toBe('bundle.js');
    expect(chunks![0].code).toContain('const x = 42;');
  });

  test('buildChunks: 옵션 (format=cjs) 적용', () => {
    const chunks = buildChunks('/index.ts', { format: 'cjs' });
    expect(chunks).not.toBeNull();
    expect(chunks!.length).toBe(1);
    expect(chunks![0].code).toContain('"use strict"');
  });

  test('buildChunks: 존재하지 않는 entry → null + ZNTC 표준 진단 형식 에러', () => {
    const chunks = buildChunks('/nonexistent.ts');
    expect(chunks).toBeNull();
    const msg = bundlerLastErrorMessage();
    expect(msg.length).toBeGreaterThan(0);
    // 표준 형식: `× <message> [<tag>]` (+ optional `\n  hint: ...`)
    expect(msg.startsWith('×')).toBe(true);
    // 에러 종류: bundle 단계 실패 / 빈 출력 / unresolved import 중 하나.
    expect(msg).toMatch(/번들링 실패|nonexistent|빈 출력|ZNTC\d{4}/);
  });

  test('bundlerLastErrorMessage: 성공 호출 후엔 비어있음', () => {
    buildChunks('/index.ts'); // 성공
    expect(bundlerLastErrorMessage()).toBe('');
  });

  test('buildChunks: JSON escape — code 안의 특수 문자 round-trip', () => {
    // 출력에 quote / newline / backslash 가 들어가니 JSON escape 검증.
    const chunks = buildChunks('/utils.ts');
    expect(chunks).not.toBeNull();
    // utils.ts 의 template literal `hi ${n}` 가 그대로 출력에 — backtick / dollar / brace
    expect(chunks![0].code).toContain('`hi ${n}`');
    // newline 도 escape 안 깨지고 round-trip
    expect(chunks![0].code.split('\n').length).toBeGreaterThan(1);
  });

  test('build: target=es5 옵션 → 화살표 함수가 function 으로 다운레벨링', () => {
    // utils.ts 의 `(n) => ...` arrow 가 baseline (esnext) 에는 그대로,
    // es5 에선 function expression 으로 변환되어야 함.
    const baseline = build('/utils.ts');
    const downleveled = build('/utils.ts', { target: 'es5' });
    expect(baseline).not.toBeNull();
    expect(downleveled).not.toBeNull();
    expect(baseline?.code).toContain('=>');
    expect(downleveled?.code).not.toContain('=>');
    expect(downleveled?.code).toContain('function');
  });

  // #4645 — multi-file. 이전엔 entry 만 읽고 의존 모듈 해석 시도조차 없었다.
  test('build: 상대 import 를 재귀 해석해 의존 모듈을 번들에 포함', () => {
    bundlerFixtureVfs.set('/multi/dep.ts', 'export const foo = 42;');
    bundlerFixtureVfs.set('/multi/entry.ts', `export { foo } from './dep';`);
    const result = build('/multi/entry.ts');
    expect(result).not.toBeNull();
    // 값이 실제로 들어와야 한다 — export 이름만 남는 빈 껍데기가 아니라.
    expect(result?.code).toContain('const foo = 42;');
    expect(result?.code).toContain('export { foo }');
    expect(bundlerLastErrorMessage()).toBe('');
  });

  test('build: import + 재export 형태도 동일하게 해석', () => {
    bundlerFixtureVfs.set('/multi2/dep.ts', 'export const bar = 7;');
    bundlerFixtureVfs.set('/multi2/entry.ts', `import { bar } from './dep'; export { bar };`);
    const result = build('/multi2/entry.ts');
    expect(result?.code).toContain('const bar = 7;');
  });

  test('build: 하위 디렉토리 체인 (entry → 컴포넌트 → util) 전부 포함', () => {
    bundlerFixtureVfs.set('/chain/util/scale.ts', 'export const scale = (n: number) => n * 2;');
    bundlerFixtureVfs.set(
      '/chain/Button.tsx',
      `import { scale } from './util/scale';\nexport const Button = () => scale(21);`,
    );
    bundlerFixtureVfs.set('/chain/index.ts', `export { Button } from './Button';`);
    const result = build('/chain/index.ts');
    expect(result?.code).toContain('n * 2');
    expect(result?.code).toContain('scale(21)');
  });

  test('build: 디렉토리 import 는 index 파일로 해석', () => {
    bundlerFixtureVfs.set('/dirindex/lib/index.ts', 'export const q = 9;');
    bundlerFixtureVfs.set('/dirindex/entry.ts', `export { q } from './lib';`);
    const result = build('/dirindex/entry.ts');
    expect(result?.code).toContain('const q = 9;');
  });

  test('build: 확장자를 명시한 상대 import 도 해석', () => {
    bundlerFixtureVfs.set('/ext/dep.ts', 'export const e = 5;');
    bundlerFixtureVfs.set('/ext/entry.ts', `export { e } from './dep.ts';`);
    expect(build('/ext/entry.ts')?.code).toContain('const e = 5;');
  });

  test('build: 해석 불가 import → null + ZNTC0100 (부분 출력 미공개)', () => {
    bundlerFixtureVfs.set('/missing/entry.ts', `export { nope } from './does-not-exist';`);
    const result = build('/missing/entry.ts');
    // 부분 번들을 성공처럼 돌려주면 호출부가 실패를 감지할 수 없다.
    expect(result).toBeNull();
    const msg = bundlerLastErrorMessage();
    expect(msg).toContain('ZNTC0100');
    expect(msg).toContain('./does-not-exist');
  });

  test('buildChunks: 해석 불가 import → null (build 와 같은 계약)', () => {
    bundlerFixtureVfs.set('/missing2/entry.ts', `export { nope } from './gone';`);
    expect(buildChunks('/missing2/entry.ts')).toBeNull();
    expect(bundlerLastErrorMessage()).toContain('ZNTC0100');
  });

  test('buildChunks: codeSplitting → 동적 import 가 별도 chunk 로 분리', () => {
    bundlerFixtureVfs.set('/split/lazy.ts', 'export const lazy = 7;');
    bundlerFixtureVfs.set('/split/entry.ts', `export const go = () => import('./lazy');`);
    const chunks = buildChunks('/split/entry.ts', { codeSplitting: true });
    expect(chunks).not.toBeNull();
    expect(chunks!.length).toBe(2);
    expect(chunks!.some((c) => c.code.includes('const lazy = 7;'))).toBe(true);
  });

  test('build: jsxFactory 커스텀 옵션 적용', () => {
    // 임시로 JSX 파일 추가 — 그러나 globalVfs 가 모듈-수준이라 직접 set 안 됨.
    // utils.ts 에 JSX 가 없으니 jsx 옵션 효과 없음. 그래서 ABI smoke test 만 — 옵션
    // 전달이 에러 없이 처리되는지 확인.
    const result = build('/index.ts', {
      jsx: 'classic',
      jsxFactory: 'h',
      jsxFragment: 'Frag',
    });
    expect(result).not.toBeNull();
  });
});
