---
'@zntc/web': patch
---

`zntc dev` 를 한 번 돌린 프로젝트에서 `zntc build` 가 실패하던 문제를 고쳤다 (#4674).

```
error: ENOENT: no such file or directory, open
  '/var/.../zntc-postcss-build-XXXX/.zntc-dev/s.module.css'
```

PostCSS temp root 로 프로젝트를 복사할 때는 dev 산출 디렉토리(`.zntc-dev`)를 제외하는데,
CSS Module **탐색**은 `outdir` 하나만 제외해서 `.zntc-dev` 안의 `.module.css` 를 처리 대상으로
잡았다. 복사본에 그 파일이 없으니 열다가 죽었다.

"무엇이 source 인가" 라는 같은 질문에 복사와 탐색이 다르게 답하던 것을 **하나의 목록**
(`postcssExcludedDirs`)으로 합쳤다. `collectAppFiles` 에 `skipDirs` 를 추가해 같은 목록을
그대로 넘긴다.
