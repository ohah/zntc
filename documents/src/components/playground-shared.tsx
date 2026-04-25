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

// ─── 옵션 패널 폼 헬퍼 (Section / Chk / Sel / Txt) ───

export function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="mb-3">
      <div className="mb-1.5 border-b border-surface-800 pb-1 text-[11px] font-bold uppercase tracking-[0.08em] text-neutral-400">
        {title}
      </div>
      <div className="flex flex-col gap-1.5">{children}</div>
    </div>
  );
}

export function Chk({
  label,
  checked,
  onChange,
}: {
  label: string;
  checked: boolean;
  onChange: (v: boolean) => void;
}) {
  return (
    <label className="flex cursor-pointer items-center gap-1.5 text-[13px] text-neutral-300">
      <input type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} />
      {label}
    </label>
  );
}

const FIELD_CLASS =
  "max-w-[130px] rounded border border-surface-800 bg-surface-950 px-1 py-0.5 text-[12px] text-neutral-200";

export function Sel({
  label,
  value,
  onChange,
  options,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  options: [string, string][];
}) {
  return (
    <div className="flex items-center justify-between text-[13px] text-neutral-300">
      <span>{label}</span>
      <select value={value} onChange={(e) => onChange(e.target.value)} className={FIELD_CLASS}>
        {options.map(([v, t]) => (
          <option key={v} value={v}>
            {t}
          </option>
        ))}
      </select>
    </div>
  );
}

export function Txt({
  label,
  value,
  placeholder,
  onChange,
}: {
  label: string;
  value: string;
  placeholder?: string;
  onChange: (v: string) => void;
}) {
  return (
    <div className="flex items-center justify-between text-[13px] text-neutral-300">
      <span>{label}</span>
      <input
        type="text"
        value={value}
        placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)}
        className={`${FIELD_CLASS} w-[130px]`}
      />
    </div>
  );
}
