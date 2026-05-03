#!/usr/bin/env bun
// `@react-native/codegen` (vendored at references/react-native-codegen) 의 reference
// 출력을 fixture 마다 생성해 golden 으로 저장. ZTS native codegen 과 byte-diff 0
// 보장의 ground truth.
//
// vendored 자료 + deps 준비는 tests/codegen-snapshots/README.md 참고.
//
// 사용:
//   bun scripts/generate-codegen-golden.mjs                   # 전체 재생성
//   bun scripts/generate-codegen-golden.mjs ScreenNative      # 부분 재생성

import { readFileSync, writeFileSync, readdirSync, mkdirSync } from 'node:fs';
import { join, basename, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const ROOT = join(__dirname, '..');

const REF = join(ROOT, 'references/react-native-codegen');
const SNAPSHOTS = join(ROOT, 'tests/codegen-snapshots');

const require = createRequire(join(REF, 'package.json'));
const { TypeScriptParser } = require(join(REF, 'lib/parsers/typescript/parser.js'));
const { FlowParser } = require(join(REF, 'lib/parsers/flow/parser.js'));
const RNCodegen = require(join(REF, 'lib/generators/RNCodegen.js'));

const tsParser = new TypeScriptParser();
const flowParser = new FlowParser();

const filter = process.argv[2];

const suites = readdirSync(SNAPSHOTS).filter((d) => {
  try {
    return readdirSync(join(SNAPSHOTS, d, 'fixtures')).length > 0;
  } catch {
    return false;
  }
});

let total = 0;
let written = 0;
let failed = 0;

for (const suite of suites) {
  const fixturesDir = join(SNAPSHOTS, suite, 'fixtures');
  const goldenDir = join(SNAPSHOTS, suite, 'golden');
  mkdirSync(goldenDir, { recursive: true });

  for (const file of readdirSync(fixturesDir)) {
    // 컨벤션: `*NativeComponent.{ts,js}` 만 처리. .d.ts / .test.ts 등은 제외.
    if (!/\.(ts|js)$/.test(file) || file.endsWith('.d.ts')) continue;
    if (filter && !file.includes(filter)) continue;
    total++;

    const code = readFileSync(join(fixturesDir, file), 'utf8');
    // libraryName 컨벤션: 파일명에서 `NativeComponent.{js,ts}` suffix 제거.
    // 예: ScreenStackNativeComponent.ts → "ScreenStack". 다른 명명규칙은 미지원.
    const libraryName = basename(file).replace(/NativeComponent\.(js|ts)$/, '');
    const parser = file.endsWith('.ts') ? tsParser : flowParser;

    try {
      const schema = parser.parseString(code, file);
      const result = RNCodegen.generateViewConfig({ libraryName, schema });
      const out = join(goldenDir, file.replace(/\.(ts|js)$/, '.golden.js'));
      writeFileSync(out, result);
      console.log(`  ✓ ${suite}/${file}`);
      written++;
    } catch (err) {
      console.log(`  ✗ ${suite}/${file} — ${err.message?.slice(0, 100)}`);
      failed++;
    }
  }
}

console.log(`\n${written}/${total} written, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
