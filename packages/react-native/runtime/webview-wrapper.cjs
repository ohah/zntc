'use strict';

// MCP WebView wrapper — dev 빌드 한정. zntc resolver alias 가 `react-native-webview`
// import 를 이 파일로 redirect 하고, 원본 패키지는 escape alias `__zntc_webview_original__`
// 로만 접근하게 한다 (alias self-loop 회피).
//
// 목적:
//   `<WebView />` 의 forwardRef 안 instance 를 mount 시 자동으로 `__ZNTC_WEBVIEW_REGISTRY__`
//   에 등록 → 후속 PR (PR-E `webview_evaluate_script`) 가 instance.injectJavaScript() 등
//   imperative method 를 ref 로 호출 가능.
//
// 핵심 invariant:
//   - JSX 안 건드림 (Babel plugin 0)
//   - callback ref 패턴 — useEffect commit phase 지연 race 회피, attach/detach
//     정확한 시점에 registry update (StrictMode double-mount 안전)
//   - `_nextId` 가 global counter — HMR module 재평가 시 ID monotonic 유지 (충돌 회피)
//   - 사용자 ref (function/object) forwardRef contract 그대로 (callback ref 안에서
//     사용자 ref 도 호출/할당)
//   - 원본 패키지의 named exports (WebViewMessageEvent 등) 모두 spread re-export
//   - production 빌드에는 alias 가 적용 안 됨 — 사용자 코드는 원본 그대로
//   - registry global 은 mcp-runtime 의 `__ZNTC_MCP_RUNTIME__` 과 분리 (PR-E 가
//     필요 시 두 entry point 연결)

const React = require('react');
const Original = require('__zntc_webview_original__');

// `globalThis` 위에 두 값을 둔다 — wrapper module 이 HMR 로 재평가돼도 counter 와
// registry 가 살아남아 ID 충돌 회피.
const _g = typeof globalThis !== 'undefined' ? globalThis : global;

const _registry = (() => {
  if (_g.__ZNTC_WEBVIEW_REGISTRY__) return _g.__ZNTC_WEBVIEW_REGISTRY__;
  const map = new Map();
  Object.defineProperty(_g, '__ZNTC_WEBVIEW_REGISTRY__', {
    value: map,
    writable: false,
    configurable: false,
    enumerable: false,
  });
  return map;
})();

// _nextId 도 global — module-local 로 두면 HMR 재평가 시 1 부터 다시 시작해서
// 기존 registry 의 ID 와 충돌 (overwrite). global counter 는 monotonic.
function _nextWvId() {
  const cur = _g.__ZNTC_WEBVIEW_NEXT_ID__ || 1;
  _g.__ZNTC_WEBVIEW_NEXT_ID__ = cur + 1;
  return 'wv_' + cur;
}

// CJS / ESM interop: 원본 패키지가 named `WebView`, default, 또는 `module.exports = WebView`
// 셋 중 어느 형태든 받음. 셋 다 falsy 면 명시적 throw (silent 깨짐 대신 fail-loud).
const OriginalWebView =
  (Original && Original.WebView) ||
  (Original && Original.default) ||
  (typeof Original === 'function' ? Original : null);
if (!OriginalWebView) {
  throw new Error(
    '[zntc:mcp:webview-wrapper] react-native-webview 모듈 의 WebView export 를 찾지 못했습니다. ' +
      '지원 형태: named `WebView`, `default`, 또는 `module.exports = WebView` (legacy CJS). ' +
      'react-native-webview 버전 호환성 확인 필요.',
  );
}

const ZntcWebView = React.forwardRef(function ZntcWebView(props, userRef) {
  // callback ref 패턴 — useEffect (commit phase 지연) 대신 attach/detach 정확한
  // 시점에 registry update. RN strict mode 의 double-mount 도 정확히 등록/해제.
  // 사용자 ref (function 또는 object) 와 동시 forwarding.
  const idRef = React.useRef(null);

  const onRef = React.useCallback(
    (instance) => {
      // 이전 instance 의 registry entry 정리 (StrictMode 의 unmount → remount 안전)
      if (idRef.current) {
        _registry.delete(idRef.current);
        idRef.current = null;
      }
      // 새 instance 등록 (null 이면 detach 의미 — register 안 함)
      if (instance) {
        const id = _nextWvId();
        idRef.current = id;
        _registry.set(id, instance);
      }
      // 사용자 ref 도 같이 forward — forwardRef 의 contract 보존.
      if (typeof userRef === 'function') userRef(instance);
      else if (userRef != null) userRef.current = instance;
    },
    [userRef],
  );

  return React.createElement(OriginalWebView, {
    ...props,
    ref: onRef,
  });
});
ZntcWebView.displayName = 'ZntcWebView';

// 원본 모듈의 named/default exports 모두 보존 — WebView 만 wrap 으로 덮어쓴다.
// caller 가 `import { WebViewMessageEvent } from 'react-native-webview'` 처럼 가져가는
// 부수 export 가 깨지지 않게 spread.
const wrapperExports = Object.assign({}, Original, {
  WebView: ZntcWebView,
  default: ZntcWebView,
});
// `__esModule: true` 명시 — pure CJS 원본 패키지 (marker 부재) 에서도 zntc/Metro 의
// CJS→ESM interop 이 default import 를 `module.default` 로 unwrap 하도록 보장.
// 미 명시 시 `import WebView from 'react-native-webview'` 가 wrapper module 객체
// 전체를 받아 JSX `<WebView />` 가 invariant violation 으로 깨진다.
Object.defineProperty(wrapperExports, '__esModule', { value: true });
module.exports = wrapperExports;
