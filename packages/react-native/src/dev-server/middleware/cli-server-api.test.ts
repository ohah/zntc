import { describe, expect, test } from 'bun:test';

import { loadCliServerApi } from './cli-server-api.ts';

describe('loadCliServerApi', () => {
  test('@react-native-community/cli-server-api 가 dependency — instance 반환', async () => {
    // PR #2642 에서 peer optional → dependencies 로 이전 (번개 parity).
    // workspace 에 자동 install 되니 항상 instance.
    const result = await loadCliServerApi({ port: 8081, host: 'localhost' });
    expect(result).not.toBeNull();
    expect(typeof result?.broadcast).toBe('function');
    expect(result?.websocketEndpoints).toBeDefined();
  });
});
