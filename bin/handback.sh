#!/usr/bin/env bash
# 리뷰 결과를 그 워크트리의 작업 에이전트에게 되돌려 고치게 한다.
#
#   handback.sh <repo> <worktree-name> [review-file]
#
# 리뷰 파일을 안 주면 review.sh가 쓰는 기본 경로를 쓴다.
# 작업 에이전트가 죽었으면 같은 워크트리에 새로 띄운다. 워크트리가 컨텍스트를
# 들고 있으므로 브랜치와 커밋은 그대로다.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -ge 2 ] || die "사용법: handback.sh <repo> <worktree-name> [review-file]"

REPO="$1"; NAME="$2"
FILE="${3:-$(review_file "$REPO" "$NAME")}"

WT="$(worktree_path "$REPO" "$NAME")"
require_worktree "$WT"

[ -f "$FILE" ] || die "리뷰 결과 파일이 없다: $FILE
리뷰가 아직 안 끝났거나 파일로 안 남겼다. review.sh 로 돌린다."

BLOCKING="$(blocking_count "$FILE")"
printf '%s/%s 에 리뷰 결과를 넘긴다 (%s)\n' "$REPO" "$NAME" "$FILE"

MSG="리뷰 결과가 $FILE 에 있다. 읽고 blocking을 고쳐라.

- blocking은 전부 닫는다. non-blocking은 값을 재서 판단하고, 안 고치기로 한 것은 왜 안 고치는지 한 줄로 남긴다.
- 리뷰어가 틀렸다고 판단되면 고치지 말고 근거를 대라. 지적을 받았다는 이유만으로 코드를 바꾸지 않는다.
- 고친 뒤 빌드와 테스트를 실제로 돌려 결과를 보고한다.
- 같은 브랜치에 이어서 커밋한다. push는 하지 않는다.
- 리뷰 결과 파일은 고치지 마라. 재리뷰가 덮어쓴다."

# 리뷰가 난 뒤에 바깥에서 달라진 것이 있으면 오케스트레이터가 함께 실어 보낸다.
# 다른 워크트리가 계약을 고쳐 그 판정의 전제가 바뀌는 일이 실제로 난다.
if [ -n "${NOTE:-}" ]; then
  MSG="$MSG

## 오케스트레이터 메모 — 리뷰가 난 뒤에 달라진 것

$NOTE"
fi

if H="$(load_handle "$REPO" "$NAME" work 2>/dev/null)"; then
  printf '작업 에이전트에게 보낸다: %s\n' "$H"
  send_prompt "$H" "$MSG" || die "메시지가 에이전트에 안 들어갔다. Orca에서 그 탭을 직접 본다."
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

# 카드를 리뷰에서 작업으로 되돌린다. 리뷰어가 남긴 판정 줄을 여기서 덮어야
# 카드가 "리뷰: blocking 2건"에 멈춰 있지 않고 지금 처지를 든다.
# 위에서 메시지가 안 들어가면 die하므로 여기까지 오는 것은 실제로 넘어간 때뿐이다.
if [ "${BLOCKING:-0}" -gt 0 ]; then
  card "$WT" in-progress "재작업 -- 리뷰 blocking 반영"
else
  card "$WT" in-progress "재작업 -- 리뷰 지적 반영"
fi

journal "handback $REPO/$NAME -- blocking ${BLOCKING:-0}건"

printf '\n고치고 커밋되면 재리뷰: %s/bin/review.sh %s %s\n' "$PLUGIN_ROOT" "$REPO" "$NAME"
