# @zts/server

ZTS 의 internal server layer. **`@zts/web` / `@zts/react-native` 가 의존성으로 사용** — 사용자가 직접 install 할 일 없음.

> 공개 npm 패키지지만 의도는 internal 라이브러리. ZTS bundler 가 workspace dep auto-inline 을 지원하기 전까지의 임시 노출 — 후속에 다시 private 로 전환 예정 (#2539).

## 역할

- HMR protocol (HMR_MSG enum, type 정의)
- WS frame builder (RFC 6455)
- file watcher wrapper (`fs.watch` 기반, 미래에 NAPI watch)
- HMR channel (broadcast)
- 미래: BoringSSL TLS wrapper, NAPI server start/stop

자세한 계획: [#2539](https://github.com/ohah/zts/issues/2539).
