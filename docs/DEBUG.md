# Debug Logging

런타임에 진단 로그를 카테고리별로 켜고 끄는 경량 인프라. ZTS 바이너리와 `@zts/core` NAPI 양쪽에서 동일 구조로 동작한다.

- 구현: `src/debug_log.zig`
- 활성 카테고리 enum: `src/debug_log.zig` 의 `Category`
- 동작: 프로세스 전역 비트마스크. 비활성 카테고리의 로그 호출은 단일 `bool` 분기 이후 바로 리턴 — hot path 에서도 부담 없음.

## 활성화

### 환경 변수
```bash
ZTS_DEBUG=compiled_cache zts --bundle entry.ts
ZTS_DEBUG=compiled_cache,hmr bun run bungae:start
```

쉼표 구분. 공백과 대소문자 무시. 알 수 없는 이름은 조용히 무시된다.

### NAPI 옵션
```ts
import { build } from "@zts/core";

await build({
  entryPoints: ["src/index.ts"],
  debug: ["compiled_cache"],
});
```

`ZTS_DEBUG` env 와 **합집합** — 한쪽만 설정해도 충분하고, 둘 다 설정하면 양쪽 카테고리 모두 활성.

### CLI 플래그
별도 플래그 없음. env 로 전달하는 게 충분하다고 판단 (개별 실행/watch/NAPI 에서 일관된 UX).

## 카테고리

현재 정의된 카테고리:

| 이름 | 출력 내용 | 추가된 PR |
|------|-----------|-----------|
| `compiled_cache` | HMR/watch 의 compiled output cache hit/miss 집계 | RFC #1672 B2 |

추가 시: `src/debug_log.zig` 의 `Category` enum 에 이름만 추가 → 사용처에서 `debug_log.print(.new_category, ...)` 호출 → 이 표 업데이트.

## 출력 형식

```
[<category>] key1=value1 key2=value2 ...
```

- prefix: `[<category>]` — 카테고리 구분 + grep 친화
- 본문: 자유 형식 (사용처가 `std.fmt` 포맷 문자열 직접 제공). 권장은 `key=value` 공백 구분
- 목적지: `stderr` — stdout 이 bundle output 일 수 있으므로

예시:
```
[compiled_cache] first=false hits=3 misses=1 no_mtime_skipped=0 (entries=4)
```

## 코드 사용법

```zig
const debug_log = @import("debug_log.zig");  // 또는 @import("zts_lib").debug_log

// 단순 로그
debug_log.print(.compiled_cache, "hits={d} misses={d}\n", .{ hits, misses });

// 비싼 format 계산은 enabled 체크 후에
if (debug_log.enabled(.compiled_cache)) {
    const summary = try buildSummary(allocator);
    defer allocator.free(summary);
    debug_log.print(.compiled_cache, "{s}\n", .{summary});
}
```

## 초기화 시점

- **CLI (`src/main.zig`)**: `pub fn main()` 진입 직후 `debug_log.initFromEnv(allocator)` 호출
- **NAPI (`packages/core/src/napi_entry.zig`)**: `napi_register_module_v1` 에서 1회 호출
- **BundleOptions**: `Bundler.init` / `Bundler.initWithResolveCache` 가 `opts.debug` 리스트를 `addCategories` 로 merge

모든 진입점이 `addFromCsv` / `addCategories` 로 **합집합**을 갱신하므로 중복 호출 안전.

## 스레드 안전성

`enabled_mask` 는 단일 `u64`. `initFromEnv` / `addCategories` 는 프로세스 시작 직후 또는 `Bundler.init` 시점에만 호출된다고 가정하며, 로그 호출 시점에는 **read-only** 로 사용된다. 일반적인 ZTS 호출 흐름에서는 mask 변경과 `enabled` 조회가 교차하지 않아 별도 동기화는 두지 않는다.

## 장기 확장

- 카테고리 세부 레벨 (info/debug/trace) 필요하면 `Category` 를 `{category, level}` 쌍으로 확장
- 구조화 출력 (JSON) 이 필요하면 별도 포매터 분기 — env `ZTS_DEBUG_FORMAT=json` 등
- 와일드카드 (`ZTS_DEBUG=*` 혹은 `ZTS_DEBUG=bundler:*`) 는 현재 미지원. 카테고리 수가 많아지기 전에는 쉼표 구분이 충분
