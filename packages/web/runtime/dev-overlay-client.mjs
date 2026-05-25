// @zntc/web 의 브라우저 inject 코드 — `<script type="module" src="/__zntc_app_dev_hmr__">`
// 로 dev server 가 내려보내는 텍스트. WebSocket 연결 + Shadow DOM error overlay
// + sourcemap 디코더 + runtime error capture 를 모두 포함.
//
// 정본은 Zig 트리의 src/server/dev_overlay_client.js — Zig dev server 가 거기
// @embedFile 로 베이크해서 같은 client 를 송신한다 (#2538 4-3). npm publish 대상은
// 이 디렉토리의 dev-overlay-client.raw.js 사본. 두 파일의 byte-equal 동기성은
// dev-overlay-client.test.ts 가 가드.
//
// 정본 raw 파일은 `__ZNTC_HMR_*__` sentinel 토큰을 string literal 안에 박은 상태
// — 그대로는 브라우저에서 동작하지 않는다. 아래 placeholder 표로 @zntc/server/protocol
// 의 실제 값들을 replaceAll 한 결과만 송신한다.

import { readFileSync } from 'node:fs';

import { APP_DEV_HMR_WS_PATH, HMR_MSG } from '@zntc/server';

const RAW_TEMPLATE_PATH = new URL('./dev-overlay-client.raw.js', import.meta.url);

const PLACEHOLDERS = /** @type {const} */ ([
  ['__ZNTC_HMR_WS_PATH__', APP_DEV_HMR_WS_PATH],
  ['__ZNTC_HMR_MSG_ERROR__', HMR_MSG.Error],
  ['__ZNTC_HMR_MSG_CLEAR_ERROR__', HMR_MSG.ClearError],
  ['__ZNTC_HMR_MSG_UPDATE_START__', HMR_MSG.UpdateStart],
  ['__ZNTC_HMR_MSG_UPDATE_DONE__', HMR_MSG.UpdateDone],
  ['__ZNTC_HMR_MSG_UPDATE__', HMR_MSG.Update],
  ['__ZNTC_HMR_MSG_FULL_RELOAD__', HMR_MSG.FullReload],
  ['__ZNTC_HMR_MSG_CSS_UPDATE__', HMR_MSG.CssUpdate],
]);

function substitute(raw) {
  let out = raw;
  for (const [token, value] of PLACEHOLDERS) {
    out = out.replaceAll(token, value);
  }
  return out;
}

export const APP_DEV_HMR_CLIENT = substitute(readFileSync(RAW_TEMPLATE_PATH, 'utf8'));
