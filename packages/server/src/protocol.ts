// HMR protocol — web overlay 가 사용하는 메시지 타입.
// RN Metro adapter 는 #2540 에서 별도 protocol 로 추가됨 (revisionId 기반).

export const HMR_MSG = Object.freeze({
  Connected: "connected",
  CssUpdate: "css-update",
  ClearError: "clear-error",
  Error: "error",
  FullReload: "full-reload",
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

export const APP_DEV_HMR_CLIENT_PATH = "/__zts_app_dev_hmr__";
export const APP_DEV_HMR_WS_PATH = "/__hmr";

// RFC 6455 §1.3 — handshake 에 쓰이는 fixed GUID. 변경 불가.
export const HMR_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

interface RawError {
  text?: unknown;
  message?: unknown;
  location?: { file?: unknown };
}

export function normalizeHmrErrors(errors: readonly unknown[] | unknown): HmrError[] {
  if (!Array.isArray(errors) || errors.length === 0) {
    return [{ file: "", message: "Unknown build error" }];
  }
  return errors.map((error: unknown) => {
    const e = (error ?? {}) as RawError;
    const file = typeof e.location?.file === "string" ? e.location.file : "";
    const message = String(e.text ?? e.message ?? error);
    return { file, message };
  });
}
