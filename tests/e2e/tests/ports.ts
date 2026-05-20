/**
 * 모든 e2e 테스트가 공유하는 단일 port 발급처.
 *
 * playwright 는 기본적으로 test 파일 간 parallel 실행이라, 두 파일이 동일 port 로
 * 서버를 spawn 하면 EADDRINUSE 또는 응답이 섞이며 fail 이 race 로 들쭉날쭉해진다.
 * fixed port 가 필요한 케이스는 모두 여기서 unique 하게 발급한다.
 * 동적 port (`listen(0)`) 를 쓰는 케이스는 등록 불필요.
 */
export const PORTS = {
  SMOKE: 3999,
  SOURCEMAP: 3986,
  VITE_APP: 3985,

  BUILD_PREVIEW: 3997,
  DEV: 3998,
  CSS_MODULE_PREVIEW: 3995,
  CSS_MODULE_DEV: 3994,
  SCSS_PREVIEW: 3993,
  SCSS_DEV: 3992,
  SASS_HTML_PREVIEW: 3991,
  SCSS_RECOVERY_DEV: 3990,
  OVERLAY_DEV: 3989,
  RUNTIME_OVERLAY_DEV: 3988,
  REJECTION_OVERLAY_DEV: 3987,
  NESTED: 3996,
  DEV_JSX: 3984,
  BUILD_JSX: 3983,
  VERIFY_MCP: 3982,
} as const;
