import {
  describe,
  test,
  expect,
  mkdtempSync,
  writeFileSync,
  rmSync,
  mkdirSync,
  tmpdir,
  join,
  runCli,
} from './helpers';

describe('CLI: tsconfig', () => {
  test('tsconfig.json에서 experimentalDecorators 자동 로드', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-tsconfig-'));
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: { experimentalDecorators: true },
      }),
    );
    writeFileSync(
      join(dir, 'input.ts'),
      '@sealed\nclass Greeter {\n  greeting: string;\n  constructor(message: string) { this.greeting = message; }\n}',
    );

    const { stdout, exitCode } = runCli([join(dir, 'input.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('__decorate');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig.json에서 jsx 자동 로드', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-tsconfig-jsx-'));
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: { jsx: 'react-jsx' },
      }),
    );
    writeFileSync(join(dir, 'app.tsx'), 'export default () => <div>hello</div>;');

    const { stdout, exitCode } = runCli([join(dir, 'app.tsx')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('jsx');
    rmSync(dir, { recursive: true, force: true });
  });

  test('--project로 명시적 tsconfig 경로', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-project-'));
    const configDir = mkdtempSync(join(tmpdir(), 'zntc-cli-config-'));
    writeFileSync(
      join(configDir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: { experimentalDecorators: true },
      }),
    );
    writeFileSync(
      join(dir, 'input.ts'),
      '@sealed\nclass Greeter { greeting: string; constructor(m: string) { this.greeting = m; } }',
    );

    const { stdout, exitCode } = runCli([
      join(dir, 'input.ts'),
      '-p',
      join(configDir, 'tsconfig.json'),
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('__decorate');
    rmSync(dir, { recursive: true, force: true });
    rmSync(configDir, { recursive: true, force: true });
  });

  test('--tsconfig-path 는 -p 의 alias (NAPI `tsconfigPath` 와 통일된 이름)', () => {
    // 공백/=형 모두, 디렉토리/파일 경로 모두 지원.
    const configDir = mkdtempSync(join(tmpdir(), 'zntc-cli-tsc-alias-'));
    writeFileSync(
      join(configDir, 'tsconfig.json'),
      JSON.stringify({ compilerOptions: { verbatimModuleSyntax: true } }),
    );
    const inputPath = join(configDir, 'input.ts');
    writeFileSync(inputPath, 'import { foo } from "./bar";');

    for (const args of [
      ['--tsconfig-path', configDir],
      [`--tsconfig-path=${configDir}`],
      ['--tsconfig-path', join(configDir, 'tsconfig.json')],
      ['-p', join(configDir, 'tsconfig.json')], // -p 도 파일 경로 지원 (loadFromPath 전환)
    ]) {
      const { stdout, exitCode } = runCli([inputPath, ...args]);
      expect(exitCode).toBe(0);
      // verbatimModuleSyntax 가 적용되면 미사용 import 도 보존
      expect(stdout).toContain('./bar');
    }
    rmSync(configDir, { recursive: true, force: true });
  });

  test('CLI 옵션이 tsconfig보다 우선', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-override-'));
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: { jsx: 'react' }, // classic
      }),
    );
    writeFileSync(join(dir, 'app.tsx'), 'export default () => <div>hello</div>;');

    // --jsx=automatic으로 오버라이드
    const { stdout, exitCode } = runCli([join(dir, 'app.tsx'), '--jsx=automatic']);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('jsx'); // automatic이면 import 문 생성
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig.json에 주석이 있어도 파싱 성공', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-tsconfig-comments-'));
    writeFileSync(
      join(dir, 'tsconfig.json'),
      `{
  // 이것은 주석입니다
  "compilerOptions": {
    /* 블록 주석 */
    "experimentalDecorators": true
  }
}`,
    );
    writeFileSync(
      join(dir, 'input.ts'),
      '@sealed\nclass G { x: string; constructor(m: string) { this.x = m; } }',
    );

    const { stdout, exitCode } = runCli([join(dir, 'input.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('__decorate');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig.json 없으면 무시 (에러 없음)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-no-tsconfig-'));
    writeFileSync(join(dir, 'input.ts'), 'const x: number = 1;');

    const { stdout, exitCode } = runCli([join(dir, 'input.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('const x = 1');
    rmSync(dir, { recursive: true, force: true });
  });

  test('useDefineForClassFields=false tsconfig 로드', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-define-fields-'));
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: { useDefineForClassFields: false },
      }),
    );
    writeFileSync(join(dir, 'input.ts'), 'class A { x = 1; }');

    const { stdout, exitCode } = runCli([join(dir, 'input.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('this.x');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig에 URL이 포함된 문자열이 있어도 파싱 성공', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-tsconfig-url-'));
    writeFileSync(
      join(dir, 'tsconfig.json'),
      `{
  // tsconfig with URL in value
  "compilerOptions": {
    "experimentalDecorators": true,
    "baseUrl": "https://example.com/path"
  }
}`,
    );
    writeFileSync(
      join(dir, 'input.ts'),
      '@sealed\nclass G { x: string; constructor(m: string) { this.x = m; } }',
    );

    const { stdout, exitCode } = runCli([join(dir, 'input.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('__decorate');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig paths: wildcard + exact alias 가 bundler 에서 해석됨', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-tsc-paths-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: {
          baseUrl: '.',
          paths: {
            '@/*': ['./src/*'],
            '@utils': ['./src/utils.ts'],
          },
        },
      }),
    );
    writeFileSync(
      join(dir, 'src', 'utils.ts'),
      'export function hello(name: string): string { return `Hello, ${name}!`; }',
    );
    writeFileSync(join(dir, 'src', 'greet.ts'), "export function greet(): string { return 'hi'; }");
    writeFileSync(
      join(dir, 'entry.ts'),
      'import { hello } from "@utils";\nimport { greet } from "@/greet";\nconsole.log(hello("world"), greet());',
    );
    const { stdout, exitCode } = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
    expect(exitCode).toBe(0);
    // 두 파일이 모두 번들에 들어와야 함 (paths 가 해석되지 않으면 resolve 실패로 번들 실패).
    expect(stdout).toContain('Hello, ${name}!');
    expect(stdout).toContain(`return "hi"`);
    rmSync(dir, { recursive: true, force: true });
  });

  test('--alias 가 tsconfig paths 를 덮어씀', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-alias-priority-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    mkdirSync(join(dir, 'alt'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: { paths: { '@utils': ['./src/utils.ts'] } },
      }),
    );
    writeFileSync(
      join(dir, 'src', 'utils.ts'),
      "export function hello(): string { return 'FROM_TSCONFIG'; }",
    );
    writeFileSync(
      join(dir, 'alt', 'utils.ts'),
      "export function hello(): string { return 'FROM_ALIAS_CLI'; }",
    );
    writeFileSync(join(dir, 'entry.ts'), 'import { hello } from "@utils";\nconsole.log(hello());');

    // --alias 없으면 tsconfig 값 적용
    const withoutAlias = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
    expect(withoutAlias.exitCode).toBe(0);
    expect(withoutAlias.stdout).toContain('FROM_TSCONFIG');

    // --alias 가 붙으면 그 값이 tsconfig 를 덮어씀 (CLI > tsconfig)
    const withAlias = runCli([
      '--bundle',
      '-p',
      dir,
      `--alias:@utils=${join(dir, 'alt', 'utils.ts')}`,
      join(dir, 'entry.ts'),
    ]);
    expect(withAlias.exitCode).toBe(0);
    expect(withAlias.stdout).toContain('FROM_ALIAS_CLI');
    expect(withAlias.stdout).not.toContain('FROM_TSCONFIG');

    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig paths: 깊은 서브경로 prefix 매칭 (@/a/b/c)', () => {
    // "@/*" alias 가 중첩 디렉토리까지 정상 전파되는지 — applyAlias 의 prefix 로직 검증.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-deep-'));
    mkdirSync(join(dir, 'src', 'a', 'b'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({ compilerOptions: { baseUrl: '.', paths: { '@/*': ['./src/*'] } } }),
    );
    writeFileSync(join(dir, 'src', 'a', 'b', 'c.ts'), "export const V = 'DEEP_OK';");
    writeFileSync(join(dir, 'entry.ts'), 'import { V } from "@/a/b/c";\nconsole.log(V);');
    const { stdout, exitCode } = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('DEEP_OK');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig paths: baseUrl 없으면 tsconfig 디렉토리가 기본 base', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-nobase-'));
    mkdirSync(join(dir, 'lib'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({ compilerOptions: { paths: { '#lib': ['./lib/index.ts'] } } }),
    );
    writeFileSync(join(dir, 'lib', 'index.ts'), "export const L = 'NOBASE_OK';");
    writeFileSync(join(dir, 'entry.ts'), 'import { L } from "#lib";\nconsole.log(L);');
    const { stdout, exitCode } = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('NOBASE_OK');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig paths: 배열 여러 후보 중 첫 번째만 사용 (v1 제약)', () => {
    // TS 공식은 순차 시도이나 ZNTC v1 은 단일 — 첫 번째가 없어도 fallback 안 함을 문서화.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-multi-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: { paths: { '@m': ['./src/a.ts', './src/b.ts'] } },
      }),
    );
    writeFileSync(join(dir, 'src', 'a.ts'), "export const M = 'FIRST';");
    writeFileSync(join(dir, 'src', 'b.ts'), "export const M = 'SECOND';");
    writeFileSync(join(dir, 'entry.ts'), 'import { M } from "@m";\nconsole.log(M);');
    const { stdout, exitCode } = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('FIRST');
    expect(stdout).not.toContain('SECOND');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig paths: 빈 paths 객체는 무시 (no crash)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-empty-'));
    writeFileSync(join(dir, 'tsconfig.json'), JSON.stringify({ compilerOptions: { paths: {} } }));
    writeFileSync(join(dir, 'entry.ts'), "console.log('OK');");
    const { stdout, exitCode } = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('OK');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig paths: extends 체인에서 paths 상속', () => {
    // base tsconfig 의 paths 를 child 가 상속받는지 — mergeFrom 경로 검증.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-extends-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.base.json'),
      JSON.stringify({ compilerOptions: { paths: { '@base': ['./src/base.ts'] } } }),
    );
    writeFileSync(join(dir, 'tsconfig.json'), JSON.stringify({ extends: './tsconfig.base.json' }));
    writeFileSync(join(dir, 'src', 'base.ts'), "export const B = 'EXTENDED';");
    writeFileSync(join(dir, 'entry.ts'), 'import { B } from "@base";\nconsole.log(B);');
    const { stdout, exitCode } = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('EXTENDED');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig paths: 존재하지 않는 tsconfig 경로 → silent fallback (no crash)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-missing-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('OK');");
    const { stdout, exitCode } = runCli([
      '--bundle',
      '-p',
      '/nonexistent/path/tsconfig.json',
      join(dir, 'entry.ts'),
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('OK');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig paths: 자동 발견 — entry 상위 디렉토리에서 tsconfig.json 탐색', () => {
    // `-p` 없이도 entry 가 깊은 서브디렉토리에 있으면 상위로 올라가며 tsconfig.json 을 찾는다.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-auto-discover-'));
    mkdirSync(join(dir, 'src', 'deep'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({ compilerOptions: { baseUrl: '.', paths: { '@/*': ['./src/*'] } } }),
    );
    writeFileSync(join(dir, 'src', 'utils.ts'), "export function hello() { return 'AUTO_OK'; }");
    writeFileSync(
      join(dir, 'src', 'deep', 'entry.ts'),
      'import { hello } from "@/utils";\nconsole.log(hello());',
    );
    // `-p` 없이 실행
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'src', 'deep', 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('AUTO_OK');
    rmSync(dir, { recursive: true, force: true });
  });

  test("tsconfig paths: 이중 '*' key 또는 비대칭 wildcard 는 경고 + skip", () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-warn-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: {
          paths: {
            '@bad/**/y': ['./src/x.ts'], // key 에 '*' 두 개 → ts(5073) 스킵
            '@mix/*': ['./src/plain.ts'], // key wildcard + target 비wildcard → ts(5063) 스킵
            '@ok/*': ['./src/*'], // 유효
          },
        },
      }),
    );
    writeFileSync(join(dir, 'src', 'hello.ts'), "export const H = 'ok_valid';");
    writeFileSync(join(dir, 'entry.ts'), 'import { H } from "@ok/hello";\nconsole.log(H);');
    const { stdout, stderr, exitCode } = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('ok_valid');
    // 잘못된 entry 2 건은 경고 로그 — stderr 에 키워드 포함되는지 확인.
    expect(stderr).toContain('5073');
    expect(stderr).toContain('5063');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig paths: 중간 wildcard (@pkg/*/types)', () => {
    // TS 공식 스펙: `*` 가 key 중간에 있으면 해당 위치의 세그먼트가 capture 되어 target 에 대입.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-mid-wild-'));
    mkdirSync(join(dir, 'packages/foo/src'), { recursive: true });
    mkdirSync(join(dir, 'packages/bar/src'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: { paths: { '@pkg/*/types': ['./packages/*/src/types.ts'] } },
      }),
    );
    writeFileSync(join(dir, 'packages/foo/src/types.ts'), "export const T = 'FOO_TYPES';");
    writeFileSync(join(dir, 'packages/bar/src/types.ts'), "export const T = 'BAR_TYPES';");
    writeFileSync(
      join(dir, 'entry.ts'),
      'import { T as F } from "@pkg/foo/types";\nimport { T as B } from "@pkg/bar/types";\nconsole.log(F, B);',
    );
    const { stdout, exitCode } = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('FOO_TYPES');
    expect(stdout).toContain('BAR_TYPES');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig paths: 다중 후보 순차 fallback (첫 번째 실패 시 두 번째)', () => {
    // TS 공식 스펙: value 배열은 순서대로 시도. 첫 후보가 파일로 존재 안 하면 다음 후보로.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-multi-cand-'));
    mkdirSync(join(dir, 'vendor'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: {
          paths: { '@lib': ['./does-not-exist.ts', './vendor/lib.ts'] },
        },
      }),
    );
    writeFileSync(join(dir, 'vendor/lib.ts'), "export const L = 'FALLBACK_OK';");
    writeFileSync(join(dir, 'entry.ts'), 'import { L } from "@lib";\nconsole.log(L);');
    const { stdout, exitCode } = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('FALLBACK_OK');
    rmSync(dir, { recursive: true, force: true });
  });

  test("tsconfig paths: .js extension 매핑 — '@util' → './src/util.ts'", () => {
    // tsconfig 값이 ./src/util.ts 인데 source 가 ./src/util.js 로 import 해도
    // resolver 의 TS extension mapping 이 동작해야 함 (pre-existing 기능, 회귀 방지).
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-ext-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({ compilerOptions: { paths: { '@util': ['./src/util'] } } }),
    );
    writeFileSync(join(dir, 'src', 'util.ts'), "export const U = 'EXT_OK';");
    writeFileSync(join(dir, 'entry.ts'), 'import { U } from "@util";\nconsole.log(U);');
    const { stdout, exitCode } = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('EXT_OK');
    rmSync(dir, { recursive: true, force: true });
  });
});

// ─── zntc.config.{ts,json} 자동 탐색 + BuildOptions 머지 (#2099 / #2101) ───
