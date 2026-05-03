import { describe, expect, test } from "bun:test";
import { computeMetricStats, formatMetric } from "./stats";

describe("benchmark stats", () => {
  test("median, p95, trimmed mean을 한 곳에서 계산한다", () => {
    const stats = computeMetricStats([10, 20, 30, 40, 1000]);

    expect(stats.median).toBe(30);
    expect(stats.mean).toBe(220);
    expect(stats.min).toBe(10);
    expect(stats.max).toBe(1000);
    expect(stats.trimmedMean).toBe(30);
    expect(stats.p95).toBeCloseTo(808, 6);
  });

  test("샘플이 2개 이하이면 trimmed mean은 일반 평균과 같다", () => {
    expect(computeMetricStats([4]).trimmedMean).toBe(4);
    expect(computeMetricStats([4, 8]).trimmedMean).toBe(6);
  });

  test("빈 샘플은 측정 오류로 처리한다", () => {
    expect(() => computeMetricStats([])).toThrow("empty samples");
  });

  test("단위별 출력 포맷을 공유한다", () => {
    expect(formatMetric(3.1415)).toBe("3.14ms");
    expect(formatMetric(12.34)).toBe("12.3ms");
    expect(formatMetric(123.4, "us")).toBe("123us");
  });
});
