# AST Plugin System

## 개요

ZTS의 AST 플러그인 시스템은 transformer 내부에서 AST 노드 방문 시 호출되는 훅을 제공한다.
기존 string-based 플러그인(`onTransform`: 코드 문자열 → 코드 문자열)과 달리,
AST 레벨에서 스코프 분석, closure 변수 추출, 프로퍼티 주입 등이 가능하다.

## 아키텍처

```
Plugin (plugin.zig) — 통합 인터페이스
├── String 훅: resolveId, load, transform, renderChunk, generateBundle
└── AST 훅:    onFunction (향후: onClass, onNode)

두 훅 유형이 하나의 Plugin struct에 공존.
string-only 플러그인은 AST 훅이 null, AST-only 플러그인은 string 훅이 null.
```

## 플러그인 제공 형태

### 1. JS 플러그인 (외부 개발 가능)

npm 패키지로 배포. `build.onAstFunction()`으로 등록.

```typescript
// zts-plugin-worklet (npm 패키지)
export default {
  name: 'worklet',
  setup(build) {
    build.onAstFunction({ filter: /\.tsx?$/ }, (info) => {
      if (info.directives.includes('worklet')) {
        return {
          stripDirective: 'worklet',
          trailingCode: [
            `${info.name}.__workletHash = ${hash(info.bodyText)};`,
            `${info.name}.__closure = { ${info.closureVars.join(', ')} };`,
          ],
        };
      }
      return null;
    });
  },
};
```

**장점**: npm install → 설정에 추가 → 즉시 사용. 언어: JS/TS.
**단점**: NAPI 오버헤드 (Zig↔JS 왕복). JSON 직렬화 비용.

### 2. Zig 내장 플러그인 (ZTS 코어에 포함)

`src/transformer/plugins/` 디렉토리에 구현. `builtin.zig` 프리셋에 등록.

```zig
// src/transformer/plugins/worklet_plugin.zig
pub fn plugin() Plugin {
    return .{
        .name = "reanimated-worklet",
        .onFunction = onFunction,
    };
}
```

```zig
// src/transformer/plugins/builtin.zig
if (options.worklet) {
    merged[i] = worklet_plugin.plugin();
}
```

**장점**: 네이티브 속도 (오버헤드 0). AST 직접 조작.
**단점**: ZTS 소스에 포함되어야 함. 추가 시 ZTS 재빌드 필요.

### 3. 공유 라이브러리 (검토 완료, 미구현)

`.dylib`/`.so`/`.dll`로 컴파일된 Zig 플러그인을 `dlopen`으로 런타임 로드.

```bash
zts --bundle entry.ts --ast-plugin ./libworklet.dylib
```

**장점**: 네이티브 속도. 외부 배포 가능.
**단점**:
- Zig ABI 버전이 ZTS와 일치해야 함 (Zig는 stable ABI가 없음)
- `Plugin` struct 레이아웃 변경 시 플러그인 재빌드 필요
- OS별 바이너리 3개 필요 (macOS/Linux/Windows)
- 보안: 샌드박스 없이 프로세스 메모리 공유

**결론**: Zig의 ABI 불안정성으로 인해 현 시점에서는 비실용적.

### 4. WASM 플러그인 (검토 완료, 미구현)

`.wasm`으로 컴파일된 플러그인을 WASM 런타임(wasmtime 등)에서 실행.

```bash
zts --bundle entry.ts --ast-plugin ./worklet.wasm
```

**장점**: 언어 무관 (Zig, Rust, C 등). 샌드박스 안전. ABI 안정적 (WASM 스펙).
**단점**:
- ZTS에 WASM 런타임 임베딩 필요 (바이너리 크기 증가)
- 네이티브 대비 ~80% 성능
- 개발 복잡도 높음

**결론**: 수요가 생기면 고려. SWC가 이 방식을 사용하므로 참고 가능.

## 현재 결정

| 형태 | 상태 | 대상 |
|------|------|------|
| JS 플러그인 | ✅ 구현 완료 | 외부 개발자, 커뮤니티 |
| Zig 내장 플러그인 | ✅ 구현 완료 | 성능 크리티컬 (worklet 등) |
| 공유 라이브러리 | ❌ 미구현 | Zig ABI 불안정으로 보류 |
| WASM 플러그인 | ❌ 미구현 | 수요 발생 시 검토 |

**전략**: 외부 개발자는 JS 플러그인 API를 사용. 성능이 중요한 플러그인은 ZTS 코어에 PR로 제출하여 내장 프리셋에 포함.

## JS AST Plugin API

### AstFunctionInfo (Zig → JS)

```typescript
interface AstFunctionInfo {
  name: string | null;         // 함수 이름 (null = 익명)
  directives: string[];        // body 첫 문장 디렉티브 (["worklet"] 등)
  closureVars: string[];       // 외부 참조 변수 (디렉티브 있을 때만 계산)
  params: string[];            // 파라미터 이름
  sourcePath: string;          // 소스 파일 경로
  bodyText: string;            // body 소스 텍스트
  flags: { async: boolean; generator: boolean };
}
```

### AstFunctionResult (JS → Zig)

```typescript
interface AstFunctionResult {
  stripDirective?: string;     // 제거할 디렉티브
  trailingCode?: string[];     // 함수 뒤에 삽입할 코드 문자열
}
```

### 실행 흐름

```
Transformer.visitFunction() 완료
    ↓
Plugin.onFunction 훅 호출 (모든 플러그인 순회)
    ↓
Zig 플러그인: AstTransformCtx API로 직접 AST 조작
JS 플러그인:  FunctionInfo JSON 직렬화 → NAPI → JS callback
              → AstFunctionResult 반환 → Zig가 해석 + AST 반영
    ↓
modified_body가 있으면 result 노드 패치
trailing_nodes가 있으면 함수 뒤에 삽입
```

## 내장 플러그인 추가 방법

1. `src/transformer/plugins/my_plugin.zig` 생성
2. `Plugin` 인터페이스 구현 (`onFunction` 등)
3. `builtin.zig`에 옵션 + 조건 추가
4. `EmitOptions`에 활성화 플래그 추가
5. `main.zig` 프리셋에서 플래그 설정
