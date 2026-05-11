# ZNTC Plugin System Design

플러그인 시스템 + 로더 + 특수 기능 상세 설계 문서.

## 설계 원칙
- Rollup 플러그인 API 호환 (resolveId, load, transform, renderChunk, generateBundle)
- Vite 플러그인 확장 지원 (config, configureServer, hotUpdate 등은 후순위)
- N-API 바인딩을 통해 JS 플러그인 실행 (Phase 6)
- Builtin 플러그인은 Zig로 구현하여 최고 성능

## Build Hooks (빌드 단계)
```
┌──────────────┬─────────────────────────────────────────┬──────────┐
│ 훅           │ 용도                                     │ 우선순위  │
├──────────────┼─────────────────────────────────────────┼──────────┤
│ buildStart   │ 빌드 시작 시점 (캐시 초기화 등)           │ 필수      │
│ resolveId    │ 모듈 경로 해석 커스텀 (alias, virtual)    │ 필수      │
│ load         │ 모듈 내용 로딩 (virtual module, 로더)     │ 필수      │
│ transform    │ 코드 변환 (Babel, PostCSS 등)            │ 필수      │
│ buildEnd     │ 빌드 종료 시점                           │ 필수      │
│ moduleParsed │ 모듈 파싱 완료 알림 (moduleInfo)          │ 후순위    │
│ watchChange  │ watch 모드에서 파일 변경 감지             │ 중간      │
│ onLog        │ 로그/경고 필터링 및 조작                  │ 낮음      │
└──────────────┴─────────────────────────────────────────┴──────────┘
```

## Output Hooks (출력 단계)
```
┌──────────────────┬──────────────────────────────────────┬──────────┐
│ 훅               │ 용도                                  │ 우선순위  │
├──────────────────┼──────────────────────────────────────┼──────────┤
│ renderStart      │ 출력 생성 시작                        │ 필수      │
│ renderChunk      │ 청크 코드 후처리 (banner/footer 등)    │ 필수      │
│ generateBundle   │ 번들 생성 완료 (에셋 추가/수정)        │ 필수      │
│ writeBundle      │ 디스크 쓰기 완료 후 콜백               │ 중간      │
│ augmentChunkHash │ 청크 해시에 추가 정보                  │ 낮음      │
│ closeBundle      │ 출력 파일 write 완료 후 cleanup/알림   │ 필수      │
└──────────────────┴──────────────────────────────────────┴──────────┘
```

## Plugin Context API
```
this.emitFile({ type, name, source })  — 에셋/청크 동적 생성
this.getFileName(referenceId)          — emitFile로 만든 파일 이름 조회
this.resolve(source, importer)         — 다른 플러그인의 resolveId 호출
this.parse(code)                       — AST 파싱
this.warn(message) / this.error(msg)   — 진단 메시지
this.addWatchFile(path)                — watch 대상 추가
this.getModuleInfo(id)                 — 모듈 메타데이터 조회
```

## 파이프라인 훅 삽입 지점
```
파일 읽기
  ↓
resolver.resolve()          ← [resolveId 훅] resolver.zig:69, resolve() 시작
  ↓
graph.parseModule()         ← [load 훅] graph.zig:238, readFileAlloc() 직전
  ↓
Transformer.transform()     AST-to-AST 변환 (TS 스트리핑, define 치환)
  ↓
Codegen.generate()          AST → JS 문자열
  ↓                         ← [transform 훅] emitter.zig:1148, codegen 직후
CJS 래핑 등
  ↓                         ← [renderChunk 훅] emitter.zig:700, 청크 완성 후
최종 출력                    ← [generateBundle 훅] bundler.zig:273, 번들 완료 시점
파일 write 완료              ← [closeBundle 훅] JS layer, writeOutputFiles 이후
watch callback 완료          ← [closeBundle 훅] JS layer, onReady/onRebuild 이후
```

현재 JS 플러그인은 `packages/core/index.ts` 의 dispatcher가 NAPI hook 요청을 받아 실행한다.
`buildStart` / `buildEnd` 는 native bundler가 dispatch하고, `closeBundle`은 Rollup 의미
보존을 위해 JS layer가 출력 write 이후에 dispatch한다. `watch()`도 초기 build와 매 rebuild에서
같은 lifecycle을 사용하며, `closeBundle`은 `onReady` / `onRebuild` callback 이후에 호출된다.

## 구현 전략 — 3단계

### 1단계: Zig Builtin 플러그인 ✅ 완료 (PR #521)
- Plugin struct (context + 5개 훅 함수 포인터) + PluginRunner
- 파이프라인 5곳에 훅 삽입 (resolver → graph → emitter → bundler)
- 내부 플러그인 전용 (worklet, refresh 등)

### 2단계: ~~JS 플러그인 — subprocess 방식~~ ❌ 제거 (D101)
> 2단계는 Node.js 자식 프로세스 + stdin/stdout JSON IPC로 구현됐으나, 3단계 NAPI가
> 완성된 이후 **중복 경로가 되어 제거**. 자세한 배경은 [DECISIONS.md](./DECISIONS.md) D101 참조.
>
> JS 플러그인은 이제 **3단계(NAPI) 경로로만** 지원. CLI 사용자는 npm 배포된
> `zntc` 명령(내부적으로 `@zntc/core` NAPI 호출)을 사용하면 동일한 기능 + 더 빠른 속도.

### 3단계: C NAPI 바인딩 ✅ 완료 (기본 경로, #975, #978, #979, #980)
- `zig build napi` → `.node` 공유 라이브러리 빌드
- `@zntc/core` npm 패키지: `transpile()`, `buildSync()`, `build()`, `watch()` API
- esbuild 스타일 JS 플러그인: `onResolve`, `onLoad`, `onTransform`, lifecycle hook
- `napi_threadsafe_function` + mutex/condvar로 워커 스레드 ↔ 메인 스레드 동기화
- Node.js + Bun 모두 지원, 80개 테스트 (1240 expect calls)

```typescript
import { init, build } from "@zntc/core";
init();
const result = await build({
  entryPoints: ["src/index.ts"],
  plugins: [{
    name: "css-plugin",
    setup(build) {
      build.onResolve({ filter: /\.css$/ }, args => ({ path: resolve(args.path) }));
      build.onLoad({ filter: /\.css$/ }, () => ({ contents: 'export default "red"' }));
    },
  }],
});
```

**제한사항**: `buildSync()`에서는 JS 플러그인 미지원 (메인 스레드 데드락). `build()` / `watch()`에서 사용 가능.

### 4단계: Vite/Rollup 호환 어댑터 ✅ 완료 (#992, #1004, #1007)
- `vitePlugin()` 함수로 Rollup 스타일 플러그인을 ZNTC 플러그인으로 변환
- `resolveId`, `load`, `transform`, `renderChunk`, `generateBundle`, lifecycle 훅 지원
- `buildStart`, `buildEnd`, `closeBundle` lifecycle 훅 지원 (`watch()`는 초기 build와 매 rebuild)
- 모든 훅 async/Promise 반환 지원 (`MaybePromise<T>`)
- ZNTC 네이티브 플러그인과 혼합 사용 가능
- `onRenderChunk`: 청크 코드 후처리 (체이닝), `onGenerateBundle`: 번들 완료 콜백
- **미지원**: `this.resolve()`, `this.emitFile()` (후순위)

### 5단계: Tapable 하이브리드 — webpack/Rspack 호환 (예정)
> 방식 C: Zig에 Tapable 스타일 훅을 네이티브로 구현하고 NAPI로 노출.
> 네이티브 속도 + webpack 훅 시스템을 동시에 달성하는 것이 목표.

**왜 하이브리드인가:**
- A (Rspack 방식, 풀 재작성): webpack 호환 90%+이지만 번들러 재설계 필요, ZNTC의 단순함/속도 잃을 위험
- B (어댑터 방식, JS 시뮬레이션): 코어 변경 없지만 플러그인 호출마다 JS 오버헤드
- **C (하이브리드)**: Zig에 훅 포인트 추가 + NAPI 콜백으로 JS에 노출. 플러그인 없으면 오버헤드 제로

**구현 계획:**

```
Zig 코어 (번들러 파이프라인에 Tapable 훅 포인트 추가)
  ↕ NAPI (napi_threadsafe_function)
JS Compiler/Compilation 객체
  ├─ compiler.hooks.compilation.tap(...)
  ├─ compilation.hooks.processAssets.tap(...)
  └─ compilation.hooks.optimizeChunks.tap(...)
```

1단계: Compiler/Compilation 기본 훅 (compile, thisCompilation, compilation, make, emit, done)
2단계: processAssets 6단계 (ADDITIONAL → OPTIMIZE → SUMMARIZE → ...)
3단계: Module/Chunk 훅 (buildModule, succeedModule, optimizeModules, optimizeChunks)
4단계: Loader 호환 (module.rules, loader context)

**우선 구현할 webpack 훅 (실무 사용 빈도 순):**
| 훅 | 사용 빈도 | 용도 |
|---|---|---|
| `compiler.hooks.compilation` | 매우 높음 | compilation 객체 접근 |
| `compilation.hooks.processAssets` | 높음 | 에셋 후처리 (HTML, manifest) |
| `compiler.hooks.emit` | 높음 | 출력 전 에셋 추가/수정 |
| `compiler.hooks.done` | 높음 | 빌드 완료 후 콜백 |
| `module.rules` (loaders) | 매우 높음 | 파일별 변환 (babel-loader 등) |
| `compiler.hooks.afterPlugins` | 중간 | 플러그인 초기화 후 |
| `compilation.hooks.optimizeChunks` | 중간 | 청크 최적화 |

**벤치마크 목표:**
- 플러그인 없음: 현재 ZNTC 성능과 동일 (훅 포인트만 조건 분기, 오버헤드 ~0)
- webpack 플러그인 사용: Rspack과 동등 수준

### 참고: 번들러별 JS 플러그인 아키텍처
| 번들러 | 방식 | 플러그인 모델 |
|--------|------|-------------|
| esbuild | subprocess + JSON IPC | esbuild 전용 (onResolve/onLoad) |
| rolldown | NAPI (napi-rs) | Rollup 호환 (resolveId/load/transform) |
| rspack | NAPI (napi-rs) | webpack 호환 (Tapable compiler.hooks) |
| **ZNTC** | **NAPI (C NAPI)** | **esbuild → Vite → webpack 점진적 확장** |
| Bun | JS 런타임 내장 (JSC) | esbuild 호환 |

## 플러그인 인터페이스
```zig
pub const Plugin = struct {
    name: []const u8,
    resolveId: ?*const fn (specifier: []const u8, importer: ?[]const u8, allocator: Allocator) !?ResolveResult = null,
    load: ?*const fn (path: []const u8, allocator: Allocator) !?[]const u8 = null,
    transform: ?*const fn (code: []const u8, id: []const u8, allocator: Allocator) !?[]const u8 = null,
    renderChunk: ?*const fn (code: []const u8, chunk_name: []const u8, allocator: Allocator) !?[]const u8 = null,
    generateBundle: ?*const fn (output_files: []const OutputFile) void = null,
    buildStart: ?*const fn (ctx: ?*anyopaque) PluginError!void = null,
    buildEnd: ?*const fn (ctx: ?*anyopaque, build_error: ?*const BundlerDiagnostic) PluginError!void = null,
    closeBundle: ?*const fn (ctx: ?*anyopaque) PluginError!void = null,
};
```

## 훅 실행 순서 (다중 플러그인)
- resolveId/load: 첫 번째 non-null 반환 플러그인이 승리 (Rollup first 모드)
- transform/renderChunk: 순차 체이닝 — 이전 플러그인 출력이 다음 플러그인 입력
- generateBundle: 모두 실행 (Rollup parallel 모드)
- lifecycle: `buildStart → buildEnd → closeBundle` 순서로 모두 실행. `buildEnd` / `closeBundle` 에러는 본 build 결과를 가리지 않도록 swallow
- watch lifecycle: `buildStart → buildEnd → onReady/onRebuild → closeBundle` 순서로 초기 build와 매 rebuild마다 실행

## Builtin 플러그인 (Zig 구현)
```
┌────────────────────────┬───────────────────────────────────────┐
│ 플러그인               │ 기능                                   │
├────────────────────────┼───────────────────────────────────────┤
│ json                   │ JSON → export default + named exports  │
│ asset                  │ 이미지/폰트 → 해시 파일명 + URL export │
│ text                   │ 텍스트 파일 → 문자열 export            │
│ glob-import            │ import.meta.glob(...) 처리             │
│ dynamic-import-vars    │ import(`./pages/${name}.ts`) 처리     │
│ wasm                   │ WASM 파일 로딩                         │
└────────────────────────┴───────────────────────────────────────┘
```

## Vite 호환 확장 (4단계)
- resolveId / load / transform — Rollup 호환 (어댑터로 변환)
- renderChunk / generateBundle — 출력 단계 훅
- buildStart / buildEnd / closeBundle — lifecycle 훅
- config / configResolved — 설정 변환
- configureServer — 서버 커스텀
- transformIndexHtml — HTML 변환
- hotUpdate — HMR 업데이트 커스터마이징

## webpack 호환 확장 (5단계)
- Compiler hooks: compilation, emit, done, afterPlugins
- Compilation hooks: processAssets (6단계), optimizeChunks, optimizeModules
- Module/Chunk 객체 노출
- Loader 시스템 (module.rules, pitch, context)

## 구현 순서
1. ✅ 플러그인 인터페이스 정의 (Zig struct) — 1단계
2. ✅ 파이프라인에 훅 호출 삽입 (resolver, graph, emitter) — 1단계
3. ✅ Builtin 플러그인 (json, text, asset) — 1단계
4. ✅ C NAPI .node addon + esbuild 스타일 JS 플러그인 — 3단계
5. ✅ Vite/Rollup 플러그인 어댑터 (`vitePlugin()`) — 4단계
6. Tapable 하이브리드: Zig 훅 포인트 + NAPI 노출 — 5단계
7. webpack Compiler/Compilation 호환 — 5단계
8. Loader 시스템 (module.rules) — 5단계

## 활용 가능한 플러그인

ZNTC가 공식 빌트인이나 레퍼런스 예제로 동봉하지 않지만, 현재 plugin API (`onResolve`/`onLoad`/`transform`) 와 `vitePlugin()` Rollup 호환 어댑터로 다음 시나리오는 모두 활용 가능. 빌트인 통합 (CSS pipeline에 직접 끼우는 등) 은 4단계 Dev Server 통일 (`appDev` 추상화, ROADMAP 4-4) 이후로 일정 정리.

### PostCSS / Tailwind
- 경로 1 — **PostCSS as a plugin**: `transform` 훅에서 `postcss(plugins).process(code, { from, to }).then(r => ({ code: r.css, map: r.map }))`. PostCSS 플러그인 (`autoprefixer`, `tailwindcss`, `postcss-nested`, …) 그대로 import.
- 경로 2 — **Vite/Rollup 어댑터**: 기존 `@vitejs/plugin-*` / `rollup-plugin-postcss` 를 `vitePlugin()` 으로 감싸서 그대로 사용.
- 한계: `appDev` 컨트롤러가 현재 postcss/sass 를 **직접** 호출 (`zntc.mjs:runServe`) 하기 때문에, plugin API 경로와 컨트롤러 경로가 병행 존재. 사용자가 양쪽을 동시에 켜면 중복 변환 가능 — 4-4 단계에서 단일 plugin 경로로 통합 예정.

### SVG
- 경로 1 — **`onLoad` 직접**: `.svg` 확장자 필터로 파일 텍스트를 읽어 `export default ${JSON.stringify(svgText)}` (raw) / `export default "data:image/svg+xml;base64,..."` (data URL) / `import { ReactComponent } from "..."` (JSX wrapper) 중 원하는 형태로 변환.
- 경로 2 — **Vite 어댑터**: `vite-plugin-svgr` 같은 기존 플러그인을 `vitePlugin()` 으로 활용.
- 한계: ZNTC 빌트인 `asset` 로더 (`--loader:.svg=file|dataurl`) 는 raw URL / data URL 만 지원. JSX 컴포넌트 변환은 사용자 plugin 필요.

### YAML
- 경로 1 — **`onLoad` 직접**: `.yaml`/`.yml` 확장자 필터에서 `yaml` (eemeli/yaml) 등 npm 파서로 파싱 후 `export default ${JSON.stringify(data)}` 로 emit. 결과는 JSON-loader 와 동일한 named exports + default export 형태로 ZNTC tree-shaker 가 흡수.
- 경로 2 — **Rollup 어댑터**: `@rollup/plugin-yaml` 을 `vitePlugin()` 으로 활용.
- 한계: 동적 YAML 파일 watcher 통합은 ZNTC HMR `import.meta.hot.accept` 로 사용자가 명시.

> 참고: 위 시나리오들은 모두 npm 의존성을 사용자 측에서 제공한다 (ZNTC 가 PostCSS / Tailwind / yaml 파서를 묶지 않음). 정식 레퍼런스 예제 (`examples/postcss`, `examples/tailwind`, ...) 는 ROADMAP "3단계 생태계" 에 트래킹되어 있고 미공급 상태.

## 참고
- Rollup/Rolldown: `references/rolldown/packages/rolldown/src/plugin/index.ts`
- Vite: `references/vite/packages/vite/src/node/plugin.ts`
- esbuild: `references/esbuild/pkg/api/api.go` (OnResolve, OnLoad)

---

## 로더 시스템 (esbuild/Rolldown 호환)

현재 ZNTC는 .ts/.tsx/.js/.jsx/.css를 네이티브 처리. 그 외는 플러그인의 load 훅으로 구현:
- **CSS**: `import './style.css'` → 별도 `.css` 파일 emit, `@import` 인라이닝, `--minify` 시 Lightning CSS
- **JSON**: `import pkg from './package.json'` → `export default {...}` + named exports
- **Text**: 파일 내용을 문자열로 `export default "..."`
- **Base64**: 파일을 base64 인코딩 `export default "data:...;base64,..."`
- **DataURL**: 파일을 data URL로 export
- **Binary**: 파일을 Uint8Array로 export
- **File/Asset**: 파일을 출력 디렉토리에 복사, 해시 파일명 URL 반환
- **Copy**: 파일을 그대로 복사
- **Empty**: 빈 모듈로 처리 (tree-shaking 대상, `--loader:.css=empty`로 CSS 무시 가능)

CLI: `--loader:.json=json --loader:.txt=text --loader:.png=file --loader:.css=empty`

---

## 특수 기능 (Vite/Rolldown 호환)

### import.meta.glob (Vite 킬러 기능)
```typescript
// 기본 — lazy import
const modules = import.meta.glob('./modules/*.ts')
// → { './modules/a.ts': () => import('./modules/a.ts'), ... }

// eager — 빌드타임 인라인
const modules = import.meta.glob('./modules/*.ts', { eager: true })

// named import만
const defaults = import.meta.glob('./modules/*.ts', { import: 'default' })

// 부정 패턴
const modules = import.meta.glob(['./src/**/*.ts', '!**/*.test.ts'])
```
구현: 렉서에서 `import.meta.glob` 감지 → 파서에서 인자 분석 → 트랜스포머에서 glob 매칭 + 코드 생성

### Dynamic Import Variables
```typescript
import(`./pages/${name}.ts`)
// → glob 패턴으로 확대하여 가능한 모듈 전부 번들에 포함
```

### Web Workers
```typescript
new Worker(new URL('./worker.ts', import.meta.url))
// → 워커 파일을 별도 엔트리로 번들링
```

### Virtual Modules
- resolveId 훅에서 `\0` 프리픽스로 가상 모듈 마킹
- load 훅에서 가상 모듈 내용 반환
- 파일시스템에 존재하지 않는 모듈 생성 가능

---

## CLI 옵션 상태 (esbuild/Rolldown 호환)

### 현재 노출
- `--banner=...` / `--banner:js=...`, `--footer=...` / `--footer:js=...`
- `--analyze`, `--metafile`
- `--minify-whitespace` / `--minify-identifiers` / `--minify-syntax`
- `--log-level`, `--log-limit`
- `--legal-comments`
- `--target`, `--browserslist`
- `--keep-names`
- `--packages=external`
- `--out-extension:.js=.mjs`, `--outbase`
- `--charset=utf8`, `--ascii-only`, `--sources-content=false`, `--source-root`
- `--public-path`, `--inject:file`
- `--pure:Name`, `--pure:Namespace.member`, `--pure:Namespace.*`
- `--preserve-symlinks`
- `--watch-delay`
- `--line-limit`
- `--certfile`, `--keyfile`

### CLI에 노출됨

- `--tsconfig-raw` — tsconfig JSON 문자열 오버라이드

### 아직 CLI에 미노출
- `--conditions`, `--node-paths` — resolver 조건/추가 탐색 경로
- `--ignore-annotations`, `--jsx-side-effects`
- `--mangle-props`, `--mangle-cache`, `--reserve-props`
- `--log-override`
- CORS 설정
