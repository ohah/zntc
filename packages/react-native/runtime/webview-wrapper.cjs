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
//   - 사용자가 직접 단 ref 와 wrapper 의 inner ref 가 충돌하지 않도록 mergeRefs
//   - 원본 패키지의 named exports (WebViewMessageEvent 등) 모두 spread re-export
//   - production 빌드에는 alias 가 적용 안 됨 — 사용자 코드는 원본 그대로
//   - registry global 은 mcp-runtime 의 `__ZNTC_MCP_RUNTIME__` 과 분리 (PR-E 가
//     필요 시 두 entry point 연결)

const React = require('react');
const Original = require('__zntc_webview_original__');

const _registry = (() => {
  const g = typeof globalThis !== 'undefined' ? globalThis : global;
  if (g.__ZNTC_WEBVIEW_REGISTRY__) return g.__ZNTC_WEBVIEW_REGISTRY__;
  const map = new Map();
  Object.defineProperty(g, '__ZNTC_WEBVIEW_REGISTRY__', {
    value: map,
    writable: false,
    configurable: false,
    enumerable: false,
  });
  return map;
})();

let _nextId = 1;

function mergeRefs(...refs) {
  return (value) => {
    for (const ref of refs) {
      if (typeof ref === 'function') ref(value);
      else if (ref != null) ref.current = value;
    }
  };
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
  const innerRef = React.useRef(null);
  const idRef = React.useRef(null);

  React.useEffect(() => {
    const id = 'wv_' + _nextId++;
    idRef.current = id;
    _registry.set(id, innerRef.current);
    return () => {
      _registry.delete(id);
      idRef.current = null;
    };
  }, []);

  return React.createElement(OriginalWebView, {
    ...props,
    ref: mergeRefs(innerRef, userRef),
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
