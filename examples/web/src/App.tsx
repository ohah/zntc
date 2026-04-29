import { StyledShowcase } from "./styled-cases";
import { EmotionShowcase } from "./emotion-cases";

export function App() {
  return (
    <div style={{ fontFamily: "system-ui, sans-serif", padding: 24, maxWidth: 960, margin: "0 auto" }}>
      <header style={{ marginBottom: 32 }}>
        <h1>ZTS Web Example</h1>
        <p>
          styled-components / emotion 패턴을 모은 데모. 향후 <code>compiler.styledComponents</code>{" "}
          / <code>compiler.emotion</code> 1st-party transform 의 회귀 검증 대상.
        </p>
      </header>

      <section>
        <h2>styled-components</h2>
        <StyledShowcase />
      </section>

      <section style={{ marginTop: 48 }}>
        <h2>emotion</h2>
        <EmotionShowcase />
      </section>
    </div>
  );
}
