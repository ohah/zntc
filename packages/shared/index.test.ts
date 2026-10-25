import { expect, test } from 'bun:test';

import { buildOptionsJson, type TranspileOptions } from './index';

test('standalone keepNames preserves explicit true, false, and omitted JSON options', () => {
  for (const keepNames of [true, false, undefined]) {
    const options: TranspileOptions = keepNames === undefined ? {} : { keepNames };
    const payload = JSON.parse(buildOptionsJson(options));
    expect(payload.keepNames).toBe(keepNames);
    expect(Object.hasOwn(payload, 'keepNames')).toBe(keepNames !== undefined);
    expect(payload.minifyIdentifiers).toBeUndefined();
  }
});
