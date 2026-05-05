import { describe, expect, test } from "bun:test";

import { handleIndexPage, isIndexRoute } from "./index-page.ts";

describe("isIndexRoute", () => {
  test("/ 매치", () => expect(isIndexRoute("/")).toBe(true));
  test("/index.html 매치", () => expect(isIndexRoute("/index.html")).toBe(true));
  test("다른 path 미매치", () => expect(isIndexRoute("/status")).toBe(false));
  test("/foo 미매치", () => expect(isIndexRoute("/foo")).toBe(false));
});

describe("handleIndexPage", () => {
  test("HTML 응답 + bundle/map/HMR link 포함", () => {
    let statusCode: number | undefined;
    let body: string | undefined;
    let headers: Record<string, unknown> | undefined;
    const res = {
      writeHead(c: number, h: Record<string, unknown>) {
        statusCode = c;
        headers = h;
      },
      end(b: string) {
        body = b;
      },
    };
    handleIndexPage({} as never, res as never, 8081);
    expect(statusCode).toBe(200);
    expect(headers!["Content-Type"]).toBe("text/html; charset=utf-8");
    expect(body).toContain("ZTS RN Dev Server");
    expect(body).toContain("/index.bundle?platform=ios&dev=true");
    expect(body).toContain("/index.bundle?platform=android&dev=true");
    expect(body).toContain("/index.bundle.map?platform=ios");
    expect(body).toContain("ws://localhost:8081/hot");
  });

  test("port 동적 적용", () => {
    let body: string | undefined;
    const res = {
      writeHead() {},
      end(b: string) {
        body = b;
      },
    };
    handleIndexPage({} as never, res as never, 9999);
    expect(body).toContain("ws://localhost:9999/hot");
    expect(body).toContain("port 9999");
  });
});
