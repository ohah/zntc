// Native `watch()` 의 `WatchRebuildEvent` → web overlay HmrChannel broadcast 변환.
// JS dev server (zntc.mjs runServe) 가 직접 fsWatch + runBundle 반복으로 처리하던 자리에
// native watch handle 의 onRebuild 콜백을 끼우면서, 같은 변환을 RN bridge (hmr-bridge.ts) 와
// 일관되게 분리. graph change → full-reload, modules → update sequence, error → reportError.
// 이슈 #3779 — 기존 runServe 는 비-CSS 변경을 무조건 FullReload 로 처리해 state 손실됐다.

import { HMR_MSG } from './protocol.ts';
import type { HmrChannel } from './hmr-channel.ts';

/**
 * `WatchRebuildEvent` 의 최소 표면 — `@zntc/core` 의 정의에 의존하지 않도록
 * structural 정의. 같은 shape 인 한 RN 측 사용과 호환.
 */
export interface RebuildEventLike {
  readonly success: boolean;
  /** Single error tag (catch path) — multi-error 가 있으면 errors 우선. */
  readonly error?: string;
  /**
   * #3799 — Multiple bundler diagnostics (success-but-errors path). file/message 둘 다 보존
   * 해 overlay 가 다중 error + location 정보 표시. 빈 배열이거나 미정의면 `error` fallback.
   */
  readonly errors?: ReadonlyArray<{ readonly file: string; readonly message: string }>;
  readonly graphChanged?: boolean;
  readonly updates?: ReadonlyArray<{ readonly id: string; readonly code: string }>;
}

/**
 * 한 번의 rebuild event 를 적절한 HMR 메시지 sequence 로 변환해 broadcast.
 *
 * - `success=false` → `reportError`
 * - `graphChanged=true` → `clearError` + `FullReload`
 * - `updates` 있음 → `clearError` + `UpdateStart` → `Update(modules)` → `UpdateDone`
 * - 그 외 (code 변경 없음) → `clearError` 만 호출 (#3799 — success 한 rebuild 라 이전 error
 *   latch 도 자동 해제. 사용자가 syntax error 를 whitespace-only edit 등으로 fix 했을 때
 *   overlay 가 stuck 안 되도록.)
 *
 * Return: 어떤 분기로 갔는지 — 호출자가 로그/메트릭에 사용. Test 에서 분기 검증.
 */
export type RebuildBroadcastOutcome = 'error' | 'full-reload' | 'update' | 'noop';

export function broadcastRebuildEvent(
  hmr: HmrChannel,
  event: RebuildEventLike,
): RebuildBroadcastOutcome {
  if (!event.success) {
    // #3799 — multi-error 가 있으면 file/message 둘 다 전달. 단일 `error` 는 catch path 의
    // Zig error tag (예: 'OutOfMemory') 라 fallback.
    if (event.errors && event.errors.length > 0) {
      hmr.reportError(event.errors.map((e) => ({ text: e.message, location: { file: e.file } })));
    } else {
      hmr.reportError([{ text: event.error ?? 'Unknown build error' }]);
    }
    return 'error';
  }
  if (event.graphChanged) {
    hmr.clearError();
    hmr.broadcast({ type: HMR_MSG.FullReload, timestamp: Date.now() });
    return 'full-reload';
  }
  if (event.updates && event.updates.length > 0) {
    hmr.clearError();
    hmr.broadcast({ type: HMR_MSG.UpdateStart });
    hmr.broadcast({
      type: HMR_MSG.Update,
      modules: event.updates.map((u) => ({ id: u.id, code: u.code })),
    });
    hmr.broadcast({ type: HMR_MSG.UpdateDone });
    return 'update';
  }
  // #3799 — 성공한 rebuild + code 변경 없음 (whitespace-only edit 등 bytewise-identical
  // output). 이전 error latch 도 자동 해제 — 사용자가 fix 한 셈. clearError 자체는 broadcast
  // 아님 (state mutation only), 다음 연결되는 client 에게 stale error 가 안 전달되도록 가드.
  hmr.clearError();
  return 'noop';
}
