import { describe, expect, test } from "bun:test";

import { handleDevMenu, isDevMenuRoute } from "./devmenu.ts";

describe("isDevMenuRoute", () => {
  test("/devmenu 매치", () => expect(isDevMenuRoute("/devmenu")).toBe(true));
  test("/dev-menu 미매치 (typo 가드)", () => expect(isDevMenuRoute("/dev-menu")).toBe(false));
});

describe("handleDevMenu", () => {
  test("broadcast('devMenu') + 200 OK", () => {
    const calls: string[] = [];
    let body: string | undefined;
    const res = {
      writeHead() {},
      end(b: string) {
        body = b;
      },
    };
    handleDevMenu({} as never, res as never, (m) => calls.push(m));
    expect(calls).toEqual(["devMenu"]);
    expect(body).toBe("OK");
  });
});
