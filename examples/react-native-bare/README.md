# React Native 0.85 bare — ZTS example

ZTS dev server + bundler 의 React Native 0.85 bare 예제.

## 시작

```sh
# Pod install (iOS, 첫 실행 시)
cd ios && pod install && cd ..

# ZTS dev server 시작 (Metro 호환 — port 8081)
bun run start:zts

# 다른 터미널에서 RN 앱 실행
bun run ios   # 또는 bun run android
```

## 키보드 단축키 (Metro 호환)

dev server 터미널에서:

- `r` — Reload
- `d` — Dev Menu
- `j` — DevTools (open-debugger)
- `i` — iOS Simulator open
- `a` — Android Emulator open
- `c` — Clear cache
- `?` — Help

## Production bundle

```sh
# iOS
bun run bundle:zts:ios

# Android
bun run bundle:zts:android
```

## ZTS vs Metro 비교

| 기능 | ZTS | Metro |
|------|-----|-------|
| dev server | `bun run start:zts` | `bun run start` |
| iOS bundle | `bun run bundle:zts:ios` | `bun run bundle:metro:ios` |
| Android bundle | `bun run bundle:zts:android` | `bun run bundle:metro:android` |
