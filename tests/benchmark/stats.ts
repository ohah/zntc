export interface MetricStats {
  median: number;
  mean: number;
  min: number;
  max: number;
  p95: number;
  trimmedMean: number;
}

/// JSON 직렬화용 통계 형태 — `MetricStats` 와 동일하지만 `trimmed_mean` snake_case.
export interface JsonStats {
  median: number;
  mean: number;
  min: number;
  max: number;
  p95: number;
  trimmed_mean: number;
}

export function toJsonStats(stats: MetricStats): JsonStats {
  return {
    median: stats.median,
    mean: stats.mean,
    min: stats.min,
    max: stats.max,
    p95: stats.p95,
    trimmed_mean: stats.trimmedMean,
  };
}

export function computeMetricStats(samples: number[]): MetricStats {
  if (samples.length === 0) {
    throw new Error('cannot compute benchmark stats from empty samples');
  }

  const sorted = [...samples].sort((a, b) => a - b);
  const n = sorted.length;
  const median = n % 2 ? sorted[(n - 1) / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
  const mean = samples.reduce((a, b) => a + b, 0) / n;
  const trimmed = n > 2 ? sorted.slice(1, -1) : sorted;
  const trimmedMean = trimmed.reduce((a, b) => a + b, 0) / trimmed.length;
  const p95 = percentile(sorted, 0.95);

  return {
    median,
    mean,
    min: sorted[0],
    max: sorted[n - 1],
    p95,
    trimmedMean,
  };
}

export function formatMetric(n: number, unit: 'ms' | 'us' = 'ms'): string {
  const rounded = n >= 100 ? n.toFixed(0) : n >= 10 ? n.toFixed(1) : n.toFixed(2);
  return `${rounded}${unit}`;
}

function percentile(sortedSamples: number[], p: number): number {
  if (sortedSamples.length === 1) return sortedSamples[0];

  // 선형 보간 percentile. p95가 max 하나에 끌려가는 것을 피한다.
  const idx = (sortedSamples.length - 1) * p;
  const lo = Math.floor(idx);
  const hi = Math.ceil(idx);
  if (lo === hi) return sortedSamples[lo];
  return sortedSamples[lo] + (sortedSamples[hi] - sortedSamples[lo]) * (idx - lo);
}
