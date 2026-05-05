import { describe, expect, test } from "bun:test";
import {
  APP_DEV_HMR_CLIENT_PATH,
  APP_DEV_HMR_WS_PATH,
  HMR_MSG,
  HMR_WS_GUID,
  type HmrMessage,
  normalizeHmrErrors,
} from "./protocol.ts";

describe("HMR_MSG enum", () => {
  test("모든 메시지 타입이 string literal", () => {
    expect(HMR_MSG.Connected).toBe("connected");
    expect(HMR_MSG.CssUpdate).toBe("css-update");
    expect(HMR_MSG.ClearError).toBe("clear-error");
    expect(HMR_MSG.Error).toBe("error");
    expect(HMR_MSG.FullReload).toBe("full-reload");
  });

  test("frozen 객체로 런타임 변경 불가", () => {
    expect(Object.isFrozen(HMR_MSG)).toBe(true);
  });
});

describe("protocol 상수", () => {
  test("client/ws path 가 정의된 namespace", () => {
    expect(APP_DEV_HMR_CLIENT_PATH).toBe("/__zts_app_dev_hmr__");
    expect(APP_DEV_HMR_WS_PATH).toBe("/__hmr");
  });

  test("RFC 6455 GUID 는 spec 고정값", () => {
    expect(HMR_WS_GUID).toBe("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
  });
});

describe("HmrMessage type 의 round-trip", () => {
  test("Connected", () => {
    const msg: HmrMessage = { type: HMR_MSG.Connected };
    expect(JSON.parse(JSON.stringify(msg))).toEqual({ type: "connected" });
  });

  test("CssUpdate 는 href + timestamp", () => {
    const msg: HmrMessage = {
      type: HMR_MSG.CssUpdate,
      href: "/styles.css",
      timestamp: 12345,
    };
    expect(JSON.parse(JSON.stringify(msg))).toEqual({
      type: "css-update",
      href: "/styles.css",
      timestamp: 12345,
    });
  });

  test("Error 는 errors[] + timestamp", () => {
    const msg: HmrMessage = {
      type: HMR_MSG.Error,
      errors: [{ file: "a.ts", message: "boom" }],
      timestamp: 1,
    };
    expect(JSON.parse(JSON.stringify(msg))).toEqual({
      type: "error",
      errors: [{ file: "a.ts", message: "boom" }],
      timestamp: 1,
    });
  });

  test("FullReload 는 timestamp", () => {
    const msg: HmrMessage = { type: HMR_MSG.FullReload, timestamp: 9 };
    expect(JSON.parse(JSON.stringify(msg))).toEqual({
      type: "full-reload",
      timestamp: 9,
    });
  });
});

describe("normalizeHmrErrors", () => {
  test("빈 배열은 default 메시지", () => {
    expect(normalizeHmrErrors([])).toEqual([{ file: "", message: "Unknown build error" }]);
  });

  test("배열 아닌 입력도 default 메시지", () => {
    expect(normalizeHmrErrors(null)).toEqual([{ file: "", message: "Unknown build error" }]);
    expect(normalizeHmrErrors(undefined)).toEqual([{ file: "", message: "Unknown build error" }]);
    expect(normalizeHmrErrors("string")).toEqual([{ file: "", message: "Unknown build error" }]);
  });

  test("location.file + text 조합", () => {
    const errors = [{ location: { file: "src/a.ts" }, text: "oops" }];
    expect(normalizeHmrErrors(errors)).toEqual([{ file: "src/a.ts", message: "oops" }]);
  });

  test("text 없으면 message fallback", () => {
    const errors = [{ message: "oops" }];
    expect(normalizeHmrErrors(errors)).toEqual([{ file: "", message: "oops" }]);
  });

  test("text/message 둘 다 없으면 String(error) fallback", () => {
    const errors = ["raw string"];
    expect(normalizeHmrErrors(errors)).toEqual([{ file: "", message: "raw string" }]);
  });

  test("location.file 가 string 아니면 빈 string", () => {
    const errors = [{ location: { file: 123 }, text: "x" }];
    expect(normalizeHmrErrors(errors)).toEqual([{ file: "", message: "x" }]);
  });

  test("null/undefined element 도 안전 처리", () => {
    const errors = [null, undefined];
    expect(normalizeHmrErrors(errors)).toEqual([
      { file: "", message: "null" },
      { file: "", message: "undefined" },
    ]);
  });
});
