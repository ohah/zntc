# Changesets

이 폴더는 `@changesets/cli` 가 관리. 자세한 설정 / 흐름은 [docs/PUBLISH.md](../docs/PUBLISH.md#changesets--version-bump--changelog-자동화) 참조.

## 빠른 사용

```bash
# 변경 의도 기록 (PR 작업 중)
bun run changeset
#   → 변경된 패키지 / bump 종류 / 사유 입력
#   → .changeset/<random>.md 생성 → commit

# release PR 작업 (누적된 changeset 일괄 적용)
bun run changeset:version
#   → version bump + CHANGELOG.md + bun install
#   → diff 확인 후 commit + PR

# 누적 상태 확인
bun run changeset:status
```

실제 publish 는 `bun run release:publish` (release.ts) — `changeset publish` 는 사용 안 함 (release.ts 가 더 다중 가드).

자세한 changesets 사용법: <https://github.com/changesets/changesets/blob/main/docs/common-questions.md>
