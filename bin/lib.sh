#!/usr/bin/env bash
# bin/ 의 스크립트가 공유하는 함수. 직접 실행하지 않고 source 한다.
#
# 프로젝트마다 달라지는 값은 전부 프로젝트 루트의 .orca-flow.json 에서 온다.
# 그 파일이 없어도 기본값으로 돈다 -- 셋업만 조용히 빠지고 dispatch, review,
# handback, status, land 는 그대로 쓸 수 있다.
#
# 우선순위는 환경변수 > 설정 파일 > 기본값이다. 환경변수를 위에 두는 것은
# 한 번만 다르게 돌리는 자리가 실제로 있어서다(NO_PUSH=1, FORCE=1 처럼).

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=bin/config.sh
source "$PLUGIN_ROOT/bin/config.sh"

die() { printf '%s\n' "$*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 이(가) 없다. 먼저 설치한다."
}

need orca
need python3
need git

# ---------------------------------------------------------------------------
# 프로젝트 설정
# ---------------------------------------------------------------------------

# 사람이 부르는 자리라 $PWD 에서 위로 올라가며 찾는다.
orca_flow_load "$PWD"

ORCA_WORKSPACES="$(expand_home "${ORCA_WORKSPACES:-$(cfg_get workspaces "$HOME/orca/workspaces")}")"
ORCA_REVIEWS="$(expand_home "${ORCA_REVIEWS:-$(cfg_get reviews "$HOME/orca/reviews")}")"
AGENT_CMD="${AGENT_CMD:-$(cfg_get agentCmd "claude --permission-mode auto")}"
# 사람이 env 로 준 것인지를 설정 파일 값으로 덮기 전에 잡아 둔다.
# base_branch_for 의 우선순위가 여기서 나온다.
BASE_BRANCH_ENV="${BASE_BRANCH:-}"
BASE_BRANCH="${BASE_BRANCH:-$(cfg_get baseBranch main)}"

# 프로젝트가 쓴 셋업 스크립트. 안 적으면 플러그인이 들고 온 것을 쓴다.
setup_script() {
  local custom
  custom="$(cfg_get setup.script "")"
  if [ -n "$custom" ]; then
    case "$custom" in
      /*) printf '%s' "$custom" ;;
      *) printf '%s/%s' "${PROJECT_ROOT:-$PWD}" "$custom" ;;
    esac
    return 0
  fi
  printf '%s/bin/worktree-setup.sh' "$PLUGIN_ROOT"
}

# ---------------------------------------------------------------------------
# Orca
# ---------------------------------------------------------------------------

# 레포 displayName -> 메인 체크아웃 절대 경로
repo_path() {
  orca repo list --json 2>/dev/null | python3 -c '
import sys, json
want = sys.argv[1]
for r in json.load(sys.stdin)["result"]["repos"]:
    if r.get("displayName") == want:
        print(r["path"])
        break
' "$1"
}

# 레포 displayName, 메인 체크아웃 경로, 프로젝트 그룹 id 를 탭으로 이어 한 줄에
# 하나씩. 여러 레포를 도는 자리가 있어 한 번에 들고 온다 -- 레포마다 repo_path 를
# 부르면 orca repo list 를 그 수만큼 친다. 처음 쓸 때 채우고 그 뒤로는 안 친다.
# 서브셸에서 처음 부르면 그 메모가 부모로 안 돌아오므로, 레포를 여럿 도는 쪽은
# 루프에 들기 전에 `repo_paths >/dev/null` 로 한 번 채워 둔다.
REPO_PATHS=""
repo_paths() {
  [ -n "$REPO_PATHS" ] || REPO_PATHS="$(orca repo list --json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in d.get("result", {}).get("repos", []):
    # 탭으로 이어 찍으므로 값 안의 탭은 턴다. TERMS, CARDS 블록과 같은 규칙이다.
    print("%s\t%s\t%s" % (
        (r.get("displayName") or "").replace("\t", " "),
        (r.get("path") or "").replace("\t", " "),
        r.get("projectGroupId") or "",
    ))
' || true)"
  printf '%s\n' "$REPO_PATHS"
}

# 그 레포의 기준 브랜치.
#
# 우선순위는 env BASE_BRANCH > 레포 설정 > 호스트 설정이다. 마지막 것이 위의
# $BASE_BRANCH -- $PWD 나 ORCA_FLOW_ROOT 에서 한 번 정해진 값이다.
#
# 레포마다 따로 읽는 이유는 status 가 여러 레포의 워크트리를 한 표에 찍기
# 때문이다. 한 기준을 전부에 대면 기준이 main 이 아닌 레포는 커밋 칸이 통째로
# '?' 가 된다. status 가 안내한 land 가 실제로 돌려면 dispatch, review, land 도
# 같은 함수로 기준을 정해야 한다.
#
# 서브셸에서 ORCA_FLOW_ROOT 를 걷어 내는 것은, 그것이 있으면 config.sh 가 인자로
# 준 경로를 보지도 않아서다. 앱 플러그인이 status 를 부를 때 바로 그것을 준다.
base_branch_for() { # repo
  [ -z "$BASE_BRANCH_ENV" ] || { printf '%s' "$BASE_BRANCH_ENV"; return 0; }
  local path b
  path="$(repo_paths | awk -F'\t' -v n="$1" '$1==n {print $2; exit}')"
  [ -n "$path" ] || { printf '%s' "$BASE_BRANCH"; return 0; }
  b="$( (unset ORCA_FLOW_ROOT; orca_flow_load "$path"; cfg_get baseBranch "$BASE_BRANCH") )" || b=""
  printf '%s' "${b:-$BASE_BRANCH}"
}

# 지금 서 있는 자리의 레포 displayName. 못 알아내면 빈 문자열이다.
#
# 워크스페이스 아래면 경로에서 바로 나온다(owner_id 가 "<레포>.<워크트리>"). 아니면
# git 최상위를 등록된 경로와 맞춰 본다 -- 메인 체크아웃에서 부르는 경우다.
current_repo() {
  local owner top
  owner="$(owner_id)"
  [ -z "$owner" ] || { printf '%s' "${owner%%.*}"; return 0; }
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -n "$top" ] || return 0
  repo_paths | awk -F'\t' -v p="$top" '$2==p {print $1; exit}'
}

# 지금 서 있는 레포의 프로젝트 그룹 id. 그룹이 안 잡히면 빈 문자열이다.
current_group() {
  local me
  me="$(current_repo)"
  [ -n "$me" ] || return 0
  repo_paths | awk -F'\t' -v n="$me" '$1==n {print $3; exit}'
}

# 후보 레포. 기본은 지금 서 있는 레포와 **같은 프로젝트 그룹**의 것만이다.
#
# 그룹으로 거르는 것은 한 머신에 무관한 프로젝트가 여럿 등록돼 있기 때문이다.
# 전부를 후보로 내밀면 오케스트레이터가 남의 프로젝트 레포를 겨눌 수 있고,
# 사람이 그걸 잡아내려면 목록을 통째로 읽어야 한다. Orca 가 이미 그룹을 알고
# 있으니(repo list 의 projectGroupId) 그것을 그대로 쓴다.
#
# 그룹이 안 잡히는 자리(레포 밖, 그룹에 안 넣은 레포)에서는 거르지 않는다 --
# 거기서 빈 목록을 주면 후보가 아예 없어진다.
repo_names() { # [--all]
  local group=""
  [ "${1:-}" = "--all" ] || group="$(current_group)"
  repo_paths | awk -F'\t' -v g="$group" 'g == "" || $3 == g { print ($1 == "" ? "(이름 없음)" : $1) }'
}

worktree_path() { printf '%s/%s/%s' "$ORCA_WORKSPACES" "$1" "$2"; }

# orca --json 출력을 받아 ok가 아니면 죽는다
orca_check() {
  python3 -c '
import sys, json
d = json.load(sys.stdin)
if not d.get("ok"):
    sys.stderr.write(json.dumps(d.get("error", d), ensure_ascii=False) + "\n")
    sys.exit(1)
'
}

resolve_repo() {
  local name="$1" path
  path="$(repo_path "$name")"
  [ -n "$path" ] || die "orca에 등록되지 않은 레포다: $name
같은 그룹: $(repo_names | tr '\n' ' ')
전부 보려면 $PLUGIN_ROOT/bin/dispatch.sh --repos --all 이다.
등록은 Orca 앱에서 하거나 orca repo add 로 한다."
  printf '%s' "$path"
}

require_worktree() {
  local wt="$1"
  [ -d "$wt" ] || die "워크트리가 없다: $wt
먼저 dispatch 로 만든다."
}

# 리뷰 결과 파일. 워크트리 밖에 둔다 -- 안에 쓰면 작업 트리가 더러워지고 다음
# 커밋에 딸려 나간다.
review_file() { printf '%s/%s-%s.md' "$ORCA_REVIEWS" "$1" "$2"; }

# "이 워크트리의 셋업은 내가 맡는다"는 표식. Orca 플러그인이 이걸 보고 물러선다.
# 워크트리를 만들기 전에 놓아야 한다. worktree.created 이벤트는 생성과 동시에
# 날아가므로, 만든 뒤에 놓으면 플러그인이 그 사이에 먼저 잡는다. 그러면
# dispatch가 75로 되돌아오고 셋업이 끝나기 전에 에이전트가 뜬다.
claim_file() { printf '%s/.claims/%s-%s' "$ORCA_REVIEWS" "$1" "$2"; }

# 셋업이 이미 도는 중이면 그 잠금이 풀릴 때까지 기다린다.
# 사람이 손으로 부른 것과 겹치면 우리 쪽은 75로 즉시 돌아오는데, 그대로 지나가면
# 아직 채워지지 않은 워크트리에 에이전트가 뜬다. 그것을 막는 것이 dispatch의 일이다.
wait_for_setup() { # worktree-path [seconds]
  local wt="$1" limit="${2:-600}" gitdir lock waited=0
  gitdir="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  lock="$gitdir/worktree-setup.lock"
  while [ -d "$lock" ] && [ "$waited" -lt "$limit" ]; do
    sleep 2
    waited=$((waited + 2))
  done
  if [ -d "$lock" ]; then
    printf '  %s초를 기다렸는데 셋업이 안 끝났다. 빌드 전에 손으로 확인한다.\n' "$limit" >&2
  fi
  return 0
}

# Orca 워크스페이스 카드에 진행을 찍는다.
# CLI에는 알림을 쏘는 명령이 없어서, 상태를 바꾸는 쪽이 카드를 직접 고치는 것이
# 그 자리다. git을 긁어 상태를 추측하는 워처보다 낫다 -- 커밋 수 말고
# "테스트 도는 중", "FK에 막힘" 같은 것을 쓸 수 있다.
# 카드는 조용히 바뀌므로 그 줄을 데스크톱까지 밀어 주는 것은 Orca 플러그인이 맡는다.
# 표시일 뿐이므로 실패해도 넘어간다. 이것 때문에 리뷰나 머지가 멈추면 안 된다.
# 인자 이름을 st로 줄인 것은 zsh에서 status가 읽기 전용이라서다. 이 스크립트는
# bash로 돌지만 사람이 zsh에서 lib.sh를 source 해 보는 일이 있다.
card() { # worktree-path [status] [comment]  -- 빈 인자는 그 필드를 건드리지 않는다
  local wt="$1" st="${2:-}" comment="${3:-}"
  local args=(--worktree "path:$wt")
  [ -d "$wt" ] || return 0
  if [ -n "$st" ]; then args+=(--workspace-status "$st"); fi
  if [ -n "$comment" ]; then args+=(--comment "$comment"); fi
  [ "${#args[@]}" -gt 2 ] || return 0
  orca worktree set "${args[@]}" --json >/dev/null 2>&1 || true
}

# 에이전트가 제 카드를 스스로 갱신하게 하는 지시. 프롬프트 끝에 붙인다.
# 워크트리 경로를 박아 넣는 것은 active 셀렉터가 터미널이 아니라 UI에서 켜 둔
# 워크트리를 가리킬 수 있어서다. 그러면 엉뚱한 카드에 남는다.
card_rule() { # worktree-path
  printf '%s' "

## 카드를 갱신한다

마디가 바뀔 때마다 Orca 카드에 한 줄을 남긴다. 오케스트레이터는 그 줄로 진행을 본다.

\`\`\`
orca worktree set --worktree \"path:$1\" --comment \"<지금 무엇을 하고 있는지>\" --json
\`\`\`

재현, 구현, 검증, 막힘, 넘김처럼 상태가 실제로 바뀐 때만 쓴다. 짧게 쓰고 지금 것만 남긴다.
커밋 수나 파일 수는 적지 않는다 -- 그건 status가 직접 센다."
}

# 프롬프트를 보내고 에이전트가 실제로 받았는지까지 본다.
# --enter 가 텍스트만 넣고 Enter를 안 누르는 때가 있다. CLI는 ok를 돌려주므로
# 보낸 쪽은 성공으로 읽고, 메시지는 입력창에 앉은 채 아무 일도 안 일어난다.
send_prompt() { # handle text
  local h="$1" text="$2" i
  orca terminal send --terminal "$h" --text "$text" --enter --json 2>&1 | orca_check
  for i in 1 2 3; do
    sleep 5
    if terminal_busy "$h"; then return 0; fi
    # 입력창에 남아 있으면 Enter만 다시 친다
    orca terminal send --terminal "$h" --text "" --enter --json >/dev/null 2>&1 || true
  done
  sleep 5
  if terminal_busy "$h"; then return 0; fi
  printf '보냈지만 에이전트가 움직이지 않는다: %s\n' "$h" >&2
  printf 'Orca에서 그 탭을 열어 입력창에 메시지가 남아 있는지 본다.\n' >&2
  return 1
}

# 에이전트가 지금 무언가 하고 있나. TUI 하단 상태줄에 도는 표시가 뜬다.
terminal_busy() {
  orca terminal read --terminal "$1" --limit 80 --json 2>/dev/null | python3 -c '
import sys, json, re
try:
    t = json.load(sys.stdin)["result"]["terminal"]
except Exception:
    sys.exit(1)
body = "\n".join(re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", l) for l in t.get("tail", []))
# 도는 동안에만 뜨는 표시들.
# 스피너 문구는 Churning, Crunching, Mulling, Cooking 처럼 매번 다르지만 전부 말줄임표를 단다.
# 그래서 단어를 열거하지 않고 그 표시와 인터럽트 안내, 토큰 속도를 본다.
sys.exit(0 if re.search(r"…|esc to interrupt|tok/s|thinking|thought for|◐", body) else 1)
'
}

# 터미널 핸들을 레포/이름과 역할(work|review)로 기억한다.
# 에이전트가 탭 제목을 자기 마음대로 바꾸므로 제목으로는 되찾지 못한다.
handle_file() { printf '%s/.handles/%s-%s.%s' "$ORCA_REVIEWS" "$1" "$2" "$3"; }

save_handle() { # repo name role handle
  mkdir -p "$ORCA_REVIEWS/.handles"
  printf '%s' "$4" > "$(handle_file "$1" "$2" "$3")"
}

load_handle() { # repo name role -- 살아 있는 핸들만 돌려준다
  local f h
  f="$(handle_file "$1" "$2" "$3")"
  [ -f "$f" ] || return 1
  h="$(cat "$f")"
  [ -n "$h" ] || return 1
  orca terminal list --json 2>/dev/null | python3 -c '
import sys, json
want = sys.argv[1]
for t in json.load(sys.stdin).get("result", {}).get("terminals", []):
    if t.get("handle") == want and not t.get("orphaned"):
        print(want)
        break
' "$h" | grep -q . || return 1
  printf '%s' "$h"
}

# orca --json 출력에서 새 터미널 핸들을 뽑는다
terminal_handle() {
  python3 -c '
import sys, json
d = json.load(sys.stdin)
if not d.get("ok"):
    sys.stderr.write(json.dumps(d.get("error", d), ensure_ascii=False) + "\n")
    sys.exit(1)
r = d.get("result", {})
print(r.get("handle")
      or (r.get("terminal") or {}).get("handle")
      or r.get("agentTerminalHandle")
      or (r.get("startupTerminal") or {}).get("handle")
      or "")
'
}

# ---------------------------------------------------------------------------
# 우산 워크트리
# ---------------------------------------------------------------------------
#
# 우산 레포에서 서브 레포로 일을 내보내는 쓰임에서, 서브 레포의 워크트리가
# 누구 것인지가 이름 말고는 어디에도 안 남는다. 레포 하나에 우산 여럿이 붙으면
# status가 남의 것까지 찍고 land도 남의 것을 겨눈다.
#
# 그래서 소유자를 이름에 박는다. 따로 인덱스 파일을 두지 않는 것은, 워크트리를
# 사람이 Orca UI에서 지울 수 있어서다 -- 인덱스는 곧 실제와 어긋나는데 이름은 안 그렇다.

# 이 셸이 어느 우산 워크트리 안에서 도는지. "<repo>.<worktree>" 또는 빈 문자열.
# $PWD 로 판단한다. 워크스페이스 아래가 아니면(메인 체크아웃, 홈) 우산이 없는 것이다.
owner_id() {
  if [ -n "${ORCA_OWNER:-}" ]; then printf '%s' "$ORCA_OWNER"; return 0; fi
  local rest repo name
  rest="${PWD#"$ORCA_WORKSPACES"/}"
  [ "$rest" != "$PWD" ] || return 0
  case "$rest" in */*) ;; *) return 0 ;; esac
  repo="${rest%%/*}"
  name="${rest#*/}"; name="${name%%/*}"
  [ -n "$repo" ] && [ -n "$name" ] || return 0
  printf '%s.%s' "$repo" "$name"
}

# 소유자 접두를 붙인다. 이미 붙어 있으면 그대로 둔다 -- status가 찍어 준 이름을
# 사람이 그대로 복사해 review나 land에 넘기는 것이 정상 경로라서다.
prefixed_name() { # owner name
  case "$2" in
    "$1".*) printf '%s' "$2" ;;
    *) printf '%s.%s' "$1" "$2" ;;
  esac
}

# 접두를 뗀 이름. 터미널 제목처럼 워크트리가 이미 맥락을 들고 있는 자리에 쓴다.
# 우산이 안 잡히면 이름을 그대로 돌려준다.
short_name() { # name
  local owner
  owner="$(owner_id)"
  [ -n "$owner" ] || { printf '%s' "$1"; return 0; }
  case "$1" in
    "$owner".*) printf '%s' "${1#"$owner".}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# 진척 기록
# ---------------------------------------------------------------------------
#
# 카드는 지금 처지 한 줄만 든다. 앞의 줄은 덮여 사라지고, land가 워크트리를
# 지우면 카드도 같이 간다. 무엇을 했는지가 그래서 아무 데도 안 남는다.
# 우산마다 파일 하나에 append 한다. 컨텍스트가 차 세션을 갈아탈 때 이걸 읽는다.
journal_file() { # [owner]  -- 우산이 없으면 _solo 로 모은다
  local owner="${1:-$(owner_id)}"
  printf '%s/.journal/%s.md' "$ORCA_REVIEWS" "${owner:-_solo}"
}

journal() { # line...
  local f
  f="$(journal_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  printf '%s  %s\n' "$(date '+%m-%d %H:%M')" "$*" >> "$f" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 리뷰 라운드
# ---------------------------------------------------------------------------
#
# 리뷰가 몇 번째인지를 파일 이름으로 센다. 한 번 돌 때마다 앞 판정을
# .roundN.md 로 밀어 두므로, 재리뷰가 앞 판정을 덮어 무엇이 지적이었는지
# 사라지던 것이 같이 막힌다.
round_file() { printf '%s/%s-%s.round%s.md' "$ORCA_REVIEWS" "$1" "$2" "$3"; }

# 지금까지 끝난 라운드 수. 밀어 둔 것 + 아직 안 민 현재 판정.
rounds_done() { # repo name
  local n=0
  while [ -f "$(round_file "$1" "$2" "$((n + 1))")" ]; do n=$((n + 1)); done
  [ -f "$(review_file "$1" "$2")" ] && n=$((n + 1))
  printf '%s' "$n"
}

# 현재 판정을 .roundN.md 로 민다. 없으면 아무것도 안 한다.
archive_review() { # repo name
  local out n=0
  out="$(review_file "$1" "$2")"
  [ -f "$out" ] || return 0
  while [ -f "$(round_file "$1" "$2" "$((n + 1))")" ]; do n=$((n + 1)); done
  mv "$out" "$(round_file "$1" "$2" "$((n + 1))")"
}

# 터미널 하나가 지금 어느 처지인가. 돎 / 막힘 / 쉼.
#
# terminal list 가 주는 preview(TUI 마지막 줄)로 먼저 가른다. 도는 중이면
# 거기 스피너와 토큰 속도가 앉아 있어서 추가 호출이 필요 없다.
# 쉬는 것으로 보일 때만 tail 을 읽는다 -- 프롬프트에 막힌 것과 정말 쉬는 것이
# 마지막 줄로는 안 갈리는데, 그 둘을 뭉치면 승인 하나를 몇 시간 기다린다.
terminal_state() { # handle preview
  if printf '%s' "$2" | grep -qE '…|esc to interrupt|tok/s|◐|◑|◒|◓'; then
    printf '돎'
    return 0
  fi
  orca terminal read --terminal "$1" --limit 60 --json 2>/dev/null | python3 -c '
import sys, json, re
try:
    t = json.load(sys.stdin)["result"]["terminal"]
except Exception:
    print("쉼"); sys.exit(0)
body = "\n".join(re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", l) for l in t.get("tail", []))
if re.search(r"…|esc to interrupt|tok/s", body):
    print("돎")
# 사람 손을 기다리는 자리들. 신뢰 확인, 도구 승인, y/n.
elif re.search(r"Do you (want|trust)|one you trust|❯\s*1\.|\(y/n\)|Press Enter to continue", body, re.I):
    print("막힘")
else:
    print("쉼")
'
}

# ---------------------------------------------------------------------------
# 판정 파일 읽기
# ---------------------------------------------------------------------------
#
# "## blocking" 절만 떼어 낸다. 다음 같은 수준 제목에서 끊는 것이 핵심이다 --
# 안 끊으면 뒤에 오는 non-blocking 절까지 통째로 딸려 나온다.
# non-blocking 은 제목이 "blocking" 으로 시작하지 않아 여는 조건에 안 걸린다.
# 자를 줄 수는 awk 가 직접 센다. 밖에서 `| head -N` 로 자르면 절이 그보다 길
# 때 awk 가 SIGPIPE(141)로 죽고, lib.sh 의 pipefail + set -e 가 부른 쪽 스크립트를
# 에러 한 줄 없이 끝낸다. 절이 짧으면 파이프 버퍼에 다 들어가 안 걸려서, 판정
# 길이에 따라 되기도 하고 안 되기도 했다.
blocking_section() { # review-file [max-lines]
  awk -v max="${2:-0}" '
    tolower($0) ~ /^#+[ \t]*blocking/ { p = 1; print; n++; next }
    p && /^##[^#]/ { exit }
    p { if (max && ++n > max) exit; print }
  ' "$1"
}

# 그 절에 든 항목 수. 제목 줄을 세면 판정이 "없다"여도 1건이 되고, 카드와
# 기록에 없는 blocking 이 앉는다. 목록 표시와 하위 제목만 센다.
blocking_count() { # review-file
  blocking_section "$1" | awk '/^[-*+] |^[0-9]+\. |^#{3,} / { n++ } END { print n + 0 }'
}
