// React Fast Refresh preamble — `zntc dev` 가 reactRefresh 활성 시 앱 번들보다 *먼저*
// 실행시키는 classic <script> 본문을 만든다. Vite 의 `/@react-refresh` preamble 과 동치:
//   1) react-refresh/runtime 을 글로벌 `__ReactRefresh` 로 노출(번들러가 깐
//      `__zntc_resolveRefresh` 가 이 글로벌을 먼저 읽고 단락 — 브라우저에 없는
//      `require("react-refresh/runtime")` 경로를 안 탄다).
//   2) `injectIntoGlobalHook(window)` 를 React 로드 *전* 에 호출(리액트 reconciler 패치).
//   3) `$RefreshReg$/$RefreshSig$` 글로벌 no-op 기본값(모듈별 wrapper 가 임시 override).
// react-refresh 미설치 시 noop 폴백 + 경고(Fast Refresh 비활성, 빌드는 정상).

import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { dirname, resolve, sep } from 'node:path';

const NOOP_PREAMBLE =
  'console.warn("[zntc] react-refresh not found — React Fast Refresh disabled. ' +
  '`npm install react-refresh` for HMR with state preservation.");\n' +
  '(function(){var g=typeof globalThis!=="undefined"?globalThis:window;' +
  'g.$RefreshReg$=g.$RefreshReg$||function(){};' +
  'g.$RefreshSig$=g.$RefreshSig$||function(){return function(t){return t}};})();';

/**
 * react-refresh 런타임 소스를 글로벌 바인딩 + injectIntoGlobalHook 으로 감싼 preamble 문자열.
 *  - react-refresh 설치됨 → 실제 preamble.
 *  - react 는 있으나 react-refresh 없음 → noop + 설치 경고(=React 앱인데 FR 못 켬).
 *  - react 도 없음 → `null`(비-React 앱 — 호출자가 주입/서빙 스킵, 경고 없음).
 * @param rootDir 앱 루트(여기 node_modules 기준으로 resolve).
 */
export function buildReactRefreshPreamble(rootDir: string): string | null {
  // createRequire 는 절대 경로 필요 — caller 가 상대 경로(예: `zntc dev ./app`)를 줘도 안전하게.
  const req = createRequire(resolve(rootDir, '__zntc_resolve__.js'));
  let runtimeSource: string;
  try {
    // runtime.js 는 보통 `require('./cjs/...development.js')` 디스패처. 그 dev cjs 본문을
    // 직접 읽어 서빙한다(디스패처 자체는 process.env + require 라 브라우저에서 안 돈다).
    const runtimeJsPath = req.resolve('react-refresh/runtime');
    const pkgDir = dirname(runtimeJsPath);
    const dispatcher = readFileSync(runtimeJsPath, 'utf8');
    const m = dispatcher.match(/require\((['"])(\.[^'"]*development[^'"]*)\1\)/);
    if (m) {
      // path-traversal 가드: 추출 경로는 react-refresh 패키지 디렉토리 안이어야 한다
      // (악성/손상 dep 가 `require('../../../etc/passwd')` 로 임의 파일을 서빙하는 것 차단).
      const cjsPath = resolve(pkgDir, m[2]);
      if (cjsPath !== pkgDir && !cjsPath.startsWith(pkgDir + sep)) return NOOP_PREAMBLE;
      runtimeSource = readFileSync(cjsPath, 'utf8');
    } else if (!/\brequire\s*\(/.test(dispatcher)) {
      // 디스패처가 아니라 self-contained 런타임 본문(require 없음) — 그대로 사용(옛 버전).
      runtimeSource = dispatcher;
    } else {
      // require 가 있으나 dev cjs 경로를 못 풀음 → 브라우저에서 ReferenceError 나므로 서빙 안 함.
      return NOOP_PREAMBLE;
    }
  } catch {
    try {
      req.resolve('react');
    } catch {
      return null; // react 도 없음 = 비-React 앱. 조용히 스킵.
    }
    return NOOP_PREAMBLE; // React 앱인데 react-refresh 미설치 → 설치 안내.
  }

  // CJS shim + process 셰도우(dev cjs 의 `if(process.env.NODE_ENV!=="production")` 가드 통과).
  return (
    '(function(){\n' +
    'var process={env:{NODE_ENV:"development"}};\n' +
    'var exports={};var module={exports:exports};\n' +
    runtimeSource +
    '\nvar rt=module.exports;\n' +
    'var g=typeof globalThis!=="undefined"?globalThis:window;\n' +
    'g.__ReactRefresh=rt;g.__REACT_REFRESH_RUNTIME__=rt;\n' +
    'if(rt&&typeof rt.injectIntoGlobalHook==="function")rt.injectIntoGlobalHook(g);\n' +
    'g.$RefreshReg$=function(){};\n' +
    'g.$RefreshSig$=function(){return function(t){return t}};\n' +
    'g.__zntc_react_refresh_preamble__=true;\n' +
    '})();'
  );
}
