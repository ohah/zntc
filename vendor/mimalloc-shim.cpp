// mimalloc C++ shim — `src/static.c` 의 단일 컴파일 unit 을 C++ 로 강제.
//
// 배경: mimalloc 의 `include/mimalloc/atomic.h` 가 `_MSC_VER` 정의된 환경에서 C 로
// 컴파일될 때 ARM64 Windows MSVC intrinsic (`__ldar64` / `__stlr64` 등) 호출하는데,
// Zig 의 libc 헤더에 그 intrinsic 미선언 → MSVC ARM64 target 빌드 fail.
// 같은 atomic.h:161 가 "It is recommended to always compile as C++ when using MSVC"
// 라고 명시. C++ 분기 (`__cplusplus`) 는 std::atomic 사용해 MSVC intrinsic 우회.
//
// 본 shim 은 `src/static.c` 를 그대로 include — mimalloc 의 unity build 단위. C 코드도
// C++ 컴파일러로 처리되며 atomic.h 의 `__cplusplus` 분기로 들어가 ARM64 Windows MSVC
// 빌드 회귀 (#3779 이후 GH Actions run 26399900801) 해결.
//
// Linux/macOS 빌드는 `_MSC_VER` 미정의라 C11 stdatomic 또는 C++ std::atomic 어느 쪽이든
// 동일 동작 — cross-platform 안전.

// mimalloc 의 unity build 파일을 그대로 C++ 으로 컴파일. atomic.h 가 `__cplusplus`
// 분기로 std::atomic 사용 → MSVC ARM64 intrinsic 회피.
#include "mimalloc/src/static.c"
