import { describe, expect, test } from "bun:test";
import type { Server } from "node:http";

import type { WatchHandle, WatchRebuildEvent } from "@zts/core";

import { createHmrBridge } from "./hmr-bridge.ts";
import type { PlatformState } from "./platform-state.ts";

function fakeState(platform: "ios" | "android" = "ios"): PlatformState {
  return {
    platform,
    outputDir: "/tmp",
    outputPath: "/tmp/b.js",
    handle: {
      stop() {},
      getBundleSourceMap: () => null,
      getHmrSourceMap: () => null,
    } as unknown as WatchHandle,
    bundle: null,
    sourceMapCache: null,
    buildError: null,
    fileCount: 1,
    lastRebuildTime: 0,
  };
}

interface RecordedMessage {
  type: string;
  [k: string]: unknown;
}

function recordMessages(adapter: ReturnType<typeof createHmrBridge>["adapter"]): RecordedMessage[] {
  const recorded: RecordedMessage[] = [];
  const channel = adapter.channel as unknown as {
    broadcast: (msg: RecordedMessage) => void;
  };
  const orig = channel.broadcast.bind(channel);
  channel.broadcast = (msg) => {
    recorded.push(msg);
    orig(msg);
  };
  return recorded;
}

function rebuild(overrides: Partial<WatchRebuildEvent> = {}): WatchRebuildEvent {
  return {
    success: true,
    changed: [],
    updates: [],
    graphChanged: false,
    ...overrides,
  } as WatchRebuildEvent;
}

describe("createHmrBridge — onRebuild", () => {
  test("graphChanged=true → reload", () => {
    const bridge = createHmrBridge({ path: "/hot", host: "localhost", port: 8081 });
    const recorded = recordMessages(bridge.adapter);
    bridge.callbacks.onRebuild!(fakeState(), rebuild({ graphChanged: true }));
    expect(recorded.map((m) => m.type)).toEqual(["hmr:reload"]);
  });

  test("updates 있음 → start/update/done sequence + sourceMappingURL annotation", () => {
    const bridge = createHmrBridge({ path: "/hot", host: "localhost", port: 8081 });
    const recorded = recordMessages(bridge.adapter);
    bridge.callbacks.onRebuild!(
      fakeState("android"),
      rebuild({
        updates: [{ id: "src/foo.ts", code: "console.log('a');" }] as never,
      }),
    );
    expect(recorded.map((m) => m.type)).toEqual([
      "hmr:update-start",
      "hmr:update",
      "hmr:update-done",
    ]);
    const update = recorded[1] as { modules: Array<{ id: string; code: string }> };
    expect(update.modules[0]!.code).toContain(
      "//# sourceMappingURL=/__zts_hmr_map/src%2Ffoo.ts?platform=android",
    );
  });

  test("updates 비어있고 graph 도 안 변함 → 메시지 0", () => {
    const bridge = createHmrBridge({ path: "/hot", host: "localhost", port: 8081 });
    const recorded = recordMessages(bridge.adapter);
    bridge.callbacks.onRebuild!(fakeState(), rebuild());
    expect(recorded).toEqual([]);
  });

  test("success=false → error 메시지 (state.buildError 우선)", () => {
    const bridge = createHmrBridge({ path: "/hot", host: "localhost", port: 8081 });
    const recorded = recordMessages(bridge.adapter);
    const state = fakeState();
    state.buildError = "from state";
    bridge.callbacks.onRebuild!(state, rebuild({ success: false, error: "from event" } as never));
    expect(recorded[0]).toEqual({ type: "hmr:error", message: "from state" });
  });

  test("success=false + state.buildError null → event.error 사용", () => {
    const bridge = createHmrBridge({ path: "/hot", host: "localhost", port: 8081 });
    const recorded = recordMessages(bridge.adapter);
    bridge.callbacks.onRebuild!(
      fakeState(),
      rebuild({ success: false, error: "syntax bad" } as never),
    );
    expect(recorded[0]).toEqual({ type: "hmr:error", message: "syntax bad" });
  });

  test("success=false 에서 둘 다 null → fallback 메시지", () => {
    const bridge = createHmrBridge({ path: "/hot", host: "localhost", port: 8081 });
    const recorded = recordMessages(bridge.adapter);
    bridge.callbacks.onRebuild!(fakeState(), rebuild({ success: false } as never));
    expect(recorded[0]).toEqual({ type: "hmr:error", message: "Unknown build error" });
  });
});

describe("createHmrBridge — attachToServer", () => {
  test("server.on('upgrade') 등록 + /hot path 시 channel.accept + initial greeting 호출", () => {
    const bridge = createHmrBridge({ path: "/hot", host: "localhost", port: 8081 });
    let acceptCalled = 0;
    let greetingCalled = 0;
    // accept 와 sendInitialGreeting 을 spy 로 교체.
    const adapter = bridge.adapter as unknown as {
      channel: { accept: (req: unknown, sock: unknown) => void };
      sendInitialGreeting: () => void;
    };
    adapter.channel.accept = () => {
      acceptCalled++;
    };
    adapter.sendInitialGreeting = () => {
      greetingCalled++;
    };

    const listeners: Array<(req: unknown, sock: unknown, head: unknown) => void> = [];
    const fakeServer = {
      on(event: string, cb: (req: unknown, sock: unknown, head: unknown) => void) {
        if (event === "upgrade") listeners.push(cb);
      },
    } as never as Server;
    bridge.attachToServer(fakeServer);
    expect(listeners).toHaveLength(1);

    // /hot 호출 — accept + greeting 호출
    listeners[0]!(
      { url: "/hot", headers: { host: "x:8081" } },
      { destroy: () => {} },
      Buffer.alloc(0),
    );
    expect(acceptCalled).toBe(1);
    expect(greetingCalled).toBe(1);
  });

  test("/other path → accept 호출 안 함", () => {
    const bridge = createHmrBridge({ path: "/hot", host: "localhost", port: 8081 });
    let acceptCalled = 0;
    const adapter = bridge.adapter as unknown as {
      channel: { accept: () => void };
      sendInitialGreeting: () => void;
    };
    adapter.channel.accept = () => {
      acceptCalled++;
    };
    adapter.sendInitialGreeting = () => {};

    const listeners: Array<(req: unknown, sock: unknown, head: unknown) => void> = [];
    const fakeServer = {
      on(event: string, cb: (req: unknown, sock: unknown, head: unknown) => void) {
        if (event === "upgrade") listeners.push(cb);
      },
    } as never as Server;
    bridge.attachToServer(fakeServer);
    listeners[0]!(
      { url: "/other", headers: { host: "x:8081" } },
      { destroy: () => {} },
      Buffer.alloc(0),
    );
    expect(acceptCalled).toBe(0);
  });
});
