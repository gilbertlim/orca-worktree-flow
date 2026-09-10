#!/usr/bin/env bash
# 리뷰 결과를 작업 에이전트에 전달한다.
#
#   handback.sh <repo> <worktree-name> [review-file]
#
# 리뷰 파일을 생략하면 review.sh의 기본 경로를 사용한다.
# 에이전트가 종료됐으면 같은 워크트리에서 재실행한다. 브랜치와 커밋은 유지된다.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -ge 2 ] || die "사용법: handback.sh <repo> <worktree-name> [review-file]"

REPO="$1"; NAME="$2"
FILE="${3:-$(review_file "$REPO" "$NAME")}"

WT="$(worktree_path "$REPO" "$NAME")"
require_worktree "$WT"

[ -f "$FILE" ] || die "리뷰 결과 파일이 없다: $FILE
리뷰가 끝나지 않았거나 결과가 저장되지 않았다. review.sh로 실행한다."

BLOCKING="$(blocking_count "$FILE")"
printf '%s/%s 에 리뷰 결과를 넘긴다 (%s)\n' "$REPO" "$NAME" "$FILE"

MSG="리뷰 결과가 $FILE 에 있다. 읽고 blocking을 고쳐라.

- blocking은 모두 해결한다. non-blocking은 수정 필요성을 판단하고, 수정하지 않는 항목은 이유를 한 줄로 남긴다.
- 리뷰어가 틀렸다고 판단되면 고치지 말고 근거를 대라. 지적을 받았다는 이유만으로 코드를 바꾸지 않는다.
- 고친 뒤 빌드와 테스트를 실제로 돌려 결과를 보고한다.
- 같은 브랜치에 이어서 커밋한다. push는 하지 않는다.
- 리뷰 결과 파일은 고치지 마라. 재리뷰가 덮어쓴다."

# 리뷰 이후 외부 변경을 함께 전달한다. 다른 워크트리의 계약 변경으로
# 판정의 전제가 달라질 수 있다.
if [ -n "${NOTE:-}" ]; then
  MSG="$MSG

## 오케스트레이터 메모: 리뷰 이후 변경 사항

$NOTE"
fi

if H="$(load_handle "$REPO" "$NAME" work 2>/dev/null)"; then
  printf '작업 에이전트에게 보낸다: %s\n' "$H"
  send_prompt "$H" "$MSG" || die "에이전트에게 메시지를 전달하지 못했다. Orca에서 해당 탭을 확인한다."
else
  printf '작업 에이전트가 없다. 같은 워크트리에 새로 띄운다.\n'
  TMP="$(mktemp -t orca-handback)"
  {
    printf '너는 이 worktree(%s, 브랜치 %s)의 담당 개발자다. 이 워크트리만 수정한다.\n\n%s\n' \
      "$REPO" "$NAME" "$MSG"
    card_rule "$WT"
  } > "$TMP"
  H="$(orca terminal create \
    --worktree "path:$WT" \
    --title "$(short_name "$NAME")" \
    --command "$AGENT_CMD \"\$(cat '$TMP')\"" \
    --json 2>&1 | terminal_handle)"
  [ -n "$H" ] && save_handle "$REPO" "$NAME" work "$H"
fi

# 수정 요청을 전달한 뒤 카드를 작업 상태로 바꾼다.
# 이전 판정 대신 현재 상태를 표시하며, 메시지 전송에 실패하면 여기까지 실행되지 않는다.
if [ "${BLOCKING:-0}" -gt 0 ]; then
  card "$WT" in-progress "재작업 -- 리뷰 blocking 반영"
else
  card "$WT" in-progress "재작업 -- 리뷰 지적 반영"
fi

journal "handback $REPO/$NAME -- blocking ${BLOCKING:-0}건"

printf '\n고치고 커밋되면 재리뷰: %s/bin/review.sh %s %s\n' "$PLUGIN_ROOT" "$REPO" "$NAME"
