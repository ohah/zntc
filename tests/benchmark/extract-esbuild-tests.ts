#!/usr/bin/env bun
/**
 * esbuild ts_parser_test.go에서 expectPrintedTS / expectPrintedTSX /
 * expectPrintedExperimentalDecoratorTS 테스트 케이스를 추출하여 JSON으로 출력.
 *
 * 사용법: bun run extract-esbuild-tests.ts > esbuild-ts-cases.json
 */

import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const ROOT = resolve(__dirname, "../..");
const TEST_FILE = resolve(ROOT, "references/esbuild/internal/js_parser/ts_parser_test.go");

const source = readFileSync(TEST_FILE, "utf-8");

interface TestCase {
  fn: string;
  input: string;
  expected: string;
  line: number;
}

const cases: TestCase[] = [];

// Go 백틱 문자열과 쌍따옴표 문자열을 모두 처리하는 파서
// expectPrintedTS(t, `input`, `expected`)
// expectPrintedTS(t, "input", "expected")
const targetFns = [
  "expectPrintedTS",
  "expectPrintedTSX",
  "expectPrintedExperimentalDecoratorTS",
  "expectPrintedAssignSemanticsTS",
];

const lines = source.split("\n");

for (let i = 0; i < lines.length; i++) {
  const line = lines[i];

  for (const fn of targetFns) {
    const idx = line.indexOf(`${fn}(t, `);
    if (idx === -1) continue;

    // 함수 호출 시작부터 끝까지 수집 (여러 줄에 걸칠 수 있음)
    let chunk = "";
    let j = i;
    let parenDepth = 0;
    let started = false;

    outer: for (; j < lines.length && j < i + 100; j++) {
      const l = lines[j];
      for (let k = j === i ? idx : 0; k < l.length; k++) {
        const ch = l[k];
        if (ch === "(") {
          parenDepth++;
          started = true;
        }
        if (ch === ")") {
          parenDepth--;
          if (started && parenDepth === 0) {
            chunk += l.slice(0, k + 1);
            break outer;
          }
        }
      }
      chunk += (j === i ? l.slice(idx) : l) + "\n";
    }

    // 인자 추출: fn(t, arg1, arg2)
    // t 이후의 두 문자열 인자를 추출
    const afterT = chunk.slice(chunk.indexOf("(t, ") + 4);

    const args = extractTwoStringArgs(afterT);
    if (args) {
      cases.push({
        fn,
        input: args[0],
        expected: args[1],
        line: i + 1,
      });
    }
  }
}

function extractTwoStringArgs(s: string): [string, string] | null {
  const first = extractString(s);
  if (!first) return null;

  // 첫 번째 인자 이후 쉼표 찾기
  let rest = s.slice(first.end).trimStart();
  if (!rest.startsWith(",")) return null;
  rest = rest.slice(1).trimStart();

  const second = extractString(rest);
  if (!second) return null;

  return [first.value, second.value];
}

function extractString(s: string): { value: string; end: number } | null {
  s = s.trimStart();
  const offset = s.length;

  if (s.startsWith("`")) {
    // Go backtick string (raw string)
    const end = s.indexOf("`", 1);
    if (end === -1) return null;
    return { value: s.slice(1, end), end: s.length - offset + end + 1 };
  }

  if (s.startsWith('"')) {
    // Go double-quoted string (with escapes)
    let result = "";
    let i = 1;
    while (i < s.length) {
      if (s[i] === "\\") {
        i++;
        if (s[i] === "n") {
          result += "\n";
        } else if (s[i] === "t") {
          result += "\t";
        } else if (s[i] === "\\") {
          result += "\\";
        } else if (s[i] === '"') {
          result += '"';
        } else if (s[i] === "'") {
          result += "'";
        } else {
          result += "\\" + s[i];
        }
        i++;
      } else if (s[i] === '"') {
        return {
          value: result,
          end: s.length - offset + i + 1,
        };
      } else {
        result += s[i];
        i++;
      }
    }
    return null;
  }

  // 문자열 연결: "a" + "b" 또는 "a" +\n "b"
  // 단순 케이스만 처리
  return null;
}

console.log(JSON.stringify(cases, null, 2));
console.error(`Extracted ${cases.length} test cases`);
