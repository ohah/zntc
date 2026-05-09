import {
  buildSync,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';

describe('@zntc/core buildSync - TS export equals ES5 targets', () => {
  test('TS export = class + target=es5: 다운레벨링과 export = 호환', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-export-equals-es5-class-'));
    try {
      writeFileSync(join(dir, 'app.ts'), "class Foo { greet() { return 'hi'; } }\nexport = Foo;");
      const result = buildSync({ entryPoints: [join(dir, 'app.ts')], target: 'es5' });
      expect(result.errors.length).toBe(0);
      const out = result.outputFiles[0].text;
      expect(out).toContain('module.exports');
      expect(out).toContain('Foo');
      expect(out).not.toContain('class Foo');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('TS export = async function + target=es5: __async helper 와 함께 lower', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-export-equals-es5-async-'));
    try {
      writeFileSync(join(dir, 'app.ts'), 'export = async function () { return 42; };');
      const result = buildSync({ entryPoints: [join(dir, 'app.ts')], target: 'es5' });
      expect(result.errors.length).toBe(0);
      const out = result.outputFiles[0].text;
      expect(out).toContain('module.exports');
      expect(out).not.toContain('async function');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('TS export = arrow + target=es5: 화살표가 function expression 으로 lower', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-export-equals-es5-arrow-'));
    try {
      writeFileSync(join(dir, 'app.ts'), 'export = (x: number) => x * 2;');
      const result = buildSync({ entryPoints: [join(dir, 'app.ts')], target: 'es5' });
      expect(result.errors.length).toBe(0);
      const out = result.outputFiles[0].text;
      expect(out).toContain('module.exports');
      // bundler 의 __commonJS 헬퍼 자체는 arrow — user-side 만 정확히 변환됐는지 확인.
      expect(out).toMatch(/module\.exports\s*=\s*function/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
