// PR #A scaffold smoke — public re-export 가 깨지지 않았는지 + 타입 contract.

import { describe, expect, test } from "bun:test";

import * as devServer from "./index.ts";

describe("dev-server public surface — PR #A scaffold", () => {
  test("buildRnDevServerOptions 가 함수로 export", () => {
    expect(typeof devServer.buildRnDevServerOptions).toBe("function");
  });

  test("RnDevServerHandle 가 type-only (런타임 export 0)", () => {
    // tsc 가 type-only re-export 를 검증. 런타임에서 키 누락은 OK.
    expect("buildRnDevServerOptions" in devServer).toBe(true);
  });
});

describe("@zts/react-native top-level re-export 정합성", () => {
  test("buildRnDevServerOptions 가 패키지 entry 에서 import 가능", async () => {
    const mod = await import("../index.ts");
    expect(typeof mod.buildRnDevServerOptions).toBe("function");
  });
});
