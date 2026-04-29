/**
 * styled-components 패턴 모음.
 *
 * 향후 1st-party transform 이 처리해야 하는 케이스:
 * - displayName 자동 부여 (devtools)
 * - componentId 결정론적 hash (SSR hydration)
 * - 정적 CSS 템플릿 hoist
 * - css minify / transpile
 *
 * 현재는 transform 없이 styled-components 런타임만으로 동작.
 */

import { useState } from "react";
import styled, { css, keyframes, createGlobalStyle } from "styled-components";

// 1. 기본 styled tag
const Card = styled.div`
  border: 1px solid #ddd;
  border-radius: 8px;
  padding: 16px;
  margin: 8px 0;
  background: #fafafa;
`;

// 2. Props interpolation (조건부 스타일)
const Button = styled.button<{ $primary?: boolean }>`
  background: ${({ $primary }) => ($primary ? "#3b82f6" : "#e5e7eb")};
  color: ${({ $primary }) => ($primary ? "white" : "#111")};
  border: none;
  border-radius: 6px;
  padding: 8px 16px;
  cursor: pointer;
  font-weight: 500;

  &:hover {
    opacity: 0.85;
  }
`;

// 3. styled(Component) — 다른 컴포넌트 확장
const DangerButton = styled(Button)`
  background: #ef4444;
  color: white;
`;

// 4. .attrs() — default props 주입
const Input = styled.input.attrs({ type: "text" })`
  border: 1px solid #ccc;
  border-radius: 4px;
  padding: 6px 10px;
  font-size: 14px;
`;

// 5. keyframes
const spin = keyframes`
  from { transform: rotate(0deg); }
  to { transform: rotate(360deg); }
`;

const Spinner = styled.div`
  width: 24px;
  height: 24px;
  border: 3px solid #e5e7eb;
  border-top-color: #3b82f6;
  border-radius: 50%;
  animation: ${spin} 0.8s linear infinite;
`;

// 6. css helper — 재사용 가능한 부분 스타일
const elevated = css`
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.1);
  transform: translateY(-1px);
`;

const FancyCard = styled(Card)`
  ${elevated};
  background: white;
`;

// 7. createGlobalStyle (트랜스폼 영향 받는 또다른 헬퍼)
const GlobalReset = createGlobalStyle`
  *, *::before, *::after { box-sizing: border-box; }
`;

export function StyledShowcase() {
  const [count, setCount] = useState(0);

  return (
    <>
      <GlobalReset />

      <Card>
        <h3>1. 기본 styled tag</h3>
        <p>이 카드 자체가 styled.div 입니다.</p>
      </Card>

      <Card>
        <h3>2. Props interpolation</h3>
        <Button onClick={() => setCount(count + 1)}>일반 ({count})</Button>{" "}
        <Button $primary onClick={() => setCount(count + 1)}>
          Primary ({count})
        </Button>
      </Card>

      <Card>
        <h3>3. styled(Component) 확장</h3>
        <DangerButton onClick={() => setCount(0)}>Reset</DangerButton>
      </Card>

      <Card>
        <h3>4. .attrs() default props</h3>
        <Input placeholder="type: text 자동 부여됨" />
      </Card>

      <Card>
        <h3>5. keyframes 애니메이션</h3>
        <Spinner />
      </Card>

      <FancyCard>
        <h3>6. css helper + 7. createGlobalStyle</h3>
        <p>elevated css 가 재사용되어 그림자 + 살짝 들림. GlobalReset 도 같이 적용.</p>
      </FancyCard>
    </>
  );
}
