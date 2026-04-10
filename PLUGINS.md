# ZTS Plugin System Design

> 플러그인 시스템 + 로더 + 특수 기능 상세 설계. 핵심 정보는 [CLAUDE.md](./CLAUDE.md) 참조.

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
│ moduleParsed │ 모듈 파싱 완료 알림 (moduleInfo)          │ 중간      │
│ buildEnd     │ 빌드 종료 시점                           │ 필수      │
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
│ closeBundle      │ 번들 완전 종료                        │ 낮음      │
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
```

**수정 대상 파일:**
```
┌──────────────────────┬───────────────────────────────────────┬──────────┐
│ 파일                  │ 변경 내용                              │ 난이도    │
├──────────────────────┼───────────────────────────────────────┼──────────┤
│ bundler.zig          │ BundleOptions에 plugins 배열 추가 + 전파│ 쉬움     │
│ resolver.zig:69      │ resolve() 시작에 resolveId 훅 호출     │ 쉬움     │
│ graph.zig:238        │ parseModule()에 load 훅 호출           │ 중간     │
│ emitter.zig:1148     │ codegen 후 transform 훅 호출           │ 쉬움     │
│ emitter.zig:700      │ 청크 완성 후 renderChunk 훅 호출       │ 중간     │
└──────────────────────┴───────────────────────────────────────┴──────────┘
```

## 구현 전략 — 3단계

### 1단계: Zig Builtin 플러그인 ✅ 완료 (PR #521)
- Plugin struct (context + 5개 훅 함수 포인터) + PluginRunner
- 파이프라인 5곳에 훅 삽입 (resolver → graph → emitter → bundler)
- context: ?*anyopaque로 subprocess 플러그인 상태 전달 지원 (PR #522)

### 2단계: JS 플러그인 — subprocess 방식 ✅ 완료 (PR #523, #524, #525)
- SubprocessPlugin: Node.js child process spawn + stdin/stdout JSON IPC
- @zts/plugin npm 패키지: definePlugin(), build.onResolve/onLoad/onTransform
- CLI: `--plugin <path>` 옵션으로 JS 플러그인 파일 지정
- suffix 기반 필터 매칭 (.css, .svg 등)으로 IPC 호출 최소화
- **제한사항**: 현재 load 훅은 JS 모듈 파싱 경로에서만 동작. 비-JS 확장자(.css 등)를 JS로 변환하려면 graph.zig의 module_type 결정 로직 확장 필요.

```
ZTS (Zig 바이너리)
  ↕ stdin/stdout JSON
Node.js (JS 플러그인 호스트)
  ├─ 사용자 플러그인 코드
  ├─ PostCSS / Lightning CSS / Babel 등
  └─ @zts/plugin npm 패키지 (JSON 프로토콜 래퍼)
```

### 3단계: C NAPI 바인딩 ✅ 완료 (#975, #978, #979, #980)
- `zig build napi` → `.node` 공유 라이브러리 빌드
- `@zts/core` npm 패키지: `transpile()`, `buildSync()`, `build()` API
- esbuild 스타일 JS 플러그인: `onResolve`, `onLoad`, `onTransform`
- `napi_threadsafe_function` + mutex/condvar로 워커 스레드 ↔ 메인 스레드 동기화
- Node.js + Bun 모두 지원, 80개 테스트 (1240 expect calls)

```typescript
import { init, build } from "@zts/core";
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

**제한사항**: `buildSync()`에서는 JS 플러그인 미지원 (메인 스레드 데드락). `build()` (async)에서만 사용 가능.

### 4단계: Vite/Rollup 호환 어댑터 (예정)
- Vite/Rollup 플러그인(`resolveId`, `load`, `transform`, `renderChunk`, `generateBundle`)을
  3단계의 esbuild 스타일 API로 변환하는 JS 어댑터
- Zig 코어 수정 없이 JS 레이어에서 처리
- `this.resolve()`, `this.emitFile()` 등 Rollup 컨텍스트 메서드 구현

### 5단계: Tapable 하이브리드 — webpack/Rspack 호환 (예정)
> 방식 C: Zig에 Tapable 스타일 훅을 네이티브로 구현하고 NAPI로 노출.
> 네이티브 속도 + webpack 훅 시스템을 동시에 달성하는 것이 목표.

**왜 하이브리드인가:**
- A (Rspack 방식, 풀 재작성): webpack 호환 90%+이지만 번들러 재설계 필요, ZTS의 단순함/속도 잃을 위험
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
- 플러그인 없음: 현재 ZTS 성능과 동일 (훅 포인트만 조건 분기, 오버헤드 ~0)
- webpack 플러그인 사용: Rspack과 동등 수준

### 참고: 번들러별 JS 플러그인 아키텍처
| 번들러 | 방식 | 플러그인 모델 |
|--------|------|-------------|
| esbuild | subprocess + JSON IPC | esbuild 전용 (onResolve/onLoad) |
| rolldown | NAPI (napi-rs) | Rollup 호환 (resolveId/load/transform) |
| rspack | NAPI (napi-rs) | webpack 호환 (Tapable compiler.hooks) |
| **ZTS** | **NAPI (C NAPI)** | **esbuild → Vite → webpack 점진적 확장** |
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
};
```

## 훅 실행 순서 (다중 플러그인)
- resolveId/load: 첫 번째 non-null 반환 플러그인이 승리 (Rollup first 모드)
- transform/renderChunk: 순차 체이닝 — 이전 플러그인 출력이 다음 플러그인 입력
- generateBundle: 모두 실행 (Rollup parallel 모드)

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
4. ✅ subprocess JSON 프로토콜 (JS 플러그인 호스트) — 2단계
5. ✅ @zts/plugin npm 패키지 (JS API 래퍼) — 2단계
6. ✅ C NAPI .node addon + esbuild 스타일 JS 플러그인 — 3단계
7. Vite/Rollup 플러그인 어댑터 (JS 레이어) — 4단계
8. Tapable 하이브리드: Zig 훅 포인트 + NAPI 노출 — 5단계
9. webpack Compiler/Compilation 호환 — 5단계
10. Loader 시스템 (module.rules) — 5단계

## 참고
- Rollup/Rolldown: `references/rolldown/packages/rolldown/src/plugin/index.ts`
- Vite: `references/vite/packages/vite/src/node/plugin.ts`
- esbuild: `references/esbuild/pkg/api/api.go` (OnResolve, OnLoad)

---

## 로더 시스템 (esbuild/Rolldown 호환)

현재 ZTS는 .ts/.tsx/.js/.jsx만 처리. 플러그인의 load 훅으로 구현:
- **JSON**: `import pkg from './package.json'` → `export default {...}` + named exports
- **Text**: 파일 내용을 문자열로 `export default "..."`
- **Base64**: 파일을 base64 인코딩 `export default "data:...;base64,..."`
- **DataURL**: 파일을 data URL로 export
- **Binary**: 파일을 Uint8Array로 export
- **File/Asset**: 파일을 출력 디렉토리에 복사, 해시 파일명 URL 반환
- **Copy**: 파일을 그대로 복사
- **Empty**: 빈 모듈로 처리 (tree-shaking 대상)

CLI: `--loader:.json=json --loader:.txt=text --loader:.png=file`

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

## CLI 옵션 추가 계획 (esbuild/Rolldown 호환)

### Tier 1 (높은 우선순위)
- `--banner:js=...` / `--footer:js=...` — 출력 앞뒤 텍스트 추가
- `--analyze` — 번들 사이즈 리포트
- `--minify-whitespace` / `--minify-identifiers` / `--minify-syntax` — 세분화 minify
- `--pure:Name` — 함수 단위 pure 마킹 (tree-shaking)
- `--log-level` (verbose|debug|info|warning|error|silent)
- `--legal-comments` (none|inline|eof|linked|external)
- `--servedir` — 추가 정적 디렉토리

### Tier 2 (중간 우선순위)
- `--target` 엔진 버전 (chrome58, node10 등) — 현재 ES 타겟만
- `--keep-names` — minify 시 함수/클래스 이름 보존
- `--out-extension:.js=.mjs` — 출력 확장자 변경
- `--outbase` — 엔트리 출력 경로 기준
- `--charset=utf8` — UTF-8 코드포인트 이스케이프 안 함
- `--sources-content=false` — 소스맵에서 소스 내용 제외
- `--source-root` — 소스맵 sourceRoot 필드
- `--public-path` — 에셋 기본 URL (CDN 배포용)
- `--inject:file` — 모든 입력에 파일 자동 import
- HTTPS dev server (--certfile, --keyfile)
- CORS 설정

### Tier 3 (낮은 우선순위)
- `--mangle-props` + `--mangle-cache` — 프로퍼티 맹글링
- `--reserve-props` — 맹글링 예외
- `--ignore-annotations` — tree-shaking 어노테이션 무시
- `--preserve-symlinks` — 심링크 해석 비활성화
- `--tsconfig-raw` — tsconfig JSON 문자열 오버라이드
- `--watch-delay` — 리빌드 디바운스
- `--log-limit` / `--log-override` — 세분화 로깅
