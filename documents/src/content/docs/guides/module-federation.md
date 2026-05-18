---
title: Module Federation
description: ZNTC 의 Module Federation — 독립 빌드된 앱끼리 모듈을 노출·소비하고, 표준 런타임과 interop 하며, 계약을 빌드 시점에 검증합니다.
---

Module Federation 은 따로 빌드·배포된 앱들이 런타임에 서로의 모듈을
가져다 쓰게 하는 방식입니다. 모듈을 내보내는 쪽이 **remote**, 가져다
쓰는 쪽이 **host** 입니다.

ZNTC 는 host 런타임을 자체 구현하지 않고 **표준
`@module-federation/runtime` 계약을 타깃**합니다. 따라서 ZNTC 로 만든
remote 를 webpack 5 / rspack 으로 만든 host 가 그대로 소비할 수 있고,
반대로 ZNTC host 가 표준 remote 를 소비할 수도 있습니다(웹).

## 설정

`zntc.config`(`.ts`/`.js`/`.json`)의 `mf` 블록으로 선언합니다.

### Remote (모듈을 노출)

```json
{
  "mf": {
    "name": "remote_app",
    "exposes": { "./Button": "./src/Button.tsx" },
    "shared": { "react": { "singleton": true, "requiredVersion": "^19" } }
  }
}
```

- `name` — remote 식별자(host 가 이 이름으로 참조).
- `exposes` — 외부에 노출할 모듈. `{ 공개경로: 소스경로 }`.
- `shared` — 번들에 포함하지 않고 host 가 제공하는 단일 인스턴스를
  공유할 의존성. React 처럼 인스턴스가 갈리면 안 되는 라이브러리에 필수.
  - `singleton` — 한 인스턴스만 허용.
  - `requiredVersion` — 허용 버전 범위(semver).
  - `strictVersion` — 버전 불일치 시 런타임 폴백 대신 **빌드 실패**로 격상.
  - `shareScope` — 이 의존성이 속할 named share scope(기본 `"default"`).
    점진적 업그레이드·도메인 격리에 사용.

remote 빌드는 앱이 아니라 컨테이너이므로 core 모드로 빌드합니다:

```sh
zntc --bundle src/index.ts --outdir dist --format=iife
```

산출물: 컨테이너(remoteEntry) + `mf-manifest.json` + content-hash 청크.

### Host (remote 를 소비)

```json
{
  "mf": {
    "name": "host_app",
    "remotes": { "remote_app": "remote_app@https://cdn.example.com/mf-manifest.json" },
    "shared": { "react": { "singleton": true, "requiredVersion": "^19" } }
  }
}
```

host 코드에서는 정적·동적 import 둘 다 됩니다:

```ts
import Button from 'remote_app/Button';        // 정적
const m = await import('remote_app/Button');   // 동적
```

`shareStrategy`(`"version-first"` 기본 | `"loaded-first"`)로 공유 협상
순서를 정할 수 있습니다.

## 동작 원리

- **컨테이너 / 매니페스트** — remote 는 표준 계약대로 컨테이너와
  `mf-manifest.json` 을 emit 합니다. host 는 표준 런타임의
  `init`/`loadRemote` 로 이를 소비합니다(ZNTC 런타임 의존 없음).
- **공유 의존성** — `shared` 로 선언한 패키지는 번들에 포함되지 않고,
  host 가 등록한 단일 인스턴스를 가져다 씁니다. 그래서 host 와 remote 가
  같은 React 인스턴스를 공유해 hooks 가 정상 동작합니다. named scope
  여러 개를 동시에 쓸 수 있습니다.
- **빌드타임 계약 검증** — ZNTC 의 차별점. host 빌드가 소비하는
  remote 의 `mf-manifest.json` 을 읽어, 계약 위반을 **런타임이 아니라
  빌드에서** 잡습니다:
  - host 가 import 하는 `remote/<subpath>` 가 소비 대상 remote 의
    매니페스트에 없으면 host 빌드 실패.
  - 공유 의존성의 버전/싱글톤이 host 요구와 불일치하면 경고(또는
    `strictVersion` 시 빌드 실패).
  - 매니페스트 무결성(다이제스트/서명)이 변조·stale 이면 빌드 실패.
- **런타임 가드** — 빌드 시점에 검증할 수 없는 경우(도달 불가 remote,
  런타임 동적 등록 등)는 런타임에서 graceful 폴백으로 셸이 살아남습니다.
- **CSS** — 노출 모듈이 CSS 를 import 하면 매니페스트에 CSS 자산이
  기재돼 표준 런타임이 stylesheet 를 함께 preload 합니다.

## 한계

- **웹 전용** — React Native 는 아직 지원하지 않습니다.
- **런타임 동적 등록** — host 코드가 표준 런타임의
  `registerRemotes()` / `init({ remotes })` 로 **런타임에** 등록하는
  remote 는 빌드 시점에 존재 자체가 미지라 계약을 빌드검증할 수
  없습니다. 동작은 표준 런타임 위임으로 정상이며, 그 사각은 런타임
  가드가 메웁니다. 빌드검증은 config `remotes` 및 빌드 시 스캔되는
  정적/동적 import 로 식별되는 remote 가 대상입니다.
- **원격 매니페스트 fetch** — 빌드타임 계약 검증은 로컬에서 해석
  가능한 매니페스트가 대상입니다. 네트워크로만 받을 수 있는 매니페스트는
  빌드 시점에 검증하지 않고 런타임 가드에 맡깁니다.
- **타입 자동 생성 없음** — remote 의 `.d.ts` 를 자동 생성하지
  않습니다. 소비 측은 자체 타입 선언을 사용합니다(ZNTC 의 차별점은
  타입 힌트 다운로드가 아니라 빌드타임 계약 검증입니다).

돌려볼 수 있는 최소 예제는
[Module Federation 예제](/zntc/guides/module-federation-recipe/) 레시피를
참고하세요 — ZNTC remote 를 표준 `@module-federation/runtime` host 가
소비하고 React 단일 인스턴스 공유를 검증합니다(전체 코드:
[`examples/module-federation`](https://github.com/ohah/zntc/tree/main/examples/module-federation)).
