import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  buildCssModuleProxy,
  collectCssModuleClasses,
  cssModuleGeneratedCssPath,
  cssModuleLocalName,
  cssModuleProxyPath,
  isCssModuleFile,
  isValidExportName,
  rewriteCssModuleClasses,
  rewriteCssModuleReferences,
  scanCssModuleClassTokens,
  transformCssModules,
} from './css-modules.ts';

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'zntc-cssmod-'));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function touch(rel: string, content = ''): string {
  const path = join(dir, rel);
  mkdirSync(join(path, '..'), { recursive: true });
  writeFileSync(path, content);
  return path;
}

describe('isCssModuleFile', () => {
  test('.module.css 만 true', () => {
    expect(isCssModuleFile('a.module.css')).toBe(true);
    expect(isCssModuleFile('/abs/path/styles.module.css')).toBe(true);
  });

  test('일반 .css 는 false', () => {
    expect(isCssModuleFile('a.css')).toBe(false);
    expect(isCssModuleFile('module.css')).toBe(false);
  });

  test('.module.scss 는 false (preprocessor — sass 영역)', () => {
    expect(isCssModuleFile('a.module.scss')).toBe(false);
  });
});

describe('cssModuleGeneratedCssPath', () => {
  test('.module.css → .module.zntc.css', () => {
    expect(cssModuleGeneratedCssPath('a.module.css')).toBe('a.module.zntc.css');
    expect(cssModuleGeneratedCssPath('/x/styles.module.css')).toBe('/x/styles.module.zntc.css');
  });
});

describe('cssModuleProxyPath', () => {
  test('.js suffix', () => {
    expect(cssModuleProxyPath('a.module.css')).toBe('a.module.css.js');
  });
});

describe('cssModuleLocalName', () => {
  test('`${fileName}_${local}__${hash8}` 형식', () => {
    const name = cssModuleLocalName('/root', '/root/sub/x.module.css', 'btn');
    expect(name).toMatch(/^x_btn__[A-Za-z0-9_-]{8}$/);
  });

  test('같은 (root, file, local) → 결정적', () => {
    const a = cssModuleLocalName('/root', '/root/x.module.css', 'btn');
    const b = cssModuleLocalName('/root', '/root/x.module.css', 'btn');
    expect(a).toBe(b);
  });

  test('다른 file 은 다른 hash', () => {
    const a = cssModuleLocalName('/root', '/root/a.module.css', 'btn');
    const b = cssModuleLocalName('/root', '/root/b.module.css', 'btn');
    expect(a).not.toBe(b);
  });

  test('invalid identifier char 는 _ 로 치환', () => {
    const name = cssModuleLocalName('/root', '/root/my-file.module.css', 'btn-primary');
    expect(name).toMatch(/^my_file_btn_primary__/);
  });
});

describe('scanCssModuleClassTokens', () => {
  test('일반 .class 토큰 추출', () => {
    const tokens = scanCssModuleClassTokens('.btn { color: red; } .card-x {}');
    expect(tokens.map((t) => t.local)).toEqual(['btn', 'card-x']);
  });

  test('string 안의 . 은 skip', () => {
    const tokens = scanCssModuleClassTokens('.btn { content: ".not-a-class"; }');
    expect(tokens.map((t) => t.local)).toEqual(['btn']);
  });

  test('comment 안의 . 은 skip', () => {
    const tokens = scanCssModuleClassTokens('.btn { /* .ignored */ color: red; }');
    expect(tokens.map((t) => t.local)).toEqual(['btn']);
  });

  test('url() 안의 quote 도 정상 skip', () => {
    const tokens = scanCssModuleClassTokens('.bg { background: url(./img.png); } .btn {}');
    expect(tokens.map((t) => t.local)).toEqual(['bg', 'btn']);
  });

  test('토큰 위치 (start/end) 정확', () => {
    const css = '.a {}';
    const [t] = scanCssModuleClassTokens(css);
    expect(t).toEqual({ start: 0, end: 2, local: 'a' });
  });
});

describe('collectCssModuleClasses', () => {
  test('중복 제거 후 unique 이름만', () => {
    expect(collectCssModuleClasses('.btn { } .btn:hover { }').sort()).toEqual(['btn']);
    expect(collectCssModuleClasses('.a, .b { } .a {}').sort()).toEqual(['a', 'b']);
  });
});

describe('rewriteCssModuleClasses', () => {
  test('mapping 적용', () => {
    const css = '.btn { color: red; }';
    expect(rewriteCssModuleClasses(css, { btn: 'btn__h1' })).toBe('.btn__h1 { color: red; }');
  });

  test('mapping 없는 class 는 원본 유지', () => {
    const css = '.btn { } .other { }';
    expect(rewriteCssModuleClasses(css, { btn: 'btn__h1' })).toBe('.btn__h1 { } .other { }');
  });

  test('string/comment 안의 . 은 영향 X', () => {
    const css = '.btn { content: ".btn"; /* .btn */ }';
    expect(rewriteCssModuleClasses(css, { btn: 'btn__h1' })).toBe(
      '.btn__h1 { content: ".btn"; /* .btn */ }',
    );
  });
});

describe('isValidExportName', () => {
  test('valid identifier → true', () => {
    expect(isValidExportName('button')).toBe(true);
    expect(isValidExportName('$btn')).toBe(true);
    expect(isValidExportName('_internal')).toBe(true);
    expect(isValidExportName('camelCase')).toBe(true);
  });

  test('invalid identifier → false', () => {
    expect(isValidExportName('btn-primary')).toBe(false); // hyphen
    expect(isValidExportName('123btn')).toBe(false); // 숫자 시작
    expect(isValidExportName('')).toBe(false);
    expect(isValidExportName('with space')).toBe(false);
  });

  test('JS keyword reserved → false', () => {
    expect(isValidExportName('class')).toBe(false);
    expect(isValidExportName('default')).toBe(false);
    expect(isValidExportName('import')).toBe(false);
    expect(isValidExportName('export')).toBe(false);
    expect(isValidExportName('const')).toBe(false);
    expect(isValidExportName('function')).toBe(false);
  });
});

describe('buildCssModuleProxy', () => {
  test('default export + named export 생성', () => {
    const proxy = buildCssModuleProxy('/x/a.module.zntc.css', {
      btn: 'btn__h1',
      card: 'card__h2',
    });
    expect(proxy).toContain(`import "./a.module.zntc.css";`);
    expect(proxy).toContain(`const styles = {"btn":"btn__h1","card":"card__h2"};`);
    expect(proxy).toContain(`export default styles;`);
    expect(proxy).toContain(`export const btn = "btn__h1";`);
    expect(proxy).toContain(`export const card = "card__h2";`);
  });

  test('invalid identifier 는 named export 안 함', () => {
    const proxy = buildCssModuleProxy('/x/a.module.zntc.css', {
      'btn-primary': 'x__h1',
    });
    expect(proxy).not.toContain('export const btn-primary');
    // default export 의 styles 안에는 여전히 포함.
    expect(proxy).toContain(`"btn-primary"`);
  });

  test('JS keyword 도 named export 제외', () => {
    const proxy = buildCssModuleProxy('/x/a.module.zntc.css', { class: 'x' });
    expect(proxy).not.toContain('export const class');
  });
});

describe('rewriteCssModuleReferences', () => {
  test('import "x.module.css" → "x.module.css.js"', () => {
    const path = touch('entry.ts', `import "./styles.module.css";\n`);
    rewriteCssModuleReferences([path]);
    expect(readFileSync(path, 'utf8')).toBe(`import "./styles.module.css.js";\n`);
  });

  test('HTML 의 link 는 skip (.module.css 도 일반 CSS 로 취급)', () => {
    const original = `<link href="./x.module.css">`;
    const path = touch('index.html', original);
    rewriteCssModuleReferences([path]);
    expect(readFileSync(path, 'utf8')).toBe(original);
  });

  test('query/fragment suffix 보존', () => {
    const path = touch('entry.ts', `import "./a.module.css?inline";`);
    rewriteCssModuleReferences([path]);
    expect(readFileSync(path, 'utf8')).toBe(`import "./a.module.css.js?inline";`);
  });

  test('.module.css 가 없는 파일은 변경 없음', () => {
    const original = `import "./a.css";`;
    const path = touch('entry.ts', original);
    rewriteCssModuleReferences([path]);
    expect(readFileSync(path, 'utf8')).toBe(original);
  });

  test('작은따옴표 import 도 정상 처리', () => {
    const path = touch('entry.ts', `import './x.module.css';`);
    rewriteCssModuleReferences([path]);
    expect(readFileSync(path, 'utf8')).toBe(`import './x.module.css.js';`);
  });
});

// a1-#2 (RFC #3833): plain `{}` 의 prototype shadowing 가드.
// `.constructor` / `.toString` / `.__proto__` / `.hasOwnProperty` 같은
// Object.prototype 메서드 이름이 CSS class 로 쓰일 시, mapping = {} 의 lookup
// 이 native function 반환 → `if (!mapping[token.local])` truthy → 매핑 누락 +
// rewrite 가 native fn 을 stringify 해 CSS 에 garbage 삽입.
// fix: `Object.create(null)` 로 prototype-less mapping. lookup 안전.
describe('transformCssModules — prototype-shadowing class name (a1-#2 가드)', () => {
  function makeFixture(filename: string, css: string): { root: string; file: string } {
    const file = join(dir, filename);
    writeFileSync(file, css);
    return { root: dir, file };
  }

  test('class name `.constructor` 도 정상 scoping (prototype shadowing 회귀 가드)', () => {
    const { root, file } = makeFixture(
      'a.module.css',
      '.constructor { color: red; }\n.toString { color: blue; }\n.regular { color: green; }',
    );
    transformCssModules(root, [file], [], 'silent');

    // generated .module.zntc.css 에 scoped 클래스가 모두 있어야 (native fn stringify 가 아니라)
    const generated = readFileSync(file.replace(/\.module\.css$/, '.module.zntc.css'), 'utf8');
    expect(generated).toMatch(/\.a_constructor__[A-Za-z0-9_-]{8}/);
    expect(generated).toMatch(/\.a_toString__[A-Za-z0-9_-]{8}/);
    expect(generated).toMatch(/\.a_regular__[A-Za-z0-9_-]{8}/);
    // native fn stringify garbage 없음
    expect(generated).not.toMatch(/native code|function Object|function toString/);

    // proxy module 의 default mapping 에 prototype-shadowing 키도 own property 로 포함
    const proxy = readFileSync(`${file}.js`, 'utf8');
    expect(proxy).toContain('"constructor"');
    expect(proxy).toContain('"toString"');
    expect(proxy).toContain('"regular"');
  });

  test('class name `.__proto__` / `.hasOwnProperty` 도 정상 (다른 prototype-shadowing 케이스)', () => {
    const { root, file } = makeFixture(
      'b.module.css',
      '.__proto__ { color: red; }\n.hasOwnProperty { color: blue; }',
    );
    transformCssModules(root, [file], [], 'silent');

    const generated = readFileSync(file.replace(/\.module\.css$/, '.module.zntc.css'), 'utf8');
    // __proto__ 는 sha hash 가 다른 형식. SAFE_LOCAL_RE 가 _ 로 치환하지 않음 (alnum + _ 라).
    // 따라서 fileName_local__hash 가 fileName___proto____hash 가 됨 (4 underscores).
    expect(generated).toMatch(/\.b___proto____[A-Za-z0-9_-]{8}/);
    expect(generated).toMatch(/\.b_hasOwnProperty__[A-Za-z0-9_-]{8}/);
    expect(generated).not.toMatch(/native code|\[object/);
  });

  test('regular class 만 있는 케이스도 회귀 없음 (사전 존재 동작 보존)', () => {
    const { root, file } = makeFixture(
      'c.module.css',
      '.primary { color: red; }\n.danger { color: darkred; }',
    );
    transformCssModules(root, [file], [], 'silent');

    const generated = readFileSync(file.replace(/\.module\.css$/, '.module.zntc.css'), 'utf8');
    expect(generated).toMatch(/\.c_primary__[A-Za-z0-9_-]{8}/);
    expect(generated).toMatch(/\.c_danger__[A-Za-z0-9_-]{8}/);
  });

  // public `rewriteCssModuleClasses` (line 99 export) 가 외부 caller-supplied
  // plain `{}` mapping 받아도 안전 — Object.hasOwn 가드로 prototype lookup 무력화.
  test('public rewriteCssModuleClasses + plain {} mapping → prototype lookup 무력화', () => {
    const css =
      '.constructor { color: red; }\n.toString { color: blue; }\n.regular { color: green; }';
    const mapping: Record<string, string> = { regular: 'scoped-regular' };
    // 의도적으로 plain {} (Object.prototype 상속) 사용. caller 가 잘못 만들어도 안전.
    const out = rewriteCssModuleClasses(css, mapping);
    // .regular 만 scope 적용 (mapping 의 own property)
    expect(out).toContain('.scoped-regular { color: green; }');
    // .constructor / .toString 은 mapping own property 아님 → 원본 그대로 (skip, 변경 X)
    expect(out).toContain('.constructor { color: red; }');
    expect(out).toContain('.toString { color: blue; }');
    // native fn stringify garbage 없음
    expect(out).not.toMatch(/native code|function Object|function toString|\[object/);
  });
});
