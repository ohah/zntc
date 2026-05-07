import { describe, expect, test } from 'bun:test';
import {
  APP_DEV_HMR_CLIENT_PATH,
  APP_DEV_HMR_WS_PATH,
  HMR_MSG,
  HMR_RN_MSG,
  HMR_WS_GUID,
  type HmrMessage,
  type HmrRnMessage,
  normalizeHmrErrors,
} from './protocol.ts';

describe('HMR_MSG enum', () => {
  test('모든 메시지 타입이 string literal', () => {
    expect(HMR_MSG.Connected).toBe('connected');
    expect(HMR_MSG.CssUpdate).toBe('css-update');
    expect(HMR_MSG.ClearError).toBe('clear-error');
    expect(HMR_MSG.Error).toBe('error');
    expect(HMR_MSG.FullReload).toBe('full-reload');
  });

  test('frozen 객체로 런타임 변경 불가', () => {
    expect(Object.isFrozen(HMR_MSG)).toBe(true);
  });
});

describe('protocol 상수', () => {
  test('client/ws path 가 정의된 namespace', () => {
    expect(APP_DEV_HMR_CLIENT_PATH).toBe('/__zntc_app_dev_hmr__');
    expect(APP_DEV_HMR_WS_PATH).toBe('/__hmr');
  });

  test('RFC 6455 GUID 는 spec 고정값', () => {
    expect(HMR_WS_GUID).toBe('258EAFA5-E914-47DA-95CA-C5AB0DC85B11');
  });
});

describe('HmrMessage type 의 round-trip', () => {
  test('Connected', () => {
    const msg: HmrMessage = { type: HMR_MSG.Connected };
    expect(JSON.parse(JSON.stringify(msg))).toEqual({ type: 'connected' });
  });

  test('CssUpdate 는 href + timestamp', () => {
    const msg: HmrMessage = {
      type: HMR_MSG.CssUpdate,
      href: '/styles.css',
      timestamp: 12345,
    };
    expect(JSON.parse(JSON.stringify(msg))).toEqual({
      type: 'css-update',
      href: '/styles.css',
      timestamp: 12345,
    });
  });

  test('Error 는 errors[] + timestamp', () => {
    const msg: HmrMessage = {
      type: HMR_MSG.Error,
      errors: [{ file: 'a.ts', message: 'boom' }],
      timestamp: 1,
    };
    expect(JSON.parse(JSON.stringify(msg))).toEqual({
      type: 'error',
      errors: [{ file: 'a.ts', message: 'boom' }],
      timestamp: 1,
    });
  });

  test('FullReload 는 timestamp', () => {
    const msg: HmrMessage = { type: HMR_MSG.FullReload, timestamp: 9 };
    expect(JSON.parse(JSON.stringify(msg))).toEqual({
      type: 'full-reload',
      timestamp: 9,
    });
  });
});

describe('normalizeHmrErrors', () => {
  test('빈 배열은 default 메시지', () => {
    expect(normalizeHmrErrors([])).toEqual([{ file: '', message: 'Unknown build error' }]);
  });

  test('배열 아닌 입력도 default 메시지', () => {
    expect(normalizeHmrErrors(null)).toEqual([{ file: '', message: 'Unknown build error' }]);
    expect(normalizeHmrErrors(undefined)).toEqual([{ file: '', message: 'Unknown build error' }]);
    expect(normalizeHmrErrors('string')).toEqual([{ file: '', message: 'Unknown build error' }]);
  });

  test('location.file + text 조합', () => {
    const errors = [{ location: { file: 'src/a.ts' }, text: 'oops' }];
    expect(normalizeHmrErrors(errors)).toEqual([{ file: 'src/a.ts', message: 'oops' }]);
  });

  test('text 없으면 message fallback', () => {
    const errors = [{ message: 'oops' }];
    expect(normalizeHmrErrors(errors)).toEqual([{ file: '', message: 'oops' }]);
  });

  test('text/message 둘 다 없으면 String(error) fallback', () => {
    const errors = ['raw string'];
    expect(normalizeHmrErrors(errors)).toEqual([{ file: '', message: 'raw string' }]);
  });

  test('location.file 가 string 아니면 빈 string', () => {
    const errors = [{ location: { file: 123 }, text: 'x' }];
    expect(normalizeHmrErrors(errors)).toEqual([{ file: '', message: 'x' }]);
  });

  test('null/undefined element 도 안전 처리', () => {
    const errors = [null, undefined];
    expect(normalizeHmrErrors(errors)).toEqual([
      { file: '', message: 'null' },
      { file: '', message: 'undefined' },
    ]);
  });
});

describe('HMR_RN_MSG enum (#2540 Metro 호환)', () => {
  test('모든 메시지 타입이 Metro `hmr:` prefix 또는 log', () => {
    expect(HMR_RN_MSG.UpdateStart).toBe('hmr:update-start');
    expect(HMR_RN_MSG.Update).toBe('hmr:update');
    expect(HMR_RN_MSG.UpdateDone).toBe('hmr:update-done');
    expect(HMR_RN_MSG.Reload).toBe('hmr:reload');
    expect(HMR_RN_MSG.Error).toBe('hmr:error');
    expect(HMR_RN_MSG.Log).toBe('log');
  });

  test('frozen 객체로 런타임 변경 불가', () => {
    expect(Object.isFrozen(HMR_RN_MSG)).toBe(true);
  });

  test('web HMR_MSG namespace 와 직교 (값 충돌 없음)', () => {
    const webValues = new Set(Object.values(HMR_MSG));
    for (const rnValue of Object.values(HMR_RN_MSG)) {
      expect(webValues.has(rnValue)).toBe(false);
    }
  });
});

describe('HmrRnMessage type 의 round-trip', () => {
  test('UpdateStart 는 isInitialUpdate optional', () => {
    const initial: HmrRnMessage = { type: HMR_RN_MSG.UpdateStart, isInitialUpdate: true };
    expect(JSON.parse(JSON.stringify(initial))).toEqual({
      type: 'hmr:update-start',
      isInitialUpdate: true,
    });
    const incremental: HmrRnMessage = { type: HMR_RN_MSG.UpdateStart };
    expect(JSON.parse(JSON.stringify(incremental))).toEqual({ type: 'hmr:update-start' });
  });

  test('Update 는 modules 배열 (id/code/map)', () => {
    const msg: HmrRnMessage = {
      type: HMR_RN_MSG.Update,
      modules: [
        { id: 'abc', code: '__d(...)' },
        { id: 42, code: '__d(...)', map: '//# sourceMappingURL=...' },
      ],
    };
    expect(JSON.parse(JSON.stringify(msg))).toEqual({
      type: 'hmr:update',
      modules: [
        { id: 'abc', code: '__d(...)' },
        { id: 42, code: '__d(...)', map: '//# sourceMappingURL=...' },
      ],
    });
  });

  test('UpdateDone / Reload 는 type 만', () => {
    const done: HmrRnMessage = { type: HMR_RN_MSG.UpdateDone };
    const reload: HmrRnMessage = { type: HMR_RN_MSG.Reload };
    expect(JSON.parse(JSON.stringify(done))).toEqual({ type: 'hmr:update-done' });
    expect(JSON.parse(JSON.stringify(reload))).toEqual({ type: 'hmr:reload' });
  });

  test('Error 는 message string', () => {
    const msg: HmrRnMessage = { type: HMR_RN_MSG.Error, message: 'boom' };
    expect(JSON.parse(JSON.stringify(msg))).toEqual({ type: 'hmr:error', message: 'boom' });
  });

  test('Log 는 level + data tuple', () => {
    const msg: HmrRnMessage = {
      type: HMR_RN_MSG.Log,
      level: 'warn',
      data: ['hello', { x: 1 }],
    };
    expect(JSON.parse(JSON.stringify(msg))).toEqual({
      type: 'log',
      level: 'warn',
      data: ['hello', { x: 1 }],
    });
  });
});
