#!/usr/bin/env bash
# bin 스크립트의 공통 함수. 직접 실행하지 않고 source한다.
# 프로젝트 설정은 루트의 .orca-flow.json에서 읽으며 없으면 기본값을 사용한다.
# 우선순위는 환경변수 > 설정 파일 > 기본값이다. NO_PUSH=1, FORCE=1처럼
# 한 번의 실행을 조정할 수 있도록 환경변수를 우선한다.

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

# 호출 위치인 $PWD에서 상위로 설정을 검색한다.
orca_flow_load "$PWD"

ORCA_WORKSPACES="$(expand_home "${ORCA_WORKSPACES:-$(cfg_get workspaces "$HOME/orca/workspaces")}")"
ORCA_REVIEWS="$(expand_home "${ORCA_REVIEWS:-$(cfg_get reviews "$HOME/orca/reviews")}")"
AGENT_CMD="${AGENT_CMD:-$(cfg_get agentCmd "claude --permission-mode auto")}"
# 설정 파일을 읽기 전에 환경변수 값을 보관한다. base_branch_for에서 우선 적용한다.
BASE_BRANCH_ENV="${BASE_BRANCH:-}"
BASE_BRANCH="${BASE_BRANCH:-$(cfg_get baseBranch main)}"

# 프로젝트 전용 초기 설정 스크립트. 지정하지 않으면 플러그인 기본 스크립트를 사용한다.
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

# 레포 displayName, 메인 체크아웃 경로, 프로젝트 그룹 id를 탭으로 구분한다.
# 레포별로 CLI를 호출하지 않도록 최초 조회를 캐시한다.
# 서브셸의 캐시는 부모에게 전달되지 않으므로 여러 레포를 처리할 때는
# 루프 전에 repo_paths >/dev/null로 캐시를 채운다.
REPO_PATHS=""
repo_paths() {
  [ -n "$REPO_PATHS" ] || REPO_PATHS="$(orca repo list --json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in d.get("result", {}).get("repos", []):
    # 탭으로 열을 구분하므로 값 안의 탭은 공백으로 바꾼다. TERMS, CARDS도 같은 규칙을 사용한다.
    print("%s\t%s\t%s" % (
        (r.get("displayName") or "").replace("\t", " "),
        (r.get("path") or "").replace("\t", " "),
        r.get("projectGroupId") or "",
    ))
' || true)"
  printf '%s\n' "$REPO_PATHS"
}

# 레포별 기준 브랜치를 읽는다.
# 우선순위는 환경변수 BASE_BRANCH > 레포 설정 > $PWD나 ORCA_FLOW_ROOT에서 정한 값이다.
# status에서 여러 레포에 같은 기준을 적용하면 main을 쓰지 않는 레포의 커밋 수가 ?가 된다.
# dispatch, review, land도 같은 함수로 조회와 머지 기준을 맞춘다.
# 앱이 전달한 ORCA_FLOW_ROOT가 있으면 config.sh가 인자 경로를 무시하므로
# 서브셸에서는 해제하고 레포 설정을 검색한다.
base_branch_for() { # repo
  [ -z "$BASE_BRANCH_ENV" ] || { printf '%s' "$BASE_BRANCH_ENV"; return 0; }
  local path b
  path="$(repo_paths | awk -F'\t' -v n="$1" '$1==n {print $2; exit}')"
  [ -n "$path" ] || { printf '%s' "$BASE_BRANCH"; return 0; }
  b="$( (unset ORCA_FLOW_ROOT; orca_flow_load "$path"; cfg_get baseBranch "$BASE_BRANCH") )" || b=""
  printf '%s' "${b:-$BASE_BRANCH}"
}

# 현재 디렉터리의 레포 displayName. 못 알아내면 빈 문자열이다.
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

# 현재 레포의 프로젝트 그룹 id. 그룹이 안 잡히면 빈 문자열이다.
current_group() {
  local me
  me="$(current_repo)"
  [ -n "$me" ] || return 0
  repo_paths | awk -F'\t' -v n="$me" '$1==n {print $3; exit}'
}

# 현재 레포와 같은 프로젝트 그룹을 후보로 조회한다.
# 한 컴퓨터에 무관한 프로젝트가 등록돼 있어도 작업 대상을 혼동하지 않도록
# Orca의 projectGroupId를 사용한다. 레포 밖이거나 그룹이 없으면 전체를 반환한다.
repo_names() { # [--all]
  local group=""
  [ "${1:-}" = "--all" ] || group="$(current_group)"
  repo_paths | awk -F'\t' -v g="$group" 'g == "" || $3 == g { print ($1 == "" ? "(이름 없음)" : $1) }'
}

worktree_path() { printf '%s/%s/%s' "$ORCA_WORKSPACES" "$1" "$2"; }

# orca --json 응답의 ok가 거짓이면 오류로 종료한다.
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

# 리뷰 파일은 워크트리 밖에 저장해 미추적 파일이나 다음 커밋에 포함되지 않게 한다.
review_file() { printf '%s/%s-%s.md' "$ORCA_REVIEWS" "$1" "$2"; }

# dispatch가 초기 설정을 담당한다는 표식. 생성 이벤트 전에 기록해
# 앱 플러그인의 중복 실행을 막는다. 플러그인이 먼저 실행하면 dispatch가
# 코드 75를 받고 초기 설정 전에 에이전트를 시작할 수 있다.
claim_file() { printf '%s/.claims/%s-%s' "$ORCA_REVIEWS" "$1" "$2"; }

# 다른 초기 설정 실행과 겹쳐 코드 75를 받으면 잠금 해제를 기다린다.
# 준비되지 않은 워크트리에서 에이전트가 시작되지 않게 한다.
wait_for_setup() { # worktree-path [seconds]
  local wt="$1" limit="${2:-600}" gitdir lock waited=0
  gitdir="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  lock="$gitdir/worktree-setup.lock"
  while [ -d "$lock" ] && [ "$waited" -lt "$limit" ]; do
    sleep 2
    waited=$((waited + 2))
  done
  if [ -d "$lock" ]; then
    printf '  %s초를 기다렸는데 셋업이 안 끝났다. 빌드 전에 직접 확인한다.\n' "$limit" >&2
  fi
  return 0
}

# 카드에 진행 상태를 기록한다. 실제 작업 주체가 "테스트 실행 중", "FK 문제로 중단"처럼
# Git 조회만으로 알 수 없는 상태를 작성하고 앱 플러그인이 알림을 보낸다.
# 표시 실패로 리뷰나 머지가 중단되지 않도록 오류는 무시한다.
# zsh에서 source할 수 있도록 읽기 전용 이름 status 대신 st를 사용한다.
card() { # worktree-path [status] [comment]  -- 빈 인자는 그 필드를 건드리지 않는다
  local wt="$1" st="${2:-}" comment="${3:-}"
  local args=(--worktree "path:$wt")
  [ -d "$wt" ] || return 0
  if [ -n "$st" ]; then args+=(--workspace-status "$st"); fi
  if [ -n "$comment" ]; then args+=(--comment "$comment"); fi
  [ "${#args[@]}" -gt 2 ] || return 0
  orca worktree set "${args[@]}" --json >/dev/null 2>&1 || true
}

# 프롬프트 끝에 카드 갱신 지시를 추가한다. active 선택자는 터미널이 아닌
# UI의 워크트리를 가리킬 수 있어 대상 경로를 명시한다.
card_rule() { # worktree-path
  printf '%s' "

## 카드를 갱신한다

작업 단계가 바뀔 때마다 Orca 카드에 한 줄을 남긴다. 오케스트레이터는 그 줄로 진행을 본다.

\`\`\`
orca worktree set --worktree \"path:$1\" --comment \"<지금 무엇을 하고 있는지>\" --json
\`\`\`

재현, 구현, 검증, 입력 대기, 인계 등 상태가 바뀔 때 현재 상황만 짧게 기록한다.
커밋 수와 파일 수는 status가 집계하므로 반복해서 적지 않는다."
}

# 프롬프트 전송 후 에이전트가 시작했는지 확인한다.
# --enter가 텍스트만 입력하고 Enter를 보내지 않아도 CLI가 ok를 반환하는 경우가 있다.
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

# TUI 하단 상태줄에서 에이전트가 실행 중인지 확인한다.
terminal_busy() {
  orca terminal read --terminal "$1" --limit 80 --json 2>/dev/null | python3 -c '
import sys, json, re
try:
    t = json.load(sys.stdin)["result"]["terminal"]
except Exception:
    sys.exit(1)
body = "\n".join(re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", l) for l in t.get("tail", []))
# 실행 중에만 표시되는 문구를 확인한다.
# 스피너 문구는 Churning, Crunching, Mulling, Cooking 처럼 매번 다르지만 전부 말줄임표를 단다.
# 그래서 단어를 열거하지 않고 그 표시와 인터럽트 안내, 토큰 속도를 본다.
sys.exit(0 if re.search(r"…|esc to interrupt|tok/s|thinking|thought for|◐", body) else 1)
'
}

# 터미널 핸들을 레포/이름과 역할(work|review)로 기억한다.
# 에이전트가 탭 제목을 변경할 수 있으므로 제목으로는 되찾지 못한다.
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
# 서브 워크트리 이름에 우산 소속을 기록해 다른 작업을 잘못 조회하거나 머지하지 않게 한다.
# 사용자가 UI에서 워크트리를 삭제할 수 있으므로 별도 인덱스 대신 이름을 사용한다.

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

# 소유자 접두를 붙인다. 이미 붙어 있으면 그대로 둔다 -- status가 출력한 이름을
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
# 진행 상황 기록
# ---------------------------------------------------------------------------
#
# 카드는 현재 상태만 보관하고 land 후 삭제된다.
# 우산별 파일에 작업 이력을 추가해 세션을 이어받을 때 확인한다.
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
# 이전 판정을 .roundN.md로 보관해 재리뷰가 기록을 덮지 않게 한다.
# 파일 이름으로 리뷰 차수를 집계한다.
round_file() { printf '%s/%s-%s.round%s.md' "$ORCA_REVIEWS" "$1" "$2" "$3"; }

# 완료된 리뷰 차수. 보관 파일과 현재 판정 파일을 합산한다.
rounds_done() { # repo name
  local n=0
  while [ -f "$(round_file "$1" "$2" "$((n + 1))")" ]; do n=$((n + 1)); done
  [ -f "$(review_file "$1" "$2")" ] && n=$((n + 1))
  printf '%s' "$n"
}

# 현재 판정을 .roundN.md로 보관한다. 파일이 없으면 생략한다.
archive_review() { # repo name
  local out n=0
  out="$(review_file "$1" "$2")"
  [ -f "$out" ] || return 0
  while [ -f "$(round_file "$1" "$2" "$((n + 1))")" ]; do n=$((n + 1)); done
  mv "$out" "$(round_file "$1" "$2" "$((n + 1))")"
}

# 터미널 상태는 돎, 막힘, 쉼으로 구분한다.
# preview의 스피너와 토큰 속도로 실행 중인지 먼저 확인한다.
# 쉬는 것으로 보일 때는 tail에서 입력 대기를 구분해 승인을 놓치지 않게 한다.
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
# 사용자 입력을 기다리는 자리들. 신뢰 확인, 도구 승인, y/n.
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
# ## blocking 항목만 추출하고 다음 같은 수준의 제목에서 멈춘다.
# non-blocking은 시작 조건에 해당하지 않는다.
# 줄 수는 awk 안에서 제한한다. 외부 head로 자르면 긴 판정에서 SIGPIPE(141)가 발생해
# pipefail과 set -e에 의해 호출 스크립트가 오류 안내 없이 종료될 수 있다.
# 짧은 출력은 파이프 버퍼에 들어가 같은 문제가 나타나지 않는다.
blocking_section() { # review-file [max-lines]
  awk -v max="${2:-0}" '
    tolower($0) ~ /^#+[ \t]*blocking/ { p = 1; print; n++; next }
    p && /^##[^#]/ { exit }
    p { if (max && ++n > max) exit; print }
  ' "$1"
}

# 목록 항목과 하위 제목만 센다. 제목을 포함하면 지적이 없어도 1건으로 집계된다.
blocking_count() { # review-file
  blocking_section "$1" | awk '/^[-*+] |^[0-9]+\. |^#{3,} / { n++ } END { print n + 0 }'
}
