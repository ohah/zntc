// src/server/dev_overlay_client.js (Zig @embedFile 정본) ↔ dev-overlay-client.raw.js
// (npm publish 용 mirror) 동기성 가드. 정본 변경 시 mirror 도 같이 갱신해야
// dev server (@zntc/web) 가 같은 client 를 송신한다. byte-equal 미보장 시 Zig 와
// JS dev server 가 다른 overlay 동작을 내려보내게 됨 (#2538 epic 4-3).

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, test } from 'bun:test';

import { APP_DEV_HMR_WS_PATH, HMR_MSG } from '@zntc/server';

import { APP_DEV_HMR_CLIENT } from './dev-overlay-client.mjs';

const RAW_MIRROR_PATH = fileURLToPath(new URL('./dev-overlay-client.raw.js', import.meta.url));
const ZIG_SOURCE_PATH = fileURLToPath(
  new URL('../../../src/server/dev_overlay_client.js', import.meta.url),
);
const ZIG_DEV_SERVER_PATH = fileURLToPath(
  new URL('../../../src/server/dev_server.zig', import.meta.url),
);

describe('dev overlay client mirror', () => {
  test('raw mirror 는 Zig @embedFile 정본과 byte-equal', () => {
    const zigSource = readFileSync(ZIG_SOURCE_PATH);
    const mirror = readFileSync(RAW_MIRROR_PATH);
    expect(mirror.equals(zigSource)).toBe(true);
  });

  test('raw mirror 는 sentinel 토큰을 포함 (치환 전 상태)', () => {
    const raw = readFileSync(RAW_MIRROR_PATH, 'utf8');
    expect(raw).toContain('__ZNTC_HMR_WS_PATH__');
    expect(raw).toContain('__ZNTC_HMR_MSG_ERROR__');
    expect(raw).toContain('__ZNTC_HMR_MSG_CLEAR_ERROR__');
    expect(raw).toContain('__ZNTC_HMR_MSG_UPDATE_START__');
    expect(raw).toContain('__ZNTC_HMR_MSG_UPDATE__');
    expect(raw).toContain('__ZNTC_HMR_MSG_UPDATE_DONE__');
    expect(raw).toContain('__ZNTC_HMR_MSG_FULL_RELOAD__');
    expect(raw).toContain('__ZNTC_HMR_MSG_CSS_UPDATE__');
  });
});

// 본문 (line + block comment 제외) 만 추출 — comment 안의 sentinel 설명 문구가
// not.toContain 가드에 false-positive 로 잡히지 않도록 한다.
function codeOnly(source: string): string {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .split('\n')
    .filter((line) => !line.trim().startsWith('//'))
    .join('\n');
}

describe('APP_DEV_HMR_CLIENT', () => {
  test('export 결과는 string 이며 본문 sentinel 토큰이 전부 치환됨', () => {
    expect(typeof APP_DEV_HMR_CLIENT).toBe('string');
    expect(codeOnly(APP_DEV_HMR_CLIENT)).not.toContain('__ZNTC_HMR_');
  });

  test('@zntc/server/protocol 의 WS path / 메시지 타입 literal 포함', () => {
    // 치환 후엔 enum 값이 const 선언 (또는 직접 인용) 에 박혀 있어야 함.
    expect(APP_DEV_HMR_CLIENT).toContain('"/__hmr"');
    expect(APP_DEV_HMR_CLIENT).toContain('"error"');
    expect(APP_DEV_HMR_CLIENT).toContain('"clear-error"');
    expect(APP_DEV_HMR_CLIENT).toContain('"update-start"');
    expect(APP_DEV_HMR_CLIENT).toContain('"update-done"');
    expect(APP_DEV_HMR_CLIENT).toContain('"full-reload"');
    expect(APP_DEV_HMR_CLIENT).toContain('"css-update"');
    expect(APP_DEV_HMR_CLIENT).toContain('"update"');
  });

  test('protocol 분기와 module update 호출이 본문에 보존', () => {
    // 정본 superset 의 핵심 — Zig 측 dev_server.zig 가 broadcast 하는 update*/
    // full-reload/css-update 처리가 빠지면 안 됨 (#2538 4-3).
    const body = codeOnly(APP_DEV_HMR_CLIENT);
    expect(body).toContain('__zntc_apply_update');
    expect(body).toMatch(/new WebSocket\(/);
    expect(body).toMatch(/document\.querySelectorAll\('link\[rel="stylesheet"\]'\)/);
  });
});

// Zig dev_server.zig 의 substituteOverlayPlaceholders subs 배열을 regex 로 추출해
// TS @zntc/server/protocol 의 enum 값과 동치를 강제. Zig 는 hardcode, mjs 는 enum
// import — enum 변경 시 mjs 는 자동 추적되지만 Zig 는 drift 가능. 이 가드가 깨지면
// Zig dev server 와 JS dev server 가 같은 raw template 을 다른 값으로 치환해 서로
// 다른 client 를 브라우저로 송신하게 된다 (#2538 4-3 code-review max).
describe('Zig substituteOverlayPlaceholders ↔ TS HMR_MSG drift 가드', () => {
  function extractZigSubs(): Map<string, string> {
    const source = readFileSync(ZIG_DEV_SERVER_PATH, 'utf8');
    const pairs = new Map<string, string>();
    const re = /\.\{\s*\.token\s*=\s*"([^"]+)"\s*,\s*\.value\s*=\s*"([^"]*)"\s*\}/g;
    let match: RegExpExecArray | null;
    while ((match = re.exec(source)) !== null) {
      pairs.set(match[1], match[2]);
    }
    return pairs;
  }

  test('Zig subs 의 (token,value) 가 @zntc/server enum 과 정확히 일치', () => {
    const zig = extractZigSubs();
    const expected = new Map<string, string>([
      ['__ZNTC_HMR_WS_PATH__', APP_DEV_HMR_WS_PATH],
      ['__ZNTC_HMR_MSG_ERROR__', HMR_MSG.Error],
      ['__ZNTC_HMR_MSG_CLEAR_ERROR__', HMR_MSG.ClearError],
      ['__ZNTC_HMR_MSG_UPDATE_START__', HMR_MSG.UpdateStart],
      ['__ZNTC_HMR_MSG_UPDATE_DONE__', HMR_MSG.UpdateDone],
      ['__ZNTC_HMR_MSG_UPDATE__', HMR_MSG.Update],
      ['__ZNTC_HMR_MSG_FULL_RELOAD__', HMR_MSG.FullReload],
      ['__ZNTC_HMR_MSG_CSS_UPDATE__', HMR_MSG.CssUpdate],
    ]);
    expect(Object.fromEntries(zig)).toEqual(Object.fromEntries(expected));
  });

  test('치환 순서 안전성: prefix 가 더 긴 sentinel 이 더 짧은 sentinel 보다 먼저 등장', () => {
    // `__ZNTC_HMR_MSG_UPDATE__` 는 `__ZNTC_HMR_MSG_UPDATE_START__` 의 prefix —
    // 짧은 토큰이 먼저 치환되면 긴 토큰의 앞부분이 망가진다. Zig subs 순서와 JS
    // PLACEHOLDERS 순서가 같은 invariant 를 따르는지 검증.
    const tokens = Array.from(extractZigSubs().keys());
    for (let i = 0; i < tokens.length; i++) {
      for (let j = i + 1; j < tokens.length; j++) {
        // tokens[j] 가 tokens[i] 의 prefix 면 짧은 토큰이 긴 토큰보다 먼저 등장 — BAD.
        expect(
          tokens[i].startsWith(tokens[j]),
          `"${tokens[j]}" 가 "${tokens[i]}" 의 prefix 인데 더 먼저 등장 — 순서 swap 필요`,
        ).toBe(false);
      }
    }
  });
});
