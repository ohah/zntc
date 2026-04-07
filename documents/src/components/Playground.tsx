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

interface WasmModule {
  init: (url: URL | string) => Promise<void>;
  transpile: TranspileFn;
}

export default function Playground() {
  const [input, setInput] = useState(DEFAULT_CODE);
  const [output, setOutput] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [options, setOptions] = useState({
    jsx: "classic" as "classic" | "automatic" | "automatic-dev",
    sourcemap: false,
    minify: false,
    format: "esm" as "esm" | "cjs",
    filename: "input.tsx",
  });
  const wasmRef = useRef<WasmModule | null>(null);
  const [sourcemapOutput, setSourcemapOutput] = useState("");

  useEffect(() => {
    loadWasm();
  }, []);

  async function loadWasm() {
    try {
      const mod = await import("../../../packages/wasm/index.ts");
      const base = import.meta.env?.BASE_URL || "/zts/";
      const wasmUrl = new URL(`${base}zts.wasm`, window.location.origin);
      await mod.init(wasmUrl);
      wasmRef.current = mod;
      setLoading(false);
      doTranspile(DEFAULT_CODE, options, mod.transpile);
    } catch (err) {
      setError(`WASM 로드 실패: ${err}`);
      setLoading(false);
    }
  }

  const doTranspile = useCallback(
    (code: string, opts: typeof options, transpileFn?: TranspileFn) => {
      const fn = transpileFn || wasmRef.current?.transpile;
      if (!fn) return;
      try {
        const result = fn(code, {
          filename: opts.filename,
          jsx: opts.jsx,
          sourcemap: opts.sourcemap,
          minify: opts.minify,
          format: opts.format,
        });
        setOutput(result.code);
        setSourcemapOutput(result.map || "");
        setError("");
      } catch (err) {
        setError(String(err));
        setOutput("");
        setSourcemapOutput("");
      }
    },
    [],
  );

  const handleInputChange = useCallback(
    (value: string | undefined) => {
      const code = value ?? "";
      setInput(code);
      doTranspile(code, options);
    },
    [options, doTranspile],
  );

  const handleOptionChange = useCallback(
    (key: string, value: string | boolean) => {
      const newOpts = { ...options, [key]: value };
      setOptions(newOpts);
      doTranspile(input, newOpts);
    },
    [input, options, doTranspile],
  );

  // filename → Monaco language 매핑
  const inputLang =
    options.filename.endsWith(".tsx") || options.filename.endsWith(".jsx")
      ? "typescript"
      : options.filename.endsWith(".ts")
        ? "typescript"
        : "javascript";

  return (
    <div style={{ padding: "1rem 0", maxWidth: "100%" }}>
      {/* 옵션 바 */}
      <div style={toolbarStyle}>
        <label>
          JSX:{" "}
          <select
            value={options.jsx}
            onChange={(e) => handleOptionChange("jsx", e.target.value)}
            style={selectStyle}
          >
            <option value="classic">Classic</option>
            <option value="automatic">Automatic</option>
            <option value="automatic-dev">Automatic (Dev)</option>
          </select>
        </label>
        <label>
          Format:{" "}
          <select
            value={options.format}
            onChange={(e) => handleOptionChange("format", e.target.value)}
            style={selectStyle}
          >
            <option value="esm">ESM</option>
            <option value="cjs">CJS</option>
          </select>
        </label>
        <label>
          File:{" "}
          <select
            value={options.filename}
            onChange={(e) => handleOptionChange("filename", e.target.value)}
            style={selectStyle}
          >
            <option value="input.tsx">input.tsx</option>
            <option value="input.ts">input.ts</option>
            <option value="input.jsx">input.jsx</option>
            <option value="input.js">input.js</option>
          </select>
        </label>
        <label style={checkboxLabel}>
          <input
            type="checkbox"
            checked={options.minify}
            onChange={(e) => handleOptionChange("minify", e.target.checked)}
          />
          Minify
        </label>
        <label style={checkboxLabel}>
          <input
            type="checkbox"
            checked={options.sourcemap}
            onChange={(e) => handleOptionChange("sourcemap", e.target.checked)}
          />
          Sourcemap
        </label>
        {loading && <span style={{ opacity: 0.6, fontSize: "0.75rem" }}>Loading WASM...</span>}
      </div>

      {/* 에디터 영역 */}
      <div style={editorGrid}>
        {/* 입력 */}
        <div style={panelStyle}>
          <div style={headerStyle}>Input (TypeScript)</div>
          <div style={editorContainer}>
            <Editor
              height="500px"
              language={inputLang}
              theme="vs-dark"
              value={input}
              onChange={handleInputChange}
              options={{
                minimap: { enabled: false },
                fontSize: 14,
                lineNumbers: "on",
                scrollBeyondLastLine: false,
                wordWrap: "on",
                tabSize: 2,
                automaticLayout: true,
                padding: { top: 8 },
              }}
            />
          </div>
        </div>

        {/* 출력 */}
        <div style={panelStyle}>
          <div style={headerStyle}>
            Output (JavaScript)
            {error && (
              <span style={{ color: "#f87171", marginLeft: "0.5rem", fontWeight: 400 }}>
                Error
              </span>
            )}
          </div>
          <div style={editorContainer}>
            {error ? (
              <Editor
                height="500px"
                language="plaintext"
                theme="vs-dark"
                value={error}
                options={{
                  readOnly: true,
                  minimap: { enabled: false },
                  fontSize: 14,
                  lineNumbers: "off",
                  scrollBeyondLastLine: false,
                  wordWrap: "on",
                  automaticLayout: true,
                  padding: { top: 8 },
                }}
              />
            ) : (
              <Editor
                height="500px"
                language="javascript"
                theme="vs-dark"
                value={output}
                options={{
                  readOnly: true,
                  minimap: { enabled: false },
                  fontSize: 14,
                  lineNumbers: "on",
                  scrollBeyondLastLine: false,
                  wordWrap: "on",
                  automaticLayout: true,
                  padding: { top: 8 },
                }}
              />
            )}
          </div>
        </div>
      </div>

      {/* 소스맵 출력 */}
      {options.sourcemap && sourcemapOutput && !error && (
        <details style={{ marginTop: "0.5rem" }}>
          <summary style={{ cursor: "pointer", fontSize: "0.875rem" }}>Sourcemap</summary>
          <div style={{ marginTop: "0.25rem" }}>
            <Editor
              height="200px"
              language="json"
              theme="vs-dark"
              value={sourcemapOutput}
              options={{
                readOnly: true,
                minimap: { enabled: false },
                fontSize: 12,
                lineNumbers: "off",
                scrollBeyondLastLine: false,
                wordWrap: "on",
                automaticLayout: true,
              }}
            />
          </div>
        </details>
      )}
    </div>
  );
}

const toolbarStyle: React.CSSProperties = {
  display: "flex",
  gap: "1rem",
  flexWrap: "wrap",
  marginBottom: "0.75rem",
  alignItems: "center",
  fontSize: "0.875rem",
};

const editorGrid: React.CSSProperties = {
  display: "grid",
  gridTemplateColumns: "1fr 1fr",
  gap: "0.5rem",
};

const panelStyle: React.CSSProperties = {
  display: "flex",
  flexDirection: "column",
  overflow: "hidden",
  borderRadius: "0.375rem",
  border: "1px solid var(--sl-color-gray-5, #374151)",
};

const editorContainer: React.CSSProperties = {
  flex: 1,
  overflow: "hidden",
};

const headerStyle: React.CSSProperties = {
  padding: "0.5rem 0.75rem",
  fontSize: "0.75rem",
  fontWeight: 600,
  textTransform: "uppercase",
  letterSpacing: "0.05em",
  backgroundColor: "var(--sl-color-gray-6, #1f2937)",
  borderBottom: "1px solid var(--sl-color-gray-5, #374151)",
};

const selectStyle: React.CSSProperties = {
  padding: "0.25rem 0.5rem",
  borderRadius: "0.25rem",
  border: "1px solid var(--sl-color-gray-5, #374151)",
  backgroundColor: "var(--sl-color-gray-6, #1f2937)",
  color: "inherit",
  fontSize: "0.875rem",
};

const checkboxLabel: React.CSSProperties = {
  display: "flex",
  alignItems: "center",
  gap: "0.25rem",
};
