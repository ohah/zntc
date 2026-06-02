import { useMemo } from "react";
import ReactEChartsCore from "echarts-for-react/lib/core";

import benchmarkData from "../data/benchmark-data.json";
import { ZIG } from "../styles/brand-tokens";
import { echarts } from "./echarts-setup";
import { formatBytes } from "./format";
import { useStarlightDark } from "./useStarlightDark";

// ZNTC 만 brand token 사용. 다른 도구 색은 각자의 brand color 라 토큰화 X.
const SERIES_COLORS: Record<string, string> = {
  ZNTC: ZIG[500],
  esbuild: "#2563eb",
  SWC: "#dc2626",
  Bun: "#9333ea",
  "oxc (node)": "#16a34a",
  Rolldown: "#0d9488",
  Rspack: "#e11d48",
  rolldown: "#0d9488",
  rspack: "#e11d48",
  webpack: "#475569",
  "NAPI (.node)": "#16a34a",
  "WASM (.wasm)": "#0284c7",
  "CLI (subprocess)": "#ea580c",
  simple: "#2563eb",
  expr: "#db2777",
  string: "#16a34a",
  object: "#ca8a04",
  react: "#7c3aed",
};

type BenchEntry = {
  tool: string;
  scale: string;
  medianMs?: number;
  minMs?: number;
  maxMs?: number;
  p95Ms?: number;
  bytes?: number;
};

type ChartMetric = "ms" | "bytes";

type ChartDefinition = {
  title: string;
  description: string;
  entries: BenchEntry[];
};

/** entry 모양으로 단위를 추론 — `bytes` 가 있으면 크기 차트, 아니면 시간 차트. */
function metricOf(entries: BenchEntry[]): ChartMetric {
  return entries.some((e) => typeof e.bytes === "number") ? "bytes" : "ms";
}

function valueOf(entry: BenchEntry, metric: ChartMetric): number | undefined {
  return metric === "bytes" ? entry.bytes : entry.medianMs;
}

function uniqueInOrder(values: string[]): string[] {
  return [...new Set(values)];
}

function formatMs(value: number): string {
  if (!Number.isFinite(value)) return "-";
  if (value === 0) return "0";
  if (value < 1) {
    const us = value * 1000;
    return `${us >= 100 ? us.toFixed(0) : us.toFixed(1)}us`;
  }
  if (value < 10) return `${value.toFixed(2)}ms`;
  if (value < 100) return `${value.toFixed(1)}ms`;
  return `${value.toFixed(0)}ms`;
}

function formatValue(value: number, metric: ChartMetric): string {
  return metric === "bytes" ? formatBytes(value) : formatMs(value);
}

export const MIN_CHART_HEIGHT = 320;

export function chartHeight(entries: BenchEntry[]): number {
  const scaleCount = uniqueInOrder(entries.map((entry) => entry.scale)).length;
  const toolCount = uniqueInOrder(entries.map((entry) => entry.tool)).length;
  return Math.max(MIN_CHART_HEIGHT, 112 + scaleCount * Math.max(48, toolCount * 18));
}

function buildHorizontalBarOption(entries: BenchEntry[], isDark: boolean) {
  const metric = metricOf(entries);
  const scales = uniqueInOrder(entries.map((entry) => entry.scale));
  const tools = uniqueInOrder(entries.map((entry) => entry.tool));

  const textColor = isDark ? "#e5e7eb" : "#374151";
  const axisLineColor = isDark ? "#57534e" : "#d6d3d1";
  const gridLineColor = isDark ? "#2a2422" : "#e7e5e4";

  const series = tools.map((tool) => ({
    name: tool,
    type: "bar" as const,
    barMaxWidth: 14,
    barGap: "16%",
    emphasis: { focus: "series" as const },
    itemStyle: {
      color: SERIES_COLORS[tool] ?? "#78716c",
      borderRadius: [0, 5, 5, 0],
    },
    label: {
      show: true,
      position: "right" as const,
      color: textColor,
      fontSize: 11,
      formatter: ({ value }: { value: number | null }) =>
        typeof value === "number" ? formatValue(value, metric) : "",
    },
    data: scales.map((scale) => {
      const entry = entries.find((item) => item.tool === tool && item.scale === scale);
      const value = entry ? valueOf(entry, metric) : undefined;
      return typeof value === "number" ? Number(value.toFixed(4)) : null;
    }),
  }));

  return {
    animationDuration: 450,
    tooltip: {
      trigger: "axis" as const,
      confine: true,
      axisPointer: { type: "shadow" as const },
      formatter: (
        params: Array<{
          seriesName: string;
          axisValue: string;
          value: number | null;
          marker: string;
        }>,
      ) => {
        let html = `<strong>${params[0]?.axisValue ?? ""}</strong><br/>`;
        const zntcEntry = entries.find(
          (item) => item.tool === "ZNTC" && item.scale === params[0]?.axisValue,
        );
        const zntcValue = zntcEntry ? valueOf(zntcEntry, metric) : undefined;
        for (const param of params) {
          if (typeof param.value !== "number") continue;
          const entry = entries.find(
            (item) => item.tool === param.seriesName && item.scale === param.axisValue,
          );
          html += `${param.marker} ${param.seriesName}: <strong>${formatValue(param.value, metric)}</strong>`;
          if (entry?.minMs !== undefined && entry.maxMs !== undefined) {
            html += ` <span style="color:#8a8580">(${formatMs(entry.minMs)}-${formatMs(entry.maxMs)})</span>`;
          }
          if (entry?.p95Ms !== undefined) {
            html += ` <span style="color:#8a8580">p95 ${formatMs(entry.p95Ms)}</span>`;
          }
          if (
            metric === "bytes" &&
            param.seriesName !== "ZNTC" &&
            typeof zntcValue === "number" &&
            zntcValue > 0
          ) {
            const ratio = param.value / zntcValue;
            html += ` <span style="color:#8a8580">ZNTC ${ratio >= 1 ? `${ratio.toFixed(2)}x smaller` : `${(1 / ratio).toFixed(2)}x larger`}</span>`;
          }
          html += "<br/>";
        }
        return html;
      },
    },
    legend: {
      type: "scroll" as const,
      top: 0,
      left: 0,
      right: 0,
      itemWidth: 18,
      itemHeight: 10,
      textStyle: { color: textColor, fontSize: 12 },
    },
    grid: {
      left: 160,
      right: 78,
      bottom: 28,
      top: 52,
      containLabel: false,
    },
    xAxis: {
      type: "value" as const,
      name: metric === "bytes" ? "bundle size (raw)" : "median wall time",
      nameLocation: "middle" as const,
      nameGap: 28,
      nameTextStyle: { color: textColor, fontSize: 11 },
      axisLabel: {
        color: textColor,
        formatter: (value: number) => formatValue(value, metric),
      },
      axisLine: { lineStyle: { color: axisLineColor } },
      splitLine: { lineStyle: { color: gridLineColor } },
    },
    yAxis: {
      type: "category" as const,
      inverse: true,
      data: scales,
      axisLabel: {
        color: textColor,
        fontSize: 12,
        width: 145,
        overflow: "break" as const,
      },
      axisLine: { lineStyle: { color: axisLineColor } },
      axisTick: { show: false },
    },
    series,
  };
}

function ChartPanel({ chart, isDark }: { chart: ChartDefinition; isDark: boolean }) {
  const option = useMemo(() => buildHorizontalBarOption(chart.entries, isDark), [chart.entries, isDark]);

  return (
    <section className="not-content overflow-hidden rounded-lg border border-surface-200 bg-white shadow-sm dark:border-surface-800 dark:bg-surface-950/70">
      <div className="border-b border-surface-200 px-4 py-3 dark:border-surface-800">
        <h2 className="text-base font-semibold text-neutral-900 dark:text-neutral-100">{chart.title}</h2>
        <p className="mt-1 text-sm leading-6 text-neutral-600 dark:text-neutral-400">{chart.description}</p>
      </div>
      <div className="overflow-x-auto px-2 py-4">
        <ReactEChartsCore
          echarts={echarts}
          option={option}
          style={{ height: chartHeight(chart.entries), minWidth: 720, width: "100%" }}
          lazyUpdate
        />
      </div>
    </section>
  );
}

type BenchmarkResultKey = keyof typeof benchmarkData.results;

/** 단일 차트만 컴팩트하게 렌더 — 랜딩/하이라이트 용. */
export function BenchmarkHighlight({
  chartKey,
  height,
}: {
  chartKey: BenchmarkResultKey;
  height?: number;
}) {
  const isDark = useStarlightDark();
  const entries = benchmarkData.results[chartKey] as BenchEntry[];
  const option = useMemo(() => buildHorizontalBarOption(entries, isDark), [entries, isDark]);

  return (
    <div className="not-content overflow-x-auto">
      <ReactEChartsCore
        echarts={echarts}
        option={option}
        style={{ height: height ?? chartHeight(entries), minWidth: 720, width: "100%" }}
        lazyUpdate
      />
    </div>
  );
}

export default function BenchmarkCharts() {
  const isDark = useStarlightDark();
  const charts: ChartDefinition[] = [
    {
      title: "CLI Transpile",
      description: "Single-file TypeScript transpilation through direct CLI binaries.",
      entries: benchmarkData.results.transpileCli,
    },
    {
      title: "CLI Bundle",
      description: "Small to large deterministic module graphs through direct CLI binaries.",
      entries: benchmarkData.results.bundleCli,
    },
    {
      title: "Cold Build (in-process)",
      description:
        "Cache-less initial full build via each tool's in-process programmatic API (in-memory). esbuild's small-fixture numbers are dominated by its Node↔Go service IPC round-trip; ZNTC/rolldown are napi (no IPC).",
      entries: benchmarkData.results.coldBuild,
    },
    {
      title: "Incremental Rebuild (in-process)",
      description:
        "Pure incremental rebuild compute (cache reuse, debounce/watch latency excluded): ZNTC watch({watchDelay:0}), esbuild ctx.rebuild(), rolldown bundle.generate(). Median of 50 in-process rebuilds (constant-size in-place edit) — stable across runs.",
      entries: benchmarkData.results.incrementalRebuild,
    },
    {
      title: "Bundle Size — Tree-shake + Minify",
      description:
        "Real npm libraries bundled and minified with the same input. Raw output bytes — lower is better. Tree-shaking + minifier quality, not speed.",
      entries: benchmarkData.results.bundleSize,
    },
    {
      title: "NAPI vs WASM vs CLI",
      description: "Public in-process bindings compared with subprocess CLI startup cost.",
      entries: benchmarkData.results.napiWasmCli,
    },
    {
      title: "Bundle Perf CI Matrix",
      description: "Same-run CI-style wall time comparison for ZNTC, Rolldown, and Rspack.",
      entries: benchmarkData.results.bundlePerf,
    },
    {
      title: "ZNTC Pipeline Patterns",
      description: "ZNTC profile totals across generated simple, expression-heavy, string-heavy, object, and React-like sources.",
      entries: benchmarkData.results.pipelineTotal,
    },
  ];

  return (
    <div className="not-content flex flex-col gap-5">
      <div className="rounded-lg border border-surface-200 bg-white px-4 py-3 text-sm leading-6 text-neutral-700 shadow-sm dark:border-surface-800 dark:bg-surface-950/70 dark:text-neutral-300">
        <strong className="text-neutral-900 dark:text-neutral-100">Measurement:</strong> {benchmarkData.platform}, {benchmarkData.date}.
        CLI charts use median wall time. Lower is better.
        <br />
        <strong className="text-neutral-900 dark:text-neutral-100">Bundle Size:</strong> {benchmarkData.sizeBenchmark.libraries} real npm libraries, {benchmarkData.sizeBenchmark.date}, {benchmarkData.sizeBenchmark.mode}. {benchmarkData.sizeBenchmark.note}
      </div>
      {charts.map((chart) => (
        <ChartPanel key={chart.title} chart={chart} isDark={isDark} />
      ))}
      <p className="text-center text-sm text-neutral-500 dark:text-neutral-400">
        CLI iterations: {benchmarkData.runs.cli.iterations}. NAPI/WASM warmup: {benchmarkData.runs.napi.warmup}, iterations: {benchmarkData.runs.napi.iterations}. Bundle-perf warmup: {benchmarkData.runs.bundlePerf.warmup}, iterations: {benchmarkData.runs.bundlePerf.iterations}.
      </p>
    </div>
  );
}
