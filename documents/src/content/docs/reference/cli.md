---
title: CLI 레퍼런스
description: ZTS CLI 옵션 전체 목록
---

## 트랜스파일

```bash
zts <file.ts>                    # → stdout
zts <file.ts> -o <out.js>       # → 파일
zts <dir/> --outdir <out/>      # 디렉토리 재귀 변환
zts - < input.ts                # stdin 입력
```

## 번들

```bash
zts --bundle <entry.ts>                              # → stdout
zts --bundle <entry.ts> -o out.js                    # → 파일
zts --bundle <entry.ts> --splitting --outdir dist    # 코드 스플리팅
zts --bundle <entry.ts> --preserve-modules --outdir dist  # 모듈별 출력
zts --bundle <entry.ts> --plugin zts.config.js       # JS 플러그인
```

## 공통 옵션

| 옵션 | 설명 |
|------|------|
| `--format=esm\|cjs\|iife` | 모듈 포맷 |
| `--platform=browser\|node\|neutral\|react-native` | 타겟 플랫폼 |
| `--minify` | 출력 압축 |
| `--sourcemap` | 소스맵 생성 |
| `--ascii-only` | non-ASCII → `\uXXXX` |
| `--quotes=double\|single\|preserve` | 따옴표 스타일 |
| `--drop=console` | console.* 제거 |
| `--drop=debugger` | debugger 문 제거 |
| `--define:KEY=VALUE` | 글로벌 치환 |
| `--external <pkg>` | 번들에서 제외 |
| `--alias:FROM=TO` | import 경로 별칭 |
| `--banner:js=<text>` | 출력 앞에 텍스트 |
| `--footer:js=<text>` | 출력 뒤에 텍스트 |
| `--global-name=<name>` | IIFE export 변수명 |
| `--public-path=<url>` | 에셋 URL prefix |
| `--out-extension:.js=<ext>` | 출력 확장자 변경 |

## JSX 옵션

| 옵션 | 설명 |
|------|------|
| `--jsx=classic\|automatic\|automatic-dev` | JSX 런타임 |
| `--jsx-dev` | `--jsx=automatic-dev` 단축 |
| `--jsx-factory=<fn>` | classic factory |
| `--jsx-fragment=<fn>` | classic Fragment |
| `--jsx-import-source=<pkg>` | automatic import source |

## 번들 전용 옵션

| 옵션 | 설명 |
|------|------|
| `--splitting` | 코드 스플리팅 |
| `--preserve-modules` | 모듈별 출력 |
| `--preserve-modules-root=<dir>` | 출력 기준 경로 |
| `--entry-names=<pattern>` | 엔트리 파일명 패턴 |
| `--chunk-names=<pattern>` | 청크 파일명 패턴 |
| `--asset-names=<pattern>` | 에셋 파일명 패턴 |
| `--loader:.ext=type` | 확장자별 로더 |
| `--metafile=<path>` | 빌드 메타 JSON |
| `--analyze` | 번들 분석 출력 |
| `--legal-comments=<mode>` | 라이센스 주석 |
| `--inject:<path>` | 자동 import |
| `--keep-names` | 함수/클래스 .name 보존 |
| `--shim-missing-exports` | 없는 export에 undefined |
| `--resolve-extensions=<exts>` | 확장자 탐색 순서 |
| `--main-fields=<fields>` | package.json 필드 순서 |

## React Native 옵션

| 옵션 | 설명 |
|------|------|
| `--rn-platform=ios\|android` | RN 서브 플랫폼 |
| `--flow` | Flow 타입 스트리핑 |

## Dev Server

| 옵션 | 설명 |
|------|------|
| `--serve [dir]` | 정적 파일 서버 |
| `--port <number>` | 포트 (기본: 12300) |
| `--host [addr]` | 바인딩 주소 |
| `--open` | 브라우저 자동 열기 |
| `--proxy /api=http://host:port` | API 프록시 |

## 기타

| 옵션 | 설명 |
|------|------|
| `-w, --watch` | 파일 변경 감시 |
| `--watch-json` | NDJSON 이벤트 출력 |
| `-p, --project <path>` | tsconfig.json 경로 |
| `--experimental-decorators` | legacy decorator |
| `--use-define-for-class-fields=false` | class field → constructor |
| `--log-level=<level>` | 로그 레벨 |
| `--charset=utf8` | non-ASCII 유지 |
| `--preserve-symlinks` | 심링크 유지 |
