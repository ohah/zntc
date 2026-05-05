// routes/* 가 공유하는 헬퍼.

import type { PlatformState, PlatformStateRegistry } from "../platform-state.ts";

/** query param `?platform=ios|android` 검증 후 invalid 면 default. registry 에서 lazy spawn. */
export function resolvePlatform(
  url: URL,
  registry: PlatformStateRegistry,
  defaultPlatform: "ios" | "android",
): PlatformState {
  const param = url.searchParams.get("platform");
  const platform = param === "ios" || param === "android" ? param : defaultPlatform;
  return registry.getOrCreate(platform);
}
