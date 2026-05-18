# RN MF 스파이크0 (throwaway · RFC §8.2)

> **이 디렉토리는 버리는 코드입니다.** RFC §8 디리스크 패턴: 손수 픽스처 +
> 최소 런타임으로 실환경 증명 → **검증 후 폐기**, 동작만 나중에 영구
> 테스트·실구현으로 박제. **main 에 머지하지 않습니다**(CI 가 RN 네이티브
> 빌드 불가 + §8 폐기 전제). `spike/rn-mf-spike0` 브랜치에만 존재.

## 목적

RFC §8.2 의 RN MF go/no-go 를 가른다. "JSI `evaluateJavaScript` 로
federated 모듈을 살아있는 Hermes 런타임(New Arch)에 주입해 등록·렌더되는가"
— **(a) JS 소스 (b) 사전컴파일 `.hbc`** 두 경우 + ① RuntimeExecutor-only
② 완료값=컨테이너 ABI ③ 표준 `@module-federation/runtime` 플러그인 hook
+ 동기 등록 순서 ⑨ 상태전이 구조화 진단.

## 검증 책임 분리 (정직)

| 측 | 누가 | 방법 |
|---|---|---|
| **JS/계약/ABI/플러그인/싱글톤** | 작성자(자동) | `harness/` Node 하니스 — 표준 `@module-federation/runtime` + mock JSI 로더로 네이티브 외 전부 기계검증. **작성자가 실행해 GREEN 박제**(아래 "하니스 결과" 참조) |
| **네이티브 JSI 주입 (B1·B2·B5·B6·B9)** | **당신(수동)** | `native/` 를 fresh New Arch RN 앱에 끼워 실행 → `CHECKLIST.md` 기입·회신 → go/no-go 판정 |

작성자는 RN 네이티브를 실행할 수 없음(에이전트 환경에 Hermes/New Arch 부재).
그래서 "한 칸"(실제 Hermes-JSI 주입)만 당신 손이고, 그 외 설계 리스크
(완료값 ABI 의 JS 의미·플러그인 hook·싱글톤·globalThis 폴백 공존)는
하니스가 자동 검증해 좁혀 둔다.

## 절차

1. `harness/` — 작성자가 이미 실행·GREEN(이 README 의 "하니스 결과"에 박제).
   당신도 `bun harness/run.ts` 로 재현 가능(네이티브 불요).
2. `native/` — `npx @react-native-community/cli init SpikeApp`(**New Arch
   기본**) 후, `native/INTEGRATE.md` 절차대로 TurboModule 소스 + `host/`
   + `remote/dist` 를 끼움. iOS 면 `pod install` → Xcode run, Android 면
   `./gradlew` run.
3. 앱 실행 → 화면/로그 확인 → `CHECKLIST.md` 의 B1~B9 를 **기대출력과
   대조해 PASS/FAIL/관측값 기입** → 회신.
4. 작성자가 회신으로 go/no-go 판정. go → 학습을 영구 테스트·실구현으로
   박제 후 이 디렉토리 폐기. no-go → RFC §8.2 D4 재검토.

## 하니스 결과 (작성자 실행 박제 — 機械 검증 증거)

> /simplify 빡센 검증이 초안의 거짓-GREEN(② 완료값/B7/플러그인을
> 자가충족 wrap·tautology 로 "검증"이라 과장) 을 잡아 **정직 강등**함.
> 아래는 *진짜로* 기계 검증된 것만.

`bun spikes/rn-mf-spike0/harness/run.ts` → **PASS (exit 0)**:

```
[verify] build:container-emit     OK
[verify] build:manifest           OK
[verify] abi:globalThis:shape     OK   zntc emit 컨테이너 get/init 실재
[verify] abi:completion-is-undefined OK  zntc 미 ②-emit 확인(완료값 undefined)
[defer ] ②완료값 ABI / dual-ABI / 플러그인 / B3 / B1·B5·B6·B9  →CHECKLIST
HARNESS: PASS
```

→ **기계 검증 완료(만)**: ① zntc 실 빌드가 컨테이너+`mf-manifest`
산출 ② 그 컨테이너가 get/init 보유(네이티브 globalThis-read 경로
동형) ③ **zntc 가 아직 ②-emit 안 함을 데이터로 확인**(번들 완료값=
`undefined`).

**여기서 검증 *안* 됨(정직)**:
- **② 완료값=컨테이너 ABI** — zntc 미 ②-emit. wrap 으로 완료값을
  조작하면 globalThis 와 동일해질 뿐 → 실검증 = ②-emit 구현 + Hermes.
- dual-ABI 공존(B7) — webpack-origin 컨테이너 부재.
- 플러그인 hook — 실 `@mf/runtime` 등록 미실행.
- B3 싱글톤·실 loadRemote — `mf-runtime-interop-smoke` S2(GREEN)
  **인용 증거**(별도 기계증명, 이 하니스가 한 게 아님).
- B1/.hbc·B2/.hbc 완료값·B5/B6 실RN·B9 — Node≠Hermes.

이 미검증분 전부 CHECKLIST(사용자 실 RN 실행)로 좁혀 둠. 하니스는
검증 못 한 걸 검증했다 주장하지 않는다.

## 비대상 (스파이크 최소주의)

HTTP fetch·캐시·서명 풀구현·dev-server/MCP 풀배선·전체 RN 앱 스캐폴딩.
통과 후 정공법. 스파이크는 go/no-go 핵심만.
