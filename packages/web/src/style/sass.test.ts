import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  buildCssPreprocessorProxy,
  CSS_PREPROCESSOR_EXTENSIONS,
  cssPreprocessorOutputPath,
  cssPreprocessorProxyPath,
  isCssModulePreprocessorFile,
  isCssPreprocessorFile,
  isStyleReferenceSource,
  rewriteSassReferences,
} from './sass.ts';

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'zntc-sass-'));
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

describe('CSS_PREPROCESSOR_EXTENSIONS', () => {
  test('.scss / .sass 만 포함', () => {
    expect(CSS_PREPROCESSOR_EXTENSIONS.has('.scss')).toBe(true);
    expect(CSS_PREPROCESSOR_EXTENSIONS.has('.sass')).toBe(true);
    expect(CSS_PREPROCESSOR_EXTENSIONS.has('.css')).toBe(false);
    expect(CSS_PREPROCESSOR_EXTENSIONS.has('.less')).toBe(false);
  });
});

describe('isCssPreprocessorFile', () => {
  test('.scss / .sass true', () => {
    expect(isCssPreprocessorFile('a.scss')).toBe(true);
    expect(isCssPreprocessorFile('/abs/x.sass')).toBe(true);
  });

  test('그 외 false', () => {
    expect(isCssPreprocessorFile('a.css')).toBe(false);
    expect(isCssPreprocessorFile('a.less')).toBe(false);
    expect(isCssPreprocessorFile('a.ts')).toBe(false);
    expect(isCssPreprocessorFile('')).toBe(false);
  });
});

describe('isCssModulePreprocessorFile', () => {
  test('.module.scss / .module.sass true', () => {
    expect(isCssModulePreprocessorFile('a.module.scss')).toBe(true);
    expect(isCssModulePreprocessorFile('/abs/x.module.sass')).toBe(true);
  });

  test('일반 .scss/.sass false', () => {
    expect(isCssModulePreprocessorFile('a.scss')).toBe(false);
    expect(isCssModulePreprocessorFile('a.sass')).toBe(false);
  });

  test('.module.css 는 false (preprocessor 아님)', () => {
    expect(isCssModulePreprocessorFile('a.module.css')).toBe(false);
  });
});

describe('cssPreprocessorOutputPath', () => {
  test('.scss → .css', () => {
    expect(cssPreprocessorOutputPath('a.scss')).toBe('a.css');
  });

  test('.sass → .css', () => {
    expect(cssPreprocessorOutputPath('/abs/x.sass')).toBe('/abs/x.css');
  });

  test('case-sensitive — `.SCSS` 는 처리 안 함 (isCssPreprocessorFile gate 와 일치)', () => {
    // `isCssPreprocessorFile` 의 extname 기반 lookup 이 case-sensitive 라
    // .SCSS 는 처음부터 인식 안 됨. 두 함수 일관 (#2539).
    expect(cssPreprocessorOutputPath('a.SCSS')).toBe('a.SCSS');
  });

  test('.module.scss → .module.css', () => {
    expect(cssPreprocessorOutputPath('a.module.scss')).toBe('a.module.css');
  });

  test('.css 는 변경 없음', () => {
    expect(cssPreprocessorOutputPath('a.css')).toBe('a.css');
  });
});

describe('cssPreprocessorProxyPath', () => {
  test('.scss → .css.js (proxy)', () => {
    expect(cssPreprocessorProxyPath('a.scss')).toBe('a.css.js');
  });

  test('.sass → .css.js', () => {
    expect(cssPreprocessorProxyPath('/abs/x.sass')).toBe('/abs/x.css.js');
  });
});

describe('isStyleReferenceSource', () => {
  test('HTML 과 JS/TS 변형 true', () => {
    expect(isStyleReferenceSource('a.html')).toBe(true);
    expect(isStyleReferenceSource('a.js')).toBe(true);
    expect(isStyleReferenceSource('a.mjs')).toBe(true);
    expect(isStyleReferenceSource('a.cjs')).toBe(true);
    expect(isStyleReferenceSource('a.jsx')).toBe(true);
    expect(isStyleReferenceSource('a.ts')).toBe(true);
    expect(isStyleReferenceSource('a.tsx')).toBe(true);
  });

  test('CSS / 그 외 false', () => {
    expect(isStyleReferenceSource('a.css')).toBe(false);
    expect(isStyleReferenceSource('a.scss')).toBe(false);
    expect(isStyleReferenceSource('a.json')).toBe(false);
    expect(isStyleReferenceSource('a')).toBe(false);
  });
});

describe('buildCssPreprocessorProxy', () => {
  test('basename 만 import 하는 한 줄 proxy', () => {
    expect(buildCssPreprocessorProxy('/abs/path/a.css')).toBe(`import "./a.css";\n`);
  });

  test('이름 안에 special char 도 JSON.stringify 로 escape', () => {
    expect(buildCssPreprocessorProxy('/x/has"quote.css')).toContain(`"./has\\"quote.css"`);
  });
});

describe('rewriteSassReferences', () => {
  test('HTML 의 `<link href="x.scss">` → `.css`', () => {
    const path = touch('index.html', `<link rel="stylesheet" href="./styles.scss">`);
    rewriteSassReferences([path]);
    expect(readFileSync(path, 'utf8')).toBe(`<link rel="stylesheet" href="./styles.css">`);
  });

  test('JS/TS 의 import 는 `.css.js` proxy 로', () => {
    const path = touch('entry.ts', `import "./styles.scss";\n`);
    rewriteSassReferences([path]);
    expect(readFileSync(path, 'utf8')).toBe(`import "./styles.css.js";\n`);
  });

  test('작은따옴표 import 도 정상 처리', () => {
    const path = touch('entry.ts', `import './a.sass';`);
    rewriteSassReferences([path]);
    expect(readFileSync(path, 'utf8')).toBe(`import './a.css.js';`);
  });

  test('query/fragment suffix 보존', () => {
    const path = touch('entry.ts', `import "./a.scss?inline";`);
    rewriteSassReferences([path]);
    expect(readFileSync(path, 'utf8')).toBe(`import "./a.css.js?inline";`);
  });

  test('.scss / .sass 가 없는 파일은 변경 없음', () => {
    const original = `import "./a.css";`;
    const path = touch('entry.ts', original);
    rewriteSassReferences([path]);
    expect(readFileSync(path, 'utf8')).toBe(original);
  });

  test('HTML 의 sass 도 .css 로 (proxy 아님)', () => {
    const path = touch('index.html', `<link href="./x.sass">`);
    rewriteSassReferences([path]);
    expect(readFileSync(path, 'utf8')).toBe(`<link href="./x.css">`);
  });

  test('여러 파일 동시 처리', () => {
    const a = touch('a.ts', `import "./x.scss";`);
    const b = touch('b.html', `<link href="./y.scss">`);
    rewriteSassReferences([a, b]);
    expect(readFileSync(a, 'utf8')).toContain(`x.css.js`);
    expect(readFileSync(b, 'utf8')).toContain(`y.css`);
  });
});
