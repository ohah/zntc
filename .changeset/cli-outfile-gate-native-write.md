---
'@zntc/core': patch
---

npm CLI 에서 `--outfile` / `--outdir` 만 **산출물 보류 게이트를 건너뛰던 것**을 고쳤다.

`missing_export` · `ambiguous_export` 처럼 번들이 내부적으로 앞뒤가 안 맞는 에러에서는 세
표면(stdout · `--outfile` · Zig CLI)이 모두 산출물을 내지 않아야 하는데, `--outfile` 경로만
파일을 쓰고 있었다. 게이트 자체는 맞았지만 **디스크에 쓰는 주체가 둘**이었던 게 원인이다 —
네이티브 `build()` 의 기본값이 `write: true` 라, JS 가 게이트를 평가하기 *전에* 네이티브가
이미 파일을 써 버렸다. 성공 경로에서는 네이티브와 JS 가 같은 파일을 두 번 쓰고 있었다.

이제 `runBundle` 이 `write: false` 를 강제해 디스크 기록 주체를 JS 한 곳으로 모은다. 성공
경로 산출물은 바이트 단위로 동일하다(outfile / outfile+map / outdir / splitting /
splitting+map / minify+map 6구성 대조).
