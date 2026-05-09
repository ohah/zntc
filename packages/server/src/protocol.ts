// HMR protocol — web overlay 가 사용하는 메시지 타입 (HMR_MSG / HmrMessage union).
// RN Metro 호환 메시지 타입은 별도 namespace (HMR_RN_MSG / HmrRnMessage) — Metro 의
// `hmr:update-start` / `hmr:update` / `hmr:update-done` / `hmr:reload` / `hmr:error` /
// `log` 그대로 (RN 런타임의 HMRClient 가 소비). web 의 HMR_MSG 와 직교 (#2540).

export const HMR_MSG: Readonly<{
  Connected: 'connected';
  CssUpdate: 'css-update';
  ClearError: 'clear-error';
  Error: 'error';
  FullReload: 'full-reload';
}> = Object.freeze({
  Connected: 'connected',
  CssUpdate: 'css-update',
  ClearError: 'clear-error',
  Error: 'error',
  FullReload: 'full-reload',
} as const);

export type HmrMessageType = (typeof HMR_MSG)[keyof typeof HMR_MSG];

export interface HmrError {
  file: string;
  message: string;
}

export interface HmrConnectedMessage {
  type: typeof HMR_MSG.Connected;
}

export interface HmrCssUpdateMessage {
  type: typeof HMR_MSG.CssUpdate;
  href: string;
  timestamp: number;
}

export interface HmrClearErrorMessage {
  type: typeof HMR_MSG.ClearError;
  timestamp?: number;
}

export interface HmrErrorMessage {
  type: typeof HMR_MSG.Error;
  errors: HmrError[];
  timestamp: number;
}

export interface HmrFullReloadMessage {
  type: typeof HMR_MSG.FullReload;
  timestamp: number;
}

export type HmrMessage =
  | HmrConnectedMessage
  | HmrCssUpdateMessage
  | HmrClearErrorMessage
  | HmrErrorMessage
  | HmrFullReloadMessage;

export const APP_DEV_HMR_CLIENT_PATH = '/__zntc_app_dev_hmr__';
export const APP_DEV_HMR_WS_PATH = '/__hmr';

// RFC 6455 §1.3 — handshake 에 쓰이는 fixed GUID. 변경 불가.
export const HMR_WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

interface RawError {
  text?: unknown;
  message?: unknown;
  location?: { file?: unknown };
}

export function normalizeHmrErrors(errors: readonly unknown[] | unknown): HmrError[] {
  if (!Array.isArray(errors) || errors.length === 0) {
    return [{ file: '', message: 'Unknown build error' }];
  }
  return errors.map((error: unknown) => {
    const e = (error ?? {}) as RawError;
    const file = typeof e.location?.file === 'string' ? e.location.file : '';
    const message = String(e.text ?? e.message ?? error);
    return { file, message };
  });
}

// ─── React Native Metro HMR protocol (#2540) ─────────────────────────────────
// Metro 의 메시지 type literal 은 `hmr:` prefix — RN runtime (zntc-hmr-client.js)
// 의 onmessage 분기 키. revisionId 기반 delta 는 caller (번개 server) 가 관리,
// adapter 는 메시지 union 만 통과.

export const HMR_RN_MSG: Readonly<{
  UpdateStart: 'hmr:update-start';
  Update: 'hmr:update';
  UpdateDone: 'hmr:update-done';
  Reload: 'hmr:reload';
  Error: 'hmr:error';
  Log: 'log';
}> = Object.freeze({
  UpdateStart: 'hmr:update-start',
  Update: 'hmr:update',
  UpdateDone: 'hmr:update-done',
  Reload: 'hmr:reload',
  Error: 'hmr:error',
  Log: 'log',
} as const);

export type HmrRnMessageType = (typeof HMR_RN_MSG)[keyof typeof HMR_RN_MSG];

export interface HmrRnUpdateModule {
  /** Metro module id — number (Metro 호환) 또는 string (named module). */
  id: string | number;
  /** 모듈 wrapper 코드 (Metro `__d(...)` 호환). */
  code: string;
  /** sourceMappingURL 이 적용될 inline sourcemap (optional). */
  map?: string;
}

export interface HmrRnUpdateStartMessage {
  type: typeof HMR_RN_MSG.UpdateStart;
  /** initial connection 직후 송출하는 더미 update 시 true — RN 런타임의 'Refreshing…' 배너 회피. */
  isInitialUpdate?: boolean;
}

export interface HmrRnUpdateMessage {
  type: typeof HMR_RN_MSG.Update;
  modules: HmrRnUpdateModule[];
}

export interface HmrRnUpdateDoneMessage {
  type: typeof HMR_RN_MSG.UpdateDone;
}

export interface HmrRnReloadMessage {
  type: typeof HMR_RN_MSG.Reload;
}

/**
 * Build error 한 항목 — file:line:col 정보 (가능한 경우). RN LogBox 의 source
 * link 표시용.
 */
export interface HmrRnErrorEntry {
  description: string;
  filename?: string;
  lineNumber?: number;
  column?: number;
}

/** Metro `BuildError` body wrapper — RN HMRClient 의 LogBox 와 호환. */
export interface HmrRnErrorBody {
  type: 'BuildError';
  message: string;
  errors: HmrRnErrorEntry[];
}

export interface HmrRnErrorMessage {
  type: typeof HMR_RN_MSG.Error;
  /** Backward-compat — 단순 텍스트 표시용 fallback. */
  message: string;
  /** Metro 호환 nested wrapper — file:line:col 파싱 결과. */
  body?: HmrRnErrorBody;
}

export interface HmrRnLogMessage {
  type: typeof HMR_RN_MSG.Log;
  level: 'log' | 'info' | 'warn' | 'error' | 'debug';
  data: unknown[];
}

export type HmrRnMessage =
  | HmrRnUpdateStartMessage
  | HmrRnUpdateMessage
  | HmrRnUpdateDoneMessage
  | HmrRnReloadMessage
  | HmrRnErrorMessage
  | HmrRnLogMessage;
