# ZTS - Zig TypeScript Transpiler

## Project Overview
Zig로 작성하는 JavaScript/TypeScript/Flow 트랜스파일러. SWC/oxc 수준의 프로덕션 레벨 품질을 목표로 하는 학습 + 실용 프로젝트. 추후 번들러까지 확장 예정.

## Tech Stack
- **Language**: Zig 0.15.2
- **Version Manager**: mise
- **Build**: `zig build` (build.zig)
- **Test**: `zig build test`
- **Test262**: `zig build test262`

## Documentation

- **[docs/STRUCTURE.md](./docs/STRUCTURE.md)** — 프로젝트 디렉토리 구조 (src/, packages/, references/)
- **[docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md)** — 파이프라인 아키텍처 + 설계 결정 요약
- **[docs/ROADMAP.md](./docs/ROADMAP.md)** — Phase 현황, 성능, 미지원 기능, 배치 계획, 기술부채
- **[docs/TESTING.md](./docs/TESTING.md)** — Test262, 유닛 테스트, 통합 테스트, 스모크 테스트

### 상세 설계 문서
- **[BUNDLER.md](./BUNDLER.md)** — 번들러 상세 설계 (경쟁 환경, 모듈 설계, tree-shaking, RN 지원, 외부 통합)
- **[PLUGINS.md](./PLUGINS.md)** — 플러그인 시스템 + 로더 + 특수 기능 + CLI 옵션 추가 계획
- **[HMR.md](./HMR.md)** — Dev server + HMR 의사결정/아키텍처
- **[DECISIONS.md](./DECISIONS.md)** — 전체 의사결정 기록
- **[FLOW.md](./FLOW.md)** — Flow 지원 전략

## Commands
```bash
zig build          # 빌드
zig build run      # 실행
zig build test     # 유닛 테스트
zig build test262  # Test262 러너 테스트
```

## ZTS CLI 옵션 (현재 지원)

### 트랜스파일
```bash
zts <file.ts>                    # 트랜스파일 → stdout
zts <file.ts> -o <out.js>       # 트랜스파일 → 파일
zts <dir/> --outdir <out/>      # 디렉토리 재귀 변환
zts - < input.ts                # stdin 입력
```

### 번들
```bash
zts --bundle <entry.ts>                          # 번들 → stdout
zts --bundle <entry.ts> -o out.js                # 번들 → 파일
zts --bundle <entry.ts> --splitting --outdir dist  # 코드 스플리팅
zts --bundle <entry.ts> --plugin zts.config.js     # JS 플러그인
```

### 공통 옵션
```
--format=esm|cjs|iife            모듈 포맷 (기본: esm, --platform=browser 시 iife)
--platform=browser|node|neutral  타겟 플랫폼 (기본: browser)
--minify                         출력 압축
--sourcemap                      소스맵 생성 (.js.map)
--ascii-only                     non-ASCII를 \uXXXX로 이스케이프
--quotes=<style>                 문자열 따옴표 (double|single|preserve, 기본: double)
--drop=console                   console.* 호출 제거
--drop=debugger                  debugger 문 제거
--define:KEY=VALUE               글로벌 치환 (예: --define:DEBUG=false)
--external <pkg>                 패키지를 번들에서 제외 (반복 가능)
--experimental-decorators        legacy decorator 변환 (tsconfig compilerOptions 지원)
--use-define-for-class-fields=false  class field → constructor this.x = v 변환
--alias:FROM=TO              import 경로 별칭 (--alias:react=preact/compat)
--public-path=<url>          에셋/청크 URL prefix (CDN 배포용)
--banner:js=<text>           출력 파일 앞에 텍스트 삽입
--footer:js=<text>           출력 파일 뒤에 텍스트 삽입
--global-name=<name>         IIFE export 글로벌 변수명
--out-extension:.js=<ext>    출력 파일 확장자 변경 (.mjs, .cjs)
--source-root=<url>          소스맵 sourceRoot
--sources-content=false      소스맵에서 원본 소스 제외
--log-level=<level>          로그 레벨 (silent|error|warning|info)
--charset=utf8               non-ASCII를 이스케이프하지 않음
--preserve-symlinks          심링크를 따라가지 않고 링크 경로로 해석
--entry-names=<pattern>      엔트리 파일명 패턴 (기본: [name], 예: [name]-[hash])
--chunk-names=<pattern>      공통 청크 파일명 패턴 (기본: [name]-[hash], 예: chunks/[name]-[hash])
--asset-names=<pattern>      에셋 파일명 패턴 (기본: [name]-[hash], [dir]/[name]/[hash]/[ext] 지원)
--loader:.ext=type           확장자별 로더 지정 (file, dataurl, text, binary, copy, empty)
--metafile=<path>            빌드 입출력 JSON (esbuild 호환, 기본: meta.json)
--analyze                    번들 분석 출력 (metafile JSON을 stderr에 출력)
--legal-comments=<mode>      라이센스 주석 처리 (none, inline, eof, linked, external)
--inject:<path>              모든 엔트리에 자동 import (반복 가능)
--keep-names                 minify 시 함수/클래스 .name 프로퍼티 보존
--plugin <path>                  JS 플러그인 (subprocess JSON IPC)
-w, --watch                      파일 변경 감시
-p, --project <path>             tsconfig.json 경로
```

### Dev 서버
```
--serve [dir]                    정적 파일 서버 (기본: .)
--serve --bundle <entry.ts>      번들+서빙 (HMR 지원)
--port <number>                  서버 포트 (기본: 3000)
```

### 자동 동작 (esbuild 호환)
- `--platform=browser` + `--bundle` → format 기본값 IIFE (글로벌 스코프 오염 방지)
- `--platform=browser` + `--bundle` → `process.env.NODE_ENV`를 `"production"`으로 자동 define
- `--platform=browser` → Node 내장 모듈(fs, path, util 등) 빈 모듈로 대체
- `--platform=browser` → `package.json "browser"` 필드에서 disabled 파일 감지
- `--platform=node` → Node 내장 모듈 + 서브패스(fs/promises, stream/web) 자동 external
- `import.meta` → CJS+node: `require("url").pathToFileURL(__filename).href` / CJS+browser: `""`

## Development Workflow

### 구현 규칙
1. **작업 단위를 최대한 작게 나눈다** — 하나의 PR이 하나의 기능/토큰 그룹을 담당
2. **서브에이전트로 병렬 구현** — 독립적인 작업은 서브에이전트를 활용해 병렬 진행
3. **PR 단위로 올린다** — main에 직접 push하지 않고 feature branch → PR → merge
4. **`/simplify` 리뷰** — PR 올린 후 반드시 `/simplify`로 코드 품질 점검
   - 코드 재사용, 품질, 효율성 검토
   - 발견된 이슈 수정 후 merge
5. **테스트 먼저** — 구현 전에 해당 Test262 카테고리 또는 유닛 테스트 작성
6. **Zig 초보자에게 자세히 설명** — 모든 코드 작성 시 왜 이렇게 하는지 설명

### PR 네이밍 규칙
```
feat(lexer): add numeric literal tokenization
feat(parser): add expression parsing
fix(lexer): handle edge case in template literal nesting
```

### 브랜치 전략
```
main ← feature/lexer-token-enum
     ← feature/parser-expression
     ← fix/bundler-cjs-interop
     ...
```

## References
- Bun JS Parser: github.com/oven-sh/bun (src/js_parser.zig, src/js_lexer.zig)
- oxc: github.com/oxc-project/oxc (crates/oxc_parser/src/lexer/kind.rs — 토큰 enum 참고)
- SWC: github.com/swc-project/swc
- esbuild: github.com/evanw/esbuild
- Hermes: github.com/facebook/hermes (Flow 파서)
- Metro: github.com/facebook/metro (RN 번들러)
- TypeScript: github.com/microsoft/TypeScript (다운레벨링/decorator 테스트케이스)
- Test262: github.com/tc39/test262
- ECMAScript Spec: tc39.es/ecma262
