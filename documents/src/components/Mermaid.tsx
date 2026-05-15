import { useEffect, useId, useRef, useState } from "react";
import type { Mermaid as MermaidApi, MermaidConfig } from "mermaid";

import { useStarlightDark } from "./useStarlightDark";

interface Props {
  /** mermaid diagram source (raw text — `flowchart TD`, `sequenceDiagram`, etc.) */
  chart: string;
}

// chart source 는 docs MDX 의 빌드타임 author content — user input 아님 (XSS 무관).
// 향후 user-provided chart 를 받게 되면 securityLevel 을 "strict" 로 낮출 것.
//
// **번들 최적화**: `mermaid` (~3MB gzip) 를 dynamic import 로 분리. `client:visible` 와
// 결합 시 viewport 진입 시점에 비로소 mermaid chunk fetch — napi 페이지 방문자도
// 다이어그램이 화면에 들어오기 전엔 라이브러리 다운로드 안 함.
let mermaidPromise: Promise<MermaidApi> | null = null;
function loadMermaid(): Promise<MermaidApi> {
  if (mermaidPromise) return mermaidPromise;
  mermaidPromise = import("mermaid").then(({ default: mermaid }) => mermaid);
  return mermaidPromise;
}

const COMMON_CONFIG: MermaidConfig = {
  startOnLoad: false,
  theme: "base",
  securityLevel: "loose",
  fontFamily: "var(--sl-font, sans-serif)",
  flowchart: {
    htmlLabels: true,
    curve: "basis",
    nodeSpacing: 44,
    rankSpacing: 58,
    padding: 28,
    useMaxWidth: true,
  },
};

// ZNTC 브랜드 오렌지 (#f7a41d) 는 양쪽 공통, 면/텍스트만 light↔dark 로 토글.
// [light, dark] 페어로 묶어 한쪽 키만 추가하는 실수를 방지.
const THEME_PAIRS = {
  primaryColor: ["#fff7ed", "#1c1816"],
  primaryBorderColor: ["#f7a41d", "#f7a41d"],
  primaryTextColor: ["#431407", "#fed7aa"],
  secondaryColor: ["#ffedd5", "#2a2422"],
  secondaryBorderColor: ["#fb923c", "#fb923c"],
  tertiaryColor: ["#fafaf9", "#141110"],
  tertiaryBorderColor: ["#d6d3d1", "#3a3432"],
  clusterBkg: ["#fafaf9", "#1c1816"],
  clusterBorder: ["#d6d3d1", "#3a3432"],
  titleColor: ["#1c1816", "#f5f5f4"],
  edgeLabelBackground: ["#ffffff", "#141110"],
  lineColor: ["#9a3412", "#f7a41d"],
  fontSize: ["15px", "15px"],
} as const;

function themeVarsFor(isDark: boolean) {
  const idx = isDark ? 1 : 0;
  const out: Record<string, string> = {};
  for (const [key, pair] of Object.entries(THEME_PAIRS)) out[key] = pair[idx];
  return out;
}

// mermaid config 는 module-global. 같은 isDark 로 이미 init 됐으면 다이어그램 N 개의
// 동시 mount 에서 N-1 번의 redundant initialize 를 skip — 결과는 동일하지만 work 절약.
let lastInitDark: boolean | null = null;
function ensureMermaidTheme(mermaid: MermaidApi, isDark: boolean): void {
  if (lastInitDark === isDark) return;
  mermaid.initialize({ ...COMMON_CONFIG, themeVariables: themeVarsFor(isDark) });
  lastInitDark = isDark;
}

/** Client-side Mermaid renderer with lazy library load. `client:visible` 권장. */
export default function Mermaid({ chart }: Props) {
  const ref = useRef<HTMLDivElement>(null);
  const [error, setError] = useState<string | null>(null);
  const reactId = useId();
  const renderId = `mermaid-${reactId.replace(/:/g, "")}`;
  const isDark = useStarlightDark();

  useEffect(() => {
    let cancelled = false;
    loadMermaid()
      .then((mermaid) => {
        ensureMermaidTheme(mermaid, isDark);
        return mermaid.render(renderId, chart);
      })
      .then(({ svg }) => {
        if (!cancelled && ref.current) ref.current.innerHTML = svg;
      })
      .catch((err) => {
        if (!cancelled) setError(String(err?.message ?? err));
      });
    return () => {
      cancelled = true;
    };
  }, [chart, renderId, isDark]);

  if (error) {
    return (
      <pre style={{ color: "var(--sl-color-red, #dc2626)" }}>
        Mermaid render error: {error}
      </pre>
    );
  }
  return <div ref={ref} className="mermaid-diagram" />;
}
