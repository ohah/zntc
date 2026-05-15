import { useState } from "react";

// react-compiler 가 자동 메모이제이션 대상으로 판단할 만한 패턴:
// props 의존성을 갖는 파생 값 (`filtered`) 이 매 렌더마다 새로 계산되고 자식이
// 받는 구조. 컴파일러가 같은 deps 일 때 같은 reference 를 유지하도록 자동 캐시
// 호출을 삽입 — useMemo 를 직접 쓸 필요가 없다.
function ItemList({ items, filter }: { items: number[]; filter: string }) {
  const filtered = items.filter((n) => String(n).includes(filter));
  return (
    <ul>
      {filtered.map((n) => (
        <li key={n}>{n}</li>
      ))}
    </ul>
  );
}

export function App() {
  const [count, setCount] = useState(0);
  const [filter, setFilter] = useState("");

  // 매 렌더마다 새 배열. 컴파일러가 count 의존성을 추론해 동일 count 일 때
  // 같은 reference 를 유지하도록 자동 캐시.
  const items = Array.from({ length: 20 }, (_, i) => i + count);

  return (
    <div style={{ fontFamily: "system-ui, sans-serif", padding: 24, maxWidth: 720, margin: "0 auto" }}>
      <h1>ZNTC + Vite + React Compiler</h1>
      <p>React 19 · babel-plugin-react-compiler 가 Vite 의 babel 단계에서 동작 · 나머지 변환은 ZNTC.</p>

      <section>
        <label>
          counter: <strong>{count}</strong>{" "}
          <button onClick={() => setCount((c) => c + 1)}>+1</button>
        </label>
      </section>

      <section style={{ marginTop: 24 }}>
        <label>
          filter:{" "}
          <input value={filter} onChange={(e) => setFilter(e.target.value)} placeholder="e.g. 1" />
        </label>
        <ItemList items={items} filter={filter} />
      </section>
    </div>
  );
}
