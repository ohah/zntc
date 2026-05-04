#!/usr/bin/env bun
// 각 RN 버전별 vendored `@react-native/codegen` (references/react-native-codegen-<version>)
// 의 reference 출력을 fixture 마다 생성해 golden 으로 저장. ZTS native codegen 과
// byte-diff 0 보장의 ground truth.
//
// suite 디렉토리명 컨벤션: `rn-<version>` (예: `rn-0.85`, `rn-0.78`). 버전 부분이
// 그대로 reference 디렉토리 이름 suffix 가 됨 — `rn-0.85` 는
// `references/react-native-codegen-0.85/` 사용.
//
// vendored 자료 + deps 준비는 tests/codegen-snapshots/README.md 참고.
//
// 사용:
//   bun scripts/generate-codegen-golden.mjs                   # 전체 재생성
//   bun scripts/generate-codegen-golden.mjs ScreenNative      # 부분 재생성 (파일명 substring)
//   bun scripts/generate-codegen-golden.mjs --suite rn-0.85   # 특정 suite 만

import { readFileSync, writeFileSync, readdirSync, mkdirSync, existsSync } from 'node:fs';
import { join, basename, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const ROOT = join(__dirname, '..');

const SNAPSHOTS = join(ROOT, 'tests/codegen-snapshots');

const args = process.argv.slice(2);
let suiteFilter = null;
let nameFilter = null;
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === '--suite') {
    if (i + 1 >= args.length) {
      console.error('--suite requires a value (e.g. --suite rn-0.85)');
      process.exit(2);
    }
    suiteFilter = args[++i];
  } else if (a.startsWith('-')) {
    console.error(`unknown flag: ${a}`);
    process.exit(2);
  } else if (!nameFilter) {
    nameFilter = a;
  } else {
    console.error(`unexpected positional argument: ${a}`);
    process.exit(2);
  }
}

// suite 이름 (예: `rn-0.85`) → RN 버전 (`0.85`) 추출. 미매칭이면 null.
const SUITE_RE = /^rn-(\d+\.\d+(?:\.\d+)?)$/;

const allSuites = readdirSync(SNAPSHOTS).filter((d) => {
  try {
    return readdirSync(join(SNAPSHOTS, d, 'fixtures')).length > 0;
  } catch {
    return false;
  }
});

const suites = suiteFilter ? allSuites.filter((s) => s === suiteFilter) : allSuites;

if (suites.length === 0) {
  console.error(`no suite to process${suiteFilter ? ` (filter: ${suiteFilter})` : ''}`);
  process.exit(1);
}

let total = 0;
let written = 0;
let failed = 0;

for (const suite of suites) {
  const m = SUITE_RE.exec(suite);
  if (!m) {
    console.error(`  ✗ ${suite}/ — suite name must match \`rn-<version>\` (e.g. rn-0.85)`);
    failed++;
    continue;
  }
  const version = m[1];
  const ref = join(ROOT, `references/react-native-codegen-${version}`);
  if (!existsSync(join(ref, 'package.json'))) {
    console.error(
      `  ✗ ${suite}/ — references/react-native-codegen-${version}/ not vendored. ` +
        `See tests/codegen-snapshots/README.md`,
    );
    failed++;
    continue;
  }

  // 각 RN 버전마다 vendored deps tree 가 다름 → require resolver 도 그 위치에서.
  const require = createRequire(join(ref, 'package.json'));
  const { TypeScriptParser } = require(join(ref, 'lib/parsers/typescript/parser.js'));
  const { FlowParser } = require(join(ref, 'lib/parsers/flow/parser.js'));
  const RNCodegen = require(join(ref, 'lib/generators/RNCodegen.js'));
  const tsParser = new TypeScriptParser();
  const flowParser = new FlowParser();

  const fixturesDir = join(SNAPSHOTS, suite, 'fixtures');
  const goldenDir = join(SNAPSHOTS, suite, 'golden');
  mkdirSync(goldenDir, { recursive: true });

  for (const file of readdirSync(fixturesDir)) {
    // 컨벤션: `*NativeComponent.{ts,js}` 만 처리. .d.ts / .test.ts 등은 제외.
    if (!/\.(ts|js)$/.test(file) || file.endsWith('.d.ts')) continue;
    if (nameFilter && !file.includes(nameFilter)) continue;
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
      // truncate 안 함 — RN codegen 의 schema validation 에러는 actionable path
      // 정보 (`Module.Foo.props.bar`) 가 메시지 뒤에 붙어 잘리면 디버깅 가치 손실.
      console.error(`  ✗ ${suite}/${file} — ${err.message ?? err}`);
      failed++;
    }
  }
}

console.log(`\n${written}/${total} written, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
