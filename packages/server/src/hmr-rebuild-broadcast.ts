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
  readonly error?: string;
  readonly graphChanged?: boolean;
  readonly updates?: ReadonlyArray<{ readonly id: string; readonly code: string }>;
}

/**
 * 한 번의 rebuild event 를 적절한 HMR 메시지 sequence 로 변환해 broadcast.
 *
 * - `success=false` → `reportError`
 * - `graphChanged=true` → `clearError` + `FullReload`
 * - `updates` 있음 → `clearError` + `UpdateStart` → `Update(modules)` → `UpdateDone`
 * - 그 외 (code 변경 없음) → no-op (`clearError` 도 호출 안 함 — 이전 error latch 보존)
 *
 * Return: 어떤 분기로 갔는지 — 호출자가 로그/메트릭에 사용. Test 에서 분기 검증.
 */
export type RebuildBroadcastOutcome = 'error' | 'full-reload' | 'update' | 'noop';

export function broadcastRebuildEvent(
  hmr: HmrChannel,
  event: RebuildEventLike,
): RebuildBroadcastOutcome {
  if (!event.success) {
    hmr.reportError([{ text: event.error ?? 'Unknown build error' }]);
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
  return 'noop';
}
