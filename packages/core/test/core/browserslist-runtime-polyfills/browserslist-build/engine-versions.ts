import { describe, expect, test } from '../helpers';

describe('@zntc/core browserslist > build API', () => {
  test('browserslist: 같은 엔진의 여러 버전 — 가장 낮은 버전 기준', () => {
    const { browserslistToUnsupported } = require('../../../../../shared/index');
    // chrome 40(미지원) + chrome 100(지원) 동시 전달 — 40 때문에 async_await unsupported
    const bits = browserslistToUnsupported(['chrome 40', 'chrome 100']);
    expect(bits & (1 << 12)).not.toBe(0);
  });
});
