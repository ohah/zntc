import { useState, useCallback, useEffect, useRef } from "react";
import Editor from "@monaco-editor/react";

const DEFAULT_CODE = `interface User {
  name: string;
  age: number;
}

function greet(user: User): string {
  return \`Hello, \${user.name}!\`;
}

const user: User = { name: "World", age: 42 };
console.log(greet(user));
`;

type TranspileFn = (
  source: string,
  options?: Record<string, unknown>,
) => { code: string; map?: string };

interface Options {
  filename: string;
  jsx: "classic" | "automatic" | "automatic-dev";
  format: "esm" | "cjs";
  minify: boolean;
  minifyWhitespace: boolean;
  minifyIdentifiers: boolean;
  minifySyntax: boolean;
  sourcemap: boolean;
  dropConsole: boolean;
  dropDebugger: boolean;
  asciiOnly: boolean;
  experimentalDecorators: boolean;
  flow: boolean;
  quotes: "double" | "single" | "preserve";
}

const DEFAULT_OPTIONS: Options = {
  filename: "input.tsx",
  jsx: "classic",
  format: "esm",
  minify: false,
  minifyWhitespace: false,
  minifyIdentifiers: false,
  minifySyntax: false,
  sourcemap: false,
  dropConsole: false,
  dropDebugger: false,
  asciiOnly: false,
  experimentalDecorators: false,
  flow: false,
  quotes: "double",
};

function doTranspile(
  transpileFn: TranspileFn | undefined,
  code: string,
  opts: Options,
): { output: string; sourcemap: string; error: string } {
  if (!transpileFn) return { output: "", sourcemap: "", error: "" };
  try {
    const result = transpileFn(code, {
      filename: opts.filename,
      jsx: opts.jsx,
      sourcemap: opts.sourcemap,
      minify: opts.minify,
      minifyWhitespace: opts.minifyWhitespace,
      minifyIdentifiers: opts.minifyIdentifiers,
      minifySyntax: opts.minifySyntax,
      format: opts.format,
      dropConsole: opts.dropConsole,
      dropDebugger: opts.dropDebugger,
      asciiOnly: opts.asciiOnly,
      experimentalDecorators: opts.experimentalDecorators,
      flow: opts.flow,
      quotes: opts.quotes,
    });
    return { output: result.code, sourcemap: result.map || "", error: "" };
  } catch (err) {
    return { output: "", sourcemap: "", error: String(err) };
  }
}

export default function Playground() {
  const [input, setInput] = useState(() => {
    if (typeof window !== "undefined") {
      const hash = window.location.hash.slice(1);
      if (hash) {
        try { return atob(hash); } catch {}
      }
    }
    return DEFAULT_CODE;
  });
  const [output, setOutput] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [options, setOptions] = useState<Options>(DEFAULT_OPTIONS);
  const [showConfig, setShowConfig] = useState(true);
  const [outputTab, setOutputTab] = useState<"code" | "sourcemap">("code");
  const transpileFnRef = useRef<TranspileFn | undefined>(undefined);
  const [sourcemapOutput, setSourcemapOutput] = useState("");

  const runTranspile = useCallback((code: string, opts: Options) => {
    const result = doTranspile(transpileFnRef.current, code, opts);
    setOutput(result.output);
    setSourcemapOutput(result.sourcemap);
    setError(result.error);
  }, []);

  useEffect(() => {
    (async () => {
      try {
        const mod = await import("../../../packages/wasm/index.ts");
        const base = (import.meta.env?.BASE_URL || "/zts/").replace(/\/?$/, "/");
        const wasmUrl = new URL(`${base}zts-core.wasm`, window.location.origin);
        await mod.init(wasmUrl);
        transpileFnRef.current = mod.transpile;
        setLoading(false);
        const result = doTranspile(mod.transpile, input, options);
        setOutput(result.output);
        setSourcemapOutput(result.sourcemap);
        setError(result.error);
      } catch (err) {
        setError(`WASM load failed: ${err}`);
        setLoading(false);
      }
    })();
  }, []);

  function handleInputChange(value: string | undefined) {
    const code = value ?? "";
    setInput(code);
    runTranspile(code, options);
  }

  function updateOption<K extends keyof Options>(key: K, value: Options[K]) {
    setOptions((prev) => {
      const newOpts = { ...prev, [key]: value };
      if (key === "minify") {
        newOpts.minifyWhitespace = value as boolean;
        newOpts.minifyIdentifiers = value as boolean;
        newOpts.minifySyntax = value as boolean;
      }
      // 다음 렌더 전에 트랜스파일 — ref 기반이라 stale 없음
      setTimeout(() => runTranspile(input, newOpts), 0);
      return newOpts;
    });
  }

  function handleShare() {
    const encoded = btoa(unescape(encodeURIComponent(input)));
    const url = `${window.location.origin}${window.location.pathname}#${encoded}`;
    navigator.clipboard.writeText(url);
    alert("URL copied to clipboard!");
  }

  const inputLang =
    options.filename.endsWith(".tsx") || options.filename.endsWith(".jsx")
      ? "typescript"
      : options.filename.endsWith(".ts")
        ? "typescript"
        : "javascript";

  const editorOpts = {
    minimap: { enabled: false },
    fontSize: 13,
    lineNumbers: "on" as const,
    scrollBeyondLastLine: false,
    wordWrap: "on" as const,
    tabSize: 2,
    automaticLayout: true,
    padding: { top: 8, bottom: 8 },
    renderLineHighlight: "none" as const,
    overviewRulerLanes: 0,
    hideCursorInOverviewRuler: true,
    scrollbar: { verticalScrollbarSize: 8, horizontalScrollbarSize: 8 },
  };

  return (
    <div style={containerStyle}>
      {/* 상단 툴바 */}
      <div style={topBarStyle}>
        <div style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
          <button onClick={() => setShowConfig(!showConfig)} style={iconBtnStyle} title="Toggle config">
            <span style={{ fontSize: "1.1rem" }}>{showConfig ? "◀" : "▶"}</span>
          </button>
          <span style={{ fontWeight: 700, fontSize: "0.9rem" }}>ZTS Playground</span>
          {loading && <span style={badgeStyle}>Loading WASM...</span>}
          {!loading && !error && <span style={{ ...badgeStyle, background: "#065f46", color: "#6ee7b7" }}>Ready</span>}
        </div>
        <div style={{ display: "flex", gap: "0.5rem", alignItems: "center" }}>
          <button onClick={handleShare} style={btnStyle}>Share</button>
          <a href="https://github.com/ohah/zts" target="_blank" rel="noreferrer" style={{ ...btnStyle, textDecoration: "none" }}>
            GitHub
          </a>
        </div>
      </div>

      <div style={{ display: "flex", flex: 1, overflow: "hidden" }}>
        {/* 왼쪽 설정 패널 */}
        {showConfig && (
          <div style={configPanelStyle}>
            <ConfigSection title="Parser">
              <SelectOption label="Language" value={options.filename} onChange={(v) => updateOption("filename", v)}
                options={[
                  ["input.tsx", "TypeScript + JSX"],
                  ["input.ts", "TypeScript"],
                  ["input.jsx", "JavaScript + JSX"],
                  ["input.js", "JavaScript"],
                ]}
              />
              <CheckOption label="Flow" checked={options.flow} onChange={(v) => updateOption("flow", v)} />
              <CheckOption label="Experimental Decorators" checked={options.experimentalDecorators} onChange={(v) => updateOption("experimentalDecorators", v)} />
            </ConfigSection>

            <ConfigSection title="Transform">
              <SelectOption label="JSX Runtime" value={options.jsx} onChange={(v) => updateOption("jsx", v as Options["jsx"])}
                options={[
                  ["classic", "Classic (createElement)"],
                  ["automatic", "Automatic (jsx-runtime)"],
                  ["automatic-dev", "Automatic (Dev)"],
                ]}
              />
              <SelectOption label="Module" value={options.format} onChange={(v) => updateOption("format", v as Options["format"])}
                options={[["esm", "ESM"], ["cjs", "CommonJS"]]}
              />
            </ConfigSection>

            <ConfigSection title="Output">
              <CheckOption label="Minify (all)" checked={options.minify} onChange={(v) => updateOption("minify", v)} />
              <CheckOption label="Minify Whitespace" checked={options.minifyWhitespace} onChange={(v) => updateOption("minifyWhitespace", v)} />
              <CheckOption label="Minify Identifiers" checked={options.minifyIdentifiers} onChange={(v) => updateOption("minifyIdentifiers", v)} />
              <CheckOption label="Minify Syntax" checked={options.minifySyntax} onChange={(v) => updateOption("minifySyntax", v)} />
              <CheckOption label="Sourcemap" checked={options.sourcemap} onChange={(v) => updateOption("sourcemap", v)} />
              <CheckOption label="ASCII Only" checked={options.asciiOnly} onChange={(v) => updateOption("asciiOnly", v)} />
              <SelectOption label="Quotes" value={options.quotes} onChange={(v) => updateOption("quotes", v as Options["quotes"])}
                options={[["double", "Double"], ["single", "Single"], ["preserve", "Preserve"]]}
              />
            </ConfigSection>

            <ConfigSection title="Drop">
              <CheckOption label="console.*" checked={options.dropConsole} onChange={(v) => updateOption("dropConsole", v)} />
              <CheckOption label="debugger" checked={options.dropDebugger} onChange={(v) => updateOption("dropDebugger", v)} />
            </ConfigSection>
          </div>
        )}

        {/* 에디터 영역 */}
        <div style={{ flex: 1, display: "flex", overflow: "hidden" }}>
          {/* 입력 에디터 */}
          <div style={editorPanelStyle}>
            <div style={editorHeaderStyle}>
              <span>Input</span>
              <span style={{ opacity: 0.5, fontSize: "0.7rem" }}>{options.filename}</span>
            </div>
            <div style={{ flex: 1 }}>
              <Editor
                height="100%"
                language={inputLang}
                theme="vs-dark"
                value={input}
                onChange={handleInputChange}
                options={editorOpts}
              />
            </div>
          </div>

          {/* 구분선 */}
          <div style={dividerStyle} />

          {/* 출력 에디터 */}
          <div style={editorPanelStyle}>
            <div style={editorHeaderStyle}>
              <div style={{ display: "flex", gap: "0" }}>
                <button onClick={() => setOutputTab("code")} style={tabStyle(outputTab === "code")}>
                  Output
                </button>
                {options.sourcemap && (
                  <button onClick={() => setOutputTab("sourcemap")} style={tabStyle(outputTab === "sourcemap")}>
                    Sourcemap
                  </button>
                )}
              </div>
              {error && <span style={{ color: "#f87171", fontSize: "0.7rem" }}>Error</span>}
            </div>
            <div style={{ flex: 1 }}>
              {outputTab === "code" ? (
                <Editor
                  height="100%"
                  language={error ? "plaintext" : "javascript"}
                  theme="vs-dark"
                  value={error || output}
                  options={{ ...editorOpts, readOnly: true }}
                />
              ) : (
                <Editor
                  height="100%"
                  language="json"
                  theme="vs-dark"
                  value={sourcemapOutput}
                  options={{ ...editorOpts, readOnly: true, lineNumbers: "off" }}
                />
              )}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

// ─── Sub-components ───

function ConfigSection({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div style={{ marginBottom: "0.75rem" }}>
      <div style={sectionTitleStyle}>{title}</div>
      <div style={{ display: "flex", flexDirection: "column", gap: "0.375rem" }}>{children}</div>
    </div>
  );
}

function CheckOption({ label, checked, onChange }: { label: string; checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <label style={optionRowStyle}>
      <input type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} />
      <span>{label}</span>
    </label>
  );
}

function SelectOption({ label, value, onChange, options }: {
  label: string; value: string; onChange: (v: string) => void; options: [string, string][];
}) {
  return (
    <div style={optionRowStyle}>
      <span>{label}</span>
      <select value={value} onChange={(e) => onChange(e.target.value)} style={cfgSelectStyle}>
        {options.map(([val, text]) => <option key={val} value={val}>{text}</option>)}
      </select>
    </div>
  );
}

// ─── Styles ───

const containerStyle: React.CSSProperties = {
  display: "flex",
  flexDirection: "column",
  height: "calc(100vh - 64px)",
  margin: "-1rem -1.5rem",
  overflow: "hidden",
  backgroundColor: "#1a1a2e",
};

const topBarStyle: React.CSSProperties = {
  display: "flex",
  justifyContent: "space-between",
  alignItems: "center",
  padding: "0.5rem 1rem",
  backgroundColor: "#16162a",
  borderBottom: "1px solid #2d2d4a",
  flexShrink: 0,
};

const badgeStyle: React.CSSProperties = {
  padding: "0.125rem 0.5rem",
  borderRadius: "9999px",
  fontSize: "0.65rem",
  fontWeight: 600,
  background: "#1e3a5f",
  color: "#93c5fd",
};

const btnStyle: React.CSSProperties = {
  padding: "0.25rem 0.75rem",
  borderRadius: "0.25rem",
  border: "1px solid #2d2d4a",
  backgroundColor: "transparent",
  color: "#e2e8f0",
  fontSize: "0.8rem",
  cursor: "pointer",
};

const iconBtnStyle: React.CSSProperties = {
  ...btnStyle,
  padding: "0.25rem 0.5rem",
  lineHeight: 1,
};

const configPanelStyle: React.CSSProperties = {
  width: "240px",
  minWidth: "240px",
  backgroundColor: "#16162a",
  borderRight: "1px solid #2d2d4a",
  overflowY: "auto",
  padding: "0.75rem",
  flexShrink: 0,
  fontSize: "0.8rem",
};

const sectionTitleStyle: React.CSSProperties = {
  fontSize: "0.7rem",
  fontWeight: 700,
  textTransform: "uppercase",
  letterSpacing: "0.08em",
  color: "#94a3b8",
  marginBottom: "0.375rem",
  paddingBottom: "0.25rem",
  borderBottom: "1px solid #2d2d4a",
};

const optionRowStyle: React.CSSProperties = {
  display: "flex",
  alignItems: "center",
  justifyContent: "space-between",
  gap: "0.5rem",
  color: "#cbd5e1",
  fontSize: "0.8rem",
  cursor: "pointer",
};

const cfgSelectStyle: React.CSSProperties = {
  padding: "0.125rem 0.25rem",
  borderRadius: "0.25rem",
  border: "1px solid #2d2d4a",
  backgroundColor: "#1a1a2e",
  color: "#e2e8f0",
  fontSize: "0.75rem",
  maxWidth: "130px",
};

const editorPanelStyle: React.CSSProperties = {
  flex: 1,
  display: "flex",
  flexDirection: "column",
  minWidth: 0,
  overflow: "hidden",
};

const editorHeaderStyle: React.CSSProperties = {
  display: "flex",
  justifyContent: "space-between",
  alignItems: "center",
  padding: "0.375rem 0.75rem",
  backgroundColor: "#16162a",
  borderBottom: "1px solid #2d2d4a",
  fontSize: "0.75rem",
  fontWeight: 600,
  color: "#94a3b8",
  flexShrink: 0,
};

const dividerStyle: React.CSSProperties = {
  width: "2px",
  backgroundColor: "#2d2d4a",
  flexShrink: 0,
};

function tabStyle(active: boolean): React.CSSProperties {
  return {
    padding: "0.25rem 0.75rem",
    border: "none",
    backgroundColor: "transparent",
    color: active ? "#e2e8f0" : "#64748b",
    fontWeight: active ? 600 : 400,
    fontSize: "0.75rem",
    cursor: "pointer",
    borderBottom: active ? "2px solid #4ade80" : "2px solid transparent",
  };
}
