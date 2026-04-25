/**
 * PlaygroundBundler — `/playground/bundler` 라우트 메인 컴포넌트.
 *
 * transpile playground 와 분리: 별도 wasm binary (`zts-bundler.wasm`) lazy 로드,
 * 멀티파일 입력 (좌측 사이드바 + Monaco model swap), 단일 output editor.
 *
 * `bundler.build(entry)` 호출은 esm/browser 고정 — 옵션 패널은 ABI 가 옵션 JSON
 * 받도록 확장된 후 활성화.
 */
import { useEffect, useRef, useState } from "react";
import Editor from "@monaco-editor/react";
import {
  BTN_CLASS,
  Badge,
  EditorPanel,
  SELECT_BTN_CLASS,
  editorOpts,
  inferLanguage,
} from "./playground-shared";

interface VfsFile {
  path: string;
  content: string;
  language: "typescript" | "javascript";
}

const PRESETS: { label: string; entry: string; files: VfsFile[] }[] = [
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
];

type WasmModule = typeof import("../../../packages/wasm/index.ts");

// 매 키스트로크 = 번들 호출. 큰 파일에서 input lag 방지 (transpile 보다 비싸).
const BUNDLE_DEBOUNCE_MS = 200;

const BASE_URL = (import.meta.env.BASE_URL ?? "/").replace(/\/?$/, "/");

export default function PlaygroundBundler() {
  const [files, setFiles] = useState<VfsFile[]>(PRESETS[0].files);
  const [activePath, setActivePath] = useState<string>(PRESETS[0].entry);
  const [entryPath, setEntryPath] = useState<string>(PRESETS[0].entry);
  const [output, setOutput] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [showSidebar, setShowSidebar] = useState(true);
  const wasmRef = useRef<WasmModule | null>(null);
  const vfsRef = useRef<InstanceType<WasmModule["VirtualFileSystem"]> | null>(null);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  function runBundle(nextFiles: VfsFile[], entry: string) {
    const wasm = wasmRef.current;
    const vfs = vfsRef.current;
    if (!wasm || !vfs) return;

    vfs.clear();
    for (const f of nextFiles) vfs.set(f.path, f.content);

    try {
      const result = wasm.build(entry);
      if (result === null) {
        setOutput("");
        setError(`Bundle failed — entry "${entry}" 가 빈 출력을 반환했거나 해석 실패`);
        return;
      }
      setOutput(result.code);
      setError("");
    } catch (err) {
      setOutput("");
      setError(String(err));
    }
  }

  function scheduleBundle(nextFiles: VfsFile[], entry: string) {
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => runBundle(nextFiles, entry), BUNDLE_DEBOUNCE_MS);
  }

  useEffect(() => {
    // Init 한 번만 — files/entryPath 변경은 핸들러에서 직접 scheduleBundle 호출.
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
        runBundle(files, entryPath);
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
    scheduleBundle(next, entryPath);
  }

  function handleAddFile() {
    let i = 1;
    while (files.some((f) => f.path === `/file${i}.ts`)) i += 1;
    const path = `/file${i}.ts`;
    const next = [...files, { path, content: "", language: inferLanguage(path) }];
    setFiles(next);
    setActivePath(path);
    runBundle(next, entryPath);
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
    runBundle(next, nextEntry);
  }

  function handleDeleteFile(path: string) {
    if (files.length <= 1) return;
    const next = files.filter((f) => f.path !== path);
    const nextActive = activePath === path ? next[0].path : activePath;
    const nextEntry = entryPath === path ? next[0].path : entryPath;
    setFiles(next);
    if (nextActive !== activePath) setActivePath(nextActive);
    if (nextEntry !== entryPath) setEntryPath(nextEntry);
    runBundle(next, nextEntry);
  }

  function handleSetEntry(path: string) {
    setEntryPath(path);
    runBundle(files, path);
  }

  function handlePreset(label: string) {
    const preset = PRESETS.find((p) => p.label === label);
    if (!preset) return;
    setFiles(preset.files);
    setActivePath(preset.entry);
    setEntryPath(preset.entry);
    runBundle(preset.files, preset.entry);
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
              <p className="mb-1">
                <span className="text-zig-400">●</span> = entry point
              </p>
              <p>esm / browser 고정 (Phase 2)</p>
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
              <div className="flex w-full items-center justify-between">
                <span>Bundle Output</span>
                {error && <span className="text-[11px] text-red-400">Error</span>}
              </div>
            }
          >
            <Editor
              height="100%"
              language={error ? "plaintext" : "javascript"}
              theme="vs-dark"
              value={error || output}
              options={{ ...editorOpts, readOnly: true }}
            />
          </EditorPanel>
        </div>
      </div>
    </div>
  );
}
