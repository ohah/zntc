import { useEffect, useId, useRef, useState } from "react";
import type { Mermaid as MermaidApi } from "mermaid";

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
  mermaidPromise = import("mermaid").then(({ default: mermaid }) => {
    mermaid.initialize({
      startOnLoad: false,
      theme: "default",
      securityLevel: "loose",
      fontFamily: "var(--sl-font, sans-serif)",
    });
    return mermaid;
  });
  return mermaidPromise;
}

/** Client-side Mermaid renderer with lazy library load. `client:visible` 권장. */
export default function Mermaid({ chart }: Props) {
  const ref = useRef<HTMLDivElement>(null);
  const [error, setError] = useState<string | null>(null);
  const reactId = useId();
  const renderId = `mermaid-${reactId.replace(/:/g, "")}`;

  useEffect(() => {
    let cancelled = false;
    loadMermaid()
      .then((mermaid) => mermaid.render(renderId, chart))
      .then(({ svg }) => {
        if (!cancelled && ref.current) ref.current.innerHTML = svg;
      })
      .catch((err) => {
        if (!cancelled) setError(String(err?.message ?? err));
      });
    return () => {
      cancelled = true;
    };
  }, [chart, renderId]);

  if (error) {
    return (
      <pre style={{ color: "var(--sl-color-red, #dc2626)" }}>
        Mermaid render error: {error}
      </pre>
    );
  }
  return <div ref={ref} className="mermaid-diagram" />;
}
