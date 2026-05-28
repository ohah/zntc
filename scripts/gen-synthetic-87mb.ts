#!/usr/bin/env bun
/**
 * 87MB synthetic .ts fixture generator — RFC_TRANSFORMER_OWN_AST 측정용.
 *
 * 생성: 함수 / 클래스 / 인터페이스 / type-alias / re-export 가 섞인 N 개 모듈을
 *      단일 파일에 concat. ECMA/TS 구문 다양성을 살려 parser/transformer 경로의
 *      대표성 확보 (단순 string 반복은 intern 으로 메모리 왜곡).
 *
 * 사용:
 *   bun scripts/gen-synthetic-87mb.ts <output_path> [target_mb=87]
 *
 * 생성된 fixture (수십 MB) 는 commit 하지 말 것 — /tmp 등 repo 밖에 출력하거나
 * .gitignore 에 추가. 빌드 머신에서 1 회 생성 후 측정용으로 사용.
 */

const path = require("node:path");
const fs = require("node:fs");

const out = process.argv[2];
const targetMb = Number(process.argv[3] ?? 87);
if (!out) {
  console.error("usage: bun gen-synthetic-87mb.ts <output_path> [target_mb=87]");
  process.exit(1);
}

const targetBytes = targetMb * 1024 * 1024;

// 결정성: 동일 JS 엔진 내에서 동일 generator 가 동일 결과 — 측정 재현성 확보.
// (float64 LCG: seed*1103515245 가 2^53 를 넘어 하위 비트가 반올림되므로 glibc LCG 와
//  비트 동일하진 않으나, 한 머신에서 fixture 1 회 생성용이라 충분. 분포 uniform 검증됨.)
let seed = 0x1234abcd;
function rand(): number {
  seed = (seed * 1103515245 + 12345) & 0x7fffffff;
  return seed / 0x80000000;
}
function pick<T>(xs: T[]): T {
  return xs[Math.floor(rand() * xs.length)] ?? xs[0]!;
}

const types = ["string", "number", "boolean", "Date", "T", "U", "K", "V"];
const verbs = ["compute", "process", "handle", "format", "parse", "build", "render", "emit"];
const nouns = ["user", "order", "item", "node", "edge", "query", "result", "context"];

function genFunction(id: number): string {
  const v = pick(verbs);
  const n = pick(nouns);
  const t1 = pick(types);
  const t2 = pick(types);
  const t3 = pick(types);
  const body: string[] = [];
  const k = 8 + Math.floor(rand() * 8);
  for (let i = 0; i < k; i++) {
    body.push(`  const x_${i}: ${t3} = ${rand() < 0.5 ? Math.floor(rand() * 1000) : `"v_${i}"`} as ${t3};`);
  }
  body.push(`  return { id: ${id}, value: x_0 };`);
  return `export function ${v}${n}_${id}<${t2} extends ${t1}>(arg: ${t1}): { id: number; value: ${t3} } {\n${body.join("\n")}\n}`;
}

function genClass(id: number): string {
  const n = pick(nouns);
  const t1 = pick(types);
  const methods: string[] = [];
  const k = 4 + Math.floor(rand() * 4);
  for (let i = 0; i < k; i++) {
    const v = pick(verbs);
    methods.push(`  ${v}_${i}<U>(arg: U, opts: { flag?: boolean } = {}): ${t1} {\n    return arg as unknown as ${t1};\n  }`);
  }
  return `export class ${n.charAt(0).toUpperCase()}${n.slice(1)}_${id}<${t1}> {\n  private _id: number = ${id};\n  constructor(public name: string) {}\n${methods.join("\n")}\n}`;
}

function genInterface(id: number): string {
  const fields: string[] = [];
  const k = 5 + Math.floor(rand() * 5);
  for (let i = 0; i < k; i++) {
    fields.push(`  field_${i}?: ${pick(types)} | null;`);
  }
  return `export interface IShape_${id}<T> {\n${fields.join("\n")}\n  meta: { count: number; items: T[] };\n}`;
}

function genTypeAlias(id: number): string {
  return `export type Alias_${id}<T extends ${pick(types)}> = T extends ${pick(types)} ? Array<T> : Record<string, T>;`;
}

const generators = [genFunction, genClass, genInterface, genTypeAlias];

const fd = fs.openSync(out, "w");
let bytes = 0;
let id = 0;
const HEADER = `// 87MB synthetic — RFC_TRANSFORMER_OWN_AST measurement fixture (seed 0x1234abcd).\n// Do not edit; regenerate with: bun scripts/gen-synthetic-87mb.ts ${out} ${targetMb}\n\n`;
fs.writeSync(fd, HEADER);
bytes += HEADER.length;

while (bytes < targetBytes) {
  const block = generators[id % generators.length]!(id);
  const chunk = block + "\n\n";
  fs.writeSync(fd, chunk);
  bytes += chunk.length;
  id++;
}

fs.closeSync(fd);
console.error(`generated ${out}: ${(bytes / 1024 / 1024).toFixed(2)} MB, ${id} top-level decls`);
