# ZTS Dev Server & HMR Design

Dev 서버 + Hot Module Replacement 상세 설계 문서.

## 의사결정

### D056. HTTP 서버: `std.http.Server` (Zig 표준 라이브러리)
- Bun은 uWebSockets(C++) 사용하지만, Bun.serve()가 프로덕션 서버를 겸하기 때문
- ZTS dev server는 로컬 개발 전용 (동시 접속 1-2개) → std.http.Server로 충분
- 외부 C/C++ 의존성 없음, WASM 빌드 영향 없음
- 나중에 성능 병목 시 uWebSockets로 교체 가능 (인터페이스 동일하게 설계)

### D057. HMR API: `import.meta.hot` 기본 + `module.hot` 어댑터
- 웹 타겟: `import.meta.hot` (Vite 호환, ESM 네이티브)
- RN 타겟: `module.hot` (Metro 호환, RN 내장 HMRClient 재사용)
- 내부 HMR 엔진은 하나, API 표면만 다름
- Rolldown 계열도 동일 방식: `import.meta.hot` 기본 + metro-runtime HMRClient 교체 플러그인

### D058. HMR 프로토콜: Vite 호환 + Metro 어댑터
- 웹: Vite HMR 프로토콜 (WebSocket JSON 메시지)
- RN: Metro HMR 프로토콜 (`update-start` → `update` → `update-done`)
- 자체 프로토콜 방식은 RN 업데이트마다 호환성 검증 필요 → Metro 호환이 유지보수 비용 낮음

### D059. 동시성: `std.Thread.spawn` per-connection
- esbuild goroutine과 유사
- dev server 전용이라 OS 스레드 10-20개면 충분
- WS 클라이언트 목록: mutex 보호 고정 배열 (Metro와 동일 패턴)

### D060. import.meta.hot: 모듈 래핑 dev 번들 방식 (A안 채택)
- dev 모드에서 각 모듈을 함수로 감싸고 레지스트리에 등록
- 변경 시 해당 모듈 함수만 재실행 (full-reload 대신)
- emitter에 dev 모드 추가, 프로덕션 빌드(scope hoisting)는 그대로 유지
- B안(언번들 ESM, Vite 방식) 배제: dev/prod 동작 차이로 인한 버그 위험
- C안(API 스텁 + full-reload) 배제: 실질적 가치 없음

## HMR API 비교
```
┌─────────────┬─────────────────────┬─────────────────────────────┐
│ 번들러       │ HMR API             │ 이유                         │
├─────────────┼─────────────────────┼─────────────────────────────┤
│ Webpack 5   │ module.hot          │ CJS 레거시                   │
│ Rspack      │ module.hot          │ Webpack 호환                 │
│ Turbopack   │ module.hot          │ Webpack 호환 (Next.js)       │
│ Vite        │ import.meta.hot     │ ESM 네이티브                 │
│ Rolldown    │ import.meta.hot     │ Vite 호환                    │
│ Metro       │ module.hot (커스텀)  │ CJS + RN 내장 HMRClient     │
│ ZTS (결정)  │ import.meta.hot 기본 │ Vite 호환 + RN module.hot   │
└─────────────┴─────────────────────┴─────────────────────────────┘
```

## 구현 순서 (✅ 전체 완료)
```
기반 인프라:
  1. ✅ HTTP 정적 서버 (std.http.Server) — PR #260
  2. ✅ 번들 서빙 (on-the-fly 번들링) — PR #261
  3. ✅ WebSocket 서버 (RFC 6455) — PR #262
  4. ✅ Live Reload (thread-per-connection + watch → full-reload) — PR #263
  5. ✅ 모듈 그래프 전체 파일 감시 — PR #266

즉시 가치:
  6. ✅ 에러 오버레이 — PR #267
  7. ✅ 소스맵 서빙 — PR #272
  8. ✅ SPA 폴백 — PR #269

핵심 HMR:
  9. ✅ import.meta.hot API — PR #270, #271
  10. ✅ React Fast Refresh — PR #273, #274
  11. ✅ CSS 핫 리로드 — PR #275
```

## 아키텍처
```
브라우저/RN 앱
    │
    ├─ HTTP GET /bundle.js ──→ ZTS Dev Server ──→ on-the-fly 번들링 ──→ 응답
    │
    └─ WebSocket /__hmr ─────→ HMR 채널
                                  │
         파일 변경 감지 (watch) ──→ 모듈 그래프 diff
                                  │
                                  ├─ 변경 모듈만 재빌드
                                  ├─ HMR 업데이트 메시지 전송
                                  └─ 클라이언트: accept → 모듈 재실행 → React Refresh
```

## 참고 프로젝트
- **Rolldown**: `references/rolldown/` — Rolldown DevEngine, `import.meta.hot`
- **Metro**: `references/metro/packages/metro-runtime/` — `module.hot`, Metro HMR 프로토콜
- **Vite**: `references/vite/packages/vite/src/client/` — `import.meta.hot`, Vite HMR 프로토콜
- **esbuild**: `--serve` 모드 — 최소 구현 참고

## HMR Profiling

HMR rebuild 의 각 phase 소요시간은 `WatchRebuildEvent.phaseDurations` 에 노출된다.
`ZTS_PROFILE=hmr` 또는 `BUNGAE_HMR_PROFILE=1` 활성 시 sub-phase breakdown 수집 가능.

자세한 내용: [`docs/DEBUG.md`](./DEBUG.md) § 4 HMR Profile.

기본 측정 항목 (항상):
- `detect` / `graph` / `link` / `shake` / `emit` / `delta` / `total`

Sub-phase (profile 활성 시):
- 파이프라인: `scan` / `parse` / `resolve` / `semantic` / `transform` / `codegen` / `metadata`
- Graph 내부: `graphBuild` / `graphWorker`
- Emit 내부: `emitPolyfill` / `emitRefresh` / `emitOutput` / `emitMetafile` / `emitCss`

```ts
watch({
  entryPoints: ["src/index.ts"],
  profile: ["hmr"],
  onRebuild: (event) => {
    const pd = event.phaseDurations!;
    console.log(`total=${pd.total}ms emit=${pd.emit}ms transform=${pd.transform}ms`);
  },
});
```
