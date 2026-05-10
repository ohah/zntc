// ci.yml `napi-package-smoke` job 의 host/Alpine 두 smoke step 공통 assertion.
//
// 호출: `cd tmp-napi-smoke && node --input-type=module < ../scripts/napi-smoke-test.mjs`
// 주의 — `node ../scripts/napi-smoke-test.mjs` 로 직접 실행하면 ESM resolver 가
// 이 파일 위치(repo_root/scripts) 기준으로 node_modules 를 찾아 workspace
// symlink 를 잡아버림 → tarball 검증 무력화. stdin 입력 + `--input-type=module`
// 은 cwd 기준 resolution 이라 `tmp-napi-smoke/node_modules` 에 install 된
// tarball 을 정확히 import.
import { init, tokenize, transpile } from '@zntc/core';

init();

const result = transpile('const value: number = 1;', { filename: 'input.ts' });
if (!result.code.includes('const value = 1')) {
  throw new Error(`unexpected transpile output: ${result.code}`);
}

const tokens = tokenize('const x = 1;', { filename: 'input.ts' });
if (!Array.isArray(tokens) || tokens.length === 0) {
  throw new Error('tokenize returned no tokens');
}

console.log('napi smoke: OK');
