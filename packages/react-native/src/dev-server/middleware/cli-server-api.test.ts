import { describe, expect, test } from "bun:test";

import { loadCliServerApi } from "./cli-server-api.ts";

describe("loadCliServerApi", () => {
  test("@react-native-community/cli-server-api 미설치 환경 → null", async () => {
    // 본 zts repo 에는 peer dep 으로 설치 안 됨 — graceful skip 검증.
    const result = await loadCliServerApi({ port: 8081, host: "localhost" });
    expect(result).toBeNull();
  });
});
