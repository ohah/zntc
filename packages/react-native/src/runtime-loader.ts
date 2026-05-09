// RN runtime asset loader — `runtime/zntc-hmr-client.cjs` 를 module load 시점에
// readFileSync 로 읽어 string 으로 노출. plugin factory (createAssetPlugin) 가
// HMRClient.js path 매칭 시 onLoad 응답으로 그대로 반환 — RN runtime 의
// require('HMRClient') 가 bundle 안의 ZNTC_HMR_CLIENT_CODE 에 도달.
//
// `.cjs` 확장자: `@zntc/react-native` 의 `type: "module"` 로 인해 ESM mode 인데
// 이 파일은 RN runtime 컨벤션상 CJS (module.exports). publint --strict 가
// `.js` + ESM mode 조합을 잡아내므로 `.cjs` 로 명시 (#2802).

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// dist/index.js 옆의 ../runtime/zntc-hmr-client.cjs — package.json `files`
// 에 `runtime/` 포함으로 npm publish 시 dist/ 와 같이 복사됨.
const RUNTIME_PATH = join(
  dirname(fileURLToPath(import.meta.url)),
  '..',
  'runtime',
  'zntc-hmr-client.cjs',
);

/**
 * RN runtime 의 HMRClient interface 호환 코드 (string).
 * runtime/zntc-hmr-client.cjs 가 dist 와 함께 publish 되어야 정상 로드.
 *
 * fallback dummy: build 직후 / 누락 환경에서 dynamic require 가 throw 안 하도록
 * minimal no-op HMRClient 객체 export (RN 의 setUpBatchedBridge 가 default
 * 접근 — `module.exports.default` 보존).
 */
export const ZNTC_HMR_CLIENT_CODE: string = (() => {
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
