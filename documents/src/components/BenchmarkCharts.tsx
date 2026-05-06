import { useEffect, useMemo, useState } from "react";
import ReactEChartsCore from "echarts-for-react/lib/core";
import * as echarts from "echarts/core";
import { BarChart } from "echarts/charts";
import { TooltipComponent, GridComponent, LegendComponent } from "echarts/components";
import { CanvasRenderer } from "echarts/renderers";

import benchmarkData from "../data/benchmark-data.json";

echarts.use([BarChart, TooltipComponent, GridComponent, LegendComponent, CanvasRenderer]);

const SERIES_COLORS: Record<string, string> = {
  ZTS: "#f7a41d",
  esbuild: "#2563eb",
  SWC: "#ef4444",
  Bun: "#a855f7",
  "oxc (node)": "#f97316",
  Rolldown: "#14b8a6",
  Rspack: "#f59e0b",
  rolldown: "#14b8a6",
  rspack: "#f59e0b",
  webpack: "#06b6d4",
  "NAPI (.node)": "#22c55e",
  "WASM (.wasm)": "#38bdf8",
  "CLI (subprocess)": "#f97316",
  simple: "#60a5fa",
  expr: "#f472b6",
  string: "#34d399",
  object: "#fbbf24",
  react: "#a78bfa",
};

type BenchEntry = {
  tool: string;
  scale: string;
  medianMs: number;
  minMs?: number;
  maxMs?: number;
  p95Ms?: number;
};

type ChartDefinition = {
  title: string;
  description: string;
  entries: BenchEntry[];
};

function useIsDark(): boolean {
  const [isDark, setIsDark] = useState(false);

  useEffect(() => {
    const check = () => {
      setIsDark(document.documentElement.dataset.theme === "dark");
    };
    check();
    const observer = new MutationObserver(check);
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"],
    });
    return () => observer.disconnect();
  }, []);

  return isDark;
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

function chartHeight(entries: BenchEntry[]): number {
  const scaleCount = uniqueInOrder(entries.map((entry) => entry.scale)).length;
  const toolCount = uniqueInOrder(entries.map((entry) => entry.tool)).length;
  return Math.max(320, 112 + scaleCount * Math.max(48, toolCount * 18));
}

function buildHorizontalBarOption(entries: BenchEntry[], isDark: boolean) {
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
        typeof value === "number" ? formatMs(value) : "",
    },
    data: scales.map((scale) => {
      const entry = entries.find((item) => item.tool === tool && item.scale === scale);
      return entry ? Number(entry.medianMs.toFixed(4)) : null;
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
        for (const param of params) {
          if (typeof param.value !== "number") continue;
          const entry = entries.find(
            (item) => item.tool === param.seriesName && item.scale === param.axisValue,
          );
          html += `${param.marker} ${param.seriesName}: <strong>${formatMs(param.value)}</strong>`;
          if (entry?.minMs !== undefined && entry.maxMs !== undefined) {
            html += ` <span style="color:#8a8580">(${formatMs(entry.minMs)}-${formatMs(entry.maxMs)})</span>`;
          }
          if (entry?.p95Ms !== undefined) {
            html += ` <span style="color:#8a8580">p95 ${formatMs(entry.p95Ms)}</span>`;
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
      name: "median wall time",
      nameLocation: "middle" as const,
      nameGap: 28,
      nameTextStyle: { color: textColor, fontSize: 11 },
      axisLabel: {
        color: textColor,
        formatter: (value: number) => formatMs(value),
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

export default function BenchmarkCharts() {
  const isDark = useIsDark();
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
      title: "NAPI vs WASM vs CLI",
      description: "Public in-process bindings compared with subprocess CLI startup cost.",
      entries: benchmarkData.results.napiWasmCli,
    },
    {
      title: "Bundle Perf CI Matrix",
      description: "Same-run CI-style wall time comparison for ZTS, Rolldown, and Rspack.",
      entries: benchmarkData.results.bundlePerf,
    },
    {
      title: "ZTS Pipeline Patterns",
      description: "ZTS profile totals across generated simple, expression-heavy, string-heavy, object, and React-like sources.",
      entries: benchmarkData.results.pipelineTotal,
    },
  ];

  return (
    <div className="not-content flex flex-col gap-5">
      <div className="rounded-lg border border-surface-200 bg-white px-4 py-3 text-sm leading-6 text-neutral-700 shadow-sm dark:border-surface-800 dark:bg-surface-950/70 dark:text-neutral-300">
        <strong className="text-neutral-900 dark:text-neutral-100">Measurement:</strong> {benchmarkData.platform}, {benchmarkData.date}.
        CLI charts use median wall time. Lower is better.
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
