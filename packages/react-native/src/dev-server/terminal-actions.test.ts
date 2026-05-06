import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test';
import { EventEmitter } from 'node:events';

import { setupTerminalActions, type TerminalActionsCallbacks } from './terminal-actions.ts';

interface FakeStdin extends EventEmitter {
  isTTY: boolean;
  isRaw: boolean;
  setRawMode(mode: boolean): FakeStdin;
  resume(): FakeStdin;
  setEncoding(_encoding: string): FakeStdin;
  emitKey(key: string): void;
}

function makeStdin(opts: { isTTY?: boolean } = {}): FakeStdin {
  const emitter = new EventEmitter() as FakeStdin;
  emitter.isTTY = opts.isTTY ?? true;
  emitter.isRaw = false;
  emitter.setRawMode = (mode) => {
    emitter.isRaw = mode;
    return emitter;
  };
  emitter.resume = () => emitter;
  emitter.setEncoding = () => emitter;
  emitter.emitKey = (key) => emitter.emit('data', key);
  return emitter;
}

function makeCallbacks(): TerminalActionsCallbacks & {
  reloadCount: number;
  devMenuCount: number;
  devToolsCount: number;
  clearCount: number;
} {
  const cb = {
    reloadCount: 0,
    devMenuCount: 0,
    devToolsCount: 0,
    clearCount: 0,
    onReload() {
      cb.reloadCount++;
    },
    onDevMenu() {
      cb.devMenuCount++;
    },
    onOpenDevTools() {
      cb.devToolsCount++;
    },
    onClearCache() {
      cb.clearCount++;
    },
  };
  return cb;
}

let originalKill: typeof process.kill;
let killSpy: (pid: number, sig: string) => void;
let killCalls: Array<[number, string]>;

beforeEach(() => {
  killCalls = [];
  killSpy = (pid, sig) => {
    killCalls.push([pid, sig]);
  };
  originalKill = process.kill;
  process.kill = killSpy as never;
});

afterEach(() => {
  process.kill = originalKill;
});

describe('setupTerminalActions — disabled / non-TTY', () => {
  test('enabled=false → no-op cleanup', () => {
    const cb = makeCallbacks();
    const stdin = makeStdin();
    const cleanup = setupTerminalActions(cb, { enabled: false, stdin });
    expect(stdin.isRaw).toBe(false); // 등록 안 됨
    cleanup();
    expect(stdin.listenerCount('data')).toBe(0);
  });

  test('stdin 비-TTY → no-op cleanup + stderr 알림 (#2605 audit)', () => {
    const cb = makeCallbacks();
    const stdin = makeStdin({ isTTY: false });
    const original = process.stderr.write.bind(process.stderr);
    const writes: string[] = [];
    // @ts-expect-error — runtime mock
    process.stderr.write = (chunk: string | Uint8Array) => {
      writes.push(typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf-8'));
      return true;
    };
    let cleanup: () => void;
    try {
      cleanup = setupTerminalActions(cb, { enabled: true, stdin });
    } finally {
      process.stderr.write = original;
    }
    expect(stdin.isRaw).toBe(false);
    // wrapper script 사용자가 디버그 가능하도록 한 번 stderr 알림.
    expect(writes.join('')).toContain('stdin is not a TTY');
    expect(writes.join('')).toContain('keyboard shortcuts');
    cleanup!();
  });

  test('enabled=false → 알림 없이 no-op (silent)', () => {
    const cb = makeCallbacks();
    const stdin = makeStdin({ isTTY: false });
    const original = process.stderr.write.bind(process.stderr);
    const writes: string[] = [];
    // @ts-expect-error — runtime mock
    process.stderr.write = (chunk: string | Uint8Array) => {
      writes.push(typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf-8'));
      return true;
    };
    try {
      setupTerminalActions(cb, { enabled: false, stdin });
    } finally {
      process.stderr.write = original;
    }
    // enabled=false 는 명시적 disable — 알림 불필요.
    expect(writes.join('')).not.toContain('stdin is not a TTY');
  });
});

describe('setupTerminalActions — keypress 라우팅', () => {
  test('r → onReload', () => {
    const cb = makeCallbacks();
    const stdin = makeStdin();
    const cleanup = setupTerminalActions(cb, { enabled: true, stdin });
    stdin.emitKey('r');
    expect(cb.reloadCount).toBe(1);
    cleanup();
  });

  test('R 대문자 → onReload (toLowerCase)', () => {
    const cb = makeCallbacks();
    const stdin = makeStdin();
    const cleanup = setupTerminalActions(cb, { enabled: true, stdin });
    stdin.emitKey('R');
    expect(cb.reloadCount).toBe(1);
    cleanup();
  });

  test('d → onDevMenu / j → onOpenDevTools / c → onClearCache', () => {
    const cb = makeCallbacks();
    const stdin = makeStdin();
    const cleanup = setupTerminalActions(cb, { enabled: true, stdin });
    stdin.emitKey('d');
    stdin.emitKey('j');
    stdin.emitKey('c');
    expect([cb.devMenuCount, cb.devToolsCount, cb.clearCount]).toEqual([1, 1, 1]);
    cleanup();
  });

  test('? → printShortcuts', () => {
    const cb = makeCallbacks();
    const stdin = makeStdin();
    const printShortcuts = mock(() => {});
    const cleanup = setupTerminalActions(cb, { enabled: true, stdin, printShortcuts });
    stdin.emitKey('?');
    expect(printShortcuts).toHaveBeenCalledTimes(1);
    cleanup();
  });

  test('default printShortcuts — console.log 호출 (smoke)', () => {
    const cb = makeCallbacks();
    const stdin = makeStdin();
    const cleanup = setupTerminalActions(cb, { enabled: true, stdin });
    // print 본 경로가 throw 안 하면 OK.
    expect(() => stdin.emitKey('?')).not.toThrow();
    cleanup();
  });

  test('기타 키 → 모든 callback 미호출', () => {
    const cb = makeCallbacks();
    const stdin = makeStdin();
    const cleanup = setupTerminalActions(cb, { enabled: true, stdin });
    stdin.emitKey('x');
    stdin.emitKey('z');
    expect(cb.reloadCount + cb.devMenuCount + cb.devToolsCount + cb.clearCount).toBe(0);
    cleanup();
  });
});

describe('setupTerminalActions — Ctrl+C / Ctrl+D / iOS / Android', () => {
  test('Ctrl+C → SIGINT + listener cleanup', () => {
    const cb = makeCallbacks();
    const stdin = makeStdin();
    setupTerminalActions(cb, { enabled: true, stdin });
    stdin.emitKey('');
    expect(killCalls).toEqual([[process.pid, 'SIGINT']]);
    expect(stdin.listenerCount('data')).toBe(0);
  });

  test('Ctrl+D → SIGTERM + listener cleanup', () => {
    const cb = makeCallbacks();
    const stdin = makeStdin();
    setupTerminalActions(cb, { enabled: true, stdin });
    stdin.emitKey('');
    expect(killCalls).toEqual([[process.pid, 'SIGTERM']]);
    expect(stdin.listenerCount('data')).toBe(0);
  });

  test('i → iOS Sim (darwin 외 환경 throw 없음)', () => {
    const cb = makeCallbacks();
    const stdin = makeStdin();
    const cleanup = setupTerminalActions(cb, { enabled: true, stdin });
    expect(() => stdin.emitKey('i')).not.toThrow();
    cleanup();
  });

  test('a → Android Emulator (env 없으면 silent skip)', () => {
    const cb = makeCallbacks();
    const stdin = makeStdin();
    const original = process.env.ANDROID_HOME;
    delete process.env.ANDROID_HOME;
    delete process.env.ANDROID_SDK_ROOT;
    const cleanup = setupTerminalActions(cb, { enabled: true, stdin });
    expect(() => stdin.emitKey('a')).not.toThrow();
    cleanup();
    if (original) process.env.ANDROID_HOME = original;
  });
});

describe('setupTerminalActions — cleanup', () => {
  test('cleanup() 호출 → listener 제거 + raw mode 복원', () => {
    const cb = makeCallbacks();
    const stdin = makeStdin();
    const cleanup = setupTerminalActions(cb, { enabled: true, stdin });
    expect(stdin.isRaw).toBe(true);
    expect(stdin.listenerCount('data')).toBe(1);
    cleanup();
    expect(stdin.isRaw).toBe(false);
    expect(stdin.listenerCount('data')).toBe(0);
  });

  test('cleanup() 두 번 호출 idempotent', () => {
    const cb = makeCallbacks();
    const stdin = makeStdin();
    const cleanup = setupTerminalActions(cb, { enabled: true, stdin });
    cleanup();
    expect(() => cleanup()).not.toThrow();
  });
});
