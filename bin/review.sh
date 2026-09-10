#!/usr/bin/env bash
# 기존 워크트리에서 리뷰어를 실행한다.
#
#   review.sh <repo> <worktree-name> [prompt-file]
#
# 오케스트레이터 세션에 여러 레포의 diff가 모이지 않도록 해당 워크트리에서 리뷰한다.
# TUI 출력은 스크롤백에서 사라질 수 있어 결과를 파일에 저장한다.
# 프롬프트를 생략하면 기본 지시와 설정의 review.context를 사용한다.
# 기존 리뷰어에 재리뷰를 요청해 맥락을 유지하며, NEW=1이면 새로 실행한다.
# 이전 판정은 .roundN.md로 보관한다. 상한은 review.maxRounds(기본 5)이며
# MAX_ROUNDS로 일회 변경하거나 FORCE=1로 초과 실행할 수 있다.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -ge 2 ] || die "사용법: review.sh <repo> <worktree-name> [prompt-file]"

REPO="$1"; NAME="$2"; PROMPT_FILE="${3:-}"

WT="$(worktree_path "$REPO" "$NAME")"
require_worktree "$WT"

# 기준 브랜치는 그 레포 것으로 정한다. status, dispatch, land 와 같은 함수다.
BASE="$(base_branch_for "$REPO")"

DIRTY="$(git -C "$WT" status --porcelain | awk 'NR <= 5')"
if [ -n "$DIRTY" ]; then
  printf '워크트리에 미커밋 변경이 있다. 리뷰 중 diff가 바뀌면 판정이 실제로 커밋될 것과 달라진다.\n' >&2
  printf '%s\n' "$DIRTY" >&2
  printf '그래도 띄우려면 FORCE=1 을 준다.\n' >&2
  [ "${FORCE:-}" = "1" ] || exit 1
fi

# 로컬 기준 브랜치가 없으면 status와 같이 origin을 사용한다.
# 리뷰 범위도 프롬프트에 전달하므로 리뷰어가 사용할 수 있는 이름으로 정한다.
REV="$BASE"
git -C "$WT" rev-parse --verify -q "$REV" >/dev/null 2>&1 || REV="origin/$BASE"
AHEAD="$(git -C "$WT" rev-list --count "$REV..HEAD" 2>/dev/null || echo 0)"
[ "$AHEAD" -gt 0 ] || die "$BASE 대비 커밋이 없다. 리뷰할 것이 없다."

OUT="$(review_file "$REPO" "$NAME")"
mkdir -p "$ORCA_REVIEWS"

MAX_ROUNDS="${MAX_ROUNDS:-$(cfg_get review.maxRounds 5)}"
DONE="$(rounds_done "$REPO" "$NAME")"
ROUND=$((DONE + 1))

if [ "$ROUND" -gt "$MAX_ROUNDS" ] && [ "${FORCE:-}" != "1" ]; then
  printf '리뷰 %s차다. 상한 %s차를 넘었다.\n' "$ROUND" "$MAX_ROUNDS" >&2
  if [ -f "$OUT" ]; then
    printf '\n남은 판정 (%s) -- blocking %s건\n' "$OUT" "$(blocking_count "$OUT")" >&2
    blocking_section "$OUT" 20 >&2
  fi
  printf '\n리뷰를 계속할지 사용자가 판단한다.\n' >&2
  printf '  리뷰 계속    FORCE=1 %s/bin/review.sh %s %s\n' "$PLUGIN_ROOT" "$REPO" "$NAME" >&2
  printf '  머지 진행    %s/bin/land.sh %s %s\n' "$PLUGIN_ROOT" "$REPO" "$NAME" >&2
  exit 1
fi

# 기존 판정을 보관해 재리뷰로 기록이 덮이지 않게 한다. 파일은 차수 집계에도 사용한다.
archive_review "$REPO" "$NAME"

# 리뷰가 반복될 때 근거 없는 지적을 추가하지 않도록 검토 범위를 명시한다.
SCOPE=""
if [ "$ROUND" -ge 2 ]; then
  SCOPE="

## 이번 라운드의 범위 (리뷰 ${ROUND}차, 상한 ${MAX_ROUNDS})

앞 라운드의 판정은 $(round_file "$REPO" "$NAME" "$DONE") 에 있다. 먼저 읽는다.
이전 blocking이 해결됐는지 항목별로 확인한다.
새 발견은 blocking 대신 참고 사항으로 적는다. 발견이 없으면 없다고 적는다."
fi

OUT_RULE="

## 결과를 남기는 법

리뷰 결과를 $OUT 에 마크다운으로 저장한다. 터미널 출력은 스크롤백에서 사라질 수 있다.
blocking과 non-blocking을 구분하고, 항목마다 파일 경로와 줄 번호, 무엇이 왜 문제인지, 어떻게 고치면 되는지를 넣는다.
발견이 없으면 통과라고 적는다. 워크트리 파일은 읽기만 하고 수정하지 않는다.

파일을 다 쓴 뒤 판정을 Orca 카드에도 한 줄로 남긴다. 오케스트레이터가 파일을 열기 전에 그 줄을 먼저 본다.

\`\`\`
orca worktree set --worktree \"path:$WT\" --comment \"리뷰: blocking <개수>건\" --json
\`\`\`

통과면 comment를 \"리뷰 통과\"로 한다. Orca 메타데이터만 갱신하므로 워크트리 파일에는 변경이 없다."

if [ -n "$PROMPT_FILE" ]; then
  [ -f "$PROMPT_FILE" ] || die "프롬프트 파일이 없다: $PROMPT_FILE"
  BODY="$(cat "$PROMPT_FILE")"
else
  # 프로젝트에서 추가한 리뷰 지시. 다른 레포의 계약 정본 위치 등을 전달한다.
  CONTEXT="$(cfg_get review.context "")"
  [ -n "$CONTEXT" ] && CONTEXT="
$CONTEXT"
  BODY="너는 리뷰어다. **읽기만 한다. 코드도 문서도 고치지 않고 커밋하지 않는다.**

리뷰 대상은 지금 이 worktree($REPO, 브랜치 $NAME)이고 범위는 커밋 범위 \`$REV..HEAD\`다.$CONTEXT
정확성과 공유 계약 및 명세와의 일치 여부를 확인한다. 빌드와 테스트를 실제로 돌려 결과를 함께 적는다."
fi
BODY="$BODY$SCOPE"

# 이미 살아 있는 리뷰어가 있으면 그쪽에 재리뷰를 시킨다
if [ "${NEW:-}" != "1" ] && EXIST="$(load_handle "$REPO" "$NAME" review 2>/dev/null)"; then
  printf '리뷰어가 이미 떠 있다. 재리뷰를 시킨다: %s\n' "$EXIST"
  send_prompt "$EXIST" "고친 것이 커밋됐다. \`$REV..HEAD\`를 다시 리뷰한다.${SCOPE}${OUT_RULE}" \
    || die "리뷰어에게 메시지를 전달하지 못했다. Orca에서 해당 탭을 확인한다."
  # 메시지 전송에 성공한 뒤 카드를 갱신한다.
  card "$WT" in-review "재리뷰 ${ROUND}차 (커밋 ${AHEAD}개)"
  journal "review $REPO/$NAME ${ROUND}차 (재리뷰, 커밋 ${AHEAD}개)"
  printf '결과   %s\n' "$OUT"
  exit 0
fi

printf '리뷰어를 띄운다: %s/%s (%s차, 커밋 %s개)\n' "$REPO" "$NAME" "$ROUND" "$AHEAD"
TMP="$(mktemp -t orca-review)"
printf '%s%s\n' "$BODY" "$OUT_RULE" > "$TMP"

H="$(orca terminal create \
  --worktree "path:$WT" \
  --title "REVIEW $(short_name "$NAME")" \
  --command "$AGENT_CMD \"\$(cat '$TMP')\"" \
  --json 2>&1 | terminal_handle)"

if [ -n "$H" ]; then
  save_handle "$REPO" "$NAME" review "$H"
  card "$WT" in-review "리뷰 ${ROUND}차 (커밋 ${AHEAD}개)"
else
  card "$WT" in-review "리뷰어 시작 실패 -- Orca에서 탭 확인"
fi

journal "review $REPO/$NAME ${ROUND}차 (커밋 ${AHEAD}개)"

printf '결과   %s\n' "$OUT"
printf '되돌림 %s/bin/handback.sh %s %s\n' "$PLUGIN_ROOT" "$REPO" "$NAME"
