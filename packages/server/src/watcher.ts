import { watch as fsWatch } from 'node:fs';
import { resolve as resolvePath } from 'node:path';

export type WatchEventType = 'rename' | 'change';

export interface WatcherInstance {
  close(): void;
  on(event: 'error', listener: (error: NodeJS.ErrnoException) => void): unknown;
}

export interface WatchListener {
  (eventType: WatchEventType, filename: string | null): void;
}

export interface WatchFn {
  (path: string, options: { recursive?: boolean }, listener: WatchListener): WatcherInstance;
}

export interface CreateWatcherOptions {
  paths: readonly string[];
  debounceMs?: number;
  recursive?: boolean;
  onDirty: (paths: ReadonlySet<string>) => void;
  /**
   * Watcher error 처리. EMFILE/ENOSPC 같은 OS 한도 도달 시 `error.code` 로 분기 가능.
   * 호출 직후 watcher 는 fail-soft 자동 close 됨 — caller 는 logging/recovery 만 담당.
   */
  onError?: (error: NodeJS.ErrnoException, path: string) => void;
  /** Test-only DI. Default: `node:fs` 의 `watch`. */
  watch?: WatchFn;
}

export interface WatcherHandle {
  close(): void;
  /** 누적된 dirty path snapshot (next flush 시 비워짐). */
  readonly dirtyPaths: ReadonlySet<string>;
}

const DEFAULT_DEBOUNCE_MS = 30;

export function createWatcher(options: CreateWatcherOptions): WatcherHandle {
  const debounceMs = options.debounceMs ?? DEFAULT_DEBOUNCE_MS;
  const recursive = options.recursive ?? true;
  const watch = options.watch ?? (fsWatch as unknown as WatchFn);

  const watchers: WatcherInstance[] = [];
  const dirty = new Set<string>();
  let timer: ReturnType<typeof setTimeout> | null = null;
  let closed = false;

  function flush(): void {
    timer = null;
    if (closed || dirty.size === 0) return;
    const snapshot = new Set(dirty);
    dirty.clear();
    options.onDirty(snapshot);
  }

  function scheduleFlush(): void {
    if (timer || closed) return;
    timer = setTimeout(flush, debounceMs);
  }

  function safeClose(watcher: WatcherInstance): void {
    try {
      watcher.close();
    } catch {
      // node:fs FSWatcher close() 멱등. 이미 닫혀 있어도 안전.
    }
  }

  for (const path of options.paths) {
    const abs = resolvePath(path);
    try {
      const watcher = watch(abs, { recursive }, (_eventType, filename) => {
        if (closed) return;
        if (typeof filename === 'string' && filename.length > 0) {
          dirty.add(resolvePath(abs, filename));
        } else {
          dirty.add(abs);
        }
        scheduleFlush();
      });
      watcher.on('error', (err) => {
        if (closed) return;
        // zts.mjs parity (L2466-2482): error 후 fail-soft 자동 close.
        // EMFILE/ENOSPC 등 OS 한도 메시지는 caller 가 onError 안에서 처리.
        options.onError?.(err, abs);
        safeClose(watcher);
      });
      watchers.push(watcher);
    } catch (err) {
      options.onError?.(err as NodeJS.ErrnoException, abs);
    }
  }

  return {
    close(): void {
      if (closed) return;
      closed = true;
      if (timer) {
        clearTimeout(timer);
        timer = null;
      }
      for (const watcher of watchers) safeClose(watcher);
    },
    get dirtyPaths(): ReadonlySet<string> {
      return dirty;
    },
  };
}
