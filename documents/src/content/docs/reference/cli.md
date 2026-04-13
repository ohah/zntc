---
title: CLI 레퍼런스
description: ZTS CLI 옵션 전체 목록
---

## 트랜스파일

```bash
zts <file.ts>                      # → stdout
zts <file.ts> -o <out.js>          # → 파일
zts <dir/> --outdir <out/>         # 디렉토리 재귀 변환
zts - < input.ts                   # stdin 입력
```

## 번들

```bash
zts --bundle <entry.ts>                               # → stdout
zts --bundle <entry.ts> -o out.js                     # → 파일
zts --bundle <entry.ts> --splitting --outdir dist     # 코드 스플리팅
zts --bundle <entry.ts> --preserve-modules --outdir dist  # 모듈별 출력 (라이브러리)
zts --bundle <entry.ts> --plugin zts.config.js        # JS 플러그인
```

## 입출력

| 옵션 | 설명 |
|------|------|
| `-o, --out-file <path>` | 출력 파일 경로 |
| `--outdir <path>` | 출력 디렉토리 (디렉토리 입력·`--splitting`·`--preserve-modules`) |
| `--outbase=<dir>` | 출력 기준 디렉토리 (공통 prefix 계산) |
| `--out-extension:.js=<ext>` | 출력 확장자 변경 (예: `.mjs`) |
| `--allow-overwrite` | 입력과 같은 경로에 덮어쓰기 허용 |
| `--clean` | 빌드 전 outdir 비우기 |

## 모듈 포맷 / 플랫폼

| 옵션 | 설명 |
|------|------|
| `--format=esm\|cjs\|iife\|umd\|amd` | 모듈 포맷 (기본: `esm`) |
| `--platform=browser\|node\|neutral\|react-native` | 타겟 플랫폼 |
| `--rn-platform=ios\|android` | RN 서브 플랫폼 (`.ios.*`/`.android.*` 확장자) |
| `--target=<spec>` | ES 타겟: `es2015`~`esnext` 또는 엔진 버전 (`chrome80,safari14` 등) |
| `--global-name=<name>` | IIFE export 변수명 |
| `--global-identifier=<id>` | 글로벌 식별자 치환 |

## 미니파이

| 옵션 | 설명 |
|------|------|
| `--minify` | 세 가지 모두 켜기 (shortcut) |
| `--minify-whitespace` | 공백/세미콜론/줄바꿈만 축약 (디버깅 가능) |
| `--minify-syntax` | `true`→`!0`, 괄호 제거, constant folding |
| `--minify-identifiers` | 지역 변수명 단축 |
| `--keep-names` | 함수/클래스 `.name` 보존 |
| `--charset=utf8\|ascii` | 출력 문자셋 |
| `--ascii-only` | non-ASCII → `\uXXXX` (= `--charset=ascii`) |
| `--quotes=double\|single\|preserve` | 문자열 따옴표 스타일 |
| `--line-limit=<n>` | 한 줄 최대 길이 (minify 시 줄바꿈 삽입) |

## 소스맵

| 옵션 | 설명 |
|------|------|
| `--sourcemap` | `.js.map` 외부 파일 |
| `--sourcemap=inline` | data URL 인라인 |
| `--sourcemap=external` | sourceMappingURL 주석 없이 외부만 |
| `--sourcemap=hidden` | 외부 파일 생성만 (주석 생략) |
| `--sourcemap-debug-ids` | Sentry debugId 삽입 |
| `--sources-content=false` | `sourcesContent` 필드 생략 |
| `--source-root=<path>` | sourceRoot 필드 |

## 변환 / 치환

| 옵션 | 설명 |
|------|------|
| `--define:KEY=VALUE` | 글로벌 치환 (`process.env.NODE_ENV` → `"production"` 등) |
| `--drop=console` | `console.*` 호출 제거 |
| `--drop=debugger` | `debugger` 문 제거 |
| `--drop-labels=<list>` | 특정 label 블록 제거 (예: `DEV,TEST`) |
| `--pure:<name>` | 해당 호출을 pure로 표시해 DCE 대상화 |
| `--inject:<path>` | 자동 import (shim) |
| `--polyfill=<list>` | 런타임 폴리필 주입 |

## JSX

| 옵션 | 설명 |
|------|------|
| `--jsx=classic\|automatic\|automatic-dev` | JSX 런타임 |
| `--jsx-dev` | `--jsx=automatic-dev` shortcut |
| `--jsx-factory=<fn>` | classic factory (기본: `React.createElement`) |
| `--jsx-fragment=<fn>` | classic Fragment |
| `--jsx-import-source=<pkg>` | automatic import source (기본: `react`) |
| `--jsx-in-js` | `.js` 파일에서도 JSX 파싱 허용 |
| `--jsx-side-effects` | JSX 요소에 부수효과 있다고 표시 (DCE 회피) |

## TypeScript

| 옵션 | 설명 |
|------|------|
| `-p, --project <path>` | tsconfig.json 경로/디렉토리 |
| `--tsconfig-raw=<json>` | tsconfig 내용 인라인 주입 |
| `--experimental-decorators` | legacy decorator (`__decorateClass`) |
| `--use-define-for-class-fields=false\|true` | 클래스 필드 의미론 |

## Flow

| 옵션 | 설명 |
|------|------|
| `--flow` | Flow 타입 스트리핑 (`@flow` pragma 자동 감지) |
| `--ignore-annotations` | Flow 주석/pragma 무시 |

## 번들 전용

| 옵션 | 설명 |
|------|------|
| `--bundle` | 번들 모드 활성화 |
| `--splitting` | 코드 스플리팅 (`--outdir` 필요) |
| `--preserve-modules` | 모듈별 출력 (라이브러리 빌드) |
| `--preserve-modules-root=<dir>` | 출력 구조 기준 디렉토리 |
| `--entry-names=<pattern>` | 엔트리 파일명 패턴 (`[name]`, `[hash]`) |
| `--chunk-names=<pattern>` | 청크 파일명 패턴 |
| `--asset-names=<pattern>` | 에셋 파일명 패턴 |
| `--loader:.ext=type` | 확장자별 로더 (`file\|dataurl\|text\|binary\|copy\|json\|css\|js\|ts\|jsx\|tsx`) |
| `--metafile` / `--metafile=<path>` | 빌드 메타 JSON (stdout 또는 파일) |
| `--analyze` | 번들 분석 리포트 |
| `--legal-comments=<mode>` | 라이선스 주석: `none\|inline\|eof\|linked\|external` |
| `--banner:js=<text>` | 출력 앞 텍스트 |
| `--footer:js=<text>` | 출력 뒤 텍스트 |
| `--public-path=<url>` | 에셋 URL prefix |
| `--shim-missing-exports` | 없는 export에 `undefined` shim |

## Resolve

| 옵션 | 설명 |
|------|------|
| `--external <pkg>` / `--external=<pkg,...>` | 번들에서 제외 (반복 가능) |
| `--packages=external` | 모든 npm 패키지를 external 처리 |
| `--alias:FROM=TO` | import 경로 별칭 |
| `--conditions=<list>` | 커스텀 export 조건 (예: `production,custom`) |
| `--resolve-extensions=<exts>` | 확장자 탐색 순서 (예: `.ios.ts,.ts,.js`) |
| `--main-fields=<fields>` | package.json 필드 순서 (예: `react-native,browser,main`) |
| `--node-paths=<dirs>` | `NODE_PATH` 추가 탐색 경로 |
| `--preserve-symlinks` | 심링크 실제 경로 해석 안 함 |

## Watch / Dev Server

| 옵션 | 설명 |
|------|------|
| `-w, --watch` | 파일 변경 감시 (증분 리빌드) |
| `--watch-json` | NDJSON 이벤트 출력 (외부 HMR 연동) |
| `--watch-delay=<ms>` | 디바운스 지연 |
| `--serve [dir]` | 정적 파일 서버 (기본: `.`) |
| `--port <n>` | 서버 포트 |
| `--host [addr]` | 바인딩 주소 |
| `--open` | 브라우저 자동 열기 |
| `--proxy /api=http://host:port` | API 프록시 |
| `--dev` | 개발 모드 (HMR + 빠른 리빌드) |
| `--run-before-main=<cmd>` | 번들 엔트리 실행 전에 돌릴 코드 주입 |

**Dev Server 외부 인터페이스:** `/sse/events` (SSE 빌드 이벤트), `/reset-cache` (Control API), `/mcp` (Model Context Protocol — Claude Code 등 LLM 에이전트 연동).

## 플러그인 / 실행

| 옵션 | 설명 |
|------|------|
| `--plugin <path>` | JS/TS 플러그인 또는 설정 파일 |
| `--jobs=<n>` | 병렬 스레드 수 |

## 진단 / 로깅

| 옵션 | 설명 |
|------|------|
| `--log-level=<level>` | `silent\|error\|warning\|info\|debug\|verbose` |
| `--log-limit=<n>` | 표시할 진단 최대 개수 |
| `--timing` | 단계별 실행 시간 출력 |
| `--tokenize` | 토큰 출력 (트랜스파일 대신) |
| `--test262 <dir>` | Test262 러너 실행 |
| `-h, --help` | 도움말 |

## 참고

- JS API(`@zts/core`)는 `packages/core/index.ts`에서 동일한 옵션을 프로그램적으로 제공합니다.
- Vite 어댑터는 `vite-plugin-zts` 또는 `vitePlugin()`으로 사용하세요.
- 미지원 옵션 / 향후 계획은 [docs/ROADMAP.md](https://github.com/ohah/zts/blob/main/docs/ROADMAP.md) 참고.
