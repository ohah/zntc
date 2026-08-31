---
"@zntc/core": patch
---

`zntc <file> --sourcemap` 이 낸 맵을 브라우저가 못 찾던 것을 고쳤다.

세 가지가 겹쳐 있었다.

- **`//# sourceMappingURL=` 주석이 안 붙었다.** 맵 파일은 나오는데 코드에 가리키는 줄이
  없으니 DevTools 가 맵을 아예 읽지 않았다. 쓰는 쪽이 손수 붙여야 했다.
- **`--outdir` 로 내면 맵이 안 나왔다.** `-o` 일 때만 냈다 — `--sourcemap` 을 줘도
  조용히 무시됐다.
- **맵의 `sources` 가 CWD 기준이었다.** `-o dist/x.js` 로 내면 브라우저가
  `dist/src/x.ts` 를 찾다 못 찾는다. 맵이 놓인 자리 기준으로 적는다(tsc·esbuild 와 같다).
  `file` 도 생성 파일 이름으로 채운다.

모드도 문서대로 동작한다 — `linked`(기본)는 맵 + 주석, `external` 은 맵만,
`inline` 은 맵 파일 없이 data URL 로 심는다(예전엔 inline 인데도 `.map` 이 따로 나왔다).
