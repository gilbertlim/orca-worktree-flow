#!/usr/bin/env bash
# 레포 하나에 워크트리를 따고 그 안에서 에이전트를 띄운다.
#
#   dispatch.sh <repo> <worktree-name> <prompt-file>
#
# 예:
#   dispatch.sh shared migration-platform-trade /tmp/prompt.md
#
# 환경변수:
#   AGENT_CMD    기본은 설정의 agentCmd, 없으면 "claude --permission-mode auto"
#   BASE_BRANCH  기본은 설정의 baseBranch, 없으면 main
#   NO_SETUP=1   셋업 스크립트를 건너뛴다
#   ORCA_OWNER   우산을 손으로 지정한다. 기본은 $PWD 에서 알아낸다
#
# 우산 워크트리 안에서 부르면 만들어지는 이름 앞에 "<우산레포>.<우산워크트리>." 가
# 붙는다. 서브 레포 하나를 우산 여럿이 겨눌 때 어느 것이 누구 몫인지 이름만 보고
# 갈리게 하려는 것이고, status 가 남의 것을 안 찍는 근거도 이 접두다.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -ge 3 ] || die "사용법: dispatch.sh <repo> <worktree-name> <prompt-file>"

REPO="$1"; NAME="$2"; PROMPT_FILE="$3"
# 접두가 붙기 전 이름. 터미널 제목은 이것으로 단다 -- 탭이 이미 그 워크트리
# 안에 앉으므로 레포도 우산도 제목에서는 중복이다.
TITLE="$2"

[ -f "$PROMPT_FILE" ] || die "프롬프트 파일이 없다: $PROMPT_FILE"
[ -s "$PROMPT_FILE" ] || die "프롬프트 파일이 비었다: $PROMPT_FILE"

resolve_repo "$REPO" >/dev/null

OWNER="$(owner_id)"
if [ -n "$OWNER" ]; then
  NAME="$(prefixed_name "$OWNER" "$NAME")"
else
  printf '주의: 우산 워크트리 밖에서 부른다. 접두 없이 만든다.\n' >&2
  printf '      우산 레포에 워크트리를 먼저 따고 거기서 부르는 것이 기본이다.\n' >&2
fi

WT="$(worktree_path "$REPO" "$NAME")"

[ -d "$WT" ] && die "이미 있는 워크트리다: $WT
이어서 붙이려면 review 나 orca terminal create 를 쓴다."

# 셋업을 여기서 동기로 돌린다는 것을 만들기 전에 선언한다. 아래 setup이 끝나야
# 에이전트가 뜨는 순서가 이 스크립트의 존재 이유이고, 플러그인이 같은 생성
# 이벤트로 끼어들면 그 순서가 깨진다.
CLAIM="$(claim_file "$REPO" "$NAME")"
mkdir -p "$(dirname "$CLAIM")"
printf '%s' "$$" > "$CLAIM"
trap 'rm -f "$CLAIM"' EXIT

printf '워크트리를 만든다: %s/%s\n' "$REPO" "$NAME"
orca worktree create \
  --repo "name:$REPO" \
  --name "$NAME" \
  --base-branch "$BASE_BRANCH" \
  --json 2>&1 | orca_check

require_worktree "$WT"

SETUP="$(setup_script)"
SETUP_ENABLED="$(cfg_get setup.enabled true)"
if [ "${NO_SETUP:-}" = "1" ] || [ "$SETUP_ENABLED" = "false" ] || [ ! -x "$SETUP" ]; then
  # 건너뛰라고 했으면 플러그인도 물러서야 한다. claim은 이 스크립트가 끝나면
  # 사라지므로, 워크트리에 남는 표식으로 바꿔 둔다.
  [ -x "$SETUP" ] || printf '셋업 스크립트가 없거나 실행 권한이 없다: %s\n' "$SETUP" >&2
  date -u '+%Y-%m-%dT%H:%M:%SZ' \
    > "$(git -C "$WT" rev-parse --absolute-git-dir)/worktree-setup.done" 2>/dev/null || true
else
  printf 'gitignore된 파일을 메인 체크아웃에서 채운다\n'
  RC=0
  "$SETUP" "$WT" || RC=$?
  if [ "$RC" = 75 ]; then
    # 75는 실패가 아니라 남이 잡고 있다는 뜻이다. 끝날 때까지 기다리고,
    # 그쪽이 성공했는지는 표식으로 본다. 남의 종료 코드는 우리가 못 본다.
    printf '  다른 실행이 셋업을 잡고 있다. 끝나기를 기다린다.\n'
    wait_for_setup "$WT"
    [ -f "$(git -C "$WT" rev-parse --absolute-git-dir)/worktree-setup.done" ] || RC=1
  fi
  if [ "$RC" != 0 ] && [ "$RC" != 75 ]; then
    printf '  셋업이 깨끗하게 끝나지 않았다. 빌드 전에 손으로 확인한다.\n' >&2
    # 카드에도 남긴다. 아래에서 곧 "에이전트 투입"을 쓰므로, 여기서 안 남기면
    # 빌드가 깨진 워크트리가 카드에도 status에도 멀쩡한 얼굴로 앉는다.
    card "$WT" "" "셋업 실패 -- 빌드 전에 손으로 확인한다"
    SETUP_FAILED=1
  fi
fi

printf '에이전트를 띄운다: %s\n' "$AGENT_CMD"
# 프롬프트 파일을 그대로 넘기지 않고 카드 지시를 붙여 임시 파일로 만든다.
# 오케스트레이터가 프롬프트마다 그 지시를 기억해 넣게 두면 빠지는 날이 온다.
TMP="$(mktemp -t orca-dispatch)"
{ cat "$PROMPT_FILE"; card_rule "$WT"; } > "$TMP"

H="$(orca terminal create \
  --worktree "path:$WT" \
  --title "$TITLE" \
  --command "$AGENT_CMD \"\$(cat '$TMP')\"" \
  --json 2>&1 | terminal_handle)"

# 핸들을 기억해 둔다. 리뷰 결과를 되돌릴 때 이 터미널을 다시 찾아야 하는데,
# 에이전트가 탭 제목을 자기 마음대로 바꿔서 제목으로는 못 찾는다.
# 카드는 붙은 뒤에 찍는다. 먼저 찍으면 터미널이 안 떠도 카드는 투입됐다고 말한다.
# 셋업이 깨졌으면 그 사실을 투입 줄에 실어 보낸다. card는 필드를 통째로 덮으므로
# 앞에서 남긴 실패 줄이 여기서 지워진다.
NOTE=""
if [ "${SETUP_FAILED:-0}" = 1 ]; then
  NOTE=" -- 셋업 실패, 빌드 전에 손으로 확인한다"
fi

if [ -n "$H" ]; then
  save_handle "$REPO" "$NAME" work "$H"
  card "$WT" in-progress "에이전트 투입$NOTE"
else
  card "$WT" in-progress "에이전트가 안 붙었다 -- Orca에서 탭을 본다$NOTE"
fi

journal "dispatch $REPO/$NAME -- $(head -1 "$PROMPT_FILE" | cut -c1-80)"

printf '\n경로   %s\n' "$WT"
# Orca가 브랜치에 git 사용자명을 앞에 붙이는 일이 있어(gilbertim/<이름>) 워크트리
# 이름과 안 맞는다. 짐작하지 않고 워크트리에 직접 묻는다.
printf '브랜치 %s\n' "$(git -C "$WT" branch --show-current 2>/dev/null || printf '%s' "$NAME")"
printf '진행   %s/bin/status.sh\n' "$PLUGIN_ROOT"
printf '리뷰   %s/bin/review.sh %s %s\n' "$PLUGIN_ROOT" "$REPO" "$NAME"
# set -e 아래라 마지막 줄이 참이 아니면 종료 코드가 1로 나간다. || true 가 그것을 막는다.
[ -n "$OWNER" ] && printf '우산   %s (기록: %s)\n' "$OWNER" "$(journal_file)" || true
