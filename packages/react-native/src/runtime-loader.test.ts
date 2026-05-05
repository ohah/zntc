import { describe, expect, test } from 'bun:test';

import { HMR_CLIENT_SUFFIX, ZTS_HMR_CLIENT_CODE } from './runtime-loader.ts';

describe('ZTS_HMR_CLIENT_CODE', () => {
  test('빈 string 아님 (runtime/zts-hmr-client.js 정상 로드)', () => {
    expect(ZTS_HMR_CLIENT_CODE.length).toBeGreaterThan(0);
  });

  test('module.exports default 포함 — RN setUpBatchedBridge 호환', () => {
    expect(ZTS_HMR_CLIENT_CODE).toContain('module.exports');
    expect(ZTS_HMR_CLIENT_CODE).toContain('.default');
  });

  test('Metro HMRClient interface 의 핵심 method 포함', () => {
    expect(ZTS_HMR_CLIENT_CODE).toContain('setup');
    expect(ZTS_HMR_CLIENT_CODE).toContain('enable');
    expect(ZTS_HMR_CLIENT_CODE).toContain('disable');
    expect(ZTS_HMR_CLIENT_CODE).toContain('registerBundle');
    expect(ZTS_HMR_CLIENT_CODE).toContain('log');
  });

  test('WebSocket 사용 (Metro `/hot` endpoint)', () => {
    expect(ZTS_HMR_CLIENT_CODE).toContain('WebSocket');
    expect(ZTS_HMR_CLIENT_CODE).toContain('/hot');
  });

  test('Metro 메시지 type 분기 모두 포함', () => {
    expect(ZTS_HMR_CLIENT_CODE).toContain('hmr:connected');
    expect(ZTS_HMR_CLIENT_CODE).toContain('hmr:update-start');
    expect(ZTS_HMR_CLIENT_CODE).toContain('hmr:update');
    expect(ZTS_HMR_CLIENT_CODE).toContain('hmr:update-done');
    expect(ZTS_HMR_CLIENT_CODE).toContain('hmr:reload');
    expect(ZTS_HMR_CLIENT_CODE).toContain('hmr:error');
  });

  test('ZTS HMR runtime hook 호출 (`__zts_apply_update`, `__zts_reload`)', () => {
    expect(ZTS_HMR_CLIENT_CODE).toContain('__zts_apply_update');
    expect(ZTS_HMR_CLIENT_CODE).toContain('__zts_reload');
  });

  test("DevLoadingView 의 'Refreshing...' 배너 호출", () => {
    expect(ZTS_HMR_CLIENT_CODE).toContain('DevLoadingView');
    expect(ZTS_HMR_CLIENT_CODE).toContain('Refreshing');
  });

  test('초기 update sequence (isInitialUpdate flag) 분기 존재', () => {
    expect(ZTS_HMR_CLIENT_CODE).toContain('isInitialUpdate');
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
