import { describe, expect, test } from "bun:test";

import { handleReload, isReloadRoute } from "./reload.ts";

describe("isReloadRoute", () => {
  test("/reload 매치", () => expect(isReloadRoute("/reload")).toBe(true));
  test("다른 path 미매치", () => expect(isReloadRoute("/devmenu")).toBe(false));
});

describe("handleReload", () => {
  test("broadcast('reload') + 200 OK", () => {
    const calls: Array<[string, unknown?]> = [];
    let body: string | undefined;
    let code: number | undefined;
    const res = {
      writeHead(c: number) {
        code = c;
      },
      end(b: string) {
        body = b;
      },
    };
    handleReload({} as never, res as never, (m, p) => calls.push([m, p]));
    expect(calls).toEqual([["reload", undefined]]);
    expect(code).toBe(200);
    expect(body).toBe("OK");
  });
});
