// zts sourcemap 후처리 — DevTools 의 x_google_ignoreList 확장. zts 가 emit
// 한 폴리필 항목을 보존 + node_modules 항목 추가. 잘못된 JSON 이면 rawJson
// 반환 (caller 가 빈 응답 회피).

export function postProcessSourceMap(rawJson: string): string {
  try {
    const map = JSON.parse(rawJson);
    if (map.version !== 3 || !map.sources) return rawJson;

    const existing = new Set<number>(
      Array.isArray(map.x_google_ignoreList) ? map.x_google_ignoreList : [],
    );
    for (let i = 0; i < map.sources.length; i++) {
      if (typeof map.sources[i] === "string" && map.sources[i].includes("/node_modules/")) {
        existing.add(i);
      }
    }
    if (existing.size > 0) {
      map.x_google_ignoreList = [...existing].sort((a, b) => a - b);
    }
    return JSON.stringify(map);
  } catch {
    return rawJson;
  }
}
