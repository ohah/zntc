/**
 * emotion 패턴 모음.
 *
 * 향후 1st-party transform 이 처리해야 하는 케이스:
 * - autoLabel — 변수명 → CSS class label 자동 부여 (devtools 가독성)
 * - sourceMap — CSS-in-JS 위치를 원본 .tsx 로 역추적
 * - cssPropOptimization — `css={...}` prop 정적 hoist
 * - hash 안정화 — SSR hydration mismatch 방지
 *
 * 현재는 transform 없이 emotion 런타임만으로 동작.
 */

/** @jsxImportSource @emotion/react */

import { useState } from "react";
import { css, Global } from "@emotion/react";
import styled from "@emotion/styled";

// 1. css prop — emotion 의 시그니처 패턴. transform 으로 hoist 대상.
const cardCss = css`
  border: 1px solid #ddd;
  border-radius: 8px;
  padding: 16px;
  margin: 8px 0;
  background: #fafafa;
`;

// 2. styled (emotion 도 동일 API)
const Pill = styled.span<{ tone: "info" | "warn" | "danger" }>`
  display: inline-block;
  padding: 2px 8px;
  border-radius: 999px;
  font-size: 12px;
  background: ${({ tone }) =>
    tone === "info" ? "#dbeafe" : tone === "warn" ? "#fef3c7" : "#fee2e2"};
  color: ${({ tone }) => (tone === "info" ? "#1e40af" : tone === "warn" ? "#92400e" : "#991b1b")};
`;

// 3. dynamic css 함수 — autoLabel 의 검증 대상 (변수명 = label)
const focusableInput = (active: boolean) => css`
  border: 2px solid ${active ? "#3b82f6" : "#cbd5e1"};
  border-radius: 4px;
  padding: 6px 10px;
  outline: none;
  transition: border-color 0.15s;
`;

// 4. Global styles
const globalStyles = css`
  body {
    margin: 0;
    background: #ffffff;
    color: #111;
  }
`;

export function EmotionShowcase() {
  const [active, setActive] = useState(false);
  const [text, setText] = useState("");

  return (
    <>
      <Global styles={globalStyles} />

      <div css={cardCss}>
        <h3>1. css prop</h3>
        <p>이 카드 div 가 css={`{cardCss}`} 로 스타일됨. transform 이 들어가면 정적 hoist 대상.</p>
      </div>

      <div css={cardCss}>
        <h3>2. styled (emotion)</h3>
        <Pill tone="info">info</Pill> <Pill tone="warn">warn</Pill>{" "}
        <Pill tone="danger">danger</Pill>
      </div>

      <div css={cardCss}>
        <h3>3. 동적 css 함수 (autoLabel 검증)</h3>
        <input
          css={focusableInput(active)}
          placeholder="focus 해보세요"
          value={text}
          onChange={(e) => setText(e.target.value)}
          onFocus={() => setActive(true)}
          onBlur={() => setActive(false)}
        />
      </div>
    </>
  );
}
