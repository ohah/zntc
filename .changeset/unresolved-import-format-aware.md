---
'@zntc/core': patch
'@zntc/wasm': patch
---

해석하지 못한 import 를 **번들 바깥에 있는 것으로 취급**하도록 고쳤다. 이전에는 출력 포맷과
무관하게 `require(...)` 폴백을 방출해서, ESM/IIFE 출력이나 브라우저 타겟에서는 문법적으로
성립하지 않는 번들이 나왔다. 그 번들은 로드 시점에 `require is not defined` 로 죽는데, 정작
원인인 "패키지가 없다" 는 메시지에서 사라졌다.

이제 ESM 은 `import`, CJS 는 `require`, IIFE 는 기존 "IIFE 포맷으로는 방출 불가" 진단으로
각각 제 경로를 탄다. 런타임 메시지도 없는 패키지를 지목한다. 진단 등급은 그대로 error 다 —
external 로 _방출_ 한다는 뜻이지 오탈자를 눈감아 준다는 뜻이 아니다.

WASM `build()` / `buildChunks()` 는 해석 불가 import 가 있어도 출력을 반환한다. VFS 에
`react` 를 올리지 않는 게 정상인 플레이그라운드에서 `jsx: "automatic"` 이 주입하는 런타임
import 를 실패로 처리하면 JSX 자체를 쓸 수 없기 때문이다. 출력을 withhold 하는 건 번들이
내부적으로 앞뒤가 안 맞을 때(export 충돌·모호·누락)뿐이다. 0.1.7 에서 이 구분 없이 막았던
것을 되돌린다.

CLI 의 산출물 방출 정책도 같은 규칙으로 통일했다. 이전엔 npm CLI(`bin/zntc.mjs`)는 에러가
있어도 산출물을 냈고 Zig CLI(`zig build` 산출 바이너리)는 출력 전에 종료해 아무것도 내지
않았다. 이제 둘 다 "번들이 내부적으로 앞뒤가 안 맞을 때만 보류" 로 같은 답을 낸다. exit code
는 이와 별개로 에러가 있으면 1 이다.
