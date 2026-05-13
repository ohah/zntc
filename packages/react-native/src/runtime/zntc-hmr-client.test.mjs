import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname_ = dirname(fileURLToPath(import.meta.url));
const HMR_CLIENT_PATH = join(__dirname_, '..', '..', 'runtime', 'zntc-hmr-client.cjs');
const HMR_CLIENT_SOURCE = readFileSync(HMR_CLIENT_PATH, 'utf-8');

// CommonJS 식 module.exports 패턴 — 평가 후 module.exports 회수.
function loadHmrClient(globalEnv) {
  const moduleObj = { exports: {} };
  const fnSource = `
    var module = arguments[0];
    var global = arguments[1];
    var WebSocket = arguments[2];
    var console = arguments[3];
    var __zntc_apply_update = arguments[4];
    var __zntc_reload = arguments[5];
    var location = arguments[6];
    var window = arguments[7];
    var __ZNTC_FORWARD_CLIENT_LOGS__ = arguments[8];
    var require = arguments[9];
    ${HMR_CLIENT_SOURCE}
    return module.exports;
  `;
  const factory = new Function(fnSource);
  return factory(
    moduleObj,
    globalEnv.global,
    globalEnv.WebSocket,
    globalEnv.console,
    globalEnv.__zntc_apply_update,
    globalEnv.__zntc_reload,
    globalEnv.location,
    globalEnv.window,
    globalEnv.forwardClientLogs,
    globalEnv.require,
  );
}

class MockWebSocket {
  constructor(url) {
    MockWebSocket.lastUrl = url;
    MockWebSocket.instances.push(this);
    this.readyState = 1;
    this.url = url;
    this.sent = [];
    this.onopen = null;
    this.onmessage = null;
    this.onerror = null;
    this.onclose = null;
  }
  send(data) {
    this.sent.push(data);
  }
  close() {
    this.readyState = 3;
    if (this.onclose) this.onclose();
  }
  static reset() {
    MockWebSocket.instances = [];
    MockWebSocket.lastUrl = null;
  }
}
MockWebSocket.instances = [];

let HMRClient;
let mockGlobal;
let mockConsole;
let mockDevLoadingView;
let mockPrettyFormat;
let originalConsole;

beforeEach(() => {
  MockWebSocket.reset();
  mockDevLoadingView = {
    showMessage: mock(() => {}),
    hide: mock(() => {}),
  };
  mockGlobal = {
    WebSocket: MockWebSocket,
    __zntc_apply_update: mock(() => {}),
    __zntc_reload: mock(() => {}),
  };
  mockConsole = {
    log: mock(() => {}),
    info: mock(() => {}),
    warn: mock(() => {}),
    error: mock(() => {}),
    debug: mock(() => {}),
  };
  mockPrettyFormat = {
    format: mock((item) => `formatted:${item && item.message ? item.message : String(item)}`),
    plugins: { ReactElement: {} },
  };
  originalConsole = { ...mockConsole };
  HMRClient = loadHmrClient({
    global: mockGlobal,
    WebSocket: MockWebSocket,
    console: mockConsole,
    __zntc_apply_update: mockGlobal.__zntc_apply_update,
    __zntc_reload: mockGlobal.__zntc_reload,
    location: { reload: mock(() => {}) },
    window: undefined,
    forwardClientLogs: true,
    require: (specifier) => {
      if (specifier === 'pretty-format') return mockPrettyFormat;
      if (specifier === './DevLoadingView') return { default: mockDevLoadingView };
      throw new Error(`Unexpected require: ${specifier}`);
    },
  });
});

afterEach(() => {
  MockWebSocket.reset();
});

describe('module.exports — Metro 호환', () => {
  test('default export 가 module.exports 와 같은 객체 (setUpBatchedBridge 호환)', () => {
    expect(HMRClient.default).toBe(HMRClient);
  });

  test('Metro HMRClient interface 의 method 모두 존재', () => {
    expect(typeof HMRClient.setup).toBe('function');
    expect(typeof HMRClient.enable).toBe('function');
    expect(typeof HMRClient.disable).toBe('function');
    expect(typeof HMRClient.registerBundle).toBe('function');
    expect(typeof HMRClient.log).toBe('function');
  });
});

describe('setup()', () => {
  test('WebSocket URL 형성 (`wss://` for https scheme)', () => {
    HMRClient.setup('ios', '/abs/index.js', 'localhost', 8081, true, 'https');
    expect(MockWebSocket.lastUrl).toBe('wss://localhost:8081/hot');
  });

  test('WebSocket URL 형성 (`ws://` for non-https)', () => {
    HMRClient.setup('ios', '/abs/index.js', '127.0.0.1', 8081, true, 'http');
    expect(MockWebSocket.lastUrl).toBe('ws://127.0.0.1:8081/hot');
  });

  test('port 미지정 시 portPart 생략', () => {
    HMRClient.setup('android', '/abs/index.js', 'localhost', null, true, 'http');
    expect(MockWebSocket.lastUrl).toBe('ws://localhost/hot');
  });

  test('port 빈 string 시 portPart 생략', () => {
    HMRClient.setup('android', '/abs/index.js', 'localhost', '', true, 'http');
    expect(MockWebSocket.lastUrl).toBe('ws://localhost/hot');
  });

  test('두 번째 setup 호출은 no-op (idempotent)', () => {
    HMRClient.setup('ios', '/abs/idx.js', 'localhost', 8081, true, 'http');
    HMRClient.setup('android', '/abs/idx.js', 'localhost', 9000, true, 'http');
    expect(MockWebSocket.instances.length).toBe(1);
  });

  test('isEnabled=false 시 _enabled false', () => {
    HMRClient.setup('ios', '/abs/idx.js', 'localhost', 8081, false, 'http');
    expect(HMRClient._enabled).toBe(false);
  });
});

describe('onopen — hmr:connected + Metro log path', () => {
  test("'hmr:connected' 메시지 송출 + bundleEntry/platform 포함", () => {
    HMRClient.setup('ios', '/abs/idx.js', 'localhost', 8081, true, 'http');
    const ws = MockWebSocket.instances[0];
    ws.onopen();
    const msg = JSON.parse(ws.sent[0]);
    expect(msg).toEqual({ type: 'hmr:connected', bundleEntry: '/abs/idx.js', platform: 'ios' });
  });

  test('setup 은 console 을 직접 wrap 하지 않고 HMRClient.log 만 forward', () => {
    HMRClient.setup('ios', '/abs/idx.js', 'localhost', 8081, true, 'http');
    const ws = MockWebSocket.instances[0];
    ws.onopen();
    mockConsole.log('hello');
    expect(originalConsole.log).toHaveBeenCalledWith('hello');
    expect(ws.sent.length).toBe(1);

    HMRClient.log('log', ['hello']);
    expect(ws.sent.length).toBe(2);
    const log = JSON.parse(ws.sent[1]);
    expect(log.type).toBe('log');
    expect(log.level).toBe('log');
    expect(log.data).toEqual(['hello']);
  });

  test('nativeModuleProxy.DevLoadingView 가 있으면 호출 시점 native module 을 직접 사용', () => {
    const nativeDevLoadingView = {
      showMessage: mock(() => {}),
      hide: mock(() => {}),
    };
    HMRClient = loadHmrClient({
      global: {
        ...mockGlobal,
        nativeModuleProxy: { DevLoadingView: nativeDevLoadingView },
      },
      WebSocket: MockWebSocket,
      console: mockConsole,
      __zntc_apply_update: mockGlobal.__zntc_apply_update,
      __zntc_reload: mockGlobal.__zntc_reload,
      location: { reload: mock(() => {}) },
      window: undefined,
      forwardClientLogs: true,
      require: (specifier) => {
        if (specifier === 'pretty-format') return mockPrettyFormat;
        if (specifier === './DevLoadingView') return { default: mockDevLoadingView };
        throw new Error(`Unexpected require: ${specifier}`);
      },
    });
    HMRClient.setup('ios', '/abs/idx.js', 'localhost', 8081, true, 'http');
    const ws = MockWebSocket.instances[0];
    ws.onopen();

    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update-start' }) });
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update-done' }) });

    expect(nativeDevLoadingView.showMessage).toHaveBeenCalledWith(
      'Refreshing...',
      -1,
      -14318360,
      false,
    );
    expect(nativeDevLoadingView.hide).toHaveBeenCalled();
    expect(mockDevLoadingView.showMessage).not.toHaveBeenCalled();
  });

  test('forwardClientLogs=false 여도 client console wrap 은 설치하지 않음', () => {
    HMRClient = loadHmrClient({
      global: mockGlobal,
      WebSocket: MockWebSocket,
      console: mockConsole,
      __zntc_apply_update: mockGlobal.__zntc_apply_update,
      __zntc_reload: mockGlobal.__zntc_reload,
      location: { reload: mock(() => {}) },
      window: undefined,
      forwardClientLogs: false,
      require: (specifier) => {
        if (specifier === 'pretty-format') return mockPrettyFormat;
        if (specifier === './DevLoadingView') return { default: mockDevLoadingView };
        throw new Error(`Unexpected require: ${specifier}`);
      },
    });
    HMRClient.setup('ios', '/abs/idx.js', 'localhost', 8081, true, 'http');
    const ws = MockWebSocket.instances[0];
    ws.onopen();
    mockConsole.log('hello');
    expect(originalConsole.log).toHaveBeenCalledWith('hello');
    expect(ws.sent.length).toBe(1);
  });

  test('non-string log item 은 Metro 처럼 pretty-format 으로 format', () => {
    HMRClient.setup('ios', '/abs/idx.js', 'localhost', 8081, true, 'http');
    const ws = MockWebSocket.instances[0];
    ws.onopen();
    HMRClient.log('error', [new Error('boom')]);
    const log = JSON.parse(ws.sent[1]);
    expect(mockPrettyFormat.format).toHaveBeenCalledWith(expect.any(Error), {
      escapeString: true,
      highlight: true,
      maxDepth: 3,
      min: true,
      plugins: [mockPrettyFormat.plugins.ReactElement],
    });
    expect(log.data).toEqual(['formatted:boom']);
  });

  test('pretty-format 실패 시 Metro 처럼 log frame 을 보내지 않음', () => {
    HMRClient = loadHmrClient({
      global: mockGlobal,
      WebSocket: MockWebSocket,
      console: mockConsole,
      __zntc_apply_update: mockGlobal.__zntc_apply_update,
      __zntc_reload: mockGlobal.__zntc_reload,
      location: { reload: mock(() => {}) },
      window: undefined,
      forwardClientLogs: true,
      require: (specifier) => {
        if (specifier === 'pretty-format') {
          return {
            format: mock(() => {
              throw new Error('format failed');
            }),
            plugins: { ReactElement: {} },
          };
        }
        if (specifier === './DevLoadingView') return { default: mockDevLoadingView };
        throw new Error(`Unexpected require: ${specifier}`);
      },
    });
    HMRClient.setup('ios', '/abs/idx.js', 'localhost', 8081, true, 'http');
    const ws = MockWebSocket.instances[0];
    ws.onopen();
    expect(() => HMRClient.log('log', [{ a: 1 }])).not.toThrow();
    expect(ws.sent).toHaveLength(1);
  });

  test('source 에 JSON.parse(JSON.stringify 패턴 없음 (#2885 deep-clone 회귀 가드)', () => {
    expect(HMR_CLIENT_SOURCE).not.toContain('JSON.parse(JSON.stringify');
  });

  test('wrap 함수가 JSON.parse 호출 안 함 (deep-clone 부재 직접 검증) (#2885)', () => {
    HMRClient.setup('ios', '/abs/idx.js', 'localhost', 8081, true, 'http');
    const ws = MockWebSocket.instances[0];
    ws.onopen();
    const originalParse = JSON.parse;
    let parseCalls = 0;
    JSON.parse = function () {
      parseCalls++;
      return originalParse.apply(JSON, arguments);
    };
    try {
      HMRClient.log('log', [{ a: 1, b: { c: 2 } }]);
    } finally {
      JSON.parse = originalParse;
    }
    expect(parseCalls).toBe(0);
  });

  test('bufferedAmount 1MB 초과 시 send drop (#2885 burst 누적 가드)', () => {
    HMRClient.setup('ios', '/abs/idx.js', 'localhost', 8081, true, 'http');
    const ws = MockWebSocket.instances[0];
    ws.onopen();
    const sentBefore = ws.sent.length;
    ws.bufferedAmount = 2 * 1024 * 1024;
    HMRClient.log('log', ['this should be dropped']);
    expect(ws.sent.length).toBe(sentBefore);
    ws.bufferedAmount = 0;
    HMRClient.log('log', ['this should pass']);
    expect(ws.sent.length).toBe(sentBefore + 1);
  });

  test('readyState !== OPEN 시 send drop (#2885 stale connection 가드)', () => {
    HMRClient.setup('ios', '/abs/idx.js', 'localhost', 8081, true, 'http');
    const ws = MockWebSocket.instances[0];
    ws.onopen();
    const sentBefore = ws.sent.length;
    ws.readyState = 0; // CONNECTING
    HMRClient.log('log', ['not yet open']);
    expect(ws.sent.length).toBe(sentBefore);
    ws.readyState = 2; // CLOSING
    HMRClient.log('log', ['closing']);
    expect(ws.sent.length).toBe(sentBefore);
    ws.readyState = 3; // CLOSED
    HMRClient.log('log', ['closed']);
    expect(ws.sent.length).toBe(sentBefore);
  });
});

describe('onmessage — Metro 메시지 분기', () => {
  function setupConnected() {
    HMRClient.setup('ios', '/abs/idx.js', 'localhost', 8081, true, 'http');
    const ws = MockWebSocket.instances[0];
    ws.onopen();
    return ws;
  }

  test('hmr:update-start (isInitial=true) — DevLoadingView.showMessage 호출 안 함', () => {
    const ws = setupConnected();
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update-start', isInitialUpdate: true }) });
    expect(mockDevLoadingView.showMessage).not.toHaveBeenCalled();
  });

  test("hmr:update-start (incremental) — DevLoadingView.showMessage('Refreshing...', 'refresh')", () => {
    const ws = setupConnected();
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update-start' }) });
    expect(mockDevLoadingView.showMessage).toHaveBeenCalledWith('Refreshing...', 'refresh');
  });

  test('hmr:update — __zntc_apply_update 호출 with modules', () => {
    const ws = setupConnected();
    const modules = [{ id: 'abc', code: '__d(...)' }];
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update', modules }) });
    expect(mockGlobal.__zntc_apply_update).toHaveBeenCalledWith(modules);
  });

  test('hmr:update — modules 없으면 __zntc_apply_update 호출 안 함', () => {
    const ws = setupConnected();
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update' }) });
    expect(mockGlobal.__zntc_apply_update).not.toHaveBeenCalled();
  });

  test('hmr:update-done — pendingUpdates 0 도달 시 DevLoadingView.hide', () => {
    const ws = setupConnected();
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update-start' }) });
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update-done' }) });
    expect(mockDevLoadingView.hide).toHaveBeenCalled();
  });

  test('hmr:update-done 중첩 — 마지막 update-done 에서만 hide', () => {
    const ws = setupConnected();
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update-start' }) });
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update-start' }) });
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update-done' }) });
    expect(mockDevLoadingView.hide).not.toHaveBeenCalled();
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update-done' }) });
    expect(mockDevLoadingView.hide).toHaveBeenCalledTimes(1);
  });

  test('hmr:reload — __zntc_reload 호출', () => {
    const ws = setupConnected();
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:reload' }) });
    expect(mockGlobal.__zntc_reload).toHaveBeenCalled();
  });

  test('hmr:reload — __zntc_reload 없으면 location.reload fallback', () => {
    const reload = mock(() => {});
    HMRClient = loadHmrClient({
      global: mockGlobal,
      WebSocket: MockWebSocket,
      console: mockConsole,
      __zntc_apply_update: mockGlobal.__zntc_apply_update,
      __zntc_reload: undefined,
      location: { reload },
      window: undefined,
      forwardClientLogs: true,
      require: (specifier) => {
        if (specifier === 'pretty-format') return mockPrettyFormat;
        if (specifier === './DevLoadingView') return { default: mockDevLoadingView };
        throw new Error(`Unexpected require: ${specifier}`);
      },
    });
    const ws = setupConnected();

    ws.onmessage({ data: JSON.stringify({ type: 'hmr:reload' }) });

    expect(reload).toHaveBeenCalled();
  });

  test('hmr:error — console.error (backward-compat: body 없음)', () => {
    const ws = setupConnected();
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:error', message: 'boom' }) });
    // setupConnected 의 onopen 이 console wrap — original 검증.
    expect(originalConsole.error).toHaveBeenCalledWith('[ZNTC HMR]', 'boom');
  });

  test('hmr:error — body.errors[0].filename 있으면 file:line:col 포함 (#2605 audit)', () => {
    const ws = setupConnected();
    ws.onmessage({
      data: JSON.stringify({
        type: 'hmr:error',
        message: 'fallback',
        body: {
          type: 'BuildError',
          message: 'fallback',
          errors: [
            {
              description: 'Unexpected token',
              filename: '/proj/src/App.tsx',
              lineNumber: 42,
              column: 7,
            },
          ],
        },
      }),
    });
    expect(originalConsole.error).toHaveBeenCalledWith(
      '[ZNTC HMR] /proj/src/App.tsx:42:7',
      'Unexpected token',
    );
  });

  test('hmr:error — body.errors[0] 위치 정보 없음 → 단순 description', () => {
    const ws = setupConnected();
    ws.onmessage({
      data: JSON.stringify({
        type: 'hmr:error',
        message: 'no-loc',
        body: { type: 'BuildError', message: 'no-loc', errors: [{ description: 'no-loc' }] },
      }),
    });
    expect(originalConsole.error).toHaveBeenCalledWith('[ZNTC HMR]', 'no-loc');
  });

  test('hmr:error — filename 만 있고 lineNumber/column 누락 → location 부착 안 함 (#2605 audit)', () => {
    const ws = setupConnected();
    ws.onmessage({
      data: JSON.stringify({
        type: 'hmr:error',
        message: 'partial',
        body: {
          type: 'BuildError',
          message: 'partial',
          errors: [{ description: 'partial', filename: '/proj/foo.ts' }],
        },
      }),
    });
    // 'foo.ts:undefined:undefined' 같은 false-positive 가 아닌 description 만.
    expect(originalConsole.error).toHaveBeenCalledWith('[ZNTC HMR]', 'partial');
  });

  test('disable() 후 hmr:error 만 통과, 그 외 메시지 무시', () => {
    const ws = setupConnected();
    HMRClient.disable();
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update-start' }) });
    expect(mockDevLoadingView.showMessage).not.toHaveBeenCalled();
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:error', message: 'x' }) });
    expect(originalConsole.error).toHaveBeenCalledWith('[ZNTC HMR]', 'x');
  });

  test('invalid JSON — console.warn', () => {
    const ws = setupConnected();
    ws.onmessage({ data: 'not-json{' });
    expect(originalConsole.warn).toHaveBeenCalled();
  });
});

describe('onerror / onclose / log()', () => {
  test('onerror — console.warn', () => {
    HMRClient.setup('ios', '/abs/idx.js', 'localhost', 8081, true, 'http');
    const ws = MockWebSocket.instances[0];
    ws.onerror();
    // onerror 는 setup 후 onopen 호출 전에도 발생 가능 — wrap 안 됐으면
    // mockConsole.warn 직접, wrap 후라면 originalConsole.warn 검증.
    // 본 케이스는 onopen 호출 안 함 — wrap 안 된 상태이므로 mockConsole.warn 검증.
    expect(mockConsole.warn).toHaveBeenCalledWith('[ZNTC HMR] WebSocket error');
  });

  test('onclose — _socket null 로 reset', () => {
    HMRClient.setup('ios', '/abs/idx.js', 'localhost', 8081, true, 'http');
    const ws = MockWebSocket.instances[0];
    ws.onclose();
    expect(HMRClient._socket).toBeNull();
  });

  test('log() — readyState 1 일 때만 send', () => {
    HMRClient.setup('ios', '/abs/idx.js', 'localhost', 8081, true, 'http');
    const ws = MockWebSocket.instances[0];
    HMRClient.log('warn', ['hello']);
    const msg = JSON.parse(ws.sent[0]);
    expect(msg).toEqual({ type: 'log', level: 'warn', data: ['hello'] });
  });

  test('log() — _socket null 시 no-op', () => {
    HMRClient.log('warn', ['x']);
    // 예외 없이 통과
    expect(true).toBe(true);
  });
});

describe('registerBundle() / enable()', () => {
  test('registerBundle — no-op (ZNTC bundler 는 등록 불필요)', () => {
    expect(() => HMRClient.registerBundle('any-url')).not.toThrow();
  });

  test('enable() 후 disable() 후 enable() 토글', () => {
    HMRClient.enable();
    expect(HMRClient._enabled).toBe(true);
    HMRClient.disable();
    expect(HMRClient._enabled).toBe(false);
    HMRClient.enable();
    expect(HMRClient._enabled).toBe(true);
  });
});
