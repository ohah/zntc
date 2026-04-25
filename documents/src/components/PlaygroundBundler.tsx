/**
 * PlaygroundBundler — `/playground/bundler` 라우트 메인 컴포넌트.
 *
 * transpile playground 와 분리: 별도 wasm binary (`zts-bundler.wasm`) lazy 로드,
 * 멀티파일 입력 (좌측 사이드바 + Monaco model swap), output 패널은 chunk 별 탭.
 */
import { useEffect, useRef, useState } from "react";
import Editor from "@monaco-editor/react";
import type { BundleOptionsInput, OutputChunk, Target } from "../../../packages/wasm/index.ts";
import {
  BTN_CLASS,
  Badge,
  Chk,
  EditorPanel,
  SELECT_BTN_CLASS,
  Section,
  Sel,
  Txt,
  editorOpts,
  inferLanguage,
} from "./playground-shared";

interface VfsFile {
  path: string;
  content: string;
  language: "typescript" | "javascript";
}

interface Preset {
  label: string;
  entry: string;
  files: VfsFile[];
  /// 선택 시 자동 적용할 권장 BundleOpts (subset). 미지정 필드는 현재 값 유지.
  opts?: Partial<BundleOpts>;
}

const PRESETS: Preset[] = [
  {
    label: "기본 — entry + utils",
    entry: "/index.ts",
    files: [
      {
        path: "/index.ts",
        language: "typescript",
        content: `import { greet } from "./utils";

const user = { name: "ZTS" };
console.log(greet(user.name));
`,
      },
      {
        path: "/utils.ts",
        language: "typescript",
        content: `export const greet = (name: string): string => \`Hello, \${name}!\`;
`,
      },
    ],
  },
  {
    label: "TypeScript 단일 파일",
    entry: "/main.ts",
    files: [
      {
        path: "/main.ts",
        language: "typescript",
        content: `interface Counter {
  value: number;
  increment(): void;
}

export const counter: Counter = {
  value: 0,
  increment() {
    this.value += 1;
  },
};
`,
      },
    ],
  },
  {
    label: "CJS — Node.js 호환 출력",
    entry: "/index.ts",
    opts: { format: "cjs", platform: "node" },
    files: [
      {
        path: "/index.ts",
        language: "typescript",
        content: `// format=cjs / platform=node — Node.js 의 require/exports 로 emit.
// 출력 상단에 "use strict" prologue 자동 추가.
import { format } from "./formatter";

export function main(name: string) {
  console.log(format(name));
}
`,
      },
      {
        path: "/formatter.ts",
        language: "typescript",
        content: `export const format = (name: string): string => \`Hi, \${name}!\`;
`,
      },
    ],
  },
  {
    label: "IIFE — 브라우저 즉시 실행 함수",
    entry: "/main.ts",
    opts: { format: "iife", platform: "browser" },
    files: [
      {
        path: "/main.ts",
        language: "typescript",
        content: `// format=iife — \`(function () { ... })()\` 래퍼로 emit.
// <script> 태그로 즉시 로드 / 실행하는 단일 페이지 / 라이브러리 시나리오.
const root = document.querySelector("#app");
if (root) root.textContent = greet("World");

function greet(name: string): string {
  return \`Hello, \${name}!\`;
}
`,
      },
    ],
  },
  {
    label: "UMD — 브라우저 + Node 양쪽 호환",
    entry: "/lib.ts",
    opts: { format: "umd", platform: "neutral" },
    files: [
      {
        path: "/lib.ts",
        language: "typescript",
        content: `// format=umd — UMD wrapper: AMD (define) / CJS (exports) / global 자동 분기.
// 브라우저 <script> 직접 로드 + Node require + RequireJS 모두 지원하는 라이브러리.
export function greet(name: string): string {
  return \`Hello, \${name}!\`;
}

export const VERSION = "1.0.0";
`,
      },
    ],
  },
  {
    label: "AMD — RequireJS 호환",
    entry: "/module.ts",
    opts: { format: "amd", platform: "browser" },
    files: [
      {
        path: "/module.ts",
        language: "typescript",
        content: `// format=amd — \`define(["dep"], function (dep) { ... })\` 래퍼.
// RequireJS / SystemJS 같은 AMD 로더 환경 (legacy 또는 dynamic 로딩).
import { greet } from "./helpers";

export function run(name: string): void {
  console.log(greet(name));
}
`,
      },
      {
        path: "/helpers.ts",
        language: "typescript",
        content: `export const greet = (name: string): string => \`Hi, \${name}\`;
`,
      },
    ],
  },
  {
    label: "Dynamic import — 코드 스플리팅 시연",
    entry: "/main.ts",
    opts: { codeSplitting: true },
    files: [
      {
        path: "/main.ts",
        language: "typescript",
        content: `// "Code splitting" 옵션을 켜면 dynamic import 가 별도 chunk 로 분리.
// 각 chunk 가 우측 상단 탭으로 표시.
import { greet } from "./shared";

console.log(greet("entry"));

document.querySelector("#load")?.addEventListener("click", async () => {
  const { heavy } = await import("./heavy");
  heavy();
});
`,
      },
      {
        path: "/shared.ts",
        language: "typescript",
        content: `export const greet = (s: string): string => \`hello, \${s}\`;
`,
      },
      {
        path: "/heavy.ts",
        language: "typescript",
        content: `// 별도 chunk 후보 — main 의 dynamic import 만 참조.
import { greet } from "./shared";

export function heavy() {
  console.log(greet("dynamic"));
}
`,
      },
    ],
  },
  {
    label: "External — react 를 외부 처리",
    entry: "/app.tsx",
    opts: { externalText: "react" },
    files: [
      {
        path: "/app.tsx",
        language: "typescript",
        content: `// "External" 패널에 \`react\` 가 자동 입력됨 — import 가 그대로 보존
// (런타임이 외부에서 제공한다고 가정 — CDN, host 환경 등).
import { useState } from "react";

export function Counter() {
  const [n, setN] = useState(0);
  return <button onClick={() => setN(n + 1)}>{n}</button>;
}
`,
      },
    ],
  },
];

type WasmModule = typeof import("../../../packages/wasm/index.ts");

// 매 키스트로크 = 번들 호출. 큰 파일에서 input lag 방지 (transpile 보다 비싸).
const BUNDLE_DEBOUNCE_MS = 200;

const BASE_URL = (import.meta.env.BASE_URL ?? "/").replace(/\/?$/, "/");

interface BundleOpts {
  format: "esm" | "cjs" | "iife" | "umd" | "amd";
  platform: "browser" | "node" | "neutral" | "react-native";
  minify: boolean;
  minifyWhitespace: boolean;
  minifyIdentifiers: boolean;
  minifySyntax: boolean;
  codeSplitting: boolean;
  preserveModules: boolean;
  /// 한 줄에 specifier 하나 (`react`, `react-dom/*` 등 와일드카드 지원).
  externalText: string;
  // ─── transpile 계열 (각 모듈 transform 단계) ───
  target: Target | "esnext";
  jsx: "classic" | "automatic" | "automatic-dev";
  jsxFactory: string;
  jsxFragment: string;
  jsxImportSource: string;
  flow: boolean;
  jsxInJs: boolean;
  experimentalDecorators: boolean;
  emitDecoratorMetadata: boolean;
  useDefineForClassFields: boolean;
  charsetUtf8: boolean;
  keepNames: boolean;
  sourcemap: boolean;
}

const DEFAULT_OPTS: BundleOpts = {
  format: "esm",
  platform: "browser",
  minify: false,
  minifyWhitespace: false,
  minifyIdentifiers: false,
  minifySyntax: false,
  codeSplitting: false,
  preserveModules: false,
  externalText: "",
  target: "esnext",
  jsx: "classic",
  jsxFactory: "",
  jsxFragment: "",
  jsxImportSource: "",
  flow: false,
  jsxInJs: false,
  experimentalDecorators: false,
  emitDecoratorMetadata: false,
  useDefineForClassFields: true,
  charsetUtf8: false,
  keepNames: false,
  sourcemap: false,
};

function parseExternal(text: string): string[] {
  return text
    .split(/[\n,]/)
    .map((s) => s.trim())
    .filter(Boolean);
}

function toApiOptions(opts: BundleOpts): BundleOptionsInput {
  const external = parseExternal(opts.externalText);
  return {
    format: opts.format,
    platform: opts.platform,
    minify: opts.minify,
    minifyWhitespace: opts.minifyWhitespace,
    minifyIdentifiers: opts.minifyIdentifiers,
    minifySyntax: opts.minifySyntax,
    codeSplitting: opts.codeSplitting,
    preserveModules: opts.preserveModules,
    ...(external.length > 0 ? { external } : {}),
    // transpile 계열 — 빈 문자열 / esnext / 기본값은 전송 생략 (URL/payload 짧게).
    ...(opts.target !== "esnext" ? { target: opts.target as Target } : {}),
    jsx: opts.jsx,
    ...(opts.jsxFactory ? { jsxFactory: opts.jsxFactory } : {}),
    ...(opts.jsxFragment ? { jsxFragment: opts.jsxFragment } : {}),
    ...(opts.jsxImportSource ? { jsxImportSource: opts.jsxImportSource } : {}),
    flow: opts.flow,
    jsxInJs: opts.jsxInJs,
    experimentalDecorators: opts.experimentalDecorators,
    emitDecoratorMetadata: opts.emitDecoratorMetadata,
    useDefineForClassFields: opts.useDefineForClassFields,
    charsetUtf8: opts.charsetUtf8,
    keepNames: opts.keepNames,
    sourcemap: opts.sourcemap,
  };
}

interface SharePayload {
  files: { path: string; content: string }[];
  entry: string;
  opts?: Partial<BundleOpts>;
}

interface InitialState {
  files: VfsFile[];
  entry: string;
  opts: BundleOpts;
}

function decodeShareHash(): InitialState | null {
  if (typeof window === "undefined") return null;
  const hash = window.location.hash.slice(1);
  if (!hash) return null;
  try {
    const decoded = decodeURIComponent(escape(atob(hash)));
    const parsed = JSON.parse(decoded) as SharePayload;
    if (!Array.isArray(parsed.files) || parsed.files.length === 0) return null;
    return {
      files: parsed.files.map((f) => ({
        path: f.path,
        content: f.content,
        language: inferLanguage(f.path),
      })),
      entry: parsed.entry || parsed.files[0].path,
      opts: { ...DEFAULT_OPTS, ...parsed.opts },
    };
  } catch {
    return null;
  }
}

export default function PlaygroundBundler() {
  const initial = decodeShareHash();
  const initFiles = initial?.files ?? PRESETS[0].files;
  const initEntry = initial?.entry ?? PRESETS[0].entry;
  const initOpts = initial?.opts ?? DEFAULT_OPTS;
  const [files, setFiles] = useState<VfsFile[]>(initFiles);
  const [activePath, setActivePath] = useState<string>(initEntry);
  const [entryPath, setEntryPath] = useState<string>(initEntry);
  const [opts, setOpts] = useState<BundleOpts>(initOpts);
  const [chunks, setChunks] = useState<OutputChunk[]>([]);
  const [activeChunkPath, setActiveChunkPath] = useState<string>("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [showSidebar, setShowSidebar] = useState(true);
  const wasmRef = useRef<WasmModule | null>(null);
  const vfsRef = useRef<InstanceType<WasmModule["VirtualFileSystem"]> | null>(null);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  function runBundle(nextFiles: VfsFile[], entry: string, nextOpts: BundleOpts) {
    const wasm = wasmRef.current;
    const vfs = vfsRef.current;
    if (!wasm || !vfs) return;

    vfs.clear();
    for (const f of nextFiles) vfs.set(f.path, f.content);

    try {
      const result = wasm.buildChunks(entry, toApiOptions(nextOpts));
      if (result === null || result.length === 0) {
        setChunks([]);
        const detail = wasm.bundlerLastErrorMessage();
        setError(detail || `entry "${entry}" 번들 실패`);
        return;
      }
      setChunks(result);
      // 활성 chunk 가 새 result 에 없으면 첫 chunk 로 reset.
      setActiveChunkPath((prev) => (result.some((c) => c.path === prev) ? prev : result[0].path));
      setError("");
    } catch (err) {
      setChunks([]);
      setError(String(err));
    }
  }

  function scheduleBundle(nextFiles: VfsFile[], entry: string, nextOpts: BundleOpts) {
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(
      () => runBundle(nextFiles, entry, nextOpts),
      BUNDLE_DEBOUNCE_MS,
    );
  }

  useEffect(() => {
    // Init 한 번만 — files/entryPath/opts 변경은 핸들러에서 직접 scheduleBundle 호출.
    (async () => {
      try {
        const mod = await import("../../../packages/wasm/index.ts");
        const wasmUrl = new URL(`${BASE_URL}zts-bundler.wasm`, window.location.origin);
        const vfs = new mod.VirtualFileSystem();
        for (const f of files) vfs.set(f.path, f.content);
        await mod.initBundler(vfs, wasmUrl);
        wasmRef.current = mod;
        vfsRef.current = vfs;
        setLoading(false);
        runBundle(files, entryPath, opts);
      } catch (err) {
        setError(`WASM bundler load failed: ${err}`);
        setLoading(false);
      }
    })();
    return () => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const activeFile = files.find((f) => f.path === activePath) ?? files[0];

  function handleEditorChange(value: string | undefined) {
    const code = value ?? "";
    const next = files.map((f) => (f.path === activePath ? { ...f, content: code } : f));
    setFiles(next);
    scheduleBundle(next, entryPath, opts);
  }

  function handleAddFile() {
    let i = 1;
    while (files.some((f) => f.path === `/file${i}.ts`)) i += 1;
    const path = `/file${i}.ts`;
    const next = [...files, { path, content: "", language: inferLanguage(path) }];
    setFiles(next);
    setActivePath(path);
    runBundle(next, entryPath, opts);
  }

  function handleRenameFile(oldPath: string) {
    if (typeof window === "undefined") return;
    const newPath = window.prompt("새 파일 경로", oldPath)?.trim();
    if (!newPath || newPath === oldPath) return;
    if (files.some((f) => f.path === newPath)) return;
    const next = files.map((f) =>
      f.path === oldPath ? { ...f, path: newPath, language: inferLanguage(newPath) } : f,
    );
    const nextEntry = entryPath === oldPath ? newPath : entryPath;
    setFiles(next);
    setActivePath(newPath);
    if (nextEntry !== entryPath) setEntryPath(nextEntry);
    runBundle(next, nextEntry, opts);
  }

  function handleDeleteFile(path: string) {
    if (files.length <= 1) return;
    const next = files.filter((f) => f.path !== path);
    const nextActive = activePath === path ? next[0].path : activePath;
    const nextEntry = entryPath === path ? next[0].path : entryPath;
    setFiles(next);
    if (nextActive !== activePath) setActivePath(nextActive);
    if (nextEntry !== entryPath) setEntryPath(nextEntry);
    runBundle(next, nextEntry, opts);
  }

  function handleSetEntry(path: string) {
    setEntryPath(path);
    runBundle(files, path, opts);
  }

  function handleShare() {
    // 기본값과 다른 옵션만 포함해 URL 길이 최소화. files 의 language 는 path 에서
    // 추론 가능하니 share payload 에서 제외 (decode 시 inferLanguage).
    const changedOpts: Partial<BundleOpts> = {};
    for (const [k, v] of Object.entries(opts)) {
      if (v !== (DEFAULT_OPTS as Record<string, unknown>)[k]) {
        (changedOpts as Record<string, unknown>)[k] = v;
      }
    }
    const payload: SharePayload = {
      files: files.map((f) => ({ path: f.path, content: f.content })),
      entry: entryPath,
      ...(Object.keys(changedOpts).length > 0 ? { opts: changedOpts } : {}),
    };
    const encoded = btoa(unescape(encodeURIComponent(JSON.stringify(payload))));
    const url = `${window.location.origin}${window.location.pathname}#${encoded}`;
    navigator.clipboard.writeText(url).catch(() => {});
  }

  function handlePreset(label: string) {
    const preset = PRESETS.find((p) => p.label === label);
    if (!preset) return;
    // preset 의 권장 옵션을 현재 opts 위에 merge — 사용자가 토글한 옵션 (target=es5
    // 등) 은 보존, preset 이 명시한 키만 덮어씀. (이전 preset 의 자동-적용된 권장
    // 옵션은 그대로 남는데, 사용자가 직접 토글로 끄면 됨.)
    const nextOpts: BundleOpts = { ...opts, ...preset.opts };
    setFiles(preset.files);
    setActivePath(preset.entry);
    setEntryPath(preset.entry);
    setOpts(nextOpts);
    runBundle(preset.files, preset.entry, nextOpts);
  }

  function updateOpt<K extends keyof BundleOpts>(key: K, value: BundleOpts[K]) {
    setOpts((prev) => {
      const next = { ...prev, [key]: value };
      // minify shorthand 토글 시 개별 minify* 모두 동기화 (transpile playground 와 동일).
      if (key === "minify") {
        const b = value as boolean;
        next.minifyWhitespace = b;
        next.minifyIdentifiers = b;
        next.minifySyntax = b;
      }
      runBundle(files, entryPath, next);
      return next;
    });
  }

  return (
    <div
      className="not-content playground-root flex flex-col overflow-hidden bg-surface-950"
      style={{ height: "calc(100vh - 64px)" }}
    >
      <div className="flex shrink-0 items-center justify-between border-b border-surface-800 bg-surface-900 px-4 py-2">
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={() => setShowSidebar(!showSidebar)}
            className={BTN_CLASS}
            aria-label="Toggle file panel"
          >
            {showSidebar ? "◀" : "▶"}
          </button>
          <a href={`${BASE_URL}playground/`} className="text-sm font-bold text-neutral-200 no-underline">
            ZTS Bundler Playground
          </a>
          {loading && <Badge variant="loading" text="Loading bundler..." />}
          {!loading && !error && <Badge variant="ready" />}
          {!loading && error && <Badge variant="error" />}
        </div>
        <div className="flex items-center gap-2">
          <select
            aria-label="Preset"
            onChange={(e) => {
              if (e.target.value) handlePreset(e.target.value);
              e.target.value = "";
            }}
            defaultValue=""
            className={SELECT_BTN_CLASS}
          >
            <option value="" disabled>
              예제 선택…
            </option>
            {PRESETS.map((p) => (
              <option key={p.label} value={p.label}>
                {p.label}
              </option>
            ))}
          </select>
          <button type="button" onClick={handleShare} className={BTN_CLASS}>
            Share
          </button>
          <a href={`${BASE_URL}playground/`} className={BTN_CLASS}>
            Transpile 모드
          </a>
          <a
            href="https://github.com/ohah/zts"
            target="_blank"
            rel="noreferrer"
            className={BTN_CLASS}
          >
            GitHub
          </a>
        </div>
      </div>

      <div className="flex flex-1 overflow-hidden">
        {showSidebar && (
          <div className="w-56 min-w-[14rem] shrink-0 overflow-y-auto border-r border-surface-800 bg-surface-900 p-2 text-[13px]">
            <div className="mb-2 flex items-center justify-between border-b border-surface-800 pb-1">
              <span className="text-[11px] font-bold uppercase tracking-[0.08em] text-neutral-400">
                Files
              </span>
              <button type="button" onClick={handleAddFile} className={`${BTN_CLASS} px-2`}>
                + Add
              </button>
            </div>
            <ul className="flex flex-col gap-0.5">
              {files.map((f) => {
                const isActive = f.path === activePath;
                const isEntry = f.path === entryPath;
                return (
                  <li key={f.path}>
                    <div
                      className={`flex items-center justify-between rounded px-2 py-1 ${
                        isActive
                          ? "bg-surface-800 text-neutral-100"
                          : "text-neutral-300 hover:bg-surface-800/50"
                      }`}
                    >
                      <button
                        type="button"
                        onClick={() => setActivePath(f.path)}
                        className="flex-1 cursor-pointer truncate bg-transparent text-left"
                        title={f.path}
                      >
                        {isEntry && <span className="mr-1 text-zig-400">●</span>}
                        {f.path}
                      </button>
                      <div className="ml-2 flex shrink-0 items-center gap-1 opacity-60 hover:opacity-100">
                        {!isEntry && (
                          <button
                            type="button"
                            onClick={() => handleSetEntry(f.path)}
                            className="cursor-pointer bg-transparent text-[11px] text-neutral-400 hover:text-zig-400"
                            title="Set as entry"
                          >
                            entry
                          </button>
                        )}
                        <button
                          type="button"
                          onClick={() => handleRenameFile(f.path)}
                          className="cursor-pointer bg-transparent text-[11px] text-neutral-400 hover:text-neutral-200"
                          title="Rename"
                        >
                          ✎
                        </button>
                        {files.length > 1 && (
                          <button
                            type="button"
                            onClick={() => handleDeleteFile(f.path)}
                            className="cursor-pointer bg-transparent text-[11px] text-neutral-400 hover:text-red-400"
                            title="Delete"
                          >
                            ✕
                          </button>
                        )}
                      </div>
                    </div>
                  </li>
                );
              })}
            </ul>
            <div className="mt-3 border-t border-surface-800 pt-2 text-[11px] text-neutral-500">
              <p>
                <span className="text-zig-400">●</span> = entry point
              </p>
            </div>

            <div className="mt-4">
              <Section title="Bundler">
                <Sel
                  label="Format"
                  value={opts.format}
                  onChange={(v) => updateOpt("format", v as BundleOpts["format"])}
                  options={[
                    ["esm", "ESM"],
                    ["cjs", "CJS"],
                    ["iife", "IIFE"],
                    ["umd", "UMD"],
                    ["amd", "AMD"],
                  ]}
                />
                <Sel
                  label="Platform"
                  value={opts.platform}
                  onChange={(v) => updateOpt("platform", v as BundleOpts["platform"])}
                  options={[
                    ["browser", "Browser"],
                    ["node", "Node"],
                    ["neutral", "Neutral"],
                    ["react-native", "React Native"],
                  ]}
                />
              </Section>
              <Section title="Output">
                <Chk
                  label="Minify (all)"
                  checked={opts.minify}
                  onChange={(v) => updateOpt("minify", v)}
                />
                <Chk
                  label="Whitespace"
                  checked={opts.minifyWhitespace}
                  onChange={(v) => updateOpt("minifyWhitespace", v)}
                />
                <Chk
                  label="Identifiers"
                  checked={opts.minifyIdentifiers}
                  onChange={(v) => updateOpt("minifyIdentifiers", v)}
                />
                <Chk
                  label="Syntax"
                  checked={opts.minifySyntax}
                  onChange={(v) => updateOpt("minifySyntax", v)}
                />
              </Section>
              <Section title="Splitting">
                <Chk
                  label="Code splitting"
                  checked={opts.codeSplitting}
                  onChange={(v) => updateOpt("codeSplitting", v)}
                />
                <Chk
                  label="Preserve modules"
                  checked={opts.preserveModules}
                  onChange={(v) => updateOpt("preserveModules", v)}
                />
              </Section>
              <Section title="External">
                <textarea
                  value={opts.externalText}
                  onChange={(e) => updateOpt("externalText", e.target.value)}
                  placeholder={"한 줄에 하나\nreact\nreact-dom/*"}
                  rows={3}
                  spellCheck={false}
                  className="w-full resize-y rounded border border-surface-800 bg-surface-950 px-1.5 py-1 text-[12px] text-neutral-200 placeholder:text-neutral-600"
                />
              </Section>
              <Section title="Parser">
                <Chk label="Flow" checked={opts.flow} onChange={(v) => updateOpt("flow", v)} />
                <Chk
                  label="JSX in .js"
                  checked={opts.jsxInJs}
                  onChange={(v) => updateOpt("jsxInJs", v)}
                />
                <Chk
                  label="Experimental Decorators"
                  checked={opts.experimentalDecorators}
                  onChange={(v) => updateOpt("experimentalDecorators", v)}
                />
                <Chk
                  label="Emit Decorator Metadata"
                  checked={opts.emitDecoratorMetadata}
                  onChange={(v) => updateOpt("emitDecoratorMetadata", v)}
                />
              </Section>
              <Section title="Target">
                <Sel
                  label="Target"
                  value={opts.target}
                  onChange={(v) => updateOpt("target", v as BundleOpts["target"])}
                  options={[
                    ["esnext", "ESNext"],
                    ["es2025", "ES2025"],
                    ["es2024", "ES2024"],
                    ["es2022", "ES2022"],
                    ["es2021", "ES2021"],
                    ["es2020", "ES2020"],
                    ["es2019", "ES2019"],
                    ["es2018", "ES2018"],
                    ["es2017", "ES2017"],
                    ["es2016", "ES2016"],
                    ["es2015", "ES2015"],
                    ["es5", "ES5"],
                  ]}
                />
              </Section>
              <Section title="JSX">
                <Sel
                  label="JSX"
                  value={opts.jsx}
                  onChange={(v) => updateOpt("jsx", v as BundleOpts["jsx"])}
                  options={[
                    ["classic", "Classic"],
                    ["automatic", "Automatic"],
                    ["automatic-dev", "Automatic (Dev)"],
                  ]}
                />
                <Txt
                  label="JSX Factory"
                  value={opts.jsxFactory}
                  placeholder="React.createElement"
                  onChange={(v) => updateOpt("jsxFactory", v)}
                />
                <Txt
                  label="JSX Fragment"
                  value={opts.jsxFragment}
                  placeholder="React.Fragment"
                  onChange={(v) => updateOpt("jsxFragment", v)}
                />
                <Txt
                  label="JSX Import Source"
                  value={opts.jsxImportSource}
                  placeholder="react"
                  onChange={(v) => updateOpt("jsxImportSource", v)}
                />
              </Section>
              <Section title="Transform">
                <Chk
                  label="useDefineForClassFields"
                  checked={opts.useDefineForClassFields}
                  onChange={(v) => updateOpt("useDefineForClassFields", v)}
                />
                <Chk
                  label="Charset UTF-8"
                  checked={opts.charsetUtf8}
                  onChange={(v) => updateOpt("charsetUtf8", v)}
                />
                <Chk
                  label="Keep Names (.name 보존)"
                  checked={opts.keepNames}
                  onChange={(v) => updateOpt("keepNames", v)}
                />
              </Section>
              <Section title="Sourcemap">
                <Chk
                  label="Generate"
                  checked={opts.sourcemap}
                  onChange={(v) => updateOpt("sourcemap", v)}
                />
              </Section>
            </div>
          </div>
        )}

        <div className="flex flex-1 overflow-hidden">
          <EditorPanel
            header={
              <span>
                Input <span className="text-[11px] opacity-50">{activeFile.path}</span>
              </span>
            }
          >
            <Editor
              height="100%"
              path={activeFile.path}
              language={activeFile.language}
              theme="vs-dark"
              value={activeFile.content}
              onChange={handleEditorChange}
              options={editorOpts}
            />
          </EditorPanel>
          <div className="w-[2px] shrink-0 bg-surface-800" />
          <EditorPanel
            header={
              <div className="flex w-full items-center justify-between gap-2">
                {chunks.length > 1 ? (
                  <div className="flex flex-1 items-center gap-1 overflow-x-auto">
                    {chunks.map((c) => {
                      const active = c.path === activeChunkPath;
                      return (
                        <button
                          type="button"
                          key={c.path}
                          onClick={() => setActiveChunkPath(c.path)}
                          className={`shrink-0 cursor-pointer rounded-t border-b-2 bg-transparent px-2 py-0.5 text-[12px] transition-colors ${
                            active
                              ? "border-zig-500 text-neutral-200 font-semibold"
                              : "border-transparent text-neutral-500 hover:text-neutral-300"
                          }`}
                          title={c.path}
                        >
                          {c.path}
                        </button>
                      );
                    })}
                  </div>
                ) : (
                  <span>
                    Output{" "}
                    {chunks.length === 1 && (
                      <span className="text-[11px] opacity-50">{chunks[0].path}</span>
                    )}
                  </span>
                )}
                {error && <span className="text-[11px] text-red-400">Error</span>}
              </div>
            }
          >
            <Editor
              height="100%"
              language={error ? "plaintext" : "javascript"}
              theme="vs-dark"
              value={error || (chunks.find((c) => c.path === activeChunkPath)?.code ?? chunks[0]?.code ?? "")}
              options={{ ...editorOpts, readOnly: true }}
            />
          </EditorPanel>
        </div>
      </div>
    </div>
  );
}
