// remote 가 노출(expose)하는 실제 React 컴포넌트.
// `react` 는 zntc.config 의 mf.shared 로 선언 → 번들에 포함되지 않고
// host 가 제공하는 단일 react 인스턴스를 공유한다(useState 가 host 의
// 그것과 동일 인스턴스라야 hooks 가 동작).
import { useState, createElement } from 'react';

// 데모 전용 스캐폴딩: host.mjs 가 `mod.usedHook === hostReact.useState`
// 로 shared singleton(remote↔host 동일 react 인스턴스) 성립을 검증하기
// 위해서만 노출한다. 실제 컴포넌트에는 불필요.
export const usedHook = useState;

export default function Button() {
  const [count, setCount] = useState(0);
  return createElement(
    'button',
    { onClick: () => setCount(count + 1) },
    `remote Button — count: ${count}`,
  );
}
