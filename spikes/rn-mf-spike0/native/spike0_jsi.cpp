// RN MF 스파이크0 — 공유 JSI 코어 구현 (throwaway · UNVERIFIED).
// 패턴 모델: callstack/repack NativeScriptLoader.cpp (upstream 소스
// 검토 — 본 리포에 vendored 아님). 동작 정확성은 **vendored**
// references/hermes/API/jsi/jsi.h 의 JSI 계약으로 정적 대조.
// 빌드·실행=사용자(작성자 RN 네이티브 불가).
#include "spike0_jsi.h"
#include <cstdio>

namespace zntc_spike0 {

using namespace facebook;

void diag(const char *step, bool ok, const std::string &detail) {
  // B9: 구조화 진단 1줄(JSON). 실패 케이스 원인이 detail 에 드러나야 함.
  std::fprintf(stderr,
               "{\"spike0\":\"%s\",\"ok\":%s,\"detail\":\"%s\"}\n",
               step, ok ? "true" : "false", detail.c_str());
}

jsi::Value evaluateFederatedRemote(jsi::Runtime &runtime,
                                   std::string code,
                                   const std::string &sourceURL,
                                   const std::string &containerGlobalName,
                                   bool useCompletionValueAbi) {
  diag("resolve", true, sourceURL);

  // Hermes 는 buffer 매직바이트로 JS소스↔.hbc 자동 분기 — 분기 코드 없음
  // (Re.Pack 동형: 단일 evaluateJavaScript(Buffer)). B1/B2 가 .hbc 경로,
  // B5 가 JS 소스 경로를 실 RN 에서 가른다. **JSI 계약**(vendored
  // references/hermes/API/jsi/jsi.h:357): evaluateJavaScript 는
  // `const std::shared_ptr<const Buffer>&` 를 받음 → make_shared 필수
  // (/simplify 가 잡은 초안 결함: make_unique 는 바인딩 불가).
  auto buffer = std::make_shared<jsi::StringBuffer>(std::move(code));

  jsi::Value completion = jsi::Value::undefined();
  try {
    // 핵심 한 줄. ① runtime 은 New Arch RuntimeExecutor/CallInvoker
    // 정식 경로로 얻은 것이어야 함(INTEGRATE). 반환 = 스크립트 완료값.
    completion = runtime.evaluateJavaScript(buffer, sourceURL);
    diag("evaluate", true, "");
  } catch (jsi::JSIException &e) {
    // JSI 계약(jsi.h:351): 미파싱/잘못된 바이트코드(.hbc 버전불일치=B1)는
    // JSError 아닌 JSINativeException(둘 다 JSIException 파생). JSError 만
    // 잡으면 B1 케이스 오분류 → JSIException 으로 정확 포착(.what() 보유).
    diag("evaluate", false, e.what()); // B8/B9: evaluate/파싱 실패 원인
    return jsi::Value::undefined();
  } catch (const std::exception &e) {
    diag("evaluate", false, e.what());
    return jsi::Value::undefined();
  }

  // ②: 완료값이 곧 컨테이너(zntc ②-emit: tail 이 컨테이너 반환). B2 가
  // .hbc 에서도 이 완료값 보존되는지를 가름(JS 소스는 하니스 GREEN).
  if (useCompletionValueAbi) {
    bool isContainer = completion.isObject() &&
                       completion.getObject(runtime).hasProperty(runtime, "get") &&
                       completion.getObject(runtime).hasProperty(runtime, "init");
    diag("abi:completion", isContainer,
         isContainer ? "" : "완료값이 컨테이너 아님 → ② no-go, globalThis 폴백");
    if (isContainer)
      return completion;
    // ②실패 → 폴백 시도(아래)
  }

  // globalThis 폴백(webpack-origin / zntc 현 emit): 글로벌명에서 읽기.
  auto global = runtime.global();
  if (global.hasProperty(runtime, containerGlobalName.c_str())) {
    auto c = global.getProperty(runtime, containerGlobalName.c_str());
    bool ok = c.isObject() && c.getObject(runtime).hasProperty(runtime, "get");
    diag("abi:globalThis", ok, ok ? "" : "글로벌 컨테이너 형태 불일치");
    if (ok)
      return c;
  }
  diag("abi:resolve-fail", false, "완료값·globalThis 모두 컨테이너 미획득");
  return jsi::Value::undefined();
}

} // namespace zntc_spike0
