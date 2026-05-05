// RN runtime asset loader — `runtime/zts-hmr-client.js` 를 module load 시점에
// readFileSync 로 읽어 string 으로 노출. plugin factory (createAssetPlugin) 가
// HMRClient.js path 매칭 시 onLoad 응답으로 그대로 반환 — RN runtime 의
// require('HMRClient') 가 bundle 안의 ZTS_HMR_CLIENT_CODE 에 도달.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// dist/index.js 옆의 ../runtime/zts-hmr-client.js — package.json `files`
// 에 `runtime/` 포함으로 npm publish 시 dist/ 와 같이 복사됨.
const RUNTIME_PATH = join(
  dirname(fileURLToPath(import.meta.url)),
  '..',
  'runtime',
  'zts-hmr-client.js',
);

/**
 * RN runtime 의 HMRClient interface 호환 코드 (string).
 * runtime/zts-hmr-client.js 가 dist 와 함께 publish 되어야 정상 로드.
 *
 * fallback dummy: build 직후 / 누락 환경에서 dynamic require 가 throw 안 하도록
 * minimal no-op HMRClient 객체 export (RN 의 setUpBatchedBridge 가 default
 * 접근 — `module.exports.default` 보존).
 */
export const ZTS_HMR_CLIENT_CODE: string = (() => {
  try {
    return readFileSync(RUNTIME_PATH, 'utf-8');
  } catch {
    return 'module.exports = { setup() {}, enable() {}, disable() {}, registerBundle() {}, log() {} }; module.exports.default = module.exports;';
  }
})();

/**
 * RN runtime 의 `HMRClient.js` 의 path suffix (Metro 의 모듈 path 가 이 suffix
 * 로 끝남). plugin factory 가 onLoad path 매칭 시 사용.
 */
export const HMR_CLIENT_SUFFIX = '/Libraries/Utilities/HMRClient.js';
