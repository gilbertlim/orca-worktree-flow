#!/usr/bin/env bash
# 이미 있는 워크트리 안에서 리뷰어를 띄운다. 새 워크트리를 만들지 않는다.
#
#   review.sh <repo> <worktree-name> [prompt-file]
#
# 리뷰는 작업이 있는 그 워크트리에서 돈다. 오케스트레이터 세션에서 돌리면
# diff를 그 세션 컨텍스트로 끌어올리게 되고, 레포가 여럿일 때 그게 곧 한도다.
#
# 결과는 반드시 파일로 받는다. TUI 안에만 뱉으면 스피너가 스크롤백을 밀어내
# 판정이 통째로 사라진다.
#
# 프롬프트 파일을 안 주면 기본 리뷰 지시로 돈다. 그때 프로젝트가 설정의
# review.context 에 한 줄을 얹으면 계약 정본 위치 같은 것이 함께 실린다.
# 리뷰어가 이미 그 워크트리에 살아 있으면 새로 띄우지 않고 그쪽에 재리뷰를
# 시킨다. 컨텍스트를 들고 있어 지난 발견과 지금 상태를 견줄 수 있다.
# NEW=1 을 주면 그래도 새로 띄운다.
#
# 라운드를 센다. 한 번 돌 때마다 앞 판정을 .roundN.md 로 밀어 두므로 재리뷰가
# 앞 판정을 덮지 않고, 상한(설정 review.maxRounds, 기본 5)에 닿으면 멈춘다.
# MAX_ROUNDS 로 한 번만 다르게, FORCE=1 로 상한을 넘겨 돌릴 수 있다.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -ge 2 ] || die "사용법: review.sh <repo> <worktree-name> [prompt-file]"

REPO="$1"; NAME="$2"; PROMPT_FILE="${3:-}"

WT="$(worktree_path "$REPO" "$NAME")"
require_worktree "$WT"

# 기준 브랜치는 그 레포 것으로 정한다. status, dispatch, land 와 같은 함수다.
BASE="$(base_branch_for "$REPO")"

DIRTY="$(git -C "$WT" status --porcelain | awk 'NR <= 5')"
if [ -n "$DIRTY" ]; then
  printf '작업 트리가 깨끗하지 않다. 리뷰가 도는 동안 diff가 바뀌면 판정이 실제로 커밋될 것과 달라진다.\n' >&2
  printf '%s\n' "$DIRTY" >&2
  printf '그래도 띄우려면 FORCE=1 을 준다.\n' >&2
  [ "${FORCE:-}" = "1" ] || exit 1
fi

# 기준 브랜치가 이 워크트리에 없으면 origin 쪽을 본다. status 와 같은 fallback 이다.
# 세는 것만 맞춰서는 모자란다 -- 아래 프롬프트가 리뷰어에게 범위를 그대로
# 넘기므로, 리뷰어가 칠 수 있는 이름으로 여기서 정해 둔다.
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
  printf '\n왕복을 더 쓸 값인지 사람이 판단한다.\n' >&2
  printf '  계속 돌린다   FORCE=1 %s/bin/review.sh %s %s\n' "$PLUGIN_ROOT" "$REPO" "$NAME" >&2
  printf '  여기서 닫는다 %s/bin/land.sh %s %s\n' "$PLUGIN_ROOT" "$REPO" "$NAME" >&2
  exit 1
fi

# 이번 판정이 앞엣것을 덮지 않게 민다. 재리뷰가 무엇이 지적이었는지를 지우던
# 자리가 여기다 -- 밀어 둔 파일이 곧 라운드 수이기도 하다.
archive_review "$REPO" "$NAME"

# 셋을 넘으면 억지 지적이 붙기 시작한다. 범위를 프롬프트에서 못 박는다.
SCOPE=""
if [ "$ROUND" -ge 2 ]; then
  SCOPE="

## 이번 라운드의 범위 (리뷰 ${ROUND}차, 상한 ${MAX_ROUNDS})

앞 라운드의 판정은 $(round_file "$REPO" "$NAME" "$DONE") 에 있다. 먼저 읽는다.
거기 적힌 blocking이 항목마다 실제로 닫혔는지를 본다. 그것이 이번 리뷰의 본론이다.
새로 눈에 띈 것은 blocking으로 올리지 말고 참고로만 적는다. 없으면 없다고 적는다 -- 억지로 만들지 않는다."
fi

OUT_RULE="

## 결과를 남기는 법

발견을 $OUT 에 마크다운으로 쓴다. 터미널에만 뱉지 마라. 그러면 스크롤백에 밀려 사라진다.
blocking과 non-blocking을 갈라 적고, 항목마다 파일 경로와 줄 번호, 무엇이 왜 문제인지, 어떻게 고치면 되는지를 넣는다.
발견이 없으면 통과라고 적는다. 워크트리 안의 파일은 하나도 건드리지 마라 -- 읽기만 한다.

파일을 다 쓴 뒤 판정을 Orca 카드에도 한 줄로 남긴다. 오케스트레이터가 파일을 열기 전에 그 줄을 먼저 본다.

\`\`\`
orca worktree set --worktree \"path:$WT\" --comment \"리뷰: blocking <개수>건\" --json
\`\`\`

통과면 comment를 \"리뷰 통과\"로 한다. 이건 Orca 메타데이터라 워크트리 파일을 건드리는 것이 아니다."

if [ -n "$PROMPT_FILE" ]; then
  [ -f "$PROMPT_FILE" ] || die "프롬프트 파일이 없다: $PROMPT_FILE"
  BODY="$(cat "$PROMPT_FILE")"
else
  # 프로젝트가 얹는 한 줄. 계약 정본이 어디 있는지처럼 리뷰어가 알아야 하는데
  # 워크트리 안에서는 안 보이는 것이 여기 온다.
  CONTEXT="$(cfg_get review.context "")"
  [ -n "$CONTEXT" ] && CONTEXT="
$CONTEXT"
  BODY="너는 reviewer다. **읽기만 한다. 코드도 문서도 고치지 않고 커밋하지 않는다.**

리뷰 대상은 지금 이 worktree($REPO, 브랜치 $NAME)이고 범위는 커밋 범위 \`$REV..HEAD\`다.$CONTEXT
정확성과 공유 계약 정합, 스펙 정합을 본다. 빌드와 테스트를 실제로 돌려 결과를 함께 적는다."
fi
BODY="$BODY$SCOPE"

# 이미 살아 있는 리뷰어가 있으면 그쪽에 재리뷰를 시킨다
if [ "${NEW:-}" != "1" ] && EXIST="$(load_handle "$REPO" "$NAME" review 2>/dev/null)"; then
  printf '리뷰어가 이미 떠 있다. 재리뷰를 시킨다: %s\n' "$EXIST"
  send_prompt "$EXIST" "고친 것이 커밋됐다. \`$REV..HEAD\`를 다시 리뷰한다.${SCOPE}${OUT_RULE}" \
    || die "메시지가 리뷰어에 안 들어갔다. Orca에서 그 탭을 직접 본다."
  # 카드는 메시지가 실제로 들어간 뒤에 찍는다. 위에서 die하면 여기까지 안 온다.
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
  card "$WT" in-review "리뷰어가 안 붙었다 -- Orca에서 탭을 본다"
fi

journal "review $REPO/$NAME ${ROUND}차 (커밋 ${AHEAD}개)"

printf '결과   %s\n' "$OUT"
printf '되돌림 %s/bin/handback.sh %s %s\n' "$PLUGIN_ROOT" "$REPO" "$NAME"
