import { useState } from "react";

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
      <h1>ZNTC + React Compiler (standalone)</h1>
      <p>
        React 19 · <code>zntc.config.ts</code> 의 onTransform 어댑터가 babel-plugin-react-compiler
        를 적용 · 나머지 변환은 ZNTC 단일 파이프라인.
      </p>

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
