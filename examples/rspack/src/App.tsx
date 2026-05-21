import { useState } from "react";

export function App() {
  const [count, setCount] = useState(0);
  const [filter, setFilter] = useState("");

  const items = Array.from({ length: 20 }, (_, i) => i + count);
  const filtered = items.filter((n) => String(n).includes(filter));

  return (
    <div style={{ fontFamily: "system-ui, sans-serif", padding: 24, maxWidth: 720, margin: "0 auto" }}>
      <h1>ZNTC + Rspack (React 19)</h1>
      <p>@zntc/rspack-loader 가 rspack 의 .tsx loader 로 TS/JSX 변환 · rspack 이 번들·HMR·dev server.</p>

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
        <ul>
          {filtered.map((n) => (
            <li key={n}>{n}</li>
          ))}
        </ul>
      </section>
    </div>
  );
}
