/**
 * ZNTC CLI flag registry + parsing helpers.
 *
 * `zntc.mjs` 의 `parseArgs` 가 60+ flag 를 hand-rolled if-chain 으로 처리하던 것을
 * 메타데이터로 통합. 새 flag 추가 시 `FLAG_REGISTRY` 에 entry 한 줄만 추가하면
 * `parseArgs` / `KNOWN_FLAGS` / typo-suggest / schema-sync 모두 자동 합류.
 *
 * 별도 파일로 분리한 이유: `zntc.mjs` 의 top-level `await import("../dist/index.js")` 가
 * NAPI 바인딩을 로드하므로 테스트가 `zntc.mjs` 를 직접 import 하기 어렵다. registry 를
 * 분리해 schema-sync 테스트가 정적 정규식 파싱 대신 실제 export 를 import 하도록 함
 * (formatter 가 spec 을 multi-line 으로 reformat 해도 회귀 없음).
 *
 * spec 필드:
 *   kind:    flag 의 의미 종류 (아래 종류 표 참조)
 *   flag:    canonical flag (`--bundle`, `--outfile`)
 *   target:  opts 객체의 key (`bundle`, `outfile`)
 *   forms:   ["equal"] (`--key=val` 만), ["pair"] (`--key val` 만), ["equal","pair"] (둘 다)
 *            kind 별 기본값 차이: bool/array/key-value/ns-array/enum-bool/string-bool 은 무시,
 *            string/int 는 ["equal","pair"], csv 는 ["equal","pair"], ns-string 은 ["equal"].
 *   aliases: 추가 flag 이름 (`-o`, `--tsconfig-path`).
 *   extra:   부수효과 — 매칭 시 함께 set 할 키-값 (`{ watch: true }`).
 *   default: bool 단독 등장 시 default 값 (kind="string-default" 의 metafile 패턴).
 *   value:   bool flag 가 설정할 값. 생략 시 true (`--no-*` alias 는 false 지정).
 *   enum:    enum→bool 매핑 (`{ utf8: true }` → `--charset=utf8` 시 charsetUtf8=true).
 *   noop:    true 면 매칭만 하고 set 안 함 (deprecated/TODO flag).
 *
 * kind:
 *   bool          — boolean toggle. 정확 매칭만.
 *   string        — string scalar.
 *   int           — parseInt.
 *   array         — array push (반복 지정 시 누적). `--external foo --external bar` → ["foo","bar"].
 *   csv           — comma 분리 → array. `--env-prefix=A,B` → ["A","B"]. forms 기본 ["equal","pair"].
 *   key-value     — colon prefix `--key:K=V` → opts[target][K] = V. `--define:NODE_ENV=prod`.
 *   ns-array      — colon prefix `--key:VALUE` → opts[target].push(VALUE). `--inject:./prelude`.
 *   ns-string     — colon prefix `--key:NS=VALUE` → opts[target] = VALUE (namespace 무시).
 *                   `--banner:js=text` 가 `--banner=text` 와 동일 의미 (esbuild 호환).
 *   string-default — bool 단독 시 default 값, `--key=val` 시 val 사용. `--metafile` 패턴.
 *   enum-bool     — `--key=enumValue` 시 spec.enum 의 매핑 적용. `--charset=utf8` → charsetUtf8=true.
 *   string-bool   — `--key=anything` → true, `--key=false` → false. default=true 옵션의 toggle.
 */
export const FLAG_REGISTRY = [
  // ─── kind=bool — boolean toggle ───
  { kind: 'bool', flag: '--help', target: 'help', aliases: ['-h'] },
  // 버전 출력 후 즉시 종료 (config/NAPI 로드 불필요 — main 에서 early dispatch).
  { kind: 'bool', flag: '--version', target: 'version', aliases: ['-v'] },
  // config 파일 자동 탐색·로드 우회 (CLI flag 만으로 빌드 — 재현/테스트). --config 보다 우선.
  { kind: 'bool', flag: '--no-config', target: 'noConfig' },
  // 색상 출력 강제/억제. 미지정 시 NO_COLOR/FORCE_COLOR env + TTY 자동 판정.
  { kind: 'bool', flag: '--color', target: 'color' },
  { kind: 'bool', flag: '--no-color', target: 'color', value: false },
  { kind: 'bool', flag: '--bundle', target: 'bundle' },
  { kind: 'bool', flag: '--watch', target: 'watch', aliases: ['-w'] },
  { kind: 'bool', flag: '--watch-json', target: 'watchJson', extra: { watch: true } },
  { kind: 'bool', flag: '--open', target: 'open' },
  // RN CLI 호환 (#2605 audit P0)
  { kind: 'bool', flag: '--reset-cache', target: 'resetCache' },
  { kind: 'bool', flag: '--sourcemap-use-absolute-path', target: 'sourcemapUseAbsolutePath' },
  // Metro UI 의 `--no-interactive` 호환 — terminal actions 비활성. RN CLI 호출 시.
  { kind: 'bool', flag: '--no-interactive', target: 'noInteractive' },
  { kind: 'bool', flag: '--minify', target: 'minify' },
  { kind: 'bool', flag: '--minify-whitespace', target: 'minifyWhitespace' },
  { kind: 'bool', flag: '--minify-identifiers', target: 'minifyIdentifiers' },
  { kind: 'bool', flag: '--minify-syntax', target: 'minifySyntax' },
  // `--sourcemap` 단독 → sourcemap=true + mode="linked" (default).
  // `--sourcemap=inline/external/linked` → mode 명시. extra 가 sourcemap=true 같이 set.
  // backward compat: 과거 boolean-only 사용자도 `--sourcemap` 그대로 동작.
  {
    kind: 'string-default',
    flag: '--sourcemap',
    target: 'sourcemapMode',
    default: 'linked',
    extra: { sourcemap: true },
  },
  { kind: 'bool', flag: '--sourcemap-debug-ids', target: 'sourcemapDebugIds' },
  { kind: 'bool', flag: '--splitting', target: 'splitting' },
  { kind: 'bool', flag: '--no-splitting', target: 'splitting', value: false },
  // tree shaking / scope hoisting / .map 디스크 쓰기 — 엔진 기본값 true.
  // string-bool toggle (`--tree-shaking=false`) + 명시적 `--no-*` bool 양쪽 제공
  // (`--no-splitting` 선례와 동형). `--no-*` 는 opts=false 로 두는데, config 머지
  // default=true 루프가 `opts===true` 일 때만 동작하므로 config true 가 못 덮는다.
  { kind: 'bool', flag: '--no-tree-shaking', target: 'treeShaking', value: false },
  { kind: 'bool', flag: '--no-scope-hoist', target: 'scopeHoist', value: false },
  { kind: 'bool', flag: '--no-emit-disk-sourcemap', target: 'emitDiskSourcemap', value: false },
  { kind: 'bool', flag: '--analyze', target: 'analyze', extra: { metafile: 'meta.json' } },
  { kind: 'bool', flag: '--flow', target: 'flow' },
  { kind: 'bool', flag: '--experimental-decorators', target: 'experimentalDecorators' },
  { kind: 'bool', flag: '--emit-decorator-metadata', target: 'emitDecoratorMetadata' },
  { kind: 'bool', flag: '--jsx-in-js', target: 'jsxInJs' },
  { kind: 'bool', flag: '--verbatim-module-syntax', target: 'verbatimModuleSyntax' },
  { kind: 'bool', flag: '--keep-names', target: 'keepNames' },
  { kind: 'bool', flag: '--shim-missing-exports', target: 'shimMissingExports' },
  { kind: 'bool', flag: '--ascii-only', target: 'asciiOnly' },
  { kind: 'bool', flag: '--preserve-modules', target: 'preserveModules' },
  { kind: 'bool', flag: '--inline-dynamic-imports', target: 'inlineDynamicImports' },
  { kind: 'bool', flag: '--preserve-symlinks', target: 'preserveSymlinks' },
  { kind: 'bool', flag: '--resolve-symlink-siblings', target: 'resolveSymlinkSiblings' },
  { kind: 'bool', flag: '--disable-hierarchical-lookup', target: 'disableHierarchicalLookup' },
  { kind: 'bool', flag: '--jsx-dev', target: 'jsxDev' },
  { kind: 'bool', flag: '--clean', target: 'clean' },
  { kind: 'bool', flag: '--strict-port', target: 'strictPort' },
  { kind: 'bool', flag: '--allow-overwrite', target: 'allowOverwrite' },
  { kind: 'bool', flag: '--jsx-side-effects', target: 'jsxSideEffects' },
  { kind: 'bool', flag: '--ignore-annotations', target: 'ignoreAnnotations' },
  // dev 모드 — HMR 런타임 주입 등 dev 동작 활성화. NAPI BuildOptions.devMode 와 동일.
  { kind: 'bool', flag: '--dev', target: 'devMode' },

  // ─── kind=string — string scalar (`--key=value` 단방향) ───
  { kind: 'string', flag: '--format', target: 'format', forms: ['equal'] },
  { kind: 'string', flag: '--platform', target: 'platform', forms: ['equal'] },
  { kind: 'string', flag: '--jsx', target: 'jsx', forms: ['equal'] },
  { kind: 'string', flag: '--jsx-factory', target: 'jsxFactory', forms: ['equal'] },
  { kind: 'string', flag: '--jsx-fragment', target: 'jsxFragment', forms: ['equal'] },
  { kind: 'string', flag: '--jsx-import-source', target: 'jsxImportSource', forms: ['equal'] },
  { kind: 'string', flag: '--global-name', target: 'globalName', forms: ['equal'] },
  { kind: 'string', flag: '--public-path', target: 'publicPath', forms: ['equal'] },
  { kind: 'string', flag: '--entry-names', target: 'entryNames', forms: ['equal'] },
  { kind: 'string', flag: '--chunk-names', target: 'chunkNames', forms: ['equal'] },
  { kind: 'string', flag: '--asset-names', target: 'assetNames', forms: ['equal'] },
  { kind: 'string', flag: '--quotes', target: 'quotes', forms: ['equal'] },
  { kind: 'string', flag: '--log-level', target: 'logLevel', forms: ['equal'] },
  { kind: 'string', flag: '--legal-comments', target: 'legalComments', forms: ['equal'] },
  {
    kind: 'string',
    flag: '--preserve-modules-root',
    target: 'preserveModulesRoot',
    forms: ['equal'],
  },
  { kind: 'string', flag: '--rn-platform', target: 'rnPlatform', forms: ['equal', 'pair'] },
  // #2540 PR #7 — RN preset 의 projectRoot. 기본 cwd, 사용자 monorepo root 지정 시 사용.
  { kind: 'string', flag: '--rn-project-root', target: 'rnProjectRoot', forms: ['equal', 'pair'] },
  // ─── RN CLI 호환 flag 매트릭스 (#2605 audit P0) ───
  // `react-native bundle` / Metro CLI 의 standard flag 들 — `zntc bundle --platform=react-native`
  // 가 dropin 으로 동작하기 위한 호환 layer. zntc 내부 옵션 (outfile 등) 과 별개로 받아 매핑.
  { kind: 'string', flag: '--bundle-output', target: 'bundleOutput' },
  { kind: 'string', flag: '--sourcemap-output', target: 'sourcemapOutput' },
  { kind: 'string', flag: '--source-map-url', target: 'sourceMapUrl' },
  { kind: 'string', flag: '--sourcemap-sources-root', target: 'sourcemapSourcesRoot' },
  { kind: 'string', flag: '--assets-dest', target: 'assetsDest' },
  { kind: 'string', flag: '--asset-catalog-dest', target: 'assetCatalogDest' },
  { kind: 'string', flag: '--bundle-encoding', target: 'bundleEncoding' },
  { kind: 'string', flag: '--unstable-transform-profile', target: 'unstableTransformProfile' },
  { kind: 'string', flag: '--source-root', target: 'sourceRoot', forms: ['equal'] },
  // #2159 — `--output-exports=auto|named|default|none` (Rollup output.exports 호환).
  { kind: 'string', flag: '--output-exports', target: 'outputExports', forms: ['equal'] },
  { kind: 'string', flag: '--banner', target: 'banner', forms: ['equal'] },
  { kind: 'string', flag: '--footer', target: 'footer', forms: ['equal'] },
  { kind: 'string', flag: '--intro', target: 'intro', forms: ['equal'] },
  { kind: 'string', flag: '--outro', target: 'outro', forms: ['equal'] },
  { kind: 'string', flag: '--profile-level', target: 'profileLevel', forms: ['equal'] },
  { kind: 'string', flag: '--profile-format', target: 'profileFormat', forms: ['equal'] },
  { kind: 'string', flag: '--stop-after', target: 'stopAfter', forms: ['equal'] },
  { kind: 'string', flag: '--tokenize-format', target: 'tokenizeFormat', forms: ['equal'] },
  { kind: 'string', flag: '--runtime-polyfills', target: 'runtimePolyfills', forms: ['equal'] },
  { kind: 'string', flag: '--core-js', target: 'coreJs', forms: ['equal'] },

  // ─── kind=string — `--key value` 또는 `--key=value` 둘 다 ───
  { kind: 'string', flag: '--target', target: 'target' },
  { kind: 'string', flag: '--browserslist', target: 'browserslist' },
  { kind: 'string', flag: '--outbase', target: 'outbase' },
  { kind: 'string', flag: '--outfile', target: 'outfile', aliases: ['-o'], forms: ['pair'] },
  { kind: 'string', flag: '--outdir', target: 'outdir', forms: ['pair'] },
  { kind: 'string', flag: '--certfile', target: 'certfile', forms: ['pair'] },
  { kind: 'string', flag: '--keyfile', target: 'keyfile', forms: ['pair'] },
  // tsc-style alias (`-p`, `--project`) + NAPI naming alias (`--tsconfig-path`).
  { kind: 'string', flag: '--project', target: 'project', aliases: ['-p', '--tsconfig-path'] },
  { kind: 'string', flag: '--tsconfig-raw', target: 'tsconfigRaw', forms: ['equal'] },
  { kind: 'string', flag: '--config', target: 'configPath' },
  { kind: 'string', flag: '--mode', target: 'mode' },
  { kind: 'string', flag: '--workspace-config', target: 'workspaceConfig' },
  { kind: 'string', flag: '--workspace', target: 'workspace' },
  { kind: 'string', flag: '--env-dir', target: 'envDir' },
  { kind: 'string', flag: '--entry-html', target: 'entryHtml' },
  { kind: 'string', flag: '--public-dir', target: 'publicDir' },
  { kind: 'string', flag: '--base', target: 'base' },
  { kind: 'string', flag: '--test262', target: 'test262' },
  { kind: 'string', flag: '--host', target: 'host', forms: ['equal'] },

  // ─── kind=int — parseInt ───
  { kind: 'int', flag: '--watch-delay', target: 'watchDelay', forms: ['equal'] },
  { kind: 'int', flag: '--jobs', target: 'jobs', forms: ['equal'] },
  { kind: 'int', flag: '--port', target: 'port' },
  { kind: 'int', flag: '--log-limit', target: 'logLimit', forms: ['equal'] },
  { kind: 'int', flag: '--line-limit', target: 'lineLimit', forms: ['equal'] },
  // Rollup output.experimentalMinChunkSize 류 — 작은 common 청크 자동 병합 (bytes).
  { kind: 'int', flag: '--min-chunk-size', target: 'minChunkSize', forms: ['equal'] },
  // RN CLI 호환 — `--max-workers N` (Metro). zntc `--jobs` 와 의미 동일이므로 alias.
  { kind: 'int', flag: '--max-workers', target: 'jobs', forms: ['equal'] },

  // ─── kind=string-default — bool 단독 시 default, `--key=val` 시 val ───
  { kind: 'string-default', flag: '--metafile', target: 'metafile', default: 'meta.json' },
  { kind: 'string-default', flag: '--spa-fallback', target: 'spaFallback', default: 'index.html' },

  // ─── kind=array — push (반복 지정) ───
  { kind: 'array', flag: '--external', target: 'external' },
  { kind: 'array', flag: '--drop', target: 'drop', forms: ['equal'] },
  // 해석 차단 패턴 (Metro resolver.blockList / webpack IgnorePlugin 호환). 반복 지정.
  { kind: 'array', flag: '--block-list', target: 'blockList', forms: ['equal'] },
  { kind: 'array', flag: '--plugin', target: 'pluginPaths', forms: ['pair'] },
  { kind: 'array', flag: '--runtime-target', target: 'runtimeTargetQueries' },
  // scope hoisting 시 예약할 전역 식별자 (반복 가능). NAPI BuildOptions.globalIdentifiers.
  { kind: 'array', flag: '--global-identifier', target: 'globalIdentifiers', forms: ['equal'] },
  // 번들 시작 시 즉시 실행할 폴리필 경로 / 엔트리 모듈 직전 실행 모듈 (반복 가능, 경로 abs 변환).
  { kind: 'array', flag: '--polyfill', target: 'polyfills', forms: ['equal'] },
  { kind: 'array', flag: '--run-before-main', target: 'runBeforeMain', forms: ['equal'] },
  // 번들 그래프 밖 디렉토리를 감시 루트에 추가 (반복 가능, abs 변환). NAPI BuildOptions.watchFolders.
  // 주의: RN-CLI 호환 csv flag `--watchFolders` (target=rnWatchFolders, 위 csv 섹션) 와 별개 —
  // 이쪽은 zntc 네이티브 watcher, 저쪽은 Metro graph-bundler 경로.
  { kind: 'array', flag: '--watch-folder', target: 'watchFolders', forms: ['equal'] },
  // watchFolders 스캔 시 포함/제외 glob (반복 가능, 루트 기준 상대 경로 — abs 변환 안 함).
  { kind: 'array', flag: '--watch-include', target: 'watchInclude', forms: ['equal'] },
  { kind: 'array', flag: '--watch-exclude', target: 'watchExclude', forms: ['equal'] },

  // ─── kind=csv — `,` 분리 → array ───
  { kind: 'csv', flag: '--drop-labels', target: 'dropLabels', forms: ['equal'] },
  { kind: 'csv', flag: '--env-prefix', target: 'envPrefixes' },
  { kind: 'csv', flag: '--resolve-extensions', target: 'resolveExtensions', forms: ['equal'] },
  { kind: 'csv', flag: '--main-fields', target: 'mainFields', forms: ['equal'] },
  { kind: 'csv', flag: '--conditions', target: 'conditions', forms: ['equal'] },
  { kind: 'csv', flag: '--node-paths', target: 'nodePaths', forms: ['equal'] },
  { kind: 'csv', flag: '--profile', target: 'profile', forms: ['equal'] },
  // RN CLI 호환 (#2605 audit P0) — Metro 의 camelCase flag.
  // 주의: zntc 네이티브 watcher 용 kebab flag `--watch-folder` (target=watchFolders, 위 array 섹션) 와 별개.
  { kind: 'csv', flag: '--watchFolders', target: 'rnWatchFolders' },
  { kind: 'csv', flag: '--sourceExts', target: 'rnSourceExts' },

  // ─── kind=key-value — `--key:K=V` → opts[target][K]=V ───
  { kind: 'key-value', flag: '--define', target: 'define' },
  { kind: 'key-value', flag: '--alias', target: 'alias' },
  // Fallback resolution — 해석 실패 시에만 적용 (webpack resolve.fallback /
  // Metro extraNodeModules 호환). `--fallback:crypto=crypto-browserify`.
  // 값 "false" → 빈-모듈 강제 + specifier 제약은 normalizeFallback 참조.
  { kind: 'key-value', flag: '--fallback', target: 'fallback' },
  { kind: 'key-value', flag: '--loader', target: 'loader' },
  { kind: 'key-value', flag: '--global', target: 'globals' },
  // RN CLI 호환 (#2605 audit P0) — Metro `--transform-option key=value` /
  // `--resolver-option key=value`. 반복 지정 가능. zntc 내부에는 직접 매핑되지
  // 않지만 `runRnBundle` 이 collected dict 를 platform-specific 처리 (현재는
  // 무시 — Metro graph-bundler 전용. 미지원 stderr 경고만).
  { kind: 'key-value', flag: '--transform-option', target: 'transformOptions' },
  { kind: 'key-value', flag: '--resolver-option', target: 'resolverOptions' },

  // ─── kind=ns-array — `--key:VALUE` → opts[target].push(VALUE) ───
  { kind: 'ns-array', flag: '--inject', target: 'inject' },
  { kind: 'ns-array', flag: '--pure', target: 'pure' },

  // ─── kind=ns-string — `--key:NS=VALUE` 호환 alias (NS 무시, banner=value 와 동일) ───
  // BuildOptions 가 단일 string 인 동안 namespace key 는 무의미하지만 esbuild 사용자 호환.
  // 향후 CSS bundling 도입 시 namespace 의미 회복.
  { kind: 'ns-string', flag: '--banner:js', target: 'banner' },
  { kind: 'ns-string', flag: '--footer:js', target: 'footer' },
  { kind: 'ns-string', flag: '--out-extension:.js', target: 'outExtensionJs' },

  // ─── kind=enum-bool — `--key=enumValue` → opts[target] = spec.enum[enumValue] ───
  {
    kind: 'enum-bool',
    flag: '--packages',
    target: 'packagesExternal',
    enum: { external: true },
  },
  { kind: 'enum-bool', flag: '--charset', target: 'charsetUtf8', enum: { utf8: true } },

  // ─── kind=string-bool — default=true 의 toggle. `--key=false` → false, 그 외 → true ───
  { kind: 'string-bool', flag: '--sources-content', target: 'sourcesContent' },
  { kind: 'string-bool', flag: '--tree-shaking', target: 'treeShaking' },
  { kind: 'string-bool', flag: '--scope-hoist', target: 'scopeHoist' },
  { kind: 'string-bool', flag: '--emit-disk-sourcemap', target: 'emitDiskSourcemap' },
  { kind: 'string-bool', flag: '--use-define-for-class-fields', target: 'useDefineForClassFields' },
  { kind: 'string-bool', flag: '--tokenize', target: 'tokenize' },

  // ─── `zntc verify` 전용. 다른 모드와 silent 충돌 방지를 위해 prefix 강제 ───
  { kind: 'int', flag: '--verify-timeout', target: 'verifyTimeout' },
  { kind: 'array', flag: '--verify-ignore', target: 'verifyIgnore' },
  { kind: 'bool', flag: '--verify-allow-console-error', target: 'verifyAllowConsoleError' },
  { kind: 'bool', flag: '--verify-json', target: 'verifyJson' },
  { kind: 'string', flag: '--verify-report', target: 'verifyReport' },
];

/**
 * `--fallback:K=V` 로 수집된 dict 를 BuildOptions.fallback (`Record<string,string|false>`)
 * 으로 정규화. CLI key-value 는 RHS 를 항상 string 으로 수집하므로 `"false"` 를 boolean
 * false (빈-모듈 대체) 로 강제한다. config 가 준 실제 boolean false 는 strict `===` 에
 * 안 걸려 그대로 보존. 빈 dict 는 undefined (NAPI 미전달).
 *
 * 한계: 값이 정확히 `"false"` 인 specifier 는 CLI 로 지정 불가 (항상 빈-모듈로 강제됨).
 * 그 경우는 `zntc.config` 의 `fallback` 을 사용.
 */
export function normalizeFallback(fb) {
  const keys = Object.keys(fb);
  if (keys.length === 0) return undefined;
  return Object.fromEntries(keys.map((k) => [k, fb[k] === 'false' ? false : fb[k]]));
}

/** spec 의 canonical + alias 를 한 array 로. spec.flag (canonical) 항상 첫번째. */
export const flagsOf = (spec) => [spec.flag, ...(spec.aliases ?? [])];

/**
 * 알려진 CLI flag 이름 (canonical + aliases) — typo-suggest 등 외부 소비자가 사용.
 * `--serve`/`--host`/`--proxy` 는 if-chain 잔존이라 미포함 (next-arg optional / 특수 parser).
 */
export const KNOWN_FLAGS = Object.freeze(FLAG_REGISTRY.flatMap(flagsOf).sort());

/**
 * 단일 flag 토큰을 registry spec 들과 매칭. 매칭 시 `{ spec, action, consumed }` 반환.
 * `action` 은 `applyFlagAction(opts, ...)` 가 해석할 결과 (kind 별 형태 다름).
 *
 *  - bool / string-default(단독)         → { type: "set", value }
 *  - string / int                        → { type: "set", value }
 *  - string-default(=val)                → { type: "set", value }
 *  - array / ns-array                    → { type: "push", value }
 *  - csv                                 → { type: "set", value: string[] }
 *  - key-value                           → { type: "kv", key, value }
 *  - ns-string                           → { type: "set", value }
 *  - enum-bool                           → { type: "set", value: bool|undefined }
 *  - string-bool                         → { type: "set", value: bool }
 *  - noop                                → { type: "noop" }
 */
export function matchFlagFromRegistry(arg, args, i) {
  for (const spec of FLAG_REGISTRY) {
    const result = tryMatchSpec(spec, arg, args, i);
    if (result) return result;
  }
  return null;
}

function tryMatchSpec(spec, arg, args, i) {
  const allFlags = flagsOf(spec);
  const formsDefault = ['equal', 'pair'];
  const forms = spec.forms ?? formsDefault;

  switch (spec.kind) {
    case 'bool':
      if (allFlags.includes(arg)) {
        return spec.noop
          ? { spec, action: { type: 'noop' }, consumed: 1 }
          : { spec, action: { type: 'set', value: spec.value ?? true }, consumed: 1 };
      }
      return null;

    case 'string':
    case 'int':
      return tryMatchValueForms(spec, arg, args, i, allFlags, forms, (raw) =>
        spec.kind === 'int' ? parseInt(raw, 10) : raw,
      );

    case 'csv':
      return tryMatchValueForms(spec, arg, args, i, allFlags, forms, (raw) =>
        raw.split(',').filter(Boolean),
      );

    case 'string-default': {
      // 단독 (`--metafile`) → default 값. `--metafile=path` → path.
      if (allFlags.includes(arg)) {
        return { spec, action: { type: 'set', value: spec.default }, consumed: 1 };
      }
      return tryMatchValueForms(spec, arg, args, i, allFlags, ['equal'], (raw) => raw);
    }

    case 'array':
      return tryMatchValueForms(spec, arg, args, i, allFlags, forms, (raw) => raw, 'push');

    case 'ns-array': {
      // `--inject:./prelude` — primary flag 만, alias 미지원. forms 무시.
      const prefix = spec.flag + ':';
      if (arg.startsWith(prefix)) {
        const value = arg.slice(prefix.length);
        return { spec, action: { type: 'push', value }, consumed: 1 };
      }
      return null;
    }

    case 'key-value': {
      // `--define:K=V` — primary flag 만, alias 미지원. forms 무시.
      const prefix = spec.flag + ':';
      if (arg.startsWith(prefix)) {
        const [k, ...v] = arg.slice(prefix.length).split('=');
        return { spec, action: { type: 'kv', key: k, value: v.join('=') }, consumed: 1 };
      }
      return null;
    }

    case 'ns-string': {
      // `--banner:js=text` — spec.flag 가 이미 `--banner:js` 형태. forms=["equal"] 강제.
      const prefix = spec.flag + '=';
      if (arg.startsWith(prefix)) {
        return { spec, action: { type: 'set', value: arg.slice(prefix.length) }, consumed: 1 };
      }
      return null;
    }

    case 'enum-bool': {
      // `--charset=utf8` → opts.charsetUtf8 = true. enum 에 없는 값이면 noop (기존 동작 유지).
      const prefix = spec.flag + '=';
      if (arg.startsWith(prefix)) {
        const raw = arg.slice(prefix.length);
        const mapped = spec.enum[raw];
        if (mapped === undefined) return { spec, action: { type: 'noop' }, consumed: 1 };
        return { spec, action: { type: 'set', value: mapped }, consumed: 1 };
      }
      return null;
    }

    case 'string-bool': {
      // default=true 의 toggle. `--sources-content=false` → false, 그 외 → true.
      if (allFlags.includes(arg)) {
        return { spec, action: { type: 'set', value: true }, consumed: 1 };
      }
      const prefix = spec.flag + '=';
      if (arg.startsWith(prefix)) {
        const raw = arg.slice(prefix.length);
        return { spec, action: { type: 'set', value: raw !== 'false' }, consumed: 1 };
      }
      return null;
    }

    default:
      throw new Error(`unknown flag kind: ${spec.kind}`);
  }
}

function tryMatchValueForms(spec, arg, args, i, allFlags, forms, parseValue, op = 'set') {
  const toAction = (raw, consumed) => {
    const value = parseValue(raw);
    if (spec.kind === 'int' && Number.isNaN(value)) {
      return { spec, action: { type: 'invalid-int', raw }, consumed };
    }
    return { spec, action: { type: op, value }, consumed };
  };

  if (forms.includes('equal')) {
    for (const f of allFlags) {
      // single-letter short flag (`-X`) 는 equal-form 미지원 — esbuild/getopt 관습.
      if (f.length <= 2) continue;
      const prefix = f + '=';
      if (arg.startsWith(prefix)) {
        return toAction(arg.slice(prefix.length), 1);
      }
    }
  }
  if (forms.includes('pair') && allFlags.includes(arg)) {
    const raw = args[i + 1];
    if (raw === undefined) return { spec, action: { type: 'noop' }, consumed: 1 };
    return toAction(raw, 2);
  }
  return null;
}

/**
 * matchFlagFromRegistry 결과를 opts 에 적용. extra 가 있으면 함께 set.
 */
export function applyFlagAction(opts, spec, action) {
  if (action.type === 'invalid-int') {
    console.error(`zntc: ${spec.flag} requires a number: ${action.raw}`);
    opts.parseError = true;
  } else if (action.type === 'noop') {
    // pass — noop spec 또는 누락된 pair-form value
  } else if (action.type === 'set') {
    opts[spec.target] = action.value;
  } else if (action.type === 'push') {
    if (!Array.isArray(opts[spec.target])) opts[spec.target] = [];
    opts[spec.target].push(action.value);
  } else if (action.type === 'kv') {
    if (typeof opts[spec.target] !== 'object' || opts[spec.target] === null) {
      opts[spec.target] = {};
    }
    opts[spec.target][action.key] = action.value;
  }

  if (spec.extra) {
    for (const k of Object.keys(spec.extra)) {
      opts[k] = spec.extra[k];
    }
  }
}
