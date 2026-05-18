// RN MF 스파이크0 — 공유 JSI 코어 (throwaway · UNVERIFIED).
//
// 작성자는 RN 네이티브를 컴파일/실행할 수 없음. 이 파일은 callstack/
// repack `NativeScriptLoader.cpp`(검증된 프로덕션 패턴: CallInvoker +
// jsi::Runtime& + evaluateJavaScript(shared_ptr<Buffer>,url)) 를
// upstream 에서 검토해 **모델링**한 correctness-by-construction 초안
// (repack 은 본 리포에 vendored 아님 — 동작은 vendored references/
// hermes JSI 계약으로 정적 대조). 당신이 빌드·실행해 CHECKLIST 로
// 진위 확정. 플랫폼 glue(TurboModule 등록)는 native/INTEGRATE.md.
#pragma once
#include <jsi/jsi.h>
#include <ReactCommon/CallInvoker.h>
#include <memory>
#include <string>

namespace zntc_spike0 {

using namespace facebook;

// 진단(B9): resolve→fetch→verify→evaluate 전이마다 1줄 구조화 로그.
// 스파이크 최소판 = stderr/logcat JSON 라인. off-device 채널(dev-server/
// MCP)은 통과 후 정공법(스파이크 비대상).
void diag(const char *step, bool ok, const std::string &detail);

// 핵심: 코드 버퍼를 살아있는 Hermes 런타임에 주입하고 **컨테이너를
// 반환**한다. ②(완료값=컨테이너): JSI evaluateJavaScript 의 반환
// jsi::Value 가 곧 컨테이너(스크립트 tail 이 컨테이너 반환하도록 zntc
// 가 ②-emit 한 경우). globalThis 폴백: js_global 의 컨테이너 글로벌명.
//
// `code` = JS 소스(B5) 또는 사전컴파일 .hbc(B1/B2) — Hermes 가 매직
// 바이트로 자동 분기(Re.Pack 도 분기 코드 없음, 단일 evaluateJavaScript).
// `runtime` = ① New Arch RuntimeExecutor/CallInvoker 정식 경로로 얻은
// jsi::Runtime& (private bridge.runtime 캐스팅 금지 — INTEGRATE 참조).
//
// 반환: 성공 시 컨테이너 jsi::Value(get/init 보유), 실패 시 빈 Value +
// diag FAIL. 실 호출은 CallInvoker JS 스레드 람다 내(B6 마샬링).
jsi::Value evaluateFederatedRemote(
    jsi::Runtime &runtime,
    std::string code,
    const std::string &sourceURL,
    const std::string &containerGlobalName, // "__FEDERATION_<name>:custom__"
    bool useCompletionValueAbi);            // true=②, false=globalThis 폴백

} // namespace zntc_spike0
