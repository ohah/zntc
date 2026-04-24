import { useState, useEffect } from "react";
import ReactEChartsCore from "echarts-for-react/lib/core";
import * as echarts from "echarts/core";
import { BarChart } from "echarts/charts";
import {
  TooltipComponent,
  GridComponent,
  LegendComponent,
} from "echarts/components";
import { CanvasRenderer } from "echarts/renderers";

import benchmarkData from "../data/benchmark-data.json";

echarts.use([
  BarChart,
  TooltipComponent,
  GridComponent,
  LegendComponent,
  CanvasRenderer,
]);

const TOOL_COLORS: Record<string, string> = {
  ZTS: "#f7a41d",
  esbuild: "#eab308",
  SWC: "#ef4444",
  Bun: "#a855f7",
  oxc: "#f97316",
  rolldown: "#14b8a6",
  rspack: "#f59e0b",
  webpack: "#06b6d4",
};

const PIPELINE_COLORS = ["#60a5fa", "#f472b6", "#34d399", "#fbbf24", "#a78bfa"];

type BenchEntry = {
  tool: string;
  scale: string;
  avgMs: number;
  minMs: number;
  maxMs: number;
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

function buildGroupedBarOption(
  title: string,
  entries: BenchEntry[],
  isDark: boolean,
) {
  const scales = [...new Set(entries.map((e) => e.scale))];
  const tools = [...new Set(entries.map((e) => e.tool))];

  const textColor = isDark ? "#e5e7eb" : "#374151";
  const axisLineColor = isDark ? "#4b5563" : "#d1d5db";

  const series = tools.map((tool) => ({
    name: tool,
    type: "bar" as const,
    barGap: "10%",
    emphasis: { focus: "series" as const },
    itemStyle: { color: TOOL_COLORS[tool] || "#888" },
    data: scales.map((scale) => {
      const entry = entries.find((e) => e.tool === tool && e.scale === scale);
      return entry ? entry.avgMs : 0;
    }),
  }));

  return {
    title: {
      text: title,
      left: "center",
      textStyle: { color: textColor, fontSize: 16 },
    },
    tooltip: {
      trigger: "axis" as const,
      axisPointer: { type: "shadow" as const },
      formatter: (params: Array<{ seriesName: string; axisValue: string; value: number; marker: string }>) => {
        let html = `<strong>${params[0].axisValue}</strong><br/>`;
        for (const p of params) {
          const entry = entries.find(
            (e) => e.tool === p.seriesName && e.scale === p.axisValue,
          );
          html += `${p.marker} ${p.seriesName}: <strong>${p.value}ms</strong>`;
          if (entry) {
            html += ` <span style="color:#999">(${entry.minMs}-${entry.maxMs}ms)</span>`;
          }
          html += "<br/>";
        }
        return html;
      },
    },
    legend: {
      top: 30,
      textStyle: { color: textColor },
    },
    grid: {
      left: "3%",
      right: "4%",
      bottom: "3%",
      top: 80,
      containLabel: true,
    },
    xAxis: {
      type: "category" as const,
      data: scales,
      axisLabel: { color: textColor, fontSize: 11 },
      axisLine: { lineStyle: { color: axisLineColor } },
    },
    yAxis: {
      type: "value" as const,
      name: "ms",
      nameTextStyle: { color: textColor },
      axisLabel: { color: textColor },
      axisLine: { lineStyle: { color: axisLineColor } },
      splitLine: { lineStyle: { color: isDark ? "#374151" : "#e5e7eb" } },
    },
    series,
  };
}

function buildPipelineOption(isDark: boolean) {
  const { labels, data } = benchmarkData.results.pipeline;
  const scaleKeys = Object.keys(data) as Array<keyof typeof data>;

  const textColor = isDark ? "#e5e7eb" : "#374151";
  const axisLineColor = isDark ? "#4b5563" : "#d1d5db";

  const series = labels.map((label, i) => ({
    name: label,
    type: "bar" as const,
    stack: "pipeline",
    emphasis: { focus: "series" as const },
    itemStyle: { color: PIPELINE_COLORS[i] },
    data: scaleKeys.map((key) => data[key][i]),
  }));

  return {
    title: {
      text: "ZTS Pipeline Profile (us)",
      left: "center",
      textStyle: { color: textColor, fontSize: 16 },
    },
    tooltip: {
      trigger: "axis" as const,
      axisPointer: { type: "shadow" as const },
      formatter: (params: Array<{ seriesName: string; value: number; marker: string; axisValue: string }>) => {
        let html = `<strong>${params[0].axisValue}</strong><br/>`;
        let total = 0;
        for (const p of params) {
          html += `${p.marker} ${p.seriesName}: <strong>${p.value}us</strong><br/>`;
          total += p.value;
        }
        html += `<br/><strong>Total: ${total}us (${(total / 1000).toFixed(2)}ms)</strong>`;
        return html;
      },
    },
    legend: {
      top: 30,
      textStyle: { color: textColor },
    },
    grid: {
      left: "3%",
      right: "4%",
      bottom: "3%",
      top: 80,
      containLabel: true,
    },
    xAxis: {
      type: "category" as const,
      data: scaleKeys,
      axisLabel: { color: textColor },
      axisLine: { lineStyle: { color: axisLineColor } },
    },
    yAxis: {
      type: "value" as const,
      name: "us",
      nameTextStyle: { color: textColor },
      axisLabel: { color: textColor },
      axisLine: { lineStyle: { color: axisLineColor } },
      splitLine: { lineStyle: { color: isDark ? "#374151" : "#e5e7eb" } },
    },
    series,
  };
}

export default function BenchmarkCharts() {
  const isDark = useIsDark();

  const transpileOption = buildGroupedBarOption(
    "Transpile Performance",
    benchmarkData.results.transpile,
    isDark,
  );

  const bundleOption = buildGroupedBarOption(
    "Bundle Performance",
    benchmarkData.results.bundle,
    isDark,
  );

  const pipelineOption = buildPipelineOption(isDark);

  const chartStyle = { height: 400, width: "100%" };

  return (
    <div className="flex flex-col gap-8">
      <ReactEChartsCore
        echarts={echarts}
        option={transpileOption}
        style={chartStyle}
        lazyUpdate
      />
      <ReactEChartsCore
        echarts={echarts}
        option={bundleOption}
        style={chartStyle}
        lazyUpdate
      />
      <ReactEChartsCore
        echarts={echarts}
        option={pipelineOption}
        style={chartStyle}
        lazyUpdate
      />
      <p className="text-center text-sm text-neutral-500 dark:text-neutral-400">
        Measured on {benchmarkData.platform} | {benchmarkData.date} | {benchmarkData.iterations} iterations avg
      </p>
    </div>
  );
}
