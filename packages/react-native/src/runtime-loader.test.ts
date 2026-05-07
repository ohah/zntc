import { describe, expect, test } from 'bun:test';

import { HMR_CLIENT_SUFFIX, ZNTC_HMR_CLIENT_CODE } from './runtime-loader.ts';

describe('ZNTC_HMR_CLIENT_CODE', () => {
  test('빈 string 아님 (runtime/zntc-hmr-client.js 정상 로드)', () => {
    expect(ZNTC_HMR_CLIENT_CODE.length).toBeGreaterThan(0);
  });

  test('module.exports default 포함 — RN setUpBatchedBridge 호환', () => {
    expect(ZNTC_HMR_CLIENT_CODE).toContain('module.exports');
    expect(ZNTC_HMR_CLIENT_CODE).toContain('.default');
  });

  test('Metro HMRClient interface 의 핵심 method 포함', () => {
    expect(ZNTC_HMR_CLIENT_CODE).toContain('setup');
    expect(ZNTC_HMR_CLIENT_CODE).toContain('enable');
    expect(ZNTC_HMR_CLIENT_CODE).toContain('disable');
    expect(ZNTC_HMR_CLIENT_CODE).toContain('registerBundle');
    expect(ZNTC_HMR_CLIENT_CODE).toContain('log');
  });

  test('WebSocket 사용 (Metro `/hot` endpoint)', () => {
    expect(ZNTC_HMR_CLIENT_CODE).toContain('WebSocket');
    expect(ZNTC_HMR_CLIENT_CODE).toContain('/hot');
  });

  test('Metro 메시지 type 분기 모두 포함', () => {
    expect(ZNTC_HMR_CLIENT_CODE).toContain('hmr:connected');
    expect(ZNTC_HMR_CLIENT_CODE).toContain('hmr:update-start');
    expect(ZNTC_HMR_CLIENT_CODE).toContain('hmr:update');
    expect(ZNTC_HMR_CLIENT_CODE).toContain('hmr:update-done');
    expect(ZNTC_HMR_CLIENT_CODE).toContain('hmr:reload');
    expect(ZNTC_HMR_CLIENT_CODE).toContain('hmr:error');
  });

  test('ZNTC HMR runtime hook 호출 (`__zntc_apply_update`, `__zntc_reload`)', () => {
    expect(ZNTC_HMR_CLIENT_CODE).toContain('__zntc_apply_update');
    expect(ZNTC_HMR_CLIENT_CODE).toContain('__zntc_reload');
  });

  test("DevLoadingView 의 'Refreshing...' 배너 호출", () => {
    expect(ZNTC_HMR_CLIENT_CODE).toContain('DevLoadingView');
    expect(ZNTC_HMR_CLIENT_CODE).toContain('Refreshing');
  });

  test('초기 update sequence (isInitialUpdate flag) 분기 존재', () => {
    expect(ZNTC_HMR_CLIENT_CODE).toContain('isInitialUpdate');
  });
});

describe('HMR_CLIENT_SUFFIX', () => {
  test('RN core 의 HMRClient.js path suffix', () => {
    expect(HMR_CLIENT_SUFFIX).toBe('/Libraries/Utilities/HMRClient.js');
  });

  test('path 가 절대 (slash 시작)', () => {
    expect(HMR_CLIENT_SUFFIX.startsWith('/')).toBe(true);
  });

  test('.js 확장자로 끝남 (Metro 가 transform 대상 인식)', () => {
    expect(HMR_CLIENT_SUFFIX.endsWith('.js')).toBe(true);
  });
});
