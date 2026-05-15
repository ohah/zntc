import { useEffect, useState } from "react";

/**
 * Starlight 의 `data-theme="dark"` 마커를 구독.
 * 진실의 소스는 `<html data-theme>` (Starlight 의 ThemeSelect 가 writer) —
 * Starlight 가 React hook surface 를 제공하지 않아 직접 dataset 을 읽고 MutationObserver 로 토글 구독.
 */
export function useStarlightDark(): boolean {
  // SSR 가드: useState initializer 는 SSR 패스에서도 실행. client:only 컴포넌트는 영향 없지만,
  // hook 이 client:visible / client:idle 같은 hydration 모드에서 import 되면 Node 에 document 없음.
  const [isDark, setIsDark] = useState(() =>
    typeof document !== "undefined" && document.documentElement.dataset.theme === "dark",
  );

  useEffect(() => {
    const observer = new MutationObserver(() => {
      setIsDark(document.documentElement.dataset.theme === "dark");
    });
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"],
    });
    return () => observer.disconnect();
  }, []);

  return isDark;
}
