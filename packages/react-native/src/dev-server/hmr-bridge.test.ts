import { describe, expect, test } from 'bun:test';

import type { WatchHandle, WatchRebuildEvent } from '@zntc/core';

import { createHmrBridge } from './hmr-bridge.ts';
import type { PlatformState } from './platform-state.ts';

function fakeState(platform: 'ios' | 'android' = 'ios'): PlatformState {
  return {
    platform,
    outputDir: '/tmp',
    outputPath: '/tmp/b.js',
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

function recordMessages(adapter: ReturnType<typeof createHmrBridge>['adapter']): RecordedMessage[] {
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

describe('createHmrBridge — onRebuild', () => {
  test('graphChanged=true → reload', () => {
    const bridge = createHmrBridge({ path: '/hot' });
    const recorded = recordMessages(bridge.adapter);
    bridge.callbacks.onRebuild!(fakeState(), rebuild({ graphChanged: true }));
    expect(recorded.map((m) => m.type)).toEqual(['hmr:reload']);
  });

  test('updates 있음 → start/update/done sequence + sourceMappingURL annotation', () => {
    const bridge = createHmrBridge({ path: '/hot' });
    const recorded = recordMessages(bridge.adapter);
    bridge.callbacks.onRebuild!(
      fakeState('android'),
      rebuild({
        updates: [{ id: 'src/foo.ts', code: "console.log('a');" }] as never,
      }),
    );
    expect(recorded.map((m) => m.type)).toEqual([
      'hmr:update-start',
      'hmr:update',
      'hmr:update-done',
    ]);
    const update = recorded[1] as { modules: Array<{ id: string; code: string }> };
    expect(update.modules[0]!.code).toContain(
      '//# sourceMappingURL=/__zntc_hmr_map/src%2Ffoo.ts?platform=android',
    );
  });

  test('updates 비어있고 graph 도 안 변함 → 메시지 0', () => {
    const bridge = createHmrBridge({ path: '/hot' });
    const recorded = recordMessages(bridge.adapter);
    bridge.callbacks.onRebuild!(fakeState(), rebuild());
    expect(recorded).toEqual([]);
  });

  test('success=false → error 메시지 (state.buildError 우선) + body wrapper', () => {
    const bridge = createHmrBridge({ path: '/hot' });
    const recorded = recordMessages(bridge.adapter);
    const state = fakeState();
    state.buildError = 'from state';
    bridge.callbacks.onRebuild!(state, rebuild({ success: false, error: 'from event' } as never));
    expect(recorded[0]).toEqual({
      type: 'hmr:error',
      message: 'from state',
      body: { type: 'BuildError', message: 'from state', errors: [{ description: 'from state' }] },
    });
  });

  test('success=false + state.buildError null → event.error 사용', () => {
    const bridge = createHmrBridge({ path: '/hot' });
    const recorded = recordMessages(bridge.adapter);
    bridge.callbacks.onRebuild!(
      fakeState(),
      rebuild({ success: false, error: 'syntax bad' } as never),
    );
    expect(recorded[0]).toEqual({
      type: 'hmr:error',
      message: 'syntax bad',
      body: { type: 'BuildError', message: 'syntax bad', errors: [{ description: 'syntax bad' }] },
    });
  });

  test('success=false 에서 둘 다 null → fallback 메시지', () => {
    const bridge = createHmrBridge({ path: '/hot' });
    const recorded = recordMessages(bridge.adapter);
    bridge.callbacks.onRebuild!(fakeState(), rebuild({ success: false } as never));
    expect(recorded[0]).toEqual({
      type: 'hmr:error',
      message: 'Unknown build error',
      body: {
        type: 'BuildError',
        message: 'Unknown build error',
        errors: [{ description: 'Unknown build error' }],
      },
    });
  });
});

describe('createHmrBridge — acceptUpgrade', () => {
  test('acceptUpgrade 호출 → channel.accept + initial greeting', () => {
    const bridge = createHmrBridge({ path: '/hot' });
    let acceptCalled = 0;
    let greetingCalled = 0;
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
    bridge.acceptUpgrade({} as never, {} as never);
    expect(acceptCalled).toBe(1);
    expect(greetingCalled).toBe(1);
  });

  test('path readonly 노출', () => {
    const bridge = createHmrBridge({ path: '/__zntc_hot__' });
    expect(bridge.path).toBe('/__zntc_hot__');
  });
});
