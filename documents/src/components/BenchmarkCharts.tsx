import { Suspense, lazy } from "react";

import benchmarkData from "../data/benchmark-data.json";

// echarts (~500KB gzip + CJS deep import 인 `echarts-for-react/lib/core`) 를 분리.
// 빌드타임 / dev SSR 의 모듈 평가 단계에서 CJS body 가 evaluate 되지 않도록 dynamic import.
// 부수 효과: landing/benchmarks 페이지 진입 시점에만 chunk fetch — 다른 페이지 비용 0.
const Default = lazy(() => import("./BenchmarkChartsImpl"));
const Highlight = lazy(() =>
  import("./BenchmarkChartsImpl").then((m) => ({ default: m.BenchmarkHighlight })),
);

type BenchmarkResultKey = keyof typeof benchmarkData.results;

// `BenchmarkChartsImpl` 의 `MIN_CHART_HEIGHT` 와 같은 값.
// 정적 import 하면 echarts 가 wrapper chunk 로 끌려와 lazy split 의미가 깨짐.
const MIN_CHART_HEIGHT = 320;
const PANEL_COUNT = Object.keys(benchmarkData.results).length;
// header (~70) + gap-5 (20) 누적. lazy resolve 후 차트마다 chartHeight() 가 320 보다 커지면
// 약간의 reflow 가 발생하나, 0→2000 의 큰 CLS 는 회피.
const FULL_PAGE_FALLBACK = PANEL_COUNT * (MIN_CHART_HEIGHT + 90) + 80;

function ChartSkeleton({ minHeight }: { minHeight: number }) {
  return (
    <div
      className="not-content rounded-lg border border-surface-200 bg-white dark:border-surface-800 dark:bg-surface-950/70"
      style={{ minHeight, width: "100%" }}
      aria-hidden
    />
  );
}

export function BenchmarkHighlight(props: { chartKey: BenchmarkResultKey; height?: number }) {
  return (
    <Suspense fallback={<ChartSkeleton minHeight={props.height ?? MIN_CHART_HEIGHT} />}>
      <Highlight {...props} />
    </Suspense>
  );
}

export default function BenchmarkCharts() {
  return (
    <Suspense fallback={<ChartSkeleton minHeight={FULL_PAGE_FALLBACK} />}>
      <Default />
    </Suspense>
  );
}
