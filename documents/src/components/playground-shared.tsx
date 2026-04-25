/**
 * Playground 컴포넌트 공유 헬퍼 — transpile + bundler 두 페이지에서 사용.
 */
import type { ReactNode } from "react";

export const BTN_BASE =
  "cursor-pointer rounded border border-surface-800 bg-transparent text-[13px] text-neutral-200 no-underline transition-colors hover:border-zig-500 hover:text-zig-400";
export const BTN_CLASS = `${BTN_BASE} px-3 py-1`;
export const SELECT_BTN_CLASS = `${BTN_BASE} px-2 py-1`;

export const editorOpts = {
  minimap: { enabled: false },
  fontSize: 13,
  fontFamily: "'Menlo', 'Monaco', 'Courier New', monospace",
  fontLigatures: false,
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

export type BadgeVariant = "loading" | "ready" | "error";

const BADGE_TONES: Record<BadgeVariant, { tone: string; defaultText: string }> = {
  loading: { tone: "bg-sky-950 text-sky-300", defaultText: "Loading..." },
  ready: { tone: "bg-emerald-950 text-emerald-300", defaultText: "Ready" },
  error: { tone: "bg-red-950 text-red-300", defaultText: "Error" },
};

export function Badge({ variant, text }: { variant: BadgeVariant; text?: string }) {
  const { tone, defaultText } = BADGE_TONES[variant];
  return (
    <span className={`rounded-full px-2 py-0.5 text-[10px] font-semibold ${tone}`}>
      {text ?? defaultText}
    </span>
  );
}

export function EditorPanel({ header, children }: { header: ReactNode; children: ReactNode }) {
  return (
    <div className="flex min-w-0 flex-1 flex-col overflow-hidden">
      <div className="flex shrink-0 items-center border-b border-surface-800 bg-surface-900 px-3 py-1.5 text-[12px] font-semibold text-neutral-400">
        {header}
      </div>
      <div className="flex-1">{children}</div>
    </div>
  );
}

/// 파일 확장자로 Monaco language ID 추론.
export function inferLanguage(path: string): "typescript" | "javascript" {
  return /\.(ts|tsx|mts|cts)$/.test(path) ? "typescript" : "javascript";
}
