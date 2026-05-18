# 네이티브 통합 (사용자 실행 · throwaway · UNVERIFIED)

작성자는 RN 네이티브를 빌드/검증 못 함. 아래는 references/module-
federation-core 의 Re.Pack 네이티브(`packages/repack/{ios,android}` —
검증된 프로덕션 패턴)에 모델링한 **초안 + 절차**. 당신이 채워 빌드·
실행 → `../CHECKLIST.md` 기입.

## 0. 앱

```sh
npx @react-native-community/cli init SpikeApp   # New Arch 기본(RN 0.76+)
# Hermes 기본 ON 확인. New Arch 끄지 말 것(B4 = New Arch RuntimeExecutor).
```
`spike0_jsi.{h,cpp}` 를 앱 네이티브에 추가, `../remote/dist`(하니스가
만든 산출 or 아래 .hbc) 와 `../host/register.ts` 를 앱 JS 에 연결.

## 1. ① jsi::Runtime& 정식 경로 (핵심 — B4)

**금지**: Re.Pack 의 private `RCTBridge(JSIRuntime).runtime` 캐스팅 /
`javaScriptContextHolder` (구브릿지 호환용 멀티버전 shim — 우리는
그린필드라 불요). **사용**: New Arch 정식 핸드오프

- iOS(New Arch): TurboModule 의 `RCTTurboModule` 가 받는
  `std::shared_ptr<CallInvoker> jsInvoker` + `RuntimeExecutor`
  (`facebook::react::RuntimeExecutor`)로 `runtimeExecutor([](jsi::Runtime &rt){ ... })`.
- Android(New Arch): `TurboModule` 의 `CallInvokerHolder` +
  `RuntimeExecutor` 동일 패턴(`com.facebook.react.bridge`).

→ `spike0_jsi::evaluateFederatedRemote(rt, ...)` 를 그 람다 안에서
호출(B6: 완료 Value 를 람다 내 캡처해 Promise resolve).

## 2. TurboModule glue (플랫폼 미픽 — 당신 플랫폼만 채움)

### iOS (`.mm`, TODO)
```objc
// RCT_EXPORT_MODULE / TurboModule spec: evaluateFederatedRemote(path):Promise
// - path 로컬 파일 read → std::string code
// - self.runtimeExecutor(^(jsi::Runtime &rt){
//     auto v = zntc_spike0::evaluateFederatedRemote(rt, code, url, gname, true);
//     // v(컨테이너) → JS Promise resolve (B6). 실패=reject + diag
//   });
```

### Android (`.kt` + JNI, TODO)
```kotlin
// TurboModule: evaluateFederatedRemote(path: String, promise: Promise)
// - file read → ByteArray → JNI → C++ 에서 runtimeExecutor 람다 내
//   zntc_spike0::evaluateFederatedRemote(...) → Promise (B6)
```
참고 모델(검증된 패턴): `references/module-federation-core/packages/
repack/android/src/main/cpp/NativeScriptLoader.cpp`,
`packages/repack/ios/ScriptManager.mm` — 우리는 ① 때문에 private
경로/버전 shim 부분만 RuntimeExecutor 로 대체.

## 3. .hbc 픽스처 (B1/B2)

```sh
# 호스트 앱과 **동일 Hermes** 의 hermesc 로:
hermesc -emit-binary -out remote/dist/Button.hbc <remote 청크 JS>
```
B1: 동일 Hermes → 거부 없이 실행. (의도 불일치 .hbc → 버전에러 확인)
B2: `.hbc` 를 evaluateJavaScript → 완료값이 컨테이너 보존되는지(②).

## 4. host JS

`../host/register.ts` 참조 — 표준 `@module-federation/runtime` 에
플러그인으로 이 네이티브 로더를 1회 동기 등록(첫 lazy 전). zntc 전용
ScriptManager API 없음(D1). `loadRemote('remote_app/Button')` →
`<Button/>` 렌더 → B3 싱글톤(`usedHook===host.useState`) 로그 확인.

## 5. 실행 → CHECKLIST

iOS `pod install` → Xcode Run / Android `./gradlew :app:installDebug`.
화면 `remote Button #0` + diag JSON 로그 캡처 → `../CHECKLIST.md`
B1~B9 기입·회신.
