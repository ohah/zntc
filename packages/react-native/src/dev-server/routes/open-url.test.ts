import { describe, expect, test } from "bun:test";
import { Readable } from "node:stream";

import { handleOpenUrl, isOpenUrlRoute } from "./open-url.ts";

describe("isOpenUrlRoute", () => {
  test("POST /open-url 매치", () => expect(isOpenUrlRoute("/open-url", "POST")).toBe(true));
  test("GET /open-url 미매치 (POST only)", () =>
    expect(isOpenUrlRoute("/open-url", "GET")).toBe(false));
  test("POST /other 미매치", () => expect(isOpenUrlRoute("/other", "POST")).toBe(false));
  test("method undefined 미매치", () => expect(isOpenUrlRoute("/open-url", undefined)).toBe(false));
});

interface Recorded {
  command: string;
  args: string[];
  options: Record<string, unknown>;
}

interface MockRes {
  statusCode?: number;
  payload?: unknown;
  writeHead(c: number): void;
  end(b: string): void;
}

function makeRes(): MockRes {
  return {
    writeHead(c) {
      this.statusCode = c;
    },
    end(b) {
      this.payload = JSON.parse(b);
    },
  };
}

function streamReq(json: string) {
  const r = new Readable({ read() {} });
  r.push(json);
  r.push(null);
  return r;
}

function fakeSpawner(rec: Recorded[]) {
  return ((command: string, args: string[], options: Record<string, unknown>) => {
    rec.push({ command, args, options });
    return { unref() {} };
  }) as never;
}

describe("handleOpenUrl — happy path", () => {
  test("darwin → open <url>", async () => {
    const rec: Recorded[] = [];
    const res = makeRes();
    await handleOpenUrl(
      streamReq('{"url":"https://x.test"}') as never,
      res as never,
      fakeSpawner(rec),
      "darwin",
    );
    expect(rec).toHaveLength(1);
    expect(rec[0]).toMatchObject({ command: "open", args: ["https://x.test"] });
    expect(res.statusCode).toBe(200);
    expect(res.payload).toEqual({ success: true });
  });

  test("win32 → cmd /c start", async () => {
    const rec: Recorded[] = [];
    await handleOpenUrl(
      streamReq('{"url":"https://w.test"}') as never,
      makeRes() as never,
      fakeSpawner(rec),
      "win32",
    );
    expect(rec[0]).toMatchObject({ command: "cmd", args: ["/c", "start", "", "https://w.test"] });
  });

  test("linux → xdg-open", async () => {
    const rec: Recorded[] = [];
    await handleOpenUrl(
      streamReq('{"url":"https://l.test"}') as never,
      makeRes() as never,
      fakeSpawner(rec),
      "linux",
    );
    expect(rec[0].command).toBe("xdg-open");
  });
});

describe("handleOpenUrl — error path", () => {
  test("invalid JSON → 400 + error 응답", async () => {
    const res = makeRes();
    await handleOpenUrl(streamReq("not json") as never, res as never, fakeSpawner([]), "linux");
    expect(res.statusCode).toBe(400);
    expect(res.payload).toEqual({ error: "Invalid JSON body" });
  });

  test("body.url 누락 → 400", async () => {
    const res = makeRes();
    await handleOpenUrl(streamReq("{}") as never, res as never, fakeSpawner([]), "linux");
    expect(res.statusCode).toBe(400);
    expect(res.payload).toEqual({ error: "Invalid URL" });
  });

  test("url 이 빈 문자열 → 400", async () => {
    const res = makeRes();
    await handleOpenUrl(streamReq('{"url":""}') as never, res as never, fakeSpawner([]), "linux");
    expect(res.statusCode).toBe(400);
  });

  test("url 이 number → 400", async () => {
    const res = makeRes();
    await handleOpenUrl(streamReq('{"url":42}') as never, res as never, fakeSpawner([]), "linux");
    expect(res.statusCode).toBe(400);
  });

  test("spawn 이 throw → 500", async () => {
    const res = makeRes();
    const spawner = (() => {
      throw new Error("ENOENT");
    }) as never;
    await handleOpenUrl(
      streamReq('{"url":"https://x.test"}') as never,
      res as never,
      spawner,
      "linux",
    );
    expect(res.statusCode).toBe(500);
    expect(res.payload).toEqual({ error: "Failed to open URL" });
  });
});
