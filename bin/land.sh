#!/usr/bin/env bash
# 워크트리 브랜치를 기준 브랜치에 머지하고 push한 뒤 워크트리를 삭제한다.
#
#   land.sh <repo> <worktree-name>
#   KEEP=1 land.sh <repo> <worktree-name>     push 후 워크트리 유지
#   NO_PUSH=1 land.sh <repo> <worktree-name>  push 생략, 워크트리 유지
#
# 우산 워크트리는 리뷰를 거치지 않아 판정 파일을 검사하지 않는다.
# 우산 여부는 status.sh와 같은 owner_id로 판단한다.
# push 시 훅의 확인 프롬프트에서 사용자 확인을 받는다.
# push를 생략하면 완료한 작업이 로컬에만 남으므로 기본으로 실행한다.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -ge 2 ] || die "사용법: land.sh <repo> <worktree-name>"

REPO="$1"; NAME="$2"
MAIN="$(resolve_repo "$REPO")"
WT="$(worktree_path "$REPO" "$NAME")"
require_worktree "$WT"

# status, dispatch, review와 같은 함수로 기준 브랜치를 정한다.
# status의 머지 안내와 실제 머지 대상이 일치해야 한다.
BASE="$(base_branch_for "$REPO")"

# status.sh와 같은 기준으로 우산을 구분한다. 우산은 판정 파일 없이 커밋만 확인한다.
# land가 매번 FORCE=1을 요구하면 리뷰 검사를 습관적으로 생략할 수 있어 기준을 맞춘다.
UMBRELLA=0
[ "$REPO.$NAME" != "$(owner_id)" ] || UMBRELLA=1

BRANCH="$(git -C "$WT" branch --show-current)"
[ -n "$BRANCH" ] || die "$WT 가 브랜치에 붙어 있지 않다."

DIRTY="$(git -C "$WT" status --porcelain)"
[ -z "$DIRTY" ] || die "워크트리에 미커밋 변경이 남아 있다. 커밋하거나 버린 뒤 다시 부른다.
$DIRTY"

# rev-list 전에 메인 체크아웃의 브랜치를 확인한다. 기준 브랜치가 origin에만 있으면
# Git 오류와 코드 128로 종료되므로, 먼저 사용자에게 원인을 안내한다.
CUR="$(git -C "$MAIN" branch --show-current)"
[ "$CUR" = "$BASE" ] || die "메인 체크아웃이 $BASE 가 아니라 $CUR 에 있다. 옮긴 뒤 다시 부른다."

# push 실패, 수동 머지, KEEP=1 이후에도 다시 실행할 수 있다.
# 이미 머지된 경우 오류로 중단하지 않고 push와 정리를 진행한다.
AHEAD="$(git -C "$WT" rev-list --count "$BASE..$BRANCH")"
MERGED=0
if [ "$AHEAD" = 0 ]; then
  git -C "$WT" merge-base --is-ancestor "$BRANCH" "$BASE" 2>/dev/null \
    || die "$BASE 대비 커밋이 없다. 머지할 것이 없다."
  MERGED=1
  printf '%s 는 이미 %s 에 들어가 있다. 머지를 건너뛰고 push와 뒷정리만 한다.\n' \
    "$BRANCH" "$BASE"
else
  printf '%s 의 %s 를 %s 에 머지한다 (커밋 %s개)\n' "$REPO" "$BRANCH" "$BASE" "$AHEAD"
  git -C "$WT" log --oneline "$BASE..$BRANCH"
fi

# 리뷰하지 않은 변경이 머지되지 않도록 검사한다. 이미 머지됐다면 정리만 진행한다.
RF="$(review_file "$REPO" "$NAME")"
if [ "$MERGED" = 1 ]; then
  :
elif [ "$UMBRELLA" = 1 ]; then
  # 우산의 진행 문서와 계약 초안은 리뷰 대상에서 제외한다.
  # 반영할 변경은 앞의 커밋 로그로 확인한다.
  printf '\n우산 워크트리는 리뷰 대상이 아니므로 판정 파일을 검사하지 않는다.\n\n'
elif [ ! -f "$RF" ]; then
  printf '\n리뷰 결과 파일이 없다: %s\n' "$RF" >&2
  printf '%s/bin/review.sh %s %s 로 먼저 리뷰한다. 건너뛰려면 FORCE=1 을 준다.\n' "$PLUGIN_ROOT" "$REPO" "$NAME" >&2
  [ "${FORCE:-}" = "1" ] || exit 1
else
  printf '\n리뷰 판정 (%s) -- blocking %s건\n' "$RF" "$(blocking_count "$RF")"
  # --로 시작하는 문구가 옵션으로 해석되지 않도록 형식 문자열과 분리한다.
  blocking_section "$RF" 20
  printf '%s\n\n' "위 리뷰 지적이 해결됐는지 확인하고 진행한다"
fi

# 다른 세션도 메인 체크아웃을 사용하므로 미커밋 변경이 있으면 안내하고 중단한다.
OTHER="$(git -C "$MAIN" status --porcelain)"
if [ -n "$OTHER" ]; then
  printf '메인 체크아웃에 미커밋 변경이 있다. 머지가 그것과 같은 파일을 건드리면 실패한다.\n' >&2
  printf '%s\n' "$OTHER" >&2
  printf '그래도 진행하려면 FORCE=1 을 준다.\n' >&2
  [ "${FORCE:-}" = "1" ] || exit 1
fi

[ "$MERGED" = 1 ] || git -C "$MAIN" merge --no-ff "$BRANCH" -m "merge: $BRANCH 머지"

# push 생략과 실패를 구분한다. 같은 값이면 NO_PUSH=1도 실패로 처리될 수 있다.
if [ "${NO_PUSH:-}" = "1" ]; then
  printf '\npush를 건너뛴다. 로컬 %s 에만 있다.\n' "$BASE"
  PUSHED=skip
else
  printf '\npush한다. 훅의 사람 확인 프롬프트가 여기서 걸린다.\n'
  if git -C "$MAIN" push origin "$BASE" 2>&1 | tail -2; then PUSHED=1; else PUSHED=0; fi
fi

if [ "$PUSHED" = 0 ]; then
  # 머지는 완료됐지만 push는 실패한 상태를 카드에 기록해 남은 작업을 표시한다.
  card "$WT" "" "머지됨, push 실패 -- 직접 올린다"
  journal "land $REPO/$NAME -- $BASE 에 머지, push 실패"
  printf 'push에 실패했다. 복구할 수 있도록 워크트리를 유지한다.\n' >&2
  # 실패 시 직접 실행할 push와 워크트리 정리 명령을 안내한다.
  printf '\n직접 마무리한다:\n' >&2
  printf '  git -C %s push origin %s\n' "$MAIN" "$BASE" >&2
  printf '  orca worktree rm --worktree "path:%s" --force\n' "$WT" >&2
  exit 1
fi

# push를 생략하면 워크트리를 유지한다. 작업 브랜치가 있어야
# 로컬 기준 브랜치에 반영한 변경을 나중에 구분하고 복구하기 쉽다.
if [ "$PUSHED" = skip ]; then
  card "$WT" "" "머지됨, push 건너뜀 -- 로컬 $BASE 에만"
  journal "land $REPO/$NAME -- 로컬 $BASE 에 머지 (커밋 ${AHEAD}개, push 건너뜀)"
else
  card "$WT" completed "$BASE 에 머지, push 완료"
  # 워크트리와 카드가 삭제된 뒤에도 머지 이력을 확인할 수 있도록 기록한다.
  if [ "$MERGED" = 1 ]; then
    journal "land $REPO/$NAME -- 이미 머지돼 있어 뒷정리만 (리뷰 $(rounds_done "$REPO" "$NAME")차)"
  else
    journal "land $REPO/$NAME -- $BASE 에 머지, push 완료 (커밋 ${AHEAD}개, 리뷰 $(rounds_done "$REPO" "$NAME")차)"
  fi
fi

# 현재 작업 디렉터리는 삭제하지 않는다. 우산이 자기 변경을 land할 때
# 워크트리를 삭제하면 호출한 셸의 cwd도 사라진다.
SELF=0
case "$PWD/" in "$WT"/*) SELF=1 ;; esac
if [ "$SELF" = 1 ] && [ "${KEEP:-}" != "1" ] && [ "$PUSHED" != skip ]; then
  printf '이 워크트리 안에서 부르고 있다. 지우지 않고 남긴다.\n'
  printf '지우려면 밖에서 부른다: orca worktree rm --worktree "path:%s" --force\n' "$WT"
  KEEP=1
fi

if [ "${KEEP:-}" = "1" ] || [ "$PUSHED" = skip ]; then
  printf '워크트리를 남긴다: %s\n' "$WT"
  if [ "$PUSHED" = skip ]; then
    printf '올린 뒤 지운다: git -C %s push origin %s && orca worktree rm --worktree "path:%s" --force\n' \
      "$MAIN" "$BASE" "$WT"
  fi
else
  orca worktree rm --worktree "path:$WT" --force --json 2>&1 | orca_check
  git -C "$MAIN" branch -d "$BRANCH" 2>/dev/null || true
  rm -f "$(handle_file "$REPO" "$NAME" work)" "$(handle_file "$REPO" "$NAME" review)"
  printf '워크트리를 지웠다: %s\n' "$WT"
  printf '리뷰 기록은 남긴다: %s\n' "$RF"
fi
