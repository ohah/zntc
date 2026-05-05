/**
 * ZTS HMR Client - Metro HMRClient interface replacement for ZTS bundler.
 * Connects to the dev server WebSocket and applies ZTS-format HMR updates
 * via __zts_apply_update() (injected by ZTS dev mode runtime).
 */
"use strict";

// Metro HMRClient 와 동일한 'Refreshing...' 배너 동작을 위해 NativeModules.DevLoadingView 접근.
// RN global 이 채워지기 전/환경 부재 상황 (web, 테스트) 에선 조용히 no-op.
function getDevLoadingView() {
  try {
    var nm =
      (typeof global !== "undefined" && global.NativeModules) ||
      (typeof window !== "undefined" && window.NativeModules) ||
      null;
    return nm && nm.DevLoadingView ? nm.DevLoadingView : null;
  } catch (_e) {
    return null;
  }
}

var HMRClient = {
  _socket: null,
  _enabled: true,
  // Metro 처럼 중첩 update 를 카운트 — 마지막 update-done 에서만 배너 hide.
  _pendingUpdates: 0,

  enable: function () {
    this._enabled = true;
  },

  disable: function () {
    this._enabled = false;
  },

  registerBundle: function (_requestUrl) {
    // No-op: ZTS bundler does not require bundle registration
  },

  log: function (level, data) {
    if (this._socket && this._socket.readyState === 1) {
      try {
        this._socket.send(JSON.stringify({ type: "log", level: level, data: data }));
      } catch (_e) {
        // ignore
      }
    }
  },

  setup: function (platform, bundleEntry, host, port, isEnabled, scheme) {
    if (this._socket != null) {
      return;
    }
    var protocol = scheme === "https" ? "wss" : "ws";
    var portPart = port != null && port !== "" ? ":" + port : "";
    var wsUrl = protocol + "://" + host + portPart + "/hot";
    var socket = new (typeof WebSocket !== "undefined" ? WebSocket : global.WebSocket)(wsUrl);
    this._socket = socket;
    this._enabled = isEnabled !== false;

    var self = this;

    socket.onopen = function () {
      socket.send(
        JSON.stringify({
          type: "hmr:connected",
          bundleEntry: bundleEntry,
          platform: platform,
        }),
      );

      // Intercept console methods to forward logs to dev server terminal
      var levels = ["log", "info", "warn", "error", "debug"];
      for (var i = 0; i < levels.length; i++) {
        (function (level) {
          var original = console[level];
          if (typeof original === "function") {
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
                    } else if (typeof arg === "object" && arg !== null) {
                      try {
                        args.push(JSON.parse(JSON.stringify(arg)));
                      } catch (_e) {
                        args.push(String(arg));
                      }
                    } else {
                      args.push(arg);
                    }
                  }
                  socket.send(JSON.stringify({ type: "log", level: level, data: args }));
                } catch (_e) {
                  // ignore serialization errors
                }
              }
            };
          }
        })(levels[i]);
      }
    };

    socket.onmessage = function (event) {
      try {
        var msg = JSON.parse(event.data);
        if (!self._enabled && msg.type !== "hmr:error") {
          return;
        }
        switch (msg.type) {
          case "hmr:update-start":
            self._pendingUpdates++;
            // Initial update sequence (서버가 connect 시 전송해 로딩바 dismiss 용) 는
            // 실제 코드 변경이 아니므로 "Refreshing..." 배너 노출 skip.
            // Metro HMRClient 동일 동작 (isInitialUpdate flag 검사).
            if (self._enabled && !msg.isInitialUpdate) {
              var dlvStart = getDevLoadingView();
              if (dlvStart && typeof dlvStart.showMessage === "function") {
                try {
                  dlvStart.showMessage("Refreshing...", "refresh");
                } catch (_e) {
                  // DevLoadingView 호출 실패는 HMR 동작과 무관 — 무시
                }
              }
            }
            break;
          case "hmr:update":
            console.log(
              "[ZTS HMR] update received, modules:",
              msg.modules ? msg.modules.length : 0,
            );
            console.log("[ZTS HMR] __zts_apply_update:", typeof __zts_apply_update);
            console.log("[ZTS HMR] global.__zts_apply_update:", typeof global.__zts_apply_update);
            var applyFn =
              typeof __zts_apply_update === "function"
                ? __zts_apply_update
                : global.__zts_apply_update;
            if (typeof applyFn === "function" && msg.modules && msg.modules.length > 0) {
              console.log(
                "[ZTS HMR] calling __zts_apply_update with",
                msg.modules.length,
                "modules",
              );
              try {
                applyFn(msg.modules);
                console.log("[ZTS HMR] __zts_apply_update completed successfully");
              } catch (e) {
                console.error("[ZTS HMR] __zts_apply_update threw:", e);
              }
            } else {
              console.warn("[ZTS HMR] __zts_apply_update not available or no modules");
            }
            break;
          case "hmr:update-done":
            if (self._pendingUpdates > 0) self._pendingUpdates--;
            if (self._pendingUpdates === 0) {
              var dlvDone = getDevLoadingView();
              if (dlvDone && typeof dlvDone.hide === "function") {
                try {
                  dlvDone.hide();
                } catch (_e) {
                  // 무시
                }
              }
            }
            break;
          case "hmr:reload":
            // Reuse __zts_reload() from ZTS HMR runtime (injected via --dev mode)
            if (typeof __zts_reload === "function") {
              __zts_reload();
            } else if (typeof location !== "undefined") {
              location.reload();
            }
            break;
          case "hmr:error":
            if (msg.message) {
              console.error("[ZTS HMR]", msg.message);
            }
            break;
          default:
            break;
        }
      } catch (e) {
        console.warn("[ZTS HMR] Invalid message", e);
      }
    };

    socket.onerror = function () {
      console.warn("[ZTS HMR] WebSocket error");
    };

    socket.onclose = function () {
      self._socket = null;
    };
  },
};

// RN의 setUpBatchedBridge가 require('HMRClient').default로 접근하므로 default export 필요
module.exports = HMRClient;
module.exports.default = HMRClient;
