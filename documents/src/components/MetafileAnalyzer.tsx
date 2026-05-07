import { useMemo, useState } from "react";

type ImportRecord = {
  path?: string;
  kind?: string;
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

export function MetafileAnalyzer() {
  const [text, setText] = useState(sampleMetafile);
  const [filter, setFilter] = useState("");
  const parsed = useMemo(() => parseMetafile(text), [text]);
  const meta = parsed.meta;

  const inputs = useMemo(() => rankInputs(meta?.inputs), [meta?.inputs]);
  const outputs = useMemo(() => Object.entries(meta?.outputs ?? {}), [meta?.outputs]);
  const inputTotal = inputs.reduce((sum, item) => sum + item.bytes, 0);
  const outputTotal = outputs.reduce((sum, [, out]) => sum + (out.bytes ?? 0), 0);
  const importTotal = countImports(meta?.inputs);
  const maxInputBytes = inputs[0]?.bytes ?? 0;
  const filteredInputs = inputs.filter((item) => item.path.toLowerCase().includes(filter.toLowerCase()));

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
              <SummaryTile label="Format" value={outputs.some(([, out]) => out.inputs) ? "Detailed" : "Basic"} hint="output attribution" />
            </div>

            <section className="rounded border border-surface-800 bg-surface-900">
              <div className="flex flex-wrap items-center justify-between gap-3 border-b border-surface-800 px-4 py-3">
                <h2 className="text-[14px] font-semibold text-neutral-100">Outputs</h2>
                <span className="text-[12px] text-neutral-500">esbuild-compatible `outputs[*].inputs` is used when present</span>
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
                          {output.entryPoint ? <p className="mt-1 text-[12px] text-neutral-500">entry: {output.entryPoint}</p> : null}
                        </div>
                        <div className="shrink-0 font-mono text-[12px] text-neutral-300">{formatBytes(output.bytes ?? 0)}</div>
                      </div>
                      <div className="mt-3 flex flex-col gap-2">
                        {contributions.length > 0 ? (
                          contributions
                            .slice(0, 6)
                            .map((item) => <BarRow key={item.path} label={item.path} bytes={item.bytes} maxBytes={maxBytes} />)
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
                  onChange={(event) => setFilter(event.currentTarget.value)}
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
          </div>
        </section>
      </div>
    </main>
  );
}
