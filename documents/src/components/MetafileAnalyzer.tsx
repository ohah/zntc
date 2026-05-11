import { useDeferredValue, useMemo, useState, type ReactNode } from "react";
import ReactEChartsCore from "echarts-for-react/lib/core";
import * as echarts from "echarts/core";
import { TreemapChart, GraphChart } from "echarts/charts";
import { TooltipComponent, LegendComponent } from "echarts/components";
import { CanvasRenderer } from "echarts/renderers";

echarts.use([TreemapChart, GraphChart, TooltipComponent, LegendComponent, CanvasRenderer]);

type ImportKind =
  | "import-statement"
  | "require-call"
  | "dynamic-import"
  | "require-resolve"
  | "import-rule"
  | "composes-from"
  | "url-token";

type ImportRecord = {
  path?: string;
  kind?: ImportKind | string;
  external?: boolean;
  original?: string;
};

type InputMeta = {
  bytes?: number;
  imports?: ImportRecord[];
  format?: string;
};

type OutputInputMeta = {
  bytesInOutput?: number;
};

type OutputMeta = {
  bytes?: number;
  inputs?: Record<string, OutputInputMeta>;
  imports?: ImportRecord[];
  exports?: string[];
  entryPoint?: string;
  cssBundle?: string;
};

type Metafile = {
  inputs?: Record<string, InputMeta>;
  outputs?: Record<string, OutputMeta>;
};

type RankedModule = {
  path: string;
  bytes: number;
};

type ViewMode = "summary" | "treemap" | "graph";

const GRAPH_NODE_LIMIT = 250;

const KIND_TO_LINE_STYLE: Record<string, "solid" | "dashed" | "dotted"> = {
  "dynamic-import": "dashed",
  "require-resolve": "dotted",
};

const sampleMetafile = JSON.stringify(
  {
    inputs: {
      "src/main.ts": {
        bytes: 420,
        imports: [
          { path: "src/ui.ts", kind: "import-statement" },
          { path: "src/vendor.ts", kind: "dynamic-import" },
        ],
      },
      "src/ui.ts": {
        bytes: 860,
        imports: [{ path: "src/theme.css", kind: "import-statement" }],
      },
      "src/theme.css": { bytes: 190, imports: [] },
      "src/vendor.ts": { bytes: 2380, imports: [] },
    },
    outputs: {
      "dist/main.js": {
        bytes: 1720,
        entryPoint: "src/main.ts",
        inputs: {
          "src/main.ts": { bytesInOutput: 330 },
          "src/ui.ts": { bytesInOutput: 760 },
          "src/theme.css": { bytesInOutput: 160 },
        },
      },
      "dist/chunks/vendor.js": {
        bytes: 1180,
        inputs: { "src/vendor.ts": { bytesInOutput: 1080 } },
      },
    },
  },
  null,
  2,
);

const nf = new Intl.NumberFormat("en-US");

function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return "0 B";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
}

function parseMetafile(text: string): { meta?: Metafile; error?: string } {
  try {
    const parsed = JSON.parse(text) as Metafile;
    if (!parsed || typeof parsed !== "object") {
      return { error: "JSON object가 아닙니다." };
    }
    if (!parsed.inputs && !parsed.outputs) {
      return { error: "inputs 또는 outputs 필드가 필요합니다." };
    }
    return { meta: parsed };
  } catch (err) {
    return { error: err instanceof Error ? err.message : "JSON parse 실패" };
  }
}

function rankInputs(inputs: Record<string, InputMeta> | undefined): RankedModule[] {
  return Object.entries(inputs ?? {})
    .map(([path, meta]) => ({ path, bytes: meta.bytes ?? 0 }))
    .sort((a, b) => b.bytes - a.bytes);
}

function outputContributions(output: OutputMeta): RankedModule[] {
  return Object.entries(output.inputs ?? {})
    .map(([path, meta]) => ({ path, bytes: meta.bytesInOutput ?? 0 }))
    .sort((a, b) => b.bytes - a.bytes);
}

function countImports(inputs: Record<string, InputMeta> | undefined): number {
  return Object.values(inputs ?? {}).reduce((sum, input) => sum + (input.imports?.length ?? 0), 0);
}

type TreemapNode = {
  name: string;
  value?: number;
  children?: TreemapNode[];
  path?: string;
};

function buildTreemap(inputs: Record<string, InputMeta> | undefined): TreemapNode[] {
  if (!inputs) return [];
  const root: TreemapNode = { name: "bundle", children: [] };
  const lookups = new Map<TreemapNode, Map<string, TreemapNode>>();
  lookups.set(root, new Map());

  for (const [path, meta] of Object.entries(inputs)) {
    const segments = path.split("/").filter(Boolean);
    let cursor = root;
    for (let i = 0; i < segments.length - 1; i++) {
      const dir = segments[i];
      const childMap = lookups.get(cursor)!;
      let next = childMap.get(dir);
      if (!next) {
        next = { name: dir, children: [] };
        cursor.children!.push(next);
        childMap.set(dir, next);
        lookups.set(next, new Map());
      }
      cursor = next;
    }
    const leaf = segments[segments.length - 1] ?? path;
    cursor.children!.push({ name: leaf, value: meta.bytes ?? 0, path });
  }
  return root.children ?? [];
}

type GraphNode = {
  id: string;
  name: string;
  value: number;
  symbolSize: number;
  category: number;
};

type GraphLink = {
  source: string;
  target: string;
  kind: ImportKind | string;
};

type GraphData = {
  nodes: GraphNode[];
  links: GraphLink[];
  categories: { name: string }[];
  overflow?: number;
};

const GRAPH_CATEGORIES = [{ name: "module" }, { name: "external" }];

function buildGraph(inputs: Record<string, InputMeta> | undefined): GraphData {
  if (!inputs) return { nodes: [], links: [], categories: GRAPH_CATEGORIES };

  const inputCount = Object.keys(inputs).length;
  if (inputCount > GRAPH_NODE_LIMIT) {
    return { nodes: [], links: [], categories: GRAPH_CATEGORIES, overflow: inputCount };
  }

  let maxBytes = 1;
  for (const meta of Object.values(inputs)) {
    const b = meta.bytes ?? 0;
    if (b > maxBytes) maxBytes = b;
  }

  const nodes: GraphNode[] = [];
  const seen = new Set<string>();
  const links: GraphLink[] = [];

  function ensureNode(id: string, bytes: number, category: number): void {
    if (seen.has(id)) return;
    const size = bytes > 0 ? Math.max(8, Math.min(42, 8 + (bytes / maxBytes) * 34)) : 8;
    seen.add(id);
    nodes.push({
      id,
      name: id.split("/").pop() ?? id,
      value: bytes,
      symbolSize: size,
      category,
    });
  }

  for (const [path, meta] of Object.entries(inputs)) {
    ensureNode(path, meta.bytes ?? 0, 0);
    for (const imp of meta.imports ?? []) {
      const target = imp.path ?? imp.original;
      if (!target) continue;
      const category = imp.external ? 1 : 0;
      const targetBytes = (!imp.external && inputs[target]?.bytes) || 0;
      ensureNode(target, targetBytes, category);
      links.push({ source: path, target, kind: imp.kind ?? "import-statement" });
    }
  }

  return { nodes, links, categories: GRAPH_CATEGORIES };
}

function BarRow({
  label,
  bytes,
  maxBytes,
  sublabel,
}: {
  label: string;
  bytes: number;
  maxBytes: number;
  sublabel?: string;
}) {
  const pct = maxBytes > 0 ? Math.max(2, (bytes / maxBytes) * 100) : 0;
  return (
    <div className="grid grid-cols-[minmax(0,1fr)_92px] items-center gap-3">
      <div className="min-w-0">
        <div className="flex min-w-0 items-baseline justify-between gap-3 text-[13px]">
          <span className="truncate font-medium text-neutral-100" title={label}>
            {label}
          </span>
          {sublabel ? <span className="shrink-0 text-[11px] text-neutral-500">{sublabel}</span> : null}
        </div>
        <div className="mt-1 h-2 rounded bg-surface-800">
          <div className="h-full rounded bg-zig-500" style={{ width: `${pct}%` }} />
        </div>
      </div>
      <div className="text-right font-mono text-[12px] text-neutral-300">{formatBytes(bytes)}</div>
    </div>
  );
}

function SummaryTile({ label, value, hint }: { label: string; value: string; hint: string }) {
  return (
    <div className="rounded border border-surface-800 bg-surface-900 px-4 py-3">
      <div className="text-[11px] font-semibold uppercase text-neutral-500">{label}</div>
      <div className="mt-1 text-2xl font-semibold text-neutral-100">{value}</div>
      <div className="mt-1 text-[12px] text-neutral-400">{hint}</div>
    </div>
  );
}

function ViewToggleButton({
  active,
  label,
  onClick,
}: {
  active: boolean;
  label: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={
        "rounded border px-3 py-1.5 text-[13px] " +
        (active
          ? "border-zig-500 bg-zig-500/10 text-zig-300"
          : "border-surface-700 text-neutral-200 hover:border-zig-500 hover:text-zig-300")
      }
    >
      {label}
    </button>
  );
}

function ChartFrame({ children, footer }: { children: ReactNode; footer?: ReactNode }) {
  return (
    <div className="rounded border border-surface-800 bg-surface-900 p-2">
      {children}
      {footer ? <div className="border-t border-surface-800 px-3 py-2 text-[11px] text-neutral-500">{footer}</div> : null}
    </div>
  );
}

function EmptyChartPlaceholder({ children }: { children: ReactNode }) {
  return (
    <div className="flex h-[520px] flex-col items-center justify-center gap-2 rounded border border-surface-800 bg-surface-900 px-6 text-center text-[13px] text-neutral-300">
      {children}
    </div>
  );
}

function TreemapView({ inputs }: { inputs: Record<string, InputMeta> | undefined }) {
  const data = useMemo(() => buildTreemap(inputs), [inputs]);
  const option = useMemo(
    () => ({
      backgroundColor: "transparent",
      tooltip: {
        backgroundColor: "rgba(15,15,15,0.95)",
        borderColor: "#262626",
        textStyle: { color: "#e5e5e5", fontSize: 12 },
        formatter: (info: { treePathInfo?: { name: string }[]; value?: number; name?: string }) => {
          const trail = info.treePathInfo?.map((t) => t.name).join(" / ") ?? info.name ?? "";
          const bytes = typeof info.value === "number" ? formatBytes(info.value) : "—";
          return `<div style="font-family:ui-monospace,Menlo,monospace;font-size:11px;">${trail}</div><div style="margin-top:4px;color:#f7a41d;font-weight:600;">${bytes}</div>`;
        },
      },
      series: [
        {
          type: "treemap",
          data,
          width: "100%",
          height: "100%",
          roam: false,
          nodeClick: "zoomToNode",
          breadcrumb: {
            show: true,
            top: 6,
            itemStyle: { color: "#1f2937", borderColor: "#374151", textStyle: { color: "#e5e5e5", fontSize: 11 } },
          },
          label: { show: true, formatter: "{b}", color: "#fafafa", fontSize: 11 },
          upperLabel: { show: true, height: 22, color: "#fafafa", fontSize: 11, backgroundColor: "rgba(0,0,0,0.35)" },
          itemStyle: { borderColor: "#0a0a0a", gapWidth: 2, borderWidth: 1 },
          levels: [
            { itemStyle: { borderWidth: 0, gapWidth: 4, borderColorSaturation: 0.6 } },
            { itemStyle: { borderWidth: 4, gapWidth: 2, borderColorSaturation: 0.6 } },
            { itemStyle: { borderWidth: 1, gapWidth: 1 }, colorSaturation: [0.35, 0.55] },
          ],
        },
      ],
    }),
    [data],
  );

  if (data.length === 0) {
    return <EmptyChartPlaceholder>inputs 가 비어 있어 treemap 을 그릴 수 없습니다.</EmptyChartPlaceholder>;
  }

  return (
    <ChartFrame>
      <ReactEChartsCore echarts={echarts} option={option} style={{ height: "600px", width: "100%" }} />
    </ChartFrame>
  );
}

function GraphView({ inputs }: { inputs: Record<string, InputMeta> | undefined }) {
  const data = useMemo(() => buildGraph(inputs), [inputs]);

  const option = useMemo(() => {
    const links = data.links.map((l) => ({
      source: l.source,
      target: l.target,
      lineStyle: { type: KIND_TO_LINE_STYLE[l.kind] ?? "solid", opacity: 0.55 },
    }));
    return {
      backgroundColor: "transparent",
      tooltip: {
        backgroundColor: "rgba(15,15,15,0.95)",
        borderColor: "#262626",
        textStyle: { color: "#e5e5e5", fontSize: 12 },
        formatter: (info: { dataType?: string; data?: GraphNode | { source: string; target: string } }) => {
          if (info.dataType === "node") {
            const n = info.data as GraphNode;
            return `<div style="font-family:ui-monospace,Menlo,monospace;font-size:11px;">${n.id}</div><div style="margin-top:4px;color:#f7a41d;font-weight:600;">${formatBytes(n.value)}</div>`;
          }
          if (info.dataType === "edge") {
            const l = info.data as { source: string; target: string };
            return `<div style="font-family:ui-monospace,Menlo,monospace;font-size:11px;">${l.source}<br/>↓<br/>${l.target}</div>`;
          }
          return "";
        },
      },
      legend: [
        {
          data: ["module", "external"],
          top: 6,
          right: 12,
          textStyle: { color: "#e5e5e5", fontSize: 12 },
        },
      ],
      color: ["#f7a41d", "#737373"],
      series: [
        {
          type: "graph",
          layout: "force",
          data: data.nodes,
          links,
          categories: data.categories,
          roam: true,
          draggable: true,
          label: {
            show: true,
            position: "right",
            color: "#e5e5e5",
            fontSize: 11,
            formatter: (p: { data: GraphNode }) => p.data.name,
          },
          force: { repulsion: 90, edgeLength: 70, gravity: 0.08, friction: 0.6 },
          lineStyle: { color: "source", curveness: 0.05, width: 1 },
          emphasis: { focus: "adjacency", lineStyle: { width: 2 } },
        },
      ],
    };
  }, [data]);

  if (data.overflow != null) {
    return (
      <EmptyChartPlaceholder>
        <div className="font-semibold text-neutral-100">
          {nf.format(data.overflow)} nodes — force layout 비활성화
        </div>
        <div className="max-w-[480px] text-neutral-400">
          브라우저가 멈출 수 있어 {GRAPH_NODE_LIMIT} 노드까지만 그립니다. Summary 탭의 Largest inputs (path 필터) 또는 Treemap 을
          이용하세요.
        </div>
      </EmptyChartPlaceholder>
    );
  }
  if (data.nodes.length === 0) {
    return <EmptyChartPlaceholder>inputs 가 비어 있어 graph 를 그릴 수 없습니다.</EmptyChartPlaceholder>;
  }

  return (
    <ChartFrame
      footer={
        <>
          <span className="font-semibold text-neutral-300">solid</span> = static import ·{" "}
          <span className="font-semibold text-neutral-300">dashed</span> = dynamic-import · 휠로 zoom, 드래그로 pan, 노드 drag 가능
        </>
      }
    >
      <ReactEChartsCore echarts={echarts} option={option} style={{ height: "600px", width: "100%" }} />
    </ChartFrame>
  );
}

function SummaryView({
  meta,
  inputs,
  outputs,
  filter,
  onFilterChange,
  maxInputBytes,
}: {
  meta: Metafile | undefined;
  inputs: RankedModule[];
  outputs: [string, OutputMeta][];
  filter: string;
  onFilterChange: (next: string) => void;
  maxInputBytes: number;
}) {
  const lowerFilter = filter.toLowerCase();
  const filteredInputs = useMemo(
    () => (lowerFilter ? inputs.filter((item) => item.path.toLowerCase().includes(lowerFilter)) : inputs),
    [inputs, lowerFilter],
  );

  return (
    <>
      <section className="rounded border border-surface-800 bg-surface-900">
        <div className="flex flex-wrap items-center justify-between gap-3 border-b border-surface-800 px-4 py-3">
          <h2 className="text-[14px] font-semibold text-neutral-100">Outputs</h2>
          <span className="text-[12px] text-neutral-500">
            esbuild-compatible `outputs[*].inputs` is used when present
          </span>
        </div>
        <div className="grid gap-3 p-4 xl:grid-cols-2">
          {outputs.map(([path, output]) => {
            const contributions = outputContributions(output);
            const maxBytes = contributions[0]?.bytes ?? 0;
            return (
              <article key={path} className="rounded border border-surface-800 bg-surface-950 p-3">
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <h3 className="truncate text-[13px] font-semibold text-neutral-100" title={path}>
                      {path}
                    </h3>
                    {output.entryPoint ? (
                      <p className="mt-1 text-[12px] text-neutral-500">entry: {output.entryPoint}</p>
                    ) : null}
                  </div>
                  <div className="shrink-0 font-mono text-[12px] text-neutral-300">
                    {formatBytes(output.bytes ?? 0)}
                  </div>
                </div>
                <div className="mt-3 flex flex-col gap-2">
                  {contributions.length > 0 ? (
                    contributions
                      .slice(0, 6)
                      .map((item) => (
                        <BarRow key={item.path} label={item.path} bytes={item.bytes} maxBytes={maxBytes} />
                      ))
                  ) : (
                    <p className="text-[12px] leading-5 text-neutral-500">
                      이 output에는 input 기여도 정보가 없습니다. 현재 ZNTC metafile의 basic form에서는 output 크기와 graph
                      input/import 목록을 함께 확인하세요.
                    </p>
                  )}
                </div>
              </article>
            );
          })}
        </div>
      </section>

      <section className="rounded border border-surface-800 bg-surface-900">
        <div className="flex flex-wrap items-center justify-between gap-3 border-b border-surface-800 px-4 py-3">
          <h2 className="text-[14px] font-semibold text-neutral-100">Largest inputs</h2>
          <input
            value={filter}
            placeholder="Filter path"
            onChange={(event) => onFilterChange(event.currentTarget.value)}
            className="w-[220px] rounded border border-surface-700 bg-surface-950 px-2 py-1 text-[12px] text-neutral-200 outline-none"
          />
        </div>
        <div className="flex max-h-[420px] flex-col gap-3 overflow-auto p-4">
          {filteredInputs.slice(0, 80).map((item) => {
            const input = meta?.inputs?.[item.path];
            const importCount = input?.imports?.length ?? 0;
            return (
              <BarRow
                key={item.path}
                label={item.path}
                bytes={item.bytes}
                maxBytes={maxInputBytes}
                sublabel={importCount === 1 ? "1 import" : `${importCount} imports`}
              />
            );
          })}
        </div>
      </section>
    </>
  );
}

export function MetafileAnalyzer() {
  const [text, setText] = useState(sampleMetafile);
  const [filter, setFilter] = useState("");
  const [view, setView] = useState<ViewMode>("summary");
  const deferredText = useDeferredValue(text);
  const parsed = useMemo(() => parseMetafile(deferredText), [deferredText]);
  const meta = parsed.meta;

  const inputs = useMemo(() => rankInputs(meta?.inputs), [meta?.inputs]);
  const outputs = useMemo(() => Object.entries(meta?.outputs ?? {}), [meta?.outputs]);
  const inputTotal = useMemo(() => inputs.reduce((sum, item) => sum + item.bytes, 0), [inputs]);
  const outputTotal = useMemo(() => outputs.reduce((sum, [, out]) => sum + (out.bytes ?? 0), 0), [outputs]);
  const importTotal = useMemo(() => countImports(meta?.inputs), [meta?.inputs]);
  const maxInputBytes = inputs[0]?.bytes ?? 0;

  async function loadFile(file: File | undefined) {
    if (!file) return;
    setText(await file.text());
  }

  return (
    <main className="min-h-[calc(100vh-160px)] bg-surface-950 text-neutral-100">
      <div className="mx-auto flex max-w-[1500px] flex-col gap-4 px-4 py-4 lg:px-6">
        <header className="flex flex-col gap-3 border-b border-surface-800 pb-4 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p className="text-[12px] font-semibold uppercase text-zig-400">ZNTC Metafile</p>
            <h1 className="mt-1 text-2xl font-semibold tracking-normal text-neutral-50">Analyze bundle metadata</h1>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <label className="cursor-pointer rounded border border-surface-700 px-3 py-1.5 text-[13px] text-neutral-200 hover:border-zig-500 hover:text-zig-300">
              Upload JSON
              <input
                type="file"
                accept="application/json,.json"
                className="hidden"
                onChange={(event) => void loadFile(event.currentTarget.files?.[0])}
              />
            </label>
            <button
              type="button"
              className="rounded border border-surface-700 px-3 py-1.5 text-[13px] text-neutral-200 hover:border-zig-500 hover:text-zig-300"
              onClick={() => setText(sampleMetafile)}
            >
              Load sample
            </button>
          </div>
        </header>

        <section className="grid gap-4 lg:grid-cols-[minmax(320px,0.7fr)_minmax(0,1.3fr)]">
          <div className="flex min-h-[520px] flex-col overflow-hidden rounded border border-surface-800 bg-surface-900">
            <div className="border-b border-surface-800 px-3 py-2 text-[12px] font-semibold text-neutral-400">
              meta.json
            </div>
            <textarea
              spellCheck={false}
              value={text}
              onChange={(event) => setText(event.currentTarget.value)}
              className="min-h-0 flex-1 resize-none bg-surface-950 p-3 font-mono text-[12px] leading-5 text-neutral-200 outline-none"
            />
          </div>

          <div className="flex min-w-0 flex-col gap-4">
            {parsed.error ? (
              <div className="rounded border border-red-900 bg-red-950/40 px-4 py-3 text-[13px] text-red-200">
                {parsed.error}
              </div>
            ) : null}

            <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
              <SummaryTile label="Inputs" value={nf.format(inputs.length)} hint={formatBytes(inputTotal)} />
              <SummaryTile label="Outputs" value={nf.format(outputs.length)} hint={formatBytes(outputTotal)} />
              <SummaryTile label="Imports" value={nf.format(importTotal)} hint="resolved graph edges" />
              <SummaryTile
                label="Format"
                value={outputs.some(([, out]) => out.inputs) ? "Detailed" : "Basic"}
                hint="output attribution"
              />
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <ViewToggleButton active={view === "summary"} label="Summary" onClick={() => setView("summary")} />
              <ViewToggleButton active={view === "treemap"} label="Treemap" onClick={() => setView("treemap")} />
              <ViewToggleButton active={view === "graph"} label="Import graph" onClick={() => setView("graph")} />
            </div>

            {view === "summary" ? (
              <SummaryView
                meta={meta}
                inputs={inputs}
                outputs={outputs}
                filter={filter}
                onFilterChange={setFilter}
                maxInputBytes={maxInputBytes}
              />
            ) : view === "treemap" ? (
              <TreemapView inputs={meta?.inputs} />
            ) : (
              <GraphView inputs={meta?.inputs} />
            )}
          </div>
        </section>
      </div>
    </main>
  );
}
