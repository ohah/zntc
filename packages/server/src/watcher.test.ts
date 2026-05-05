import { describe, expect, mock, test } from "bun:test";
import { EventEmitter } from "node:events";
import { resolve as resolvePath } from "node:path";

import {
  type WatchFn,
  type WatchListener,
  type WatcherInstance,
  createWatcher,
} from "./watcher.ts";

interface RegisteredWatch {
  path: string;
  options: { recursive?: boolean };
  listener: WatchListener;
  watcher: MockWatcherInstance;
}

class MockWatcherInstance extends EventEmitter implements WatcherInstance {
  closed = false;
  closeCalls = 0;
  close(): void {
    this.closed = true;
    this.closeCalls += 1;
  }
}

interface MockWatchHarness {
  watch: WatchFn;
  registered: RegisteredWatch[];
}

function createMockWatch(): MockWatchHarness {
  const registered: RegisteredWatch[] = [];
  const watch: WatchFn = (path, options, listener) => {
    const watcher = new MockWatcherInstance();
    registered.push({ path, options, listener, watcher });
    return watcher;
  };
  return { watch, registered };
}

function flushTimers(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

describe("createWatcher — fs.watch wrapper", () => {
  test("paths 마다 watch 호출 + recursive default true", () => {
    const { watch, registered } = createMockWatch();
    const handle = createWatcher({
      paths: ["a", "b"],
      onDirty: () => {},
      watch,
    });
    expect(registered.length).toBe(2);
    expect(registered[0]!.path).toBe(resolvePath("a"));
    expect(registered[0]!.options.recursive).toBe(true);
    expect(registered[1]!.path).toBe(resolvePath("b"));
    handle.close();
  });

  test("recursive false 옵션 전달", () => {
    const { watch, registered } = createMockWatch();
    const handle = createWatcher({
      paths: ["x"],
      recursive: false,
      onDirty: () => {},
      watch,
    });
    expect(registered[0]!.options.recursive).toBe(false);
    handle.close();
  });

  test("change 이벤트 → dirty path 누적 → debounce 후 onDirty", async () => {
    const { watch, registered } = createMockWatch();
    const onDirty = mock((_paths: ReadonlySet<string>) => {});
    const handle = createWatcher({
      paths: ["root"],
      debounceMs: 5,
      onDirty,
      watch,
    });
    registered[0]!.listener("change", "a.ts");
    registered[0]!.listener("change", "b.ts");
    expect(onDirty).toHaveBeenCalledTimes(0);
    await flushTimers(20);
    expect(onDirty).toHaveBeenCalledTimes(1);
    const arg = onDirty.mock.calls[0]![0]!;
    expect(arg.has(resolvePath("root", "a.ts"))).toBe(true);
    expect(arg.has(resolvePath("root", "b.ts"))).toBe(true);
    handle.close();
  });

  test("filename null 이면 base path 자체를 dirty 로 표시", async () => {
    const { watch, registered } = createMockWatch();
    const onDirty = mock((_paths: ReadonlySet<string>) => {});
    const handle = createWatcher({
      paths: ["root"],
      debounceMs: 5,
      onDirty,
      watch,
    });
    registered[0]!.listener("rename", null);
    await flushTimers(20);
    const arg = onDirty.mock.calls[0]![0]!;
    expect(arg.has(resolvePath("root"))).toBe(true);
    handle.close();
  });

  test("debounce: 빠른 연속 이벤트는 1회 onDirty 로 수렴", async () => {
    const { watch, registered } = createMockWatch();
    const onDirty = mock((_paths: ReadonlySet<string>) => {});
    const handle = createWatcher({
      paths: ["root"],
      debounceMs: 10,
      onDirty,
      watch,
    });
    for (let i = 0; i < 5; i += 1) {
      registered[0]!.listener("change", `f${i}.ts`);
    }
    await flushTimers(30);
    expect(onDirty).toHaveBeenCalledTimes(1);
    expect(onDirty.mock.calls[0]![0]!.size).toBe(5);
    handle.close();
  });

  test("flush 후 dirty Set 은 비워져 다음 batch 누적 시작", async () => {
    const { watch, registered } = createMockWatch();
    const onDirty = mock((_paths: ReadonlySet<string>) => {});
    const handle = createWatcher({
      paths: ["root"],
      debounceMs: 5,
      onDirty,
      watch,
    });
    registered[0]!.listener("change", "a.ts");
    await flushTimers(20);
    expect(onDirty.mock.calls[0]![0]!.size).toBe(1);

    registered[0]!.listener("change", "b.ts");
    await flushTimers(20);
    expect(onDirty).toHaveBeenCalledTimes(2);
    expect(onDirty.mock.calls[1]![0]!.size).toBe(1);
    expect(onDirty.mock.calls[1]![0]!.has(resolvePath("root", "b.ts"))).toBe(true);
    handle.close();
  });

  test("watcher emit 'error' → onError 콜백 + 자동 close (zts.mjs parity)", () => {
    const { watch, registered } = createMockWatch();
    const onError = mock((_err: Error, _path: string) => {});
    const handle = createWatcher({
      paths: ["root"],
      onDirty: () => {},
      onError,
      watch,
    });
    const err = new Error("boom");
    registered[0]!.watcher.emit("error", err);
    expect(onError).toHaveBeenCalledTimes(1);
    expect(onError.mock.calls[0]![0]).toBe(err);
    expect(onError.mock.calls[0]![1]).toBe(resolvePath("root"));
    expect(registered[0]!.watcher.closed).toBe(true);
    handle.close();
  });

  test("EMFILE/ENOSPC 같은 ErrnoException code 가 onError 에 전달", () => {
    const { watch, registered } = createMockWatch();
    const onError = mock((_err: NodeJS.ErrnoException, _path: string) => {});
    const handle = createWatcher({
      paths: ["root"],
      onDirty: () => {},
      onError,
      watch,
    });
    const err: NodeJS.ErrnoException = Object.assign(new Error("too many open"), {
      code: "EMFILE",
    });
    registered[0]!.watcher.emit("error", err);
    expect(onError.mock.calls[0]![0].code).toBe("EMFILE");
    handle.close();
  });

  test("error 후에는 추가 이벤트 와도 onDirty 안 호출됨 (auto-close 효과)", async () => {
    const { watch, registered } = createMockWatch();
    const onDirty = mock((_paths: ReadonlySet<string>) => {});
    const handle = createWatcher({
      paths: ["root"],
      debounceMs: 5,
      onDirty,
      onError: () => {},
      watch,
    });
    registered[0]!.watcher.emit("error", new Error("x"));
    // 자동 close 후 listener 가 만든 이벤트 — 단위 테스트의 mock 이라 listener
    // 가 직접 호출 가능. 그러나 closed 상태라 dirty 누적 안 됨.
    handle.close();
    registered[0]!.listener("change", "f.ts");
    await flushTimers(20);
    expect(onDirty).toHaveBeenCalledTimes(0);
  });

  test("watch() 가 throw 하면 onError 로 흡수 후 다음 path 계속", () => {
    const onError = mock((_err: Error, _path: string) => {});
    const calls: string[] = [];
    const watch: WatchFn = (path, _opts, _listener) => {
      calls.push(path);
      if (path.endsWith("bad")) throw new Error("nope");
      return new MockWatcherInstance();
    };
    const handle = createWatcher({
      paths: ["bad", "good"],
      onDirty: () => {},
      onError,
      watch,
    });
    expect(calls.length).toBe(2);
    expect(onError).toHaveBeenCalledTimes(1);
    expect(onError.mock.calls[0]![0]!.message).toBe("nope");
    handle.close();
  });

  test("close() 는 모든 watcher 닫고 timer clear", async () => {
    const { watch, registered } = createMockWatch();
    const onDirty = mock((_paths: ReadonlySet<string>) => {});
    const handle = createWatcher({
      paths: ["a", "b"],
      debounceMs: 50,
      onDirty,
      watch,
    });
    registered[0]!.listener("change", "f.ts");
    handle.close();
    expect(registered[0]!.watcher.closed).toBe(true);
    expect(registered[1]!.watcher.closed).toBe(true);
    await flushTimers(80);
    expect(onDirty).toHaveBeenCalledTimes(0);
  });

  test("close() 멱등 (두 번 호출 안전)", () => {
    const { watch, registered } = createMockWatch();
    const handle = createWatcher({ paths: ["a"], onDirty: () => {}, watch });
    handle.close();
    handle.close();
    expect(registered[0]!.watcher.closeCalls).toBe(1);
  });

  test("close() 후 이벤트 들어와도 onDirty 호출 안 됨", async () => {
    const { watch, registered } = createMockWatch();
    const onDirty = mock((_paths: ReadonlySet<string>) => {});
    const handle = createWatcher({
      paths: ["a"],
      debounceMs: 5,
      onDirty,
      watch,
    });
    handle.close();
    registered[0]!.listener("change", "f.ts");
    await flushTimers(20);
    expect(onDirty).toHaveBeenCalledTimes(0);
  });

  test("watcher.close() 가 throw 해도 다른 watcher 정리 계속", () => {
    const watch: WatchFn = () => {
      const w = new MockWatcherInstance();
      // 첫 번째만 close throw
      const original = w.close.bind(w);
      let throwOnce = true;
      w.close = () => {
        if (throwOnce) {
          throwOnce = false;
          throw new Error("close failed");
        }
        original();
      };
      return w;
    };
    const handle = createWatcher({ paths: ["a", "b"], onDirty: () => {}, watch });
    expect(() => handle.close()).not.toThrow();
  });

  test("dirtyPaths 는 readonly 하지만 내부 set 의 live view (flush 전까지)", () => {
    const { watch, registered } = createMockWatch();
    const handle = createWatcher({
      paths: ["root"],
      debounceMs: 1000,
      onDirty: () => {},
      watch,
    });
    registered[0]!.listener("change", "a.ts");
    expect(handle.dirtyPaths.size).toBe(1);
    expect(handle.dirtyPaths.has(resolvePath("root", "a.ts"))).toBe(true);
    handle.close();
  });

  test("debounceMs 미지정 default 사용 (정확히 30ms 가 아닌 약간의 시간 후 flush)", async () => {
    const { watch, registered } = createMockWatch();
    const onDirty = mock((_paths: ReadonlySet<string>) => {});
    const handle = createWatcher({ paths: ["a"], onDirty, watch });
    registered[0]!.listener("change", "f.ts");
    await flushTimers(60);
    expect(onDirty).toHaveBeenCalledTimes(1);
    handle.close();
  });
});
