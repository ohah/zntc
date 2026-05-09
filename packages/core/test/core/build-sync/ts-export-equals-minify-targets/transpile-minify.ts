import { describe, expect, test, transpile } from '../helpers';

describe('@zntc/core buildSync - TS export equals transpile minify', () => {
  test('TS export = identifier (transpile + minify): export 식별자 보존, 다른 식별자만 mangle', () => {
    // transpile 모드 — 단일 파일이라 export 된 이름이 외부 require() 호출로 노출.
    // semantic analyzer 의 visitTsExportAssignment 가 inner identifier 를 export 로 mark
    // 해서 mangler 가 declaration 을 rename 하지 않는다 (export default 와 동일 보호).
    const r = transpile('class Box { v = 1; greet() { return this.v; } }\nexport = Box;', {
      filename: 'app.ts',
      minifyIdentifiers: true,
      minifyWhitespace: true,
    });
    expect(r.errors).toBeUndefined();
    expect(r.code).toContain('class Box');
    expect(r.code).toContain('module.exports=Box');
  });

  test('TS export = function (transpile + minify): export 식별자 보존, helper 식별자 mangle', () => {
    const r = transpile(
      'function add(a: number, b: number) { return a + b; }\nconst helper = (x: number) => x * 2;\nexport = add;',
      { filename: 'app.ts', minifyIdentifiers: true, minifyWhitespace: true },
    );
    expect(r.errors).toBeUndefined();
    expect(r.code).toContain('function add');
    expect(r.code).toContain('module.exports=add');
    // helper 식별자는 다른 곳에서 참조되지 않으므로 mangle 됨.
    expect(r.code).not.toContain('const helper');
  });
});
