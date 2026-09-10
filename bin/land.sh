#!/usr/bin/env bash
# 워크트리 브랜치를 그 레포의 기준 브랜치에 머지하고 push한 뒤 워크트리를 지운다.
#
#   land.sh <repo> <worktree-name>
#   KEEP=1 land.sh <repo> <worktree-name>       머지만 하고 워크트리를 남긴다
#   NO_PUSH=1 land.sh <repo> <worktree-name>    push를 건너뛰고 워크트리를 남긴다
#
# push를 하는 것이 정책이다. 사람이 최종 게이트인 것은 맞지만 그 게이트는
# 커밋 훅의 ask 프롬프트가 잡는다. 스크립트가 push를 아예 안 하면 닫았다고
# 말한 작업이 로컬에만 남는다.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -ge 2 ] || die "사용법: land.sh <repo> <worktree-name>"

REPO="$1"; NAME="$2"
MAIN="$(resolve_repo "$REPO")"
WT="$(worktree_path "$REPO" "$NAME")"
require_worktree "$WT"

BRANCH="$(git -C "$WT" branch --show-current)"
[ -n "$BRANCH" ] || die "$WT 가 브랜치에 붙어 있지 않다."

DIRTY="$(git -C "$WT" status --porcelain)"
[ -z "$DIRTY" ] || die "워크트리에 미커밋 변경이 남아 있다. 커밋하거나 버린 뒤 다시 부른다.
$DIRTY"

AHEAD="$(git -C "$WT" rev-list --count "$BASE_BRANCH..$BRANCH")"
[ "$AHEAD" -gt 0 ] || die "$BASE_BRANCH 대비 커밋이 없다. 머지할 것이 없다."

printf '%s 의 %s 를 %s 에 머지한다 (커밋 %s개)\n' "$REPO" "$BRANCH" "$BASE_BRANCH" "$AHEAD"
git -C "$WT" log --oneline "$BASE_BRANCH..$BRANCH"

# 리뷰를 안 거친 것이 조용히 기준 브랜치에 들어가지 않게 한다.
RF="$(review_file "$REPO" "$NAME")"
if [ ! -f "$RF" ]; then
  printf '\n리뷰 결과 파일이 없다: %s\n' "$RF" >&2
  printf '%s/bin/review.sh %s %s 로 먼저 리뷰한다. 건너뛰려면 FORCE=1 을 준다.\n' "$PLUGIN_ROOT" "$REPO" "$NAME" >&2
  [ "${FORCE:-}" = "1" ] || exit 1
else
  printf '\n리뷰 판정 (%s) -- blocking %s건\n' "$RF" "$(blocking_count "$RF")"
  # 앞의 -- 를 printf 형식으로 두면 옵션으로 먹힌다.
  blocking_section "$RF" | head -20
  printf '%s\n\n' "위 판정이 닫힌 것이 맞는지 보고 진행한다"
fi

CUR="$(git -C "$MAIN" branch --show-current)"
[ "$CUR" = "$BASE_BRANCH" ] || die "메인 체크아웃이 $BASE_BRANCH 가 아니라 $CUR 에 있다. 옮긴 뒤 다시 부른다."

# 메인 체크아웃은 다른 세션이 함께 만지므로, 남의 미커밋 변경이 있으면 알리고 멈춘다.
OTHER="$(git -C "$MAIN" status --porcelain)"
if [ -n "$OTHER" ]; then
  printf '메인 체크아웃에 미커밋 변경이 있다. 머지가 그것과 같은 파일을 건드리면 실패한다.\n' >&2
  printf '%s\n' "$OTHER" >&2
  printf '그래도 진행하려면 FORCE=1 을 준다.\n' >&2
  [ "${FORCE:-}" = "1" ] || exit 1
fi

git -C "$MAIN" merge --no-ff "$BRANCH" -m "merge: $BRANCH 를 받는다"

# 일부러 건너뛴 것과 하려다 실패한 것을 가른다. 둘을 0 하나로 뭉치면
# NO_PUSH=1 이 실패 경로로 떨어져 "push가 안 됐다"를 찍고 1로 빠진다.
if [ "${NO_PUSH:-}" = "1" ]; then
  printf '\npush를 건너뛴다. 로컬 %s 에만 있다.\n' "$BASE_BRANCH"
  PUSHED=skip
else
  printf '\npush한다. 훅의 사람 확인 프롬프트가 여기서 걸린다.\n'
  if git -C "$MAIN" push origin "$BASE_BRANCH" 2>&1 | tail -2; then PUSHED=1; else PUSHED=0; fi
fi

if [ "$PUSHED" = 0 ]; then
  # 머지는 됐는데 push만 안 된 상태다. 카드가 이걸 들고 있어야 한다 --
  # 안 그러면 리뷰 중으로 보이고, 실제로는 손볼 것이 남지 않은 워크트리가 방치된다.
  card "$WT" "" "머지됨, push 실패 -- 손으로 올린다"
  journal "land $REPO/$NAME -- $BASE_BRANCH 에 머지, push 실패"
  printf 'push가 안 됐다. 워크트리를 남긴다 -- 지우면 되돌릴 자리가 사라진다.\n' >&2
  # land를 다시 부르라고 하지 않는다. 머지는 이미 됐으니 다음 호출은
  # "머지할 것이 없다"에서 멈춘다. 남은 것은 push와 뒷정리 둘뿐이다.
  printf '\n손으로 마무리한다:\n' >&2
  printf '  git -C %s push origin %s\n' "$MAIN" "$BASE_BRANCH" >&2
  printf '  orca worktree rm --worktree "path:%s" --force\n' "$WT" >&2
  exit 1
fi

# push를 건너뛰면 워크트리도 남긴다. 브랜치를 지우고 나면 다시 올릴 자리가
# 로컬 기준 브랜치 하나뿐이라, 되돌릴 일이 생겼을 때 골라낼 것이 없다.
if [ "$PUSHED" = skip ]; then
  card "$WT" "" "머지됨, push 건너뜀 -- 로컬 $BASE_BRANCH 에만"
  journal "land $REPO/$NAME -- 로컬 $BASE_BRANCH 에 머지 (커밋 ${AHEAD}개, push 건너뜀)"
else
  card "$WT" completed "$BASE_BRANCH 에 머지, push 완료"
  # 워크트리와 카드는 아래에서 지워진다. 무엇이 닫혔는지는 이 줄로만 남는다.
  journal "land $REPO/$NAME -- $BASE_BRANCH 에 머지, push 완료 (커밋 ${AHEAD}개, 리뷰 $(rounds_done "$REPO" "$NAME")차)"
fi

if [ "${KEEP:-}" = "1" ] || [ "$PUSHED" = skip ]; then
  printf '워크트리를 남긴다: %s\n' "$WT"
  if [ "$PUSHED" = skip ]; then
    printf '올린 뒤 지운다: git -C %s push origin %s && orca worktree rm --worktree "path:%s" --force\n' \
      "$MAIN" "$BASE_BRANCH" "$WT"
  fi
else
  orca worktree rm --worktree "path:$WT" --force --json 2>&1 | orca_check
  git -C "$MAIN" branch -d "$BRANCH" 2>/dev/null || true
  rm -f "$(handle_file "$REPO" "$NAME" work)" "$(handle_file "$REPO" "$NAME" review)"
  printf '워크트리를 지웠다: %s\n' "$WT"
  printf '리뷰 기록은 남긴다: %s\n' "$RF"
fi
