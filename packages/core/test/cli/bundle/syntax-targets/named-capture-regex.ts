import {
  describe,
  test,
  expect,
  execSync,
  mkdtempSync,
  writeFileSync,
  rmSync,
  tmpdir,
  join,
  runCli,
} from '../../helpers';

// #1063: Hermes / ES5 target 에서 named capture group `(?<NAME>...)` 다운레벨.
// regex pattern strip + `__wrapRegExp` 로 wrap → `match.groups.NAME` /
// `replace(re, "$<NAME>")` semantic 보존.
describe('CLI: bundle syntax and targets > named capture regex (#1063)', () => {
  test('--target=es5 → 패턴 strip + __wrapRegExp wrap + helper inject', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-named-cap-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        'const re = /(?<year>\\d{4})/; const m = re.exec("2026"); console.log(m?.groups?.year);',
      );
      const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts'), '--target=es5']);
      expect(exitCode).toBe(0);
      // pattern 자체엔 named group 안 남음
      expect(stdout).not.toContain('(?<year>');
      // wrap helper 호출이 들어감
      expect(stdout).toContain('__wrapRegExp');
      // helper 정의도 inject (RegExp 상속 클래스)
      expect(stdout).toContain('BabelRegExp');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('--target=es5 + --minify → short helper name ($wR) 일관 사용', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-named-cap-min-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        'const re = /(?<word>\\w+)/; console.log(re.exec("hi")?.groups?.word);',
      );
      const { stdout, exitCode } = runCli([
        '--bundle',
        join(dir, 'entry.ts'),
        '--target=es5',
        '--minify',
      ]);
      expect(exitCode).toBe(0);
      // minify 시 short name $wR 사용 — base name __wrapRegExp 는 안 보여야 (inject + 사용처 모두 short)
      expect(stdout).toContain('$wR');
      expect(stdout).not.toContain('__wrapRegExp');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('named group 없으면 wrap 호출 없음 (불필요 helper inject 회피)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-named-cap-none-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), 'const re = /(\\d+)/; console.log(re.test("123"));');
      const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts'), '--target=es5']);
      expect(exitCode).toBe(0);
      expect(stdout).not.toContain('__wrapRegExp');
      expect(stdout).not.toContain('BabelRegExp');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('lookbehind (?<=...) 만 있으면 wrap 안 함 (named capture 아님)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-lookbehind-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        'const re = /(?<=foo)bar/; console.log(re.test("foobar"));',
      );
      const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts'), '--target=es5']);
      expect(exitCode).toBe(0);
      expect(stdout).not.toContain('__wrapRegExp');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('--target=es2018 (named capture 지원) → strip 안 함', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-es2018-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        'const re = /(?<year>\\d{4})/; console.log(re.exec("2026")?.groups?.year);',
      );
      const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts'), '--target=es2018']);
      expect(exitCode).toBe(0);
      // ES2018 은 named capture 네이티브 지원 — 변환 없음
      expect(stdout).toContain('(?<year>');
      expect(stdout).not.toContain('__wrapRegExp');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

// __wrapRegExp helper runtime semantic — Babel `_wrapRegExp` 와 동일 코드라 동등 동작 보장.
// transpile + Node 로 실제 실행해서 결과 검증. 회귀 발생 시 이 case 들이 fail.
// reference: babel/packages/babel-runtime/test/unittests/wrapRegExp.test.js
describe('CLI: named capture regex (#1063) > runtime semantic (Babel parity)', () => {
  function buildAndRun(entrySource: string): string {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-wrapregex-rt-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), entrySource);
      const out = join(dir, 'out.js');
      const { exitCode } = runCli(['--bundle', join(dir, 'entry.ts'), '-o', out, '--target=es5']);
      expect(exitCode).toBe(0);
      return execSync(`node ${out}`, { encoding: 'utf8' }).trim();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }

  test('$<UNKNOWN> — 등록 안 된 group 은 empty 로 substitute', () => {
    const result = buildAndRun(
      'const re = /(?<group>foo)/;\n' + 'console.log("foobar".replace(re, "$<UNKNOWN>"));',
    );
    // foo 가 매칭, $<UNKNOWN> 은 empty → "foo" 가 "" 로 대체
    expect(result).toBe('bar');
  });

  test('$<__proto__> — prototype pollution 방어 (groups map 이 Object.create(null))', () => {
    const result = buildAndRun(
      'const re = /(?<group>foo)/;\n' + 'console.log("foobar".replace(re, "$<__proto__>"));',
    );
    // __proto__ 는 groups 에 등록 안 됨 → empty substitute → "foo" 제거 → "bar"
    expect(result).toBe('bar');
  });

  test('$<hasOwnProperty> — reserved name 도 일반 group 처럼 처리', () => {
    const result = buildAndRun(
      'const re = /(?<group>foo)/;\n' + 'console.log("foobar".replace(re, "$<hasOwnProperty>"));',
    );
    // hasOwnProperty 도 groups 에 없음 → empty → "bar"
    expect(result).toBe('bar');
  });

  test('$<_$> — 특수 문자 group name 정상 substitute', () => {
    const result = buildAndRun(
      'const re = /(?<_$>foo)/;\n' + 'console.log("foobar".replace(re, "$<_$>$<_$>"));',
    );
    // _$ 가 등록된 group → 두 번 치환 → "foofoobar"
    expect(result).toBe('foofoobar');
  });
});
