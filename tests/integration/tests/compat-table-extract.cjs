/**
 * kangax/compat-table에서 exec 테스트 코드를 JSON으로 추출.
 * Bun의 Function.toString()이 주석을 제거하므로 Node로 실행해야 함.
 *
 * 사용: node tests/compat-table-extract.cjs > tests/fixtures/compat-table-tests.json
 */
"use strict";

const dataEs6 = require("compat-table/data-es6.js");
const dataEs2016 = require("compat-table/data-es2016plus.js");

function extractExecCode(exec) {
  if (!exec) return null;
  const src = String(exec);
  const match = src.match(/\/\*\n?([\s\S]*?)\*\//);
  if (match) return match[1].trim();
  const bodyMatch = src.match(/function\s*\(\)\s*\{([\s\S]*)\}/);
  if (bodyMatch) return bodyMatch[1].trim();
  return null;
}

const result = { es6: [], es2016: [] };

for (const feature of dataEs6.tests) {
  const subtests = feature.subtests || (feature.exec ? [{ name: "main", exec: feature.exec }] : []);
  const extracted = [];
  for (const sub of subtests) {
    const code = extractExecCode(sub.exec);
    if (code) extracted.push({ name: sub.name, code });
  }
  if (extracted.length > 0) {
    result.es6.push({ name: feature.name, subtests: extracted });
  }
}

for (const feature of dataEs2016.tests) {
  const subtests = feature.subtests || (feature.exec ? [{ name: "main", exec: feature.exec }] : []);
  const extracted = [];
  for (const sub of subtests) {
    const code = extractExecCode(sub.exec);
    if (code) extracted.push({ name: sub.name, code });
  }
  if (extracted.length > 0) {
    result.es2016.push({ name: feature.name, subtests: extracted });
  }
}

console.log(JSON.stringify(result, null, 2));
