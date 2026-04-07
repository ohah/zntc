import { useState, useCallback, useEffect, useRef } from "react";

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
      // 초기 트랜스파일
      doTranspile(DEFAULT_CODE, options, mod.transpile);
    } catch (err) {
      setError(`WASM 로드 실패: ${err}`);
      setLoading(false);
    }
  }

  const doTranspile = useCallback(
    (
      code: string,
      opts: typeof options,
      transpileFn?: TranspileFn,
    ) => {
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
        setError("");
      } catch (err) {
        setError(String(err));
        setOutput("");
      }
    },
    [],
  );

  const handleInputChange = useCallback(
    (e: React.ChangeEvent<HTMLTextAreaElement>) => {
      const value = e.target.value;
      setInput(value);
      doTranspile(value, options);
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

  return (
    <div style={{ padding: "1rem 0", maxWidth: "100%" }}>
      {/* 옵션 바 */}
      <div
        style={{
          display: "flex",
          gap: "1rem",
          flexWrap: "wrap",
          marginBottom: "0.75rem",
          alignItems: "center",
          fontSize: "0.875rem",
        }}
      >
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
        <label style={{ display: "flex", alignItems: "center", gap: "0.25rem" }}>
          <input
            type="checkbox"
            checked={options.minify}
            onChange={(e) => handleOptionChange("minify", e.target.checked)}
          />
          Minify
        </label>
        <label style={{ display: "flex", alignItems: "center", gap: "0.25rem" }}>
          <input
            type="checkbox"
            checked={options.sourcemap}
            onChange={(e) => handleOptionChange("sourcemap", e.target.checked)}
          />
          Sourcemap
        </label>
      </div>

      {/* 에디터 영역 */}
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "1fr 1fr",
          gap: "0.5rem",
          minHeight: "400px",
        }}
      >
        {/* 입력 */}
        <div style={{ display: "flex", flexDirection: "column" }}>
          <div style={headerStyle}>Input (TypeScript)</div>
          <textarea
            value={input}
            onChange={handleInputChange}
            style={editorStyle}
            spellCheck={false}
            autoComplete="off"
            autoCorrect="off"
          />
        </div>

        {/* 출력 */}
        <div style={{ display: "flex", flexDirection: "column" }}>
          <div style={headerStyle}>
            Output (JavaScript)
            {loading && <span style={{ marginLeft: "0.5rem", opacity: 0.6 }}>Loading WASM...</span>}
          </div>
          {error ? (
            <pre style={{ ...editorStyle, color: "#f87171", whiteSpace: "pre-wrap" }}>
              {error}
            </pre>
          ) : (
            <textarea
              value={output}
              readOnly
              style={{ ...editorStyle, opacity: loading ? 0.5 : 1 }}
            />
          )}
        </div>
      </div>

      {/* 소스맵 출력 */}
      {options.sourcemap && output && !error && (
        <details style={{ marginTop: "0.5rem" }}>
          <summary style={{ cursor: "pointer", fontSize: "0.875rem" }}>Sourcemap</summary>
          <pre
            style={{
              ...editorStyle,
              height: "150px",
              marginTop: "0.25rem",
              fontSize: "0.75rem",
            }}
          >
            {(() => {
              try {
                const r = wasmRef.current?.transpile(input, { ...options });
                return r?.map || "No sourcemap";
              } catch {
                return "Error generating sourcemap";
              }
            })()}
          </pre>
        </details>
      )}
    </div>
  );
}

const editorStyle: React.CSSProperties = {
  flex: 1,
  fontFamily: "'SF Mono', 'Fira Code', 'Cascadia Code', monospace",
  fontSize: "0.875rem",
  lineHeight: 1.5,
  padding: "0.75rem",
  border: "1px solid var(--sl-color-gray-5, #374151)",
  borderRadius: "0 0 0.375rem 0.375rem",
  backgroundColor: "var(--sl-color-gray-7, #111827)",
  color: "var(--sl-color-white, #f9fafb)",
  resize: "vertical",
  outline: "none",
  minHeight: "400px",
  tabSize: 2,
};

const headerStyle: React.CSSProperties = {
  padding: "0.5rem 0.75rem",
  fontSize: "0.75rem",
  fontWeight: 600,
  textTransform: "uppercase",
  letterSpacing: "0.05em",
  backgroundColor: "var(--sl-color-gray-6, #1f2937)",
  borderRadius: "0.375rem 0.375rem 0 0",
  border: "1px solid var(--sl-color-gray-5, #374151)",
  borderBottom: "none",
};

const selectStyle: React.CSSProperties = {
  padding: "0.25rem 0.5rem",
  borderRadius: "0.25rem",
  border: "1px solid var(--sl-color-gray-5, #374151)",
  backgroundColor: "var(--sl-color-gray-6, #1f2937)",
  color: "inherit",
  fontSize: "0.875rem",
};
