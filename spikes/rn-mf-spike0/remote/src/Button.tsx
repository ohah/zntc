// 스파이크 expose 픽스처. react = shared(host 단일 인스턴스 공유).
// usedHook = B3 싱글톤 검증 전용 스캐폴딩(host 의 useState 와 동일
// 인스턴스여야 hooks 안전 → 진정한 MF shared 성립 증거).
import { useState, createElement } from 'react';

export const usedHook = useState;

export default function Button() {
  const [n, setN] = useState(0);
  return createElement('button', { onClick: () => setN(n + 1) }, `remote Button #${n}`);
}
