import { useState, useCallback, useEffect, useRef } from "react";
import Editor from "@monaco-editor/react";
import type { TranspileResult } from "../../../packages/shared/index";
import {
  BTN_CLASS,
  Badge,
  Chk,
  EditorPanel,
  SELECT_BTN_CLASS,
  Section,
  Sel,
  Txt,
  editorOpts as sharedEditorOpts,
  inferLanguage,
} from "./playground-shared";

const EXAMPLES: { label: string; code: string }[] = [
  {
    label: "TypeScript 기본",
    code: `interface User {
  name: string;
  age: number;
}

function greet(user: User): string {
  return \`Hello, \${user.name}!\`;
}

const user: User = { name: "World", age: 42 };
console.log(greet(user));
`,
  },
  {
    label: "RSC: 'use client' 컴포넌트",
    code: `"use client";

import { useState } from "react";

export default function Counter() {
  const [count, setCount] = useState(0);
  return (
    <div>
      <p>Count: {count}</p>
      <button onClick={() => setCount(count + 1)}>+</button>
    </div>
  );
}
`,
  },
  {
    label: "RSC: 'use server' 액션",
    code: `"use server";

export async function createUser(data: { name: string; email: string }) {
  // 서버에서만 실행되는 코드
  const id = crypto.randomUUID();
  return { id, ...data };
}

export async function deleteUser(id: string) {
  return { ok: true, id };
}
`,
  },
  {
    label: "RSC: 인라인 server function",
    code: `export function Item({ id }: { id: number }) {
  async function deleteItem() {
    "use server";
    await fetch(\`/api/items/\${id}\`, { method: "DELETE" });
  }
  return <button onClick={deleteItem}>Delete</button>;
}
`,
  },
  {
    label: "Decorators (Stage 3)",
    code: `function loggable<T, U>(value: (this: T, ...args: any[]) => U, ctx: ClassMethodDecoratorContext<T>) {
  return function (this: T, ...args: any[]) {
    console.log(\`call \${String(ctx.name)}\`);
    return value.call(this, ...args);
  };
}

class Service {
  @loggable
  greet(name: string) { return \`hi \${name}\`; }
}

new Service().greet("world");
`,
  },
];

const DEFAULT_CODE = EXAMPLES[0].code;

type TranspileFn = (
  source: string,
  options?: Record<string, unknown>,
) => TranspileResult;

interface Options {
  filename: string;
  jsx: "classic" | "automatic" | "automatic-dev";
  jsxInJs: boolean;
  format: "esm" | "cjs";
  minify: boolean;
  minifyWhitespace: boolean;
  minifyIdentifiers: boolean;
  minifySyntax: boolean;
  sourcemap: boolean;
  sourcemapDebugIds: boolean;
  sourcesContent: boolean;
  dropConsole: boolean;
  dropDebugger: boolean;
  asciiOnly: boolean;
  charsetUtf8: boolean;
  experimentalDecorators: boolean;
  emitDecoratorMetadata: boolean;
  flow: boolean;
  quotes: "double" | "single" | "preserve";
  target: string;
  platform: string;
  useDefineForClassFields: boolean;
  jsxFactory: string;
  jsxFragment: string;
  jsxImportSource: string;
}

const DEFAULT_OPTIONS: Options = {
  filename: "input.tsx",
  jsx: "classic",
  jsxInJs: false,
  format: "esm",
  minify: false,
  minifyWhitespace: false,
  minifyIdentifiers: false,
  minifySyntax: false,
  sourcemap: false,
  sourcemapDebugIds: false,
  sourcesContent: true,
  dropConsole: false,
  dropDebugger: false,
  asciiOnly: false,
  charsetUtf8: false,
  experimentalDecorators: false,
  emitDecoratorMetadata: false,
  flow: false,
  quotes: "double",
  target: "esnext",
  platform: "browser",
  useDefineForClassFields: true,
  jsxFactory: "",
  jsxFragment: "",
  jsxImportSource: "",
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
      jsxInJs: opts.jsxInJs,
      sourcemap: opts.sourcemap,
      sourcemapDebugIds: opts.sourcemapDebugIds,
      sourcesContent: opts.sourcesContent,
      minify: opts.minify,
      minifyWhitespace: opts.minifyWhitespace,
      minifyIdentifiers: opts.minifyIdentifiers,
      minifySyntax: opts.minifySyntax,
      format: opts.format,
      dropConsole: opts.dropConsole,
      dropDebugger: opts.dropDebugger,
      asciiOnly: opts.asciiOnly,
      charsetUtf8: opts.charsetUtf8,
      experimentalDecorators: opts.experimentalDecorators,
      emitDecoratorMetadata: opts.emitDecoratorMetadata,
      flow: opts.flow,
      quotes: opts.quotes,
      target: opts.target === "esnext" ? undefined : opts.target,
      platform: opts.platform,
      useDefineForClassFields: opts.useDefineForClassFields,
      jsxFactory: opts.jsxFactory || undefined,
      jsxFragment: opts.jsxFragment || undefined,
      jsxImportSource: opts.jsxImportSource || undefined,
    });
    // tsc 호환: 시맨틱 에러가 있어도 code는 함께 반환된다.
    // result.errors가 있으면 에러 마커를 표시하되 변환 결과는 유지.
    return { output: result.code, sourcemap: result.map || "", error: result.errors || "" };
  } catch (err) {
    return { output: "", sourcemap: "", error: String(err) };
  }
}

/** URL hash에서 코드와 옵션을 디코딩한다.
 *  - 새 포맷: JSON { code, options } → base64
 *  - 구 포맷: 코드만 base64 (하위 호환)
 */
function decodeHash(): { code: string; options?: Partial<Options> } {
  if (typeof window === "undefined") return { code: DEFAULT_CODE };
  const hash = window.location.hash.slice(1);
  if (!hash) return { code: DEFAULT_CODE };
  try {
    const decoded = decodeURIComponent(escape(atob(hash)));
    // JSON 형식이면 새 포맷
    if (decoded.startsWith("{")) {
      const parsed = JSON.parse(decoded);
      return { code: parsed.code || DEFAULT_CODE, options: parsed.options };
    }
    // 구 포맷: 코드만
    return { code: decoded };
  } catch {
    return { code: DEFAULT_CODE };
  }
}

export default function Playground() {
  const hashData = decodeHash();
  const [input, setInput] = useState(hashData.code);
  const [output, setOutput] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [options, setOptions] = useState<Options>({ ...DEFAULT_OPTIONS, ...hashData.options });
  const [showConfig, setShowConfig] = useState(true);
  const [outputTab, setOutputTab] = useState<"code" | "sourcemap">("code");
  const transpileFnRef = useRef<TranspileFn | undefined>(undefined);
  const inputEditorRef = useRef<any>(null);
  const monacoRef = useRef<any>(null);
  const [sourcemapOutput, setSourcemapOutput] = useState("");

  function parseErrors(errorStr: string) {
    const markers: any[] = [];
    const regex = /(?:\S+):(\d+):(\d+):\s*error(?:\[[^\]]*\])?:\s*(.+)/g;
    let match;
    while ((match = regex.exec(errorStr)) !== null) {
      const line = parseInt(match[1], 10);
      const col = parseInt(match[2], 10);
      markers.push({
        severity: 8, // MarkerSeverity.Error
        startLineNumber: line,
        startColumn: col,
        endLineNumber: line,
        endColumn: col + 1,
        message: match[3].trim(),
        source: 'ZTS',
      });
    }
    if (markers.length === 0 && errorStr) {
      markers.push({
        severity: 8,
        startLineNumber: 1,
        startColumn: 1,
        endLineNumber: 1,
        endColumn: 1000,
        message: errorStr,
        source: 'ZTS',
      });
    }
    return markers;
  }

  function updateMarkers(errorStr: string) {
    const monaco = monacoRef.current;
    if (!monaco || !inputEditorRef.current) return;
    const model = inputEditorRef.current.getModel();
    if (!model) return;

    if (!errorStr) {
      monaco.editor.setModelMarkers(model, 'zts', []);
      return;
    }

    const markers = parseErrors(errorStr);
    monaco.editor.setModelMarkers(model, 'zts', markers);
  }

  const runTranspile = useCallback((code: string, opts: Options) => {
    const result = doTranspile(transpileFnRef.current, code, opts);
    setOutput(result.output);
    setSourcemapOutput(result.sourcemap);
    setError(result.error);
    updateMarkers(result.error);
  }, []);

  useEffect(() => {
    (async () => {
      try {
        const mod = await import("../../../packages/wasm/index.ts");
        const base = "/zts/";
        const wasmUrl = new URL(`${base}zts.wasm`, window.location.origin);
        await mod.init(wasmUrl);
        transpileFnRef.current = mod.transpile;
        setLoading(false);
        const result = doTranspile(mod.transpile, input, options);
        setOutput(result.output);
        setSourcemapOutput(result.sourcemap);
        setError(result.error);
        updateMarkers(result.error);
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
      setTimeout(() => runTranspile(input, newOpts), 0);
      return newOpts;
    });
  }

  function handleShare() {
    // 기본값과 다른 옵션만 포함하여 URL을 짧게 유지
    const changedOpts: Partial<Options> = {};
    for (const [key, val] of Object.entries(options)) {
      if (val !== (DEFAULT_OPTIONS as any)[key]) {
        (changedOpts as any)[key] = val;
      }
    }
    const payload = Object.keys(changedOpts).length > 0
      ? JSON.stringify({ code: input, options: changedOpts })
      : input; // 옵션이 기본값이면 구 포맷 유지 (하위 호환)
    const encoded = btoa(unescape(encodeURIComponent(payload)));
    const url = `${window.location.origin}${window.location.pathname}#${encoded}`;
    navigator.clipboard.writeText(url);
  }

  function handleInputMount(editor: any, monaco: any) {
    inputEditorRef.current = editor;
    monacoRef.current = monaco;

    // TypeScript compiler options for JSX support and autocompletion
    monaco.languages.typescript.typescriptDefaults.setCompilerOptions({
      target: monaco.languages.typescript.ScriptTarget.ESNext,
      module: monaco.languages.typescript.ModuleKind.ESNext,
      moduleResolution: monaco.languages.typescript.ModuleResolutionKind.NodeJs,
      jsx: monaco.languages.typescript.JsxEmit.React,
      allowJs: true,
      strict: true,
      esModuleInterop: true,
      allowNonTsExtensions: true,
    });

    // Disable TS diagnostics (ZTS provides its own error markers)
    monaco.languages.typescript.typescriptDefaults.setDiagnosticsOptions({
      noSemanticValidation: true,
      noSyntaxValidation: true,
    });

    setTimeout(() => {
      editor.layout();
      if (monaco?.editor?.remeasureFonts) monaco.editor.remeasureFonts();
    }, 100);
  }

  function handleOutputMount(editor: any) {
    setTimeout(() => {
      editor.layout();
      const m = (window as any).monaco;
      if (m?.editor?.remeasureFonts) m.editor.remeasureFonts();
    }, 100);
  }

  const inputLang = inferLanguage(options.filename);
  const editorOpts = sharedEditorOpts;

  return (
    <div
      className="not-content playground-root flex flex-col overflow-hidden bg-surface-950"
      style={{ height: "calc(100vh - 64px)" }}
    >
      <div className="flex shrink-0 items-center justify-between border-b border-surface-800 bg-surface-900 px-4 py-2">
        <div className="flex items-center gap-2">
          <button type="button" onClick={() => setShowConfig(!showConfig)} className={BTN_CLASS}>
            {showConfig ? "◀" : "▶"}
          </button>
          <a href="/zts/" className="text-sm font-bold text-neutral-200 no-underline">
            ZTS Playground
          </a>
          {loading && <Badge variant="loading" text="Loading WASM..." />}
          {!loading && !error && <Badge variant="ready" />}
        </div>
        <div className="flex items-center gap-2">
          <select
            aria-label="예제"
            onChange={(e) => {
              const ex = EXAMPLES.find((x) => x.label === e.target.value);
              if (ex) setInput(ex.code);
              e.target.value = "";
            }}
            defaultValue=""
            className={SELECT_BTN_CLASS}
          >
            <option value="" disabled>예제 선택…</option>
            {EXAMPLES.map((ex) => (
              <option key={ex.label} value={ex.label}>{ex.label}</option>
            ))}
          </select>
          <button type="button" onClick={handleShare} className={BTN_CLASS}>Share</button>
          <a href={`${(import.meta.env.BASE_URL ?? "/").replace(/\/?$/, "/")}playground/bundler/`} className={BTN_CLASS}>
            Bundler 모드
          </a>
          <a href="https://github.com/ohah/zts" target="_blank" rel="noreferrer" className={BTN_CLASS}>
            GitHub
          </a>
        </div>
      </div>

      <div className="flex flex-1 overflow-hidden">
        {showConfig && (
          <div className="pg-config w-60 min-w-[15rem] shrink-0 overflow-y-auto border-r border-surface-800 bg-surface-900 p-3 text-[13px]">
            <Section title="Parser">
              <Sel label="Language" value={options.filename} onChange={(v) => updateOption("filename", v)} options={[["input.tsx","TypeScript+JSX"],["input.ts","TypeScript"],["input.jsx","JavaScript+JSX"],["input.js","JavaScript"]]} />
              <Chk label="Flow" checked={options.flow} onChange={(v) => updateOption("flow", v)} />
              <Chk label="JSX in .js" checked={options.jsxInJs} onChange={(v) => updateOption("jsxInJs", v)} />
              <Chk label="Experimental Decorators" checked={options.experimentalDecorators} onChange={(v) => updateOption("experimentalDecorators", v)} />
              <Chk label="Emit Decorator Metadata" checked={options.emitDecoratorMetadata} onChange={(v) => updateOption("emitDecoratorMetadata", v)} />
            </Section>
            <Section title="Target">
              <Sel label="Target" value={options.target} onChange={(v) => updateOption("target", v)} options={[["esnext","ESNext"],["es2025","ES2025"],["es2024","ES2024"],["es2022","ES2022"],["es2021","ES2021"],["es2020","ES2020"],["es2019","ES2019"],["es2018","ES2018"],["es2017","ES2017"],["es2016","ES2016"],["es2015","ES2015"],["es5","ES5"]]} />
              <Sel label="Platform" value={options.platform} onChange={(v) => updateOption("platform", v)} options={[["browser","Browser"],["node","Node"],["neutral","Neutral"],["react-native","React Native"]]} />
            </Section>
            <Section title="Transform">
              <Sel label="JSX" value={options.jsx} onChange={(v) => updateOption("jsx", v as Options["jsx"])} options={[["classic","Classic"],["automatic","Automatic"],["automatic-dev","Automatic (Dev)"]]} />
              <Txt label="JSX Factory" value={options.jsxFactory} placeholder="React.createElement" onChange={(v) => updateOption("jsxFactory", v)} />
              <Txt label="JSX Fragment" value={options.jsxFragment} placeholder="React.Fragment" onChange={(v) => updateOption("jsxFragment", v)} />
              <Txt label="JSX Import Source" value={options.jsxImportSource} placeholder="react" onChange={(v) => updateOption("jsxImportSource", v)} />
              <Sel label="Module" value={options.format} onChange={(v) => updateOption("format", v as Options["format"])} options={[["esm","ESM"],["cjs","CJS"]]} />
              <Chk label="useDefineForClassFields" checked={options.useDefineForClassFields} onChange={(v) => updateOption("useDefineForClassFields", v)} />
            </Section>
            <Section title="Output">
              <Chk label="Minify (all)" checked={options.minify} onChange={(v) => updateOption("minify", v)} />
              <Chk label="Whitespace" checked={options.minifyWhitespace} onChange={(v) => updateOption("minifyWhitespace", v)} />
              <Chk label="Identifiers" checked={options.minifyIdentifiers} onChange={(v) => updateOption("minifyIdentifiers", v)} />
              <Chk label="Syntax" checked={options.minifySyntax} onChange={(v) => updateOption("minifySyntax", v)} />
              <Chk label="ASCII Only" checked={options.asciiOnly} onChange={(v) => updateOption("asciiOnly", v)} />
              <Chk label="Charset UTF-8" checked={options.charsetUtf8} onChange={(v) => updateOption("charsetUtf8", v)} />
              <Sel label="Quotes" value={options.quotes} onChange={(v) => updateOption("quotes", v as Options["quotes"])} options={[["double","Double"],["single","Single"],["preserve","Preserve"]]} />
            </Section>
            <Section title="Sourcemap">
              <Chk label="Generate" checked={options.sourcemap} onChange={(v) => updateOption("sourcemap", v)} />
              <Chk label="Sources Content" checked={options.sourcesContent} onChange={(v) => updateOption("sourcesContent", v)} />
              <Chk label="Debug IDs (Sentry)" checked={options.sourcemapDebugIds} onChange={(v) => updateOption("sourcemapDebugIds", v)} />
            </Section>
            <Section title="Drop">
              <Chk label="console.*" checked={options.dropConsole} onChange={(v) => updateOption("dropConsole", v)} />
              <Chk label="debugger" checked={options.dropDebugger} onChange={(v) => updateOption("dropDebugger", v)} />
            </Section>
          </div>
        )}

        <div className="pg-editors flex flex-1 overflow-hidden">
          <EditorPanel
            header={
              <span>
                Input <span className="text-[11px] opacity-50">{options.filename}</span>
              </span>
            }
          >
            <Editor height="100%" language={inputLang} theme="vs-dark" value={input} onChange={handleInputChange} onMount={handleInputMount} options={editorOpts} />
          </EditorPanel>
          <div className="pg-divider w-[2px] shrink-0 bg-surface-800" />
          <EditorPanel
            header={
              <div className="flex w-full items-center justify-between">
                <div className="flex">
                  <Tab active={outputTab === "code"} onClick={() => setOutputTab("code")}>Output</Tab>
                  {options.sourcemap && (
                    <Tab active={outputTab === "sourcemap"} onClick={() => setOutputTab("sourcemap")}>
                      Sourcemap
                    </Tab>
                  )}
                </div>
                {error && <span className="text-[11px] text-red-400">Error</span>}
              </div>
            }
          >
            {outputTab === "code" ? (
              <Editor height="100%" language={error ? "plaintext" : "javascript"} theme="vs-dark" value={error || output} onMount={handleOutputMount} options={{ ...editorOpts, readOnly: true }} />
            ) : (
              <Editor height="100%" language="json" theme="vs-dark" value={sourcemapOutput} onMount={handleOutputMount} options={{ ...editorOpts, readOnly: true, lineNumbers: "off" }} />
            )}
          </EditorPanel>
        </div>
      </div>
    </div>
  );
}

function Tab({ active, onClick, children }: { active: boolean; onClick: () => void; children: React.ReactNode }) {
  const state = active
    ? "border-zig-500 text-neutral-200 font-semibold"
    : "border-transparent text-neutral-500 font-normal";
  return (
    <button
      type="button"
      onClick={onClick}
      className={`cursor-pointer border-b-2 bg-transparent px-3 py-1 text-[12px] transition-colors ${state}`}
    >
      {children}
    </button>
  );
}
