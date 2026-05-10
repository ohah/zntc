#!/usr/bin/env node
// 5개 sub-package 의 prepublishOnly hook + scripts/release.ts:verifySubPackageBinary 가
// 공통 사용 — 빈 placeholder zntc.node 의 npm publish 차단.
//
// 사용:
//   node check-platform-binary.mjs [path]   # default: ./zntc.node
import { existsSync, statSync } from 'node:fs';
import { resolve } from 'node:path';

const target = resolve(process.cwd(), process.argv[2] ?? 'zntc.node');
const MIN_SIZE = 1000;

if (!existsSync(target)) {
  throw new Error(
    `${target} 누락 — release.yml 매트릭스 빌드가 platform binary 를 sub-package 에 분배해야 합니다.`,
  );
}
const size = statSync(target).size;
if (size < MIN_SIZE) {
  throw new Error(`${target} 너무 작음 (${size} bytes < ${MIN_SIZE}) — placeholder 의심`);
}
