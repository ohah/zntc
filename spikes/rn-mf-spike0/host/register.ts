// 스파이크 host 등록 (throwaway). RN 유일 추가점: 표준
// @module-federation/runtime 에 네이티브 로더를 **플러그인으로 1회
// 동기 등록**(첫 React.lazy/loadRemote 전, index.js 최상단). zntc
// 전용 ScriptManager API 없음(D1) — 표준 runtime + 얇은 플러그인.
//
// NativeSpike0 = native/INTEGRATE.md 의 TurboModule(evaluateFederated
// Remote(path)→컨테이너). 표준 runtime 의 스크립트 로드 hook 을 이
// 네이티브 호출로 대체.
import { init } from '@module-federation/runtime';
import { TurboModuleRegistry } from 'react-native';
import * as hostReact from 'react';

const Native = TurboModuleRegistry.getEnforcing<{
  evaluateFederatedRemote(path: string): Promise<any>; // jsi 컨테이너
}>('NativeSpike0');

const zntcRnLoader = () => ({
  name: 'zntc-rn-spike0-loader',
  // 표준 runtime 이 remote entry 를 로드할 지점 → 네이티브 JSI 주입.
  // (실 구현은 manifest resolve→fetch→네이티브 evaluate; 스파이크는
  //  로컬 path 직주입으로 최소화)
  loadEntry: async ({ remoteInfo }: any) =>
    Native.evaluateFederatedRemote(remoteInfo.entry),
});

// host 가 자기 react 를 shared 로 등록 → remote 가 단일 인스턴스 공유
// (B3). 첫 lazy 전 **동기 init**(등록 순서 함정 = B7/RN 공통).
init({
  name: 'host_app',
  remotes: [{ name: 'remote_app', entry: 'file:///…/remote/dist/index.js' }],
  shared: {
    react: {
      version: '19.0.0',
      lib: () => hostReact,
      shareConfig: { singleton: true, requiredVersion: '^19' },
    },
  },
  plugins: [zntcRnLoader()],
});

// 사용처(App.tsx): const B = React.lazy(()=>import('remote_app/Button'))
// → <Suspense><B/></Suspense>. mod.usedHook===hostReact.useState 로그로
// B3 확인.
