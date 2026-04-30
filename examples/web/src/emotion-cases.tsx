/**
 * emotion 패턴 모음 — 현재 지원되는 1st-party transform:
 * - autoLabel: `const X = css\`...\`` → `css\`label:X;...\``
 * - autoLabel: `const X = styled.div\`...\`` → `styled.div\`label:X;...\``
 * - autoLabel: `const X = keyframes\`...\`` → `keyframes\`label:X;...\``
 *
 * 미지원 (후속 PR):
 * - sourceMap 라벨링 / cssPropOptimization (`<div css={...}>` hoist)
 * - chain `css.x\`\`` / `styled.div.attrs({})\`\``
 */

/** @jsxImportSource @emotion/react */

import { useState } from "react";
import { css, keyframes, Global } from "@emotion/react";
import styled from "@emotion/styled";

// 1. css prop — emotion 의 시그니처 패턴. transform 으로 hoist 대상.
// styled-cases.tsx 의 Card 와 시각적으로 일치하게 유지 (두 라이브러리 authoring 비교가 목적).
const cardCss = css`
  border: 1px solid #ddd;
  border-radius: 8px;
  padding: 16px;
  margin: 8px 0;
  background: #fafafa;
`;

// 2. styled (emotion 도 동일 API)
type Tone = "info" | "warn" | "danger";
const TONE_BG: Record<Tone, string> = { info: "#dbeafe", warn: "#fef3c7", danger: "#fee2e2" };
const TONE_FG: Record<Tone, string> = { info: "#1e40af", warn: "#92400e", danger: "#991b1b" };

const Pill = styled.span<{ tone: Tone }>`
  display: inline-block;
  padding: 2px 8px;
  border-radius: 999px;
  font-size: 12px;
  background: ${({ tone }) => TONE_BG[tone]};
  color: ${({ tone }) => TONE_FG[tone]};
`;

// 3. dynamic css 함수 — autoLabel 의 검증 대상 (변수명 = label)
const focusableInput = (active: boolean) => css`
  border: 2px solid ${active ? "#3b82f6" : "#cbd5e1"};
  border-radius: 4px;
  padding: 6px 10px;
  outline: none;
  transition: border-color 0.15s;
`;

// 4. keyframes — emotion autoLabel 이 animation name 을 label 로 부여.
const fadeIn = keyframes`
  from { opacity: 0; transform: translateY(4px); }
  to { opacity: 1; transform: translateY(0); }
`;

const FadeBox = styled.div`
  animation: ${fadeIn} 0.3s ease-out;
  padding: 12px;
  border-radius: 4px;
  background: #f0f9ff;
`;

// 5. Global styles
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

      <FadeBox>
        <h3>4. keyframes + animation</h3>
        <p>이 박스 자체가 fadeIn 애니메이션. emotion autoLabel 이 keyframe 이름에도 label 부여.</p>
      </FadeBox>
    </>
  );
}
