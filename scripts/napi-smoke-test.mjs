// ci.yml `napi-package-smoke` job 의 host/Alpine 두 smoke step 공통 assertion.
// host 시나리오: heredoc 으로 inline 했던 코드를 file 로 분리 — 두 step 이 같은
// 단일 source 사용하여 drift 차단.
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
