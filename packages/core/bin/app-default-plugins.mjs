/**
 * `runAppBuild` 가 호출하는 default plugin 주입 helper. (#2538 4-4 PR-3a)
 *
 * Vite 의 `vite:css` 패턴과 동등 — 사용자가 명시 안 해도 `@zntc/web/css` plugin
 * 자동 적용. 사용자 plugins 앞에 prepend (resolveId/load/transform 우선순위).
 *
 * Opt-out:
 *   - `ZNTC_NO_CSS_DEFAULTS=1` 환경변수 (caller 가 `disableDefaults` 로 전달)
 *   - `zntc.config.appPlugins.disableDefaults: true` (caller 가 옵션 전달)
 *
 * runAppDev (dev mode) 의 default css 주입은 PR-3b (dev-controller wiring) 에서.
 * 현 PR-3a 는 runAppBuild (production build) 만 적용.
 *
 * @param {object} args
 * @param {Array<{ name: string, setup: Function }>} args.userPlugins — user
 *   plugins (config.plugins + pluginPaths). 순서 보존. 반환값은 항상 새 array
 *   (caller mutate 가 외부 영향 X).
 * @param {boolean} args.disableDefaults — true 면 default 미주입.
 * @param {{ name: string, setup: Function } | null} args.cssPlugin — `css()`
 *   factory 결과 또는 null (web module 미로드 등 — defensive).
 * @returns {Array<{ name: string, setup: Function }>} 새 array (ownership 분리)
 */
export function resolveAppPlugins({ userPlugins, disableDefaults, cssPlugin }) {
  if (disableDefaults) return [...userPlugins];
  if (!cssPlugin) return [...userPlugins];
  // 사용자가 이미 `@zntc/web/css` 를 명시 전달했으면 default 재주입 금지 (#3836).
  // 같은 filter regex 가 두 onLoad 등록 → PostCSS 가 같은 .css 2번 실행 → 사용자
  // override 가 silent shadow 또는 double-run. name 정확 일치만 — '@zntc/web/css-modules'
  // 같은 다른 plugin 은 영향 X.
  if (userPlugins.some((p) => p?.name === '@zntc/web/css')) {
    return [...userPlugins];
  }
  return [cssPlugin, ...userPlugins];
}

/**
 * `process.env.ZNTC_NO_CSS_DEFAULTS` 같은 boolean 환경변수의 truthy 정규화.
 * '1' / 'true' / 'TRUE' / 'yes' / 'YES' / 'on' / 'ON' 을 truthy. 미지정 / '0' /
 * 'false' / 'no' / 'off' / '' 는 falsy. Vite/Rollup 의 흔한 env 관용 따름.
 *
 * @param {string | undefined | null} value
 * @returns {boolean}
 */
export function isEnvTruthy(value) {
  if (value == null || value === '') return false;
  const v = value.toLowerCase();
  return v === '1' || v === 'true' || v === 'yes' || v === 'on';
}
