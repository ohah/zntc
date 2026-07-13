---
"@zntc/core": patch
---

`zig build test` 가 seed 에 따라 SIGSEGV 로 죽던 flake 수정.

`TsconfigCache.clear()` 는 arena 를 reset 하는데, 테스트가 그 **뒤에** clear 이전 결과 슬라이스를 그대로 읽고 있었다 (use-after-free). `retain_capacity` 라 대개는 우연히 살아 읽혀 통과했고, 메모리가 재사용/poison 되는 실행에서만 터졌다.

프로덕션 코드가 아니라 **테스트 자체의 버그**였지만, `pre-push` 훅이 `zig build test` 를 돌리기 때문에 **clean main 에서도 push 가 막히는** 상태였다.
