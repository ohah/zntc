/**
 * ZNTC HMR Client - Metro HMRClient interface replacement for ZNTC bundler.
 * Connects to the dev server WebSocket and applies ZNTC-format HMR updates
 * via __zntc_apply_update() (injected by ZNTC dev mode runtime).
 */
'use strict';

var REFRESH_TEXT_COLOR = -1; // #ffffff
var REFRESH_BACKGROUND_COLOR = -14318360; // #2584e8

function getRoot() {
  return (
    (typeof global !== 'undefined' && global) ||
    (typeof globalThis !== 'undefined' && globalThis) ||
    (typeof window !== 'undefined' && window) ||
    null
  );
}

function getDirectNativeDevLoadingView() {
  try {
    var root = getRoot();
    if (root) {
      if (root.nativeModuleProxy && root.nativeModuleProxy.DevLoadingView) {
        return root.nativeModuleProxy.DevLoadingView;
      }
      if (typeof root.__turboModuleProxy === 'function') {
        var turboModule = root.__turboModuleProxy('DevLoadingView');
        if (turboModule) return turboModule;
      }
      if (root.NativeModules && root.NativeModules.DevLoadingView) {
        return root.NativeModules.DevLoadingView;
      }
    }
  } catch (_e) {
    // fallback 으로 내려간다.
  }

  try {
    if (typeof require === 'function') {
      var nativeModules = require('../BatchedBridge/NativeModules');
      nativeModules = nativeModules && (nativeModules.default || nativeModules);
      if (nativeModules && nativeModules.DevLoadingView) {
        return nativeModules.DevLoadingView;
      }
    }
  } catch (_e) {
    // fallback 으로 내려간다.
  }

  try {
    if (typeof require === 'function') {
      var rn = require('react-native');
      var rnNativeModules = rn && rn.NativeModules;
      if (rnNativeModules && rnNativeModules.DevLoadingView) {
        return rnNativeModules.DevLoadingView;
      }
    }
  } catch (_e) {
    // fallback 으로 내려간다.
  }

  return null;
}

function wrapNativeDevLoadingView(nativeDevLoadingView) {
  return {
    showMessage: function (message, _type, options) {
      nativeDevLoadingView.showMessage(
        message,
        REFRESH_TEXT_COLOR,
        REFRESH_BACKGROUND_COLOR,
        !!(options && options.dismissButton),
      );
    },
    hide: function () {
      nativeDevLoadingView.hide();
    },
  };
}

// wrapper 내부 NativeDevLoadingView 값이 초기화 시점에 null 로 굳을 수 있어,
// 호출 시점 native module 재조회 경로를 먼저 시도한 뒤 require 로 폴백.
function getDevLoadingView() {
  var nativeDevLoadingView = getDirectNativeDevLoadingView();
  if (nativeDevLoadingView && typeof nativeDevLoadingView.showMessage === 'function') {
    return wrapNativeDevLoadingView(nativeDevLoadingView);
  }

  try {
    if (typeof require === 'function') {
      var mod = require('./DevLoadingView');
      return mod && (mod.default || mod) ? mod.default || mod : null;
    }
  } catch (_e) {
    // RN module resolution 실패 시 fallback 으로 내려간다.
  }

  return null;
}

var HMRClient = {
  _socket: null,
  _enabled: true,
  _originalConsole: null,
  // 중첩 update 카운트 — 마지막 update-done 에서만 배너 hide.
  _pendingUpdates: 0,
  // lazy cache — 첫 호출 때 1회 lookup (native module 가 setup 시점엔 아직 미로드).
  // socket.onclose 에서 invalidate — reconnect 시 module 상태 재조회.
  _devLoadingView: null,

  _safeCallDlv: function (method, args) {
    if (this._devLoadingView == null) this._devLoadingView = getDevLoadingView();
    var dlv = this._devLoadingView;
    if (dlv && typeof dlv[method] === 'function') {
      try {
        dlv[method].apply(dlv, args);
      } catch (_e) {
        // DevLoadingView 호출 실패는 HMR 동작과 무관 — 무시
      }
    }
  },

  _showRefreshing: function () {
    this._safeCallDlv('showMessage', ['Refreshing...', 'refresh']);
  },

  _hideRefreshing: function () {
    this._safeCallDlv('hide', []);
  },

  enable: function () {
    this._enabled = true;
  },

  disable: function () {
    this._enabled = false;
  },

  registerBundle: function (_requestUrl) {
    // No-op: ZNTC bundler does not require bundle registration
  },

  log: function (level, data) {
    if (this._socket && this._socket.readyState === 1) {
      try {
        this._socket.send(JSON.stringify({ type: 'log', level: level, data: data }));
      } catch (_e) {
        // ignore
      }
    }
  },

  setup: function (platform, bundleEntry, host, port, isEnabled, scheme) {
    if (this._socket != null) {
      return;
    }
    var protocol = scheme === 'https' ? 'wss' : 'ws';
    var portPart = port != null && port !== '' ? ':' + port : '';
    var wsUrl = protocol + '://' + host + portPart + '/hot';
    var socket = new (typeof WebSocket !== 'undefined' ? WebSocket : global.WebSocket)(wsUrl);
    this._socket = socket;
    this._enabled = isEnabled !== false;

    var self = this;

    socket.onopen = function () {
      socket.send(
        JSON.stringify({
          type: 'hmr:connected',
          bundleEntry: bundleEntry,
          platform: platform,
        }),
      );

      var forwardClientLogs =
        typeof __ZNTC_FORWARD_CLIENT_LOGS__ !== 'undefined' ? __ZNTC_FORWARD_CLIENT_LOGS__ : false;
      if (forwardClientLogs === true && self._originalConsole == null) {
        self._originalConsole = {};
        // Intercept console methods to forward logs to dev server terminal.
        var levels = ['log', 'info', 'warn', 'error', 'debug'];
        for (var i = 0; i < levels.length; i++) {
          (function (level) {
            var original = console[level];
            if (typeof original === 'function') {
              self._originalConsole[level] = original;
              console[level] = function () {
                // Call original first
                original.apply(console, arguments);
                // Forward to server
                if (socket.readyState === 1) {
                  try {
                    var args = [];
                    for (var j = 0; j < arguments.length; j++) {
                      var arg = arguments[j];
                      // Serialize safely — avoid circular references
                      if (arg instanceof Error) {
                        args.push(arg.message);
                      } else if (typeof arg === 'object' && arg !== null) {
                        try {
                          args.push(JSON.parse(JSON.stringify(arg)));
                        } catch (_e) {
                          args.push(String(arg));
                        }
                      } else {
                        args.push(arg);
                      }
                    }
                    socket.send(JSON.stringify({ type: 'log', level: level, data: args }));
                  } catch (_e) {
                    // ignore serialization errors
                  }
                }
              };
            }
          })(levels[i]);
        }
      }
    };

    socket.onmessage = function (event) {
      try {
        var msg = JSON.parse(event.data);
        if (!self._enabled && msg.type !== 'hmr:error') {
          return;
        }
        switch (msg.type) {
          case 'hmr:update-start':
            self._pendingUpdates++;
            // initial sequence (connect 시 로딩바 dismiss 용) 는 실제 코드 변경이
            // 아니므로 "Refreshing..." 배너 노출 skip.
            if (self._enabled && !msg.isInitialUpdate) {
              self._showRefreshing();
            }
            break;
          case 'hmr:update':
            // hmr-client debug — __ZNTC_HMR_DEBUG__ true 시에만 update 도착/주입
            // 진행 로그 출력. default false — forwardClientLogs 로 터미널 forwarding
            // 시 사용자 앱 console.log 가 시스템 노이즈에 묻히지 않게.
            var hmrDebug = typeof __ZNTC_HMR_DEBUG__ !== 'undefined' ? __ZNTC_HMR_DEBUG__ : false;
            if (hmrDebug) {
              console.log(
                '[ZNTC HMR] update received, modules:',
                msg.modules ? msg.modules.length : 0,
              );
            }
            var applyFn =
              typeof __zntc_apply_update === 'function'
                ? __zntc_apply_update
                : global.__zntc_apply_update;
            if (typeof applyFn === 'function' && msg.modules && msg.modules.length > 0) {
              if (hmrDebug) {
                console.log(
                  '[ZNTC HMR] applying',
                  msg.modules.length,
                  typeof __zntc_apply_update === 'function'
                    ? 'modules (local)'
                    : 'modules (global)',
                );
              }
              try {
                applyFn(msg.modules);
                if (hmrDebug) console.log('[ZNTC HMR] apply OK');
              } catch (e) {
                // 항상 출력 — apply 실패는 silent 면 안 됨. 사용자 진단 정보.
                console.error('[ZNTC HMR] __zntc_apply_update threw:', e);
              }
            } else if (hmrDebug || (msg.modules && msg.modules.length > 0)) {
              // modules 가 있는데 applyFn 없으면 항상 warn (런타임 주입 누락 진단).
              // modules 비었고 debug off 면 silent (normal idle).
              console.warn('[ZNTC HMR] __zntc_apply_update not available or no modules');
            }
            break;
          case 'hmr:update-done':
            if (self._pendingUpdates > 0) self._pendingUpdates--;
            if (self._pendingUpdates === 0) {
              self._hideRefreshing();
            }
            break;
          case 'hmr:reload':
            // Reuse __zntc_reload() from ZNTC HMR runtime (injected via --dev mode)
            if (typeof __zntc_reload === 'function') {
              __zntc_reload();
            } else if (typeof location !== 'undefined') {
              location.reload();
            }
            break;
          case 'hmr:error':
            // body.errors 가 있으면 file:line:col 정보를 함께 출력 — RN LogBox 가
            // source link 자동 추출 → 클릭 시 editor jump. backward-compat 으로
            // body 가 없는 메시지는 단순 message 만 출력.
            if (msg.body && msg.body.errors && msg.body.errors[0]) {
              var err = msg.body.errors[0];
              // filename / lineNumber / column 은 type 상 모두 optional.
              // 셋 다 있을 때만 location 부착 — 없으면 'foo.ts:undefined:undefined' 같은
              // false-positive 회피.
              var hasLoc =
                err.filename &&
                typeof err.lineNumber === 'number' &&
                typeof err.column === 'number';
              var loc = hasLoc ? ' ' + err.filename + ':' + err.lineNumber + ':' + err.column : '';
              console.error('[ZNTC HMR]' + loc, err.description || msg.message);
            } else if (msg.message) {
              console.error('[ZNTC HMR]', msg.message);
            }
            break;
          default:
            break;
        }
      } catch (e) {
        console.warn('[ZNTC HMR] Invalid message', e);
      }
    };

    socket.onerror = function () {
      console.warn('[ZNTC HMR] WebSocket error');
    };

    socket.onclose = function () {
      // console intercept 복원 — reconnect 시 stale closure / 중복 wrap 방지.
      if (self._originalConsole) {
        for (var level in self._originalConsole) {
          if (Object.prototype.hasOwnProperty.call(self._originalConsole, level)) {
            console[level] = self._originalConsole[level];
          }
        }
        self._originalConsole = null;
      }
      // 중첩 update 도중 socket drop 시 stuck banner 방지.
      if (self._pendingUpdates > 0) {
        self._pendingUpdates = 0;
        self._hideRefreshing();
      }
      // DevLoadingView cache 무효화 — reconnect 시 module 상태 변경 가능.
      self._devLoadingView = null;
      self._socket = null;
    };
  },
};

// RN의 setUpBatchedBridge가 require('HMRClient').default로 접근하므로 default export 필요
module.exports = HMRClient;
module.exports.default = HMRClient;
