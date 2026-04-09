#!/usr/bin/env node
/**
 * 에러 코드 문서 자동 생성 스크립트
 *
 * error_codes.zig에서 코드 목록을 파싱하여
 * documents/src/content/docs/reference/errors/ 에 .md 파일을 생성한다.
 *
 * 사용법: node scripts/generate-error-docs.mjs
 */

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..");
const ERROR_CODES_PATH = join(ROOT, "src/error_codes.zig");
const DOCS_DIR = join(ROOT, "documents/src/content/docs/reference/errors");

// Playground URL 생성 (hash 기반 base64)
// options가 있으면 JSON { code, options } 포맷, 없으면 코드만
function playgroundUrl(code, opts = {}) {
  const base = "https://ohah.github.io/zts/playground/";
  const hasOpts = Object.keys(opts).length > 0;
  const payload = hasOpts
    ? JSON.stringify({ code, options: opts })
    : code;
  const encoded = Buffer.from(payload).toString("base64");
  return `${base}#${encoded}`;
}

// error_codes.zig에서 코드 목록 파싱
const source = readFileSync(ERROR_CODES_PATH, "utf8");

// enum variant 파싱: name = number,
const variants = [];
const enumRegex = /^\s+(\w+)\s*=\s*(\d+),/gm;
let match;
while ((match = enumRegex.exec(source)) !== null) {
  variants.push({ name: match[1], number: parseInt(match[2]) });
}

// message() switch에서 메시지 파싱
const messages = {};
// escaped double quote도 포함하여 메시지 파싱 (\"...\" 패턴 처리)
const msgRegex = /\.(\w+)\s*=>\s*"((?:[^"\\]|\\.)*)"/g;
while ((match = msgRegex.exec(source)) !== null) {
  messages[match[1]] = match[2];
}

// 카테고리 매핑
function getCategory(num) {
  if (num < 100) return { name: "타겟/호환성", nameEn: "Target/Compatibility" };
  if (num < 200) return { name: "번들러: import/export", nameEn: "Bundler: Import/Export" };
  if (num < 300) return { name: "번들러: 파일/로더", nameEn: "Bundler: File/Loader" };
  if (num < 400) return { name: "파서: import/export", nameEn: "Parser: Import/Export" };
  if (num < 500) return { name: "파서: 선언/클래스", nameEn: "Parser: Declaration/Class" };
  if (num < 600) return { name: "파서: 바인딩/식별자", nameEn: "Parser: Binding/Identifier" };
  if (num < 700) return { name: "파서: 식/연산자", nameEn: "Parser: Expression/Operator" };
  if (num < 800) return { name: "파서: 문/제어 흐름", nameEn: "Parser: Statement/Control Flow" };
  if (num < 900) return { name: "파서: strict mode", nameEn: "Parser: Strict Mode" };
  if (num < 1000) return { name: "파서: await/yield/JSX/TS", nameEn: "Parser: Await/Yield/JSX/TS" };
  if (num < 1100) return { name: "시맨틱: 재선언", nameEn: "Semantic: Redeclaration" };
  if (num < 1200) return { name: "시맨틱: private", nameEn: "Semantic: Private Member" };
  if (num < 1300) return { name: "시맨틱: export/label", nameEn: "Semantic: Export/Label" };
  return { name: "시맨틱: class/기타", nameEn: "Semantic: Class/Other" };
}

// 재현 코드 매핑 (주요 에러들)
const examples = {
  top_level_await_target: { code: 'export const data = await fetch("/api");', opts: { target: "es2021" }, cliOpts: "--target=es2021" },
  import_in_script: { code: 'import { foo } from "./bar";', opts: {}, cliOpts: "" },
  import_not_top_level: { code: 'function f() { import { x } from "y"; }', opts: {}, cliOpts: "" },
  export_in_script: { code: 'export const x = 1;', opts: {}, cliOpts: "" },
  export_not_top_level: { code: 'function f() { export const x = 1; }', opts: {}, cliOpts: "" },
  import_cannot_new: { code: 'const m = new import("./mod");', opts: {}, cliOpts: "" },
  import_meta_in_script: { code: 'console.log(import.meta.url);', opts: {}, cliOpts: "" },
  anon_function_invoked: { code: 'export default function() {}()', opts: {}, cliOpts: "" },
  function_in_statement: { code: 'if (true) function foo() {}', opts: {}, cliOpts: "" },
  class_in_statement: { code: 'if (true) class Foo {}', opts: {}, cliOpts: "" },
  class_constructor_invalid: { code: 'class Foo { async constructor() {} }', opts: {}, cliOpts: "" },
  class_field_constructor: { code: 'class Foo { constructor = 1; }', opts: {}, cliOpts: "" },
  static_field_prototype: { code: 'class Foo { static prototype = 1; }', opts: {}, cliOpts: "" },
  identifier_expected: { code: 'const = 1;', opts: {}, cliOpts: "" },
  const_not_initialized: { code: 'const x;', opts: {}, cliOpts: "" },
  rest_must_be_last: { code: 'function f(...a, b) {}', opts: {}, cliOpts: "" },
  rest_trailing_comma: { code: 'function f(...a,) {}', opts: {}, cliOpts: "" },
  duplicate_parameter: { code: '"use strict"; function f(a, a) {}', opts: {}, cliOpts: "" },
  invalid_assignment_target: { code: '1 + 2 = 3;', opts: {}, cliOpts: "" },
  expression_expected: { code: 'const x = ;', opts: {}, cliOpts: "" },
  unary_exponentiation: { code: 'const x = -a ** 2;', opts: {}, cliOpts: "" },
  nullish_mix_logical: { code: 'const x = a ?? b || c;', opts: {}, cliOpts: "" },
  private_delete: { code: 'class C { #x = 1; f() { delete this.#x; } }', opts: {}, cliOpts: "" },
  return_outside_function: { code: 'return 1;', opts: {}, cliOpts: "" },
  break_outside: { code: 'break;', opts: {}, cliOpts: "" },
  continue_outside: { code: 'continue;', opts: {}, cliOpts: "" },
  switch_duplicate_default: { code: 'switch(x) { default: break; default: break; }', opts: {}, cliOpts: "" },
  throw_newline: { code: 'throw\nnew Error();', opts: {}, cliOpts: "" },
  with_strict: { code: '"use strict"; with(obj) {}', opts: {}, cliOpts: "" },
  octal_literal_strict: { code: '"use strict"; const x = 0123;', opts: {}, cliOpts: "" },
  delete_identifier_strict: { code: '"use strict"; var x = 1; delete x;', opts: {}, cliOpts: "" },
  await_in_parameters: { code: 'async function f(x = await 1) {}', opts: {}, cliOpts: "" },
  await_in_static_initializer: { code: 'class C { static x = await 1; }', opts: {}, cliOpts: "" },
  yield_in_parameters: { code: 'function* g(x = yield 1) {}', opts: {}, cliOpts: "" },
  template_invalid_escape: { code: 'const x = `\\unicode`;', opts: {}, cliOpts: "" },
  jsx_tag_expected: { code: 'const x = < />;', opts: {}, cliOpts: "" },
  identifier_redeclared: { code: 'export let x = 1; let x = 2;', opts: {}, cliOpts: "" },
  private_redeclared: { code: 'class C { #x; #x; }', opts: {}, cliOpts: "" },
  private_undeclared: { code: 'class C { f() { this.#x; } }', opts: {}, cliOpts: "" },
  duplicate_export: { code: 'export const x = 1; export const x = 2;', opts: {}, cliOpts: "" },
  duplicate_constructor: { code: 'class C { constructor() {} constructor() {} }', opts: {}, cliOpts: "" },
  getter_no_params: { code: 'const o = { get x(a) {} };', opts: {}, cliOpts: "" },
  setter_one_param: { code: 'const o = { set x() {} };', opts: {}, cliOpts: "" },
  super_outside_method: { code: 'const x = super.foo;', opts: {}, cliOpts: "" },
  super_call_outside_constructor: { code: 'class C { f() { super(); } }', opts: {}, cliOpts: "" },
};

// 파일 생성
mkdirSync(DOCS_DIR, { recursive: true });

let indexContent = `---
title: 에러 코드 레퍼런스
description: ZTS 에러 코드 전체 목록
---

ZTS는 모든 에러에 고유 코드를 부여합니다. 에러 코드를 클릭하면 상세 설명과 재현 코드를 볼 수 있습니다.

`;

let currentCategory = "";

for (const v of variants) {
  const code = `ZTS${String(v.number).padStart(4, "0")}`;
  const msg = messages[v.name] || v.name;
  const cat = getCategory(v.number);
  const example = examples[v.name];

  // 인덱스 페이지에 카테고리 헤더 추가
  if (cat.name !== currentCategory) {
    currentCategory = cat.name;
    indexContent += `\n## ${cat.name}\n\n| 코드 | 메시지 |\n|------|--------|\n`;
  }
  indexContent += `| [\`${code}\`](/zts/reference/errors/${code.toLowerCase()}) | ${msg} |\n`;

  // YAML frontmatter: single quote로 감싸서 double quote 문제 회피
  // single quote 안의 single quote는 '' 로 이스케이프
  const yamlMsg = msg.replace(/'/g, "''");

  // 개별 에러 페이지
  let pageContent = `---
title: '${code}: ${yamlMsg}'
description: '${yamlMsg}'
---

## ${code}

> ${msg}

**카테고리**: ${cat.name}
`;

  if (example) {
    const url = playgroundUrl(example.code, example.opts);
    pageContent += `
### 재현 코드

\`\`\`ts
${example.code}
\`\`\`

${example.cliOpts ? `**옵션**: \`${example.cliOpts}\`\n` : ""}
[Playground에서 재현하기 →](${url})
`;
  }

  pageContent += `
### 해결 방법

이 에러의 원인과 해결 방법은 에러 메시지를 참고하세요.
`;

  writeFileSync(join(DOCS_DIR, `${code.toLowerCase()}.md`), pageContent);
}

// 인덱스 페이지 작성
writeFileSync(join(DOCS_DIR, "index.md"), indexContent);

console.log(`✅ ${variants.length}개 에러 문서 생성 완료 → ${DOCS_DIR}`);
