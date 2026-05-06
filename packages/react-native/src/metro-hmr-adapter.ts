// Metro HMR adapter — `@zts/server.HmrChannel` 위 thin wrapper. caller (번개
// dev server) 가 RN runtime 의 HMRClient interface 호환 메시지 (`hmr:update-start`
// / `hmr:update` / `hmr:update-done` / `hmr:reload` / `hmr:error`) 를 type-safe
// 하게 송출. revisionId 기반 delta 자체는 caller 가 관리 — adapter 는 메시지
// union 만 통과.

import {
  type BunHmrClient,
  createHmrChannel,
  type HmrChannel,
  HMR_RN_MSG,
  type HmrRnErrorBody,
  type HmrRnErrorEntry,
  type HmrRnUpdateModule,
} from '@zts/server';

// ZTS error string 의 위치 추출 — `<file>.tsx?:<line>:<col>` 형태. Metro 의
// BuildError 의 file:line:col 과 같은 형식으로 정규화 — RN LogBox 의 source link.
const ZTS_LOCATION_RE = /([^\s]+\.[jt]sx?):(\d+):(\d+)/;

/**
 * ZTS build error → Metro 호환 `BuildError` body 로 변환. file:line:col 추출
 * 실패해도 단일 entry 의 description 만으로 fallback. bungae 의 formatHmrError
 * (zts-bundler/server/index.ts L824) 와 동일 로직 (#2605 audit).
 */
export function formatBuildError(message: string): HmrRnErrorBody {
  const match = message.match(ZTS_LOCATION_RE);
  const errors: HmrRnErrorEntry[] = match
    ? [
        {
          description: message,
          filename: match[1]!,
          lineNumber: Number.parseInt(match[2]!, 10),
          column: Number.parseInt(match[3]!, 10),
        },
      ]
    : [{ description: message }];
  return { type: 'BuildError', message, errors };
}

export interface MetroHmrAdapter {
  /**
   * 내부 HmrChannel — caller 가 직접 `accept(req, socket)` (Node http upgrade)
   * 또는 `addBunClient(ws)` (Bun.serve websocket) 로 lifecycle 등록. adapter
   * 는 send 만 wrapping 하므로 channel 자체에 직접 접근 가능.
   */
  readonly channel: HmrChannel;
  /**
   * Initial connection 직후 송출 — `update-start{isInitialUpdate:true}` →
   * `update-done` sequence. RN runtime 의 'Refreshing...' 배너 회피용. caller
   * 가 새 client connection 후 한 번 호출.
   */
  sendInitialGreeting(): void;
  /** Module delta 송출. caller 가 revisionId 따라 modules 배열 구성. */
  sendUpdate(modules: readonly HmrRnUpdateModule[]): void;
  /** RN runtime 의 `__zts_reload()` 또는 `location.reload()` 호출. */
  sendReload(): void;
  /** RN runtime 의 `console.error('[ZTS HMR]', message)` 호출. */
  sendError(message: string): void;
}

export function createMetroHmrAdapter(): MetroHmrAdapter {
  const channel = createHmrChannel();

  return {
    channel,
    sendInitialGreeting() {
      channel.broadcast({ type: HMR_RN_MSG.UpdateStart, isInitialUpdate: true });
      channel.broadcast({ type: HMR_RN_MSG.UpdateDone });
    },
    sendUpdate(modules) {
      channel.broadcast({ type: HMR_RN_MSG.UpdateStart });
      channel.broadcast({ type: HMR_RN_MSG.Update, modules: [...modules] });
      channel.broadcast({ type: HMR_RN_MSG.UpdateDone });
    },
    sendReload() {
      channel.broadcast({ type: HMR_RN_MSG.Reload });
    },
    sendError(message) {
      channel.broadcast({
        type: HMR_RN_MSG.Error,
        message,
        body: formatBuildError(message),
      });
    },
  };
}

export type { BunHmrClient, HmrChannel, HmrRnUpdateModule };
