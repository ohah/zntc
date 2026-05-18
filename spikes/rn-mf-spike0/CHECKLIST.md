# 스파이크0 go/no-go 체크리스트 (사용자 실 RN 실행 → 기입·회신)

실 New Arch + Hermes RN 앱에서 `native/` + `host/` + `remote/dist` 를
끼워 실행 후, 각 항목 **기대출력과 대조**해 `PASS/FAIL/관측값` 기입.
회신하면 작성자가 go/no-go 판정.

전제: `harness/run.ts` 는 작성자 실행 GREEN(자동분). 아래는 **Node≠
Hermes 라 자동 불가, 실 RN 만 진위 드러나는** 항목.

| # | 검증 | 기대출력 / PASS 기준 | 결과 기입 |
|---|---|---|---|
| **B1** | `.hbc` ↔ 호스트 Hermes 버전 일치 | `remote/` 를 호스트 앱과 **동일 Hermes** 로 `.hbc` 빌드 → 로더가 그 `.hbc` 를 거부 없이 실행. (의도적으로 다른 Hermes `.hbc` 주입 시 → 명확한 버전 불일치 에러) | ☐ |
| **B2** | `.hbc` 완료값=컨테이너 (②) | `.hbc` 를 `evaluateJavaScript` → 반환 `jsi::Value` 가 컨테이너(get/init 보유). **JS 소스(하니스 GREEN)와 동일하게 hbc 도 top-level 완료값 보존되는가** = ②의 hbc go/no-go | ☐ |
| **B3** | shared singleton | remote `<Button/>` 렌더, host 와 **동일 React 인스턴스**(hooks 정상, "Invalid hook call" 없음). `usedHook === host.useState` 로그 `true` | ☐ |
| **B4** | RuntimeExecutor-only (①) | New Arch 정식 `RuntimeExecutor`(또는 `CallInvoker`+runtime ptr 정식 경로)로 `jsi::Runtime&` 획득 — private `bridge.runtime` 캐스팅·멀티버전 shim **없이** 컴파일·동작 | ☐ |
| **B5** | JS 소스 주입·등록·렌더 | `.hbc` 아닌 JS 소스 remote 를 세션 중 `evaluateJavaScript` → `loadRemote('remote_app/Button')` → 화면에 `remote Button #0` 렌더 | ☐ |
| **B6** | Value 마샬링 / 스레딩 | CallInvoker async 홉에서 완료 `Value` 를 JS 스레드 람다 내 캡처 → RN Promise resolve. 반복 로드/언마운트 시 크래시·레이스 0 | ☐ |
| **B7** | webpack-origin ↔ zntc-② 공존 | (가능하면) 표준 rspack remote(globalThis) + zntc remote(②) 를 한 로더가 모두 로드. 불가 시 "단일 zntc remote 만 확인" 기입 | ☐ |
| **B8** | 실패/teardown 무오염 | 도달불가 URL / 변조 본문 / evaluate throw → 런타임 오염 없이 거부+에러, 셸 생존(graceful). 정상 remote 재시도 시 복구 | ☐ |
| **B9** | 상태전이 구조화 진단 | 로더가 `resolve→fetch→verify→evaluate` 전이마다 구조화 로그(JSON 라인) emit. **실패 케이스(B1 불일치/변조/throw)에서 원인이 로그에 드러나는가** = "디버깅 쉬움" go/no-go | ☐ |

## 판정 규칙

- **go**: B1·B2·B3 PASS (핵심) + B4·B5·B6 PASS. B7 부분/B9 형태 확인이면 충분(풀배선 정공법).
- **no-go**: B2 FAIL(hbc 완료값 미보존) → ② 폐기·globalThis 폴백(= Re.Pack 동급, 차별화 없음 → RFC §8.2 D4 재검토). B1/B3/B5 FAIL → RN MF 메커니즘 자체 재검토.
- 부분: B4 FAIL(RuntimeExecutor 불가, private 경로만) → 동작은 하나 ① 차별화 약화, 별도 판단.

## 회신 형식

각 B# 에 `PASS` / `FAIL: <관측·에러>` / `N/A: <사유>` + 핵심 로그 첨부.
이걸로 작성자가 §8.2 go/no-go 확정 → 학습 영구 박제 후 이 디렉토리 폐기.
