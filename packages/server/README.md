# @zts/server (internal)

ZTS 의 internal server layer. **private 패키지** (`"private": true`) — npm 에 publish 되지 않습니다.

`@zts/web` / `@zts/react-native` 빌드 시 dist 에 자동 inline 되어, 외부에 별도 패키지로 노출되지 않습니다.

## 역할

- HMR protocol (HMR_MSG enum, type 정의)
- WS frame builder (RFC 6455)
- file watcher wrapper (`fs.watch` 기반, 미래에 NAPI watch)
- HMR channel (broadcast)
- 미래: BoringSSL TLS wrapper, NAPI server start/stop

자세한 계획: [#2539](https://github.com/ohah/zts/issues/2539).
