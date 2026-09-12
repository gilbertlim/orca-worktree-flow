#!/usr/bin/env bash
# 레포에 워크트리를 만들고 에이전트를 실행한다.
#
#   dispatch.sh <repo> <worktree-name> <prompt-file>
#   dispatch.sh --repos [--all]  후보 레포 조회
#   예: dispatch.sh shared migration-platform-trade /tmp/prompt.md
#
# 환경변수:
#   AGENT_CMD    설정의 agentCmd, 없으면 "claude --permission-mode auto"
#   BASE_BRANCH  대상 레포의 baseBranch, 없으면 main
#   NO_SETUP=1   초기 설정 생략
#   ORCA_OWNER   우산 지정. 기본은 $PWD에서 확인
#
# 우산 안에서 실행하면 <우산레포>.<우산워크트리>. 접두를 붙인다.
# 같은 서브 레포를 여러 우산이 사용해도 status에서 소속을 구분할 수 있다.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --repos는 워크트리를 만들지 않고 같은 프로젝트 그룹의 후보를 조회한다.
# 오케스트레이터가 CLAUDE.md에서 담당 범위를 확인할 수 있도록 이름과 경로를 출력한다.
if [ "${1:-}" = "--repos" ]; then
  shift
  GROUP=""
  [ "${1:-}" = "--all" ] || GROUP="$(current_group)"
  repo_paths | awk -F'\t' -v g="$GROUP" '
    $1 == "" { next }
    g == "" || $3 == g { printf "%s\t%s\n", $1, $2 }
  '
  exit 0
fi

[ $# -ge 3 ] || die "사용법: dispatch.sh <repo> <worktree-name> <prompt-file>
후보 레포를 보려면: dispatch.sh --repos [--all]"

REPO="$1"; NAME="$2"; PROMPT_FILE="$3"
# 터미널은 워크트리 안에 있으므로 제목에서 레포와 우산 접두를 생략한다.
TITLE="$2"

[ -f "$PROMPT_FILE" ] || die "프롬프트 파일이 없다: $PROMPT_FILE"
[ -s "$PROMPT_FILE" ] || die "프롬프트 파일이 비었다: $PROMPT_FILE"

resolve_repo "$REPO" >/dev/null

# 기준 브랜치는 그 레포 것으로 정한다. status, review, land 와 같은 함수다.
BASE="$(base_branch_for "$REPO")"

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

# 생성 이벤트 전에 claim을 기록해 플러그인의 중복 실행을 막는다.
# dispatch가 초기 설정을 동기 실행한 뒤 에이전트를 시작하는 순서를 보장한다.
CLAIM="$(claim_file "$REPO" "$NAME")"
mkdir -p "$(dirname "$CLAIM")"
printf '%s' "$$" > "$CLAIM"
trap 'rm -f "$CLAIM"' EXIT

printf '워크트리를 만든다: %s/%s\n' "$REPO" "$NAME"
orca worktree create \
  --repo "name:$REPO" \
  --name "$NAME" \
  --base-branch "$BASE" \
  --json 2>&1 | orca_check

require_worktree "$WT"

SETUP="$(setup_script)"
SETUP_ENABLED="$(cfg_get setup.enabled true)"
if [ "${NO_SETUP:-}" = "1" ] || [ "$SETUP_ENABLED" = "false" ] || [ ! -x "$SETUP" ]; then
  # 초기 설정을 생략하면 플러그인도 실행하지 않도록 완료 표식을 남긴다.
  # claim은 스크립트 종료 시 삭제되므로 이 표식으로 생략 상태를 유지한다.
  [ -x "$SETUP" ] || printf '셋업 스크립트가 없거나 실행 권한이 없다: %s\n' "$SETUP" >&2
  date -u '+%Y-%m-%dT%H:%M:%SZ' \
    > "$(git -C "$WT" rev-parse --absolute-git-dir)/worktree-setup.done" 2>/dev/null || true
else
  printf 'gitignore된 파일을 메인 체크아웃에서 채운다\n'
  RC=0
  # 셋업 스크립트는 메인 체크아웃에서 상위로 올라가며 설정을 찾는다. 우산이 형제
  # 디렉터리에 있으면 그 경로로는 닿지 않으므로 dispatch가 찾은 루트를 전달한다.
  ORCA_FLOW_ROOT="${ORCA_FLOW_ROOT:-$PROJECT_ROOT}" "$SETUP" "$WT" || RC=$?
  if [ "$RC" = 75 ]; then
    # 75는 다른 실행이 잠금을 보유했다는 뜻이다. 종료를 기다린 뒤 완료 표식을 확인한다.
    # 다른 프로세스의 종료 코드는 직접 읽을 수 없다.
    printf '  다른 실행이 셋업을 실행 중이다. 완료를 기다린다.\n'
    wait_for_setup "$WT"
    [ -f "$(git -C "$WT" rev-parse --absolute-git-dir)/worktree-setup.done" ] || RC=1
  fi
  if [ "$RC" != 0 ] && [ "$RC" != 75 ]; then
    printf '  셋업이 완료되지 않았다. 빌드 전에 직접 확인한다.\n' >&2
    # 초기 설정 실패를 카드에 기록한다. 에이전트 시작 문구에도 실패를 포함해야
    # 빌드할 수 없는 상태가 정상으로 표시되지 않는다.
    card "$WT" "" "셋업 실패 -- 빌드 전에 직접 확인한다"
    SETUP_FAILED=1
  fi
fi

printf '에이전트를 띄운다: %s\n' "$AGENT_CMD"
# 카드 갱신 지시가 누락되지 않도록 프롬프트에 자동 추가하고 임시 파일로 저장한다.
TMP="$(mktemp -t orca-dispatch)"
{ cat "$PROMPT_FILE"; card_rule "$WT"; } > "$TMP"

H="$(orca terminal create \
  --worktree "path:$WT" \
  --title "$TITLE" \
  --command "$AGENT_CMD \"\$(cat '$TMP')\"" \
  --json 2>&1 | terminal_handle)"

# 수정 요청에 사용할 터미널 핸들을 저장한다. 탭 제목은 에이전트가 바꿀 수 있다.
# 터미널 생성 후 카드를 갱신해 실제 시작 여부를 반영한다.
# 카드는 전체를 덮어쓰므로 초기 설정 실패도 시작 문구에 포함한다.
NOTE=""
if [ "${SETUP_FAILED:-0}" = 1 ]; then
  NOTE=" -- 셋업 실패, 빌드 전에 직접 확인한다"
fi

if [ -n "$H" ]; then
  save_handle "$REPO" "$NAME" work "$H"
  card "$WT" in-progress "에이전트 시작$NOTE"
else
  card "$WT" in-progress "에이전트 시작 실패 -- Orca에서 탭 확인$NOTE"
fi

journal "dispatch $REPO/$NAME -- $(head -1 "$PROMPT_FILE" | cut -c1-80)"

printf '\n경로   %s\n' "$WT"
# Orca가 브랜치 앞에 Git 사용자명(gilbertim/<이름>)을 붙일 수 있으므로
# 워크트리에서 실제 브랜치 이름을 읽는다.
printf '브랜치 %s\n' "$(git -C "$WT" branch --show-current 2>/dev/null || printf '%s' "$NAME")"
printf '진행   %s/bin/status.sh\n' "$PLUGIN_ROOT"
printf '리뷰   %s/bin/review.sh %s %s\n' "$PLUGIN_ROOT" "$REPO" "$NAME"
# set -e 아래라 마지막 줄이 참이 아니면 종료 코드가 1로 나간다. || true 가 그것을 막는다.
[ -n "$OWNER" ] && printf '우산   %s (기록: %s)\n' "$OWNER" "$(journal_file)" || true
