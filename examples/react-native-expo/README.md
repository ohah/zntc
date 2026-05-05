# Expo 55 / RN 0.83 — ZTS example

ZTS dev server + bundler 의 Expo 55 / RN 0.83 예제. Expo Router 기반.

## 시작

```sh
bun install

# Terminal 1: ZTS dev server
bun run start:zts

# Terminal 2: Expo 앱 실행
bun run ios   # 또는 bun run android
```

또는 Expo dev server (Metro) 사용:

```sh
bun run start
```

## 키보드 단축키 (Metro 호환)

dev server 터미널에서 `r/d/j/i/a/c/?` — `examples/react-native-bare/README.md` 참고.

## Production bundle

```sh
# iOS
bun run bundle:zts:ios

# Android
bun run bundle:zts:android
```

## 주의

- Expo Router (`expo-router/entry`) 가 main entry — `index.js` 가 expo-router 를 require.
- `@react-navigation/*` 사용 — react-native-screens 의존성 보존.
- web 시나리오 (`bun run web`) 는 Expo dev server 사용 — ZTS 는 native 만.
