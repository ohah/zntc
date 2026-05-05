import { afterEach, beforeEach, describe, expect, mock, spyOn, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname_ = dirname(fileURLToPath(import.meta.url));
const HMR_CLIENT_PATH = join(__dirname_, '..', '..', 'runtime', 'zts-hmr-client.js');
const HMR_CLIENT_SOURCE = readFileSync(HMR_CLIENT_PATH, 'utf-8');

// CommonJS 식 module.exports 패턴 — 평가 후 module.exports 회수.
function loadHmrClient(globalEnv) {
  const moduleObj = { exports: {} };
  const fnSource = `
    var module = arguments[0];
    var global = arguments[1];
    var WebSocket = arguments[2];
    var console = arguments[3];
    var __zts_apply_update = arguments[4];
    var __zts_reload = arguments[5];
    var location = arguments[6];
    var window = arguments[7];
    ${HMR_CLIENT_SOURCE}
    return module.exports;
  `;
  const factory = new Function(fnSource);
  return factory(
    moduleObj,
    globalEnv.global,
    globalEnv.WebSocket,
    globalEnv.console,
    globalEnv.__zts_apply_update,
    globalEnv.__zts_reload,
    globalEnv.location,
    globalEnv.window,
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
// wrap 전 console.X 의 mock 보존 — onopen 에서 console.X 가 wrappedFn 으로
// 교체되므로 toHaveBeenCalledWith 검증 시 wrap 전 ref 사용 필요.
let originalConsole;

beforeEach(() => {
  MockWebSocket.reset();
  mockGlobal = {
    NativeModules: {
      DevLoadingView: { showMessage: mock(() => {}), hide: mock(() => {}) },
    },
    WebSocket: MockWebSocket,
    __zts_apply_update: mock(() => {}),
    __zts_reload: mock(() => {}),
  };
  mockConsole = {
    log: mock(() => {}),
    info: mock(() => {}),
    warn: mock(() => {}),
    error: mock(() => {}),
    debug: mock(() => {}),
  };
  originalConsole = { ...mockConsole };
  HMRClient = loadHmrClient({
    global: mockGlobal,
    WebSocket: MockWebSocket,
    console: mockConsole,
    __zts_apply_update: mockGlobal.__zts_apply_update,
    __zts_reload: mockGlobal.__zts_reload,
    location: { reload: mock(() => {}) },
    window: undefined,
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

describe('onopen — hmr:connected + console wrap', () => {
  test("'hmr:connected' 메시지 송출 + bundleEntry/platform 포함", () => {
    HMRClient.setup('ios', '/abs/idx.js', 'localhost', 8081, true, 'http');
    const ws = MockWebSocket.instances[0];
    ws.onopen();
    const msg = JSON.parse(ws.sent[0]);
    expect(msg).toEqual({ type: 'hmr:connected', bundleEntry: '/abs/idx.js', platform: 'ios' });
  });

  test('console method wrap — original 호출 + socket.send forward', () => {
    HMRClient.setup('ios', '/abs/idx.js', 'localhost', 8081, true, 'http');
    const ws = MockWebSocket.instances[0];
    ws.onopen();
    // wrap 후 mockConsole.log 자체가 wrappedFn — 호출은 wrap 된 함수로.
    mockConsole.log('hello');
    // wrap 안에서 original (originalConsole.log) 호출 검증.
    expect(originalConsole.log).toHaveBeenCalledWith('hello');
    // socket.send forward — 'hmr:connected' + 'log' 메시지
    expect(ws.sent.length).toBe(2);
    const log = JSON.parse(ws.sent[1]);
    expect(log.type).toBe('log');
    expect(log.level).toBe('log');
    expect(log.data).toEqual(['hello']);
  });

  test('Error object 는 message 만 send', () => {
    HMRClient.setup('ios', '/abs/idx.js', 'localhost', 8081, true, 'http');
    const ws = MockWebSocket.instances[0];
    ws.onopen();
    mockConsole.error(new Error('boom'));
    const log = JSON.parse(ws.sent[1]);
    expect(log.data).toEqual(['boom']);
  });

  test('circular reference 객체 fallback (String 변환)', () => {
    HMRClient.setup('ios', '/abs/idx.js', 'localhost', 8081, true, 'http');
    const ws = MockWebSocket.instances[0];
    ws.onopen();
    const obj = { a: 1 };
    obj.self = obj;
    mockConsole.log(obj);
    const log = JSON.parse(ws.sent[1]);
    expect(typeof log.data[0]).toBe('string');
    expect(log.data[0]).toContain('[object');
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
    expect(mockGlobal.NativeModules.DevLoadingView.showMessage).not.toHaveBeenCalled();
  });

  test("hmr:update-start (incremental) — DevLoadingView.showMessage('Refreshing...', 'refresh')", () => {
    const ws = setupConnected();
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update-start' }) });
    expect(mockGlobal.NativeModules.DevLoadingView.showMessage).toHaveBeenCalledWith(
      'Refreshing...',
      'refresh',
    );
  });

  test('hmr:update — __zts_apply_update 호출 with modules', () => {
    const ws = setupConnected();
    const modules = [{ id: 'abc', code: '__d(...)' }];
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update', modules }) });
    expect(mockGlobal.__zts_apply_update).toHaveBeenCalledWith(modules);
  });

  test('hmr:update — modules 없으면 __zts_apply_update 호출 안 함', () => {
    const ws = setupConnected();
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update' }) });
    expect(mockGlobal.__zts_apply_update).not.toHaveBeenCalled();
  });

  test('hmr:update-done — pendingUpdates 0 도달 시 DevLoadingView.hide', () => {
    const ws = setupConnected();
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update-start' }) });
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update-done' }) });
    expect(mockGlobal.NativeModules.DevLoadingView.hide).toHaveBeenCalled();
  });

  test('hmr:update-done 중첩 — 마지막 update-done 에서만 hide', () => {
    const ws = setupConnected();
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update-start' }) });
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update-start' }) });
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update-done' }) });
    expect(mockGlobal.NativeModules.DevLoadingView.hide).not.toHaveBeenCalled();
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update-done' }) });
    expect(mockGlobal.NativeModules.DevLoadingView.hide).toHaveBeenCalledTimes(1);
  });

  test('hmr:reload — __zts_reload 호출', () => {
    const ws = setupConnected();
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:reload' }) });
    expect(mockGlobal.__zts_reload).toHaveBeenCalled();
  });

  test('hmr:error — console.error', () => {
    const ws = setupConnected();
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:error', message: 'boom' }) });
    // setupConnected 의 onopen 이 console wrap — original 검증.
    expect(originalConsole.error).toHaveBeenCalledWith('[ZTS HMR]', 'boom');
  });

  test('disable() 후 hmr:error 만 통과, 그 외 메시지 무시', () => {
    const ws = setupConnected();
    HMRClient.disable();
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:update-start' }) });
    expect(mockGlobal.NativeModules.DevLoadingView.showMessage).not.toHaveBeenCalled();
    ws.onmessage({ data: JSON.stringify({ type: 'hmr:error', message: 'x' }) });
    expect(originalConsole.error).toHaveBeenCalledWith('[ZTS HMR]', 'x');
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
    expect(mockConsole.warn).toHaveBeenCalledWith('[ZTS HMR] WebSocket error');
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
  test('registerBundle — no-op (ZTS bundler 는 등록 불필요)', () => {
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
