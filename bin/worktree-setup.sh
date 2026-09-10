#!/usr/bin/env bash
# 새로 딴 worktree를 바로 일할 수 있는 상태로 만든다.
#
# git worktree는 추적하는 파일만 가져온다. 그런데 앱을 띄우고 테스트를 돌리는 데
# 필요한 것 상당수가 gitignore 대상이다. 개발자별 접속 설정(.env, *-local-mine.yaml),
# 코드 생성 산출물, submodule이 그렇다. 그래서 새 worktree는 체크아웃 직후 빌드도
# 기동도 안 되고, 원인이 코드처럼 보이는 오류로 나온다. 이 스크립트가 그 빈자리를
# 같은 레포의 메인 체크아웃에서 복사해 채운다.
#
# 무엇을 채울지는 프로젝트 루트의 .orca-flow.json 이 정한다. 그 파일이 없으면
# .env 계열만 옮기는 기본값으로 돈다.
#
# 정본은 언제나 메인 체크아웃이다. worktree 쪽에서 고쳐도 메인으로 돌려보내지
# 않는다. 그 파일들은 커밋되지 않아 리뷰를 못 거치는데, 양방향으로 열어 두면
# 어느 쪽이 맞는 설정인지 판정할 근거가 사라진다.
#
# 추적되는 파일은 --force를 줘도 건드리지 않는다. .env.local 처럼 커밋된 것이
# 섞여 있는 레포가 있어서, 덮으면 worktree에 출처를 모를 수정이 남고 다음 커밋에
# 딸려 나간다.
#
# 에이전트 권한 허용 목록(.claude/settings.local.json)은 기본으로 옮기지 않는다.
# 한 작업 트리에서 승인한 권한이 조용히 번지는 걸 막기 위해서다. 필요하면
# --with-agent-settings로 명시한다.
#
# 주석은 한국어, 화면에 찍히는 문구는 영어다. 이 스크립트는 Orca 플러그인이
# 백그라운드로 띄워 로그로만 읽히는 자리가 있어, 로케일을 안 타는 쪽으로 둔다.

set -euo pipefail

usage() {
  cat <<'EOF'
Seed a freshly created git worktree from the repository's main checkout.

Usage:
  worktree-setup.sh [path] [options]

  path                    worktree to seed (default: the one containing $PWD)

Options:
  --dry-run               show what would be copied, write nothing
  --force                 overwrite files that already exist (tracked files are
                          still left alone)
  --no-deps               skip pnpm install / uv sync
  --with-agent-settings   also copy .claude/settings.local.json
  -h, --help              show this help

Configuration:
  Reads .orca-flow.json from the nearest ancestor of the main checkout.
  Relevant keys live under "setup": files, dirs, prune, repoExtras, deny.

Exit codes:
  0   seeded (or nothing to do)
  1   failed
  75  another run already holds this worktree
EOF
}

# shellcheck source=bin/config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; NC=$'\033[0m'
else
  BOLD=''; DIM=''; GREEN=''; YELLOW=''; NC=''
fi
if [[ -t 2 ]]; then
  E_RED=$'\033[31m'; E_NC=$'\033[0m'
else
  E_RED=''; E_NC=''
fi

die() {
  printf '%serror%s %s\n' "$E_RED" "$E_NC" "$1" >&2
  exit 1
}

note() { printf '  %s%s%s\n' "$DIM" "$1" "$NC"; }

# find 결과를 받아 두는 임시 파일. 중간에 die하거나 cp가 죽어도 남지 않게
# 여기서 한 번에 걷는다. 잡아 둔 잠금도 같은 자리에서 푼다.
TMPFILE=""
LOCK_HELD=""
cleanup() {
  rm -f "${TMPFILE:-}"
  if [[ -n "$LOCK_HELD" ]]; then
    rm -rf "$LOCK_HELD"
  fi
}
trap cleanup EXIT

DRY_RUN=0
FORCE=0
WITH_DEPS=1
WITH_AGENT_SETTINGS=0
ARG_PATH=""

while (( $# )); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    --no-deps) WITH_DEPS=0 ;;
    --with-agent-settings) WITH_AGENT_SETTINGS=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *)
      if [[ -n "$ARG_PATH" ]]; then die "too many arguments"; fi
      ARG_PATH="$1"
      ;;
  esac
  shift
done

# 실패 메시지에 쓸 원본을 따로 붙든다. 명령 치환이 실패하면 대입 대상이 빈
# 문자열로 덮여서, 같은 변수를 메시지에 쓰면 정작 필요한 경로가 사라진다.
WANTED="${ARG_PATH:-$PWD}"
[[ -d "$WANTED" ]] || die "not a directory: $WANTED"

TARGET="$(git -C "$WANTED" rev-parse --show-toplevel 2>/dev/null)" \
  || die "not inside a git worktree: $WANTED"

# 같은 레포의 메인 체크아웃이 복사 원본이다. worktree list의 첫 항목이 그것이라
# 레포마다 경로를 적어 둘 필요가 없다. 레포가 늘어도 이 스크립트는 그대로다.
# --porcelain은 경로를 인용하지 않으므로 awk로 자르면 공백에서 끊긴다.
WT_LIST="$(git -C "$TARGET" worktree list --porcelain)"
SOURCE="$(printf '%s\n' "$WT_LIST" | awk '/^worktree / && !seen {sub(/^worktree /, ""); print; seen=1}')"
[[ -n "$SOURCE" && -d "$SOURCE" ]] || die "cannot resolve the main worktree for: $TARGET"

# bare 클론이면 첫 항목이 작업 트리가 아니라 bare 레포다. 복사할 원본이 없다.
if printf '%s\n' "$WT_LIST" | sed -n '1,/^$/p' | grep -qx 'bare'; then
  die "the main entry is a bare repository, nothing to copy from: $SOURCE"
fi

REPO="$(basename "$SOURCE")"

if [[ "$SOURCE" == "$TARGET" ]]; then
  printf '%s%s%s is the main checkout, nothing to seed.\n' "$BOLD" "$REPO" "$NC"
  exit 0
fi

# 설정은 메인 체크아웃에서 위로 올라가며 찾는다. 워크트리에서 찾으면 안 된다 --
# 워크트리는 워크스페이스 디렉터리(~/orca/workspaces/...) 아래 있어 프로젝트
# 트리 밖이고, 거기서 위로 올라가면 홈까지 가도 설정이 없다.
orca_flow_load "$SOURCE"

# 워크트리로 가르면 안 되는 레포. 우산 레포처럼 형제를 디렉터리로 품고 있으면
# 여기서 훑을 때 남의 산출물 수 MB가 딸려 온다.
while IFS= read -r denied; do
  [[ -n "$denied" && "$denied" == "$REPO" ]] || continue
  die "$REPO is marked as deny in .orca-flow.json, not meant to be worktreed"
done < <(cfg_list setup.deny)

# 복사 대상 파일. gitignore돼 있지만 없으면 앱이 안 뜨는 것들이다.
# 빌드 산출물은 기본값에 넣지 않는다. 다시 만들면 되고 용량만 크다.
COPY_FILES=()
while IFS= read -r pat; do
  [[ -n "$pat" ]] && COPY_FILES+=( "$pat" )
done < <(cfg_list setup.files)
if (( ${#COPY_FILES[@]} == 0 )); then
  COPY_FILES=( '*-local-mine.yaml' '.env' '.env.local' '.env.local-mine' '.env.*.local' )
fi

# 옵트인일 때만 붙는다. 권한 파일이라 기본 목록과 무게가 다르다.
if (( WITH_AGENT_SETTINGS )); then
  COPY_FILES+=( '*/.claude/settings.local.json' )
fi

# 통째로 옮기는 디렉터리. 코드 생성 산출물이라 원칙적으로는 다시 만들면 되지만,
# DB에 붙어야 도는 것이나 빌드를 한 번 더 타야 나오는 것은 복사가 싸다.
# 기본값을 비워 두는 것은 이 목록이 프로젝트마다 다르기 때문이다.
COPY_DIRS=()
while IFS= read -r pat; do
  [[ -n "$pat" ]] && COPY_DIRS+=( "$pat" )
done < <(cfg_list setup.dirs)

# find가 들어가지 않을 디렉터리. 빌드 산출물과 의존성 트리다.
PRUNE=()
while IFS= read -r pat; do
  [[ -n "$pat" ]] && PRUNE+=( "$pat" )
done < <(cfg_list setup.prune)
if (( ${#PRUNE[@]} == 0 )); then
  PRUNE=( .git node_modules build .gradle .nuxt .output target .venv dist .terraform __pycache__ )
fi

# 패턴 목록을 find 표현식으로 편다. 슬래시가 있으면 -path, 없으면 -name 이다.
# 반환 대신 전역 배열에 담는 것은 bash 3.2가 배열을 못 돌려주기 때문이다.
FIND_EXPR=()
build_find_expr() { # pattern...
  FIND_EXPR=()
  local pat
  for pat in "$@"; do
    if (( ${#FIND_EXPR[@]} > 0 )); then FIND_EXPR+=( -o ); fi
    case "$pat" in
      */*) FIND_EXPR+=( -path "$pat" ) ;;
      *) FIND_EXPR+=( -name "$pat" ) ;;
    esac
  done
}

# 잠금은 그 워크트리의 git 디렉터리에 둔다. TMPDIR에 두면 부르는 쪽마다 값이
# 달라 서로 다른 자리를 잠그고, 그러면 잠긴 줄 알면서 둘 다 돈다. Orca 플러그인
# 워커는 env가 허용 목록으로 스크럽돼 오므로 실제로 그 값이 갈린다.
#
# 한 워크트리를 둘이 동시에 채우면 submodule 클론과 pnpm install이 같은
# 디렉터리에서 겹친다. 부르는 자리가 셋이라 실제로 겹친다 -- dispatch.sh, Orca
# 플러그인의 생성 이벤트, 그리고 사람이 손으로. 그래서 잠금은 부르는 쪽이 아니라
# 이 스크립트가 든다.
GITDIR="$(git -C "$TARGET" rev-parse --absolute-git-dir)"
if (( DRY_RUN == 0 )); then
  LOCK="$GITDIR/worktree-setup.lock"
  if ! mkdir "$LOCK" 2>/dev/null; then
    HOLDER="$(cat "$LOCK/pid" 2>/dev/null || true)"
    # pid는 mkdir 바로 다음에 쓰인다. 그 사이에 들어온 경쟁자는 빈손으로 읽으므로,
    # 한 번 더 보고 나서야 죽었다고 판정한다. 안 보면 살아 있는 잠금을 뺏는다.
    if [[ -z "$HOLDER" ]]; then
      sleep 0.5
      HOLDER="$(cat "$LOCK/pid" 2>/dev/null || true)"
    fi
    if [[ -n "$HOLDER" ]] && kill -0 "$HOLDER" 2>/dev/null; then
      printf '%salready seeding (pid %s), skipping:%s %s\n' "$YELLOW" "$HOLDER" "$NC" "$TARGET"
      exit 75
    fi
    # 잡은 채로 죽은 프로세스가 남긴 잠금이다. 옮겨 놓고 지운다. mv가 원자적이라
    # 둘이 동시에 회수해도 하나만 성공하고, 진 쪽은 아래 mkdir에서 걸러진다.
    if mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null; then
      rm -rf "$LOCK.stale.$$"
    fi
    if ! mkdir "$LOCK" 2>/dev/null; then
      printf '%sanother run took over the stale lock, skipping:%s %s\n' "$YELLOW" "$NC" "$TARGET"
      exit 75
    fi
  fi
  LOCK_HELD="$LOCK"
  printf '%s' "$$" > "$LOCK/pid"
fi

printf '%s%s%s\n' "$BOLD" "$REPO" "$NC"
note "from $SOURCE"
note "into $TARGET"
note "config ${PROJECT_CONFIG:-none, using defaults}"

# submodule은 복사보다 먼저 채운다. 빈 디렉터리에 파일이 먼저 놓이면 그 뒤의
# submodule 클론이 non-empty를 이유로 실패한다.
if [[ -f "$TARGET/.gitmodules" && $DRY_RUN -eq 0 ]]; then
  printf '%ssubmodules%s\n' "$BOLD" "$NC"
  git -C "$TARGET" submodule update --init --recursive
fi

# 원본 쪽 submodule 작업 트리도 훑지 않는다. 그 안의 .env나 설정이 부모 레포의
# 것인 양 복사되는 걸 막는다. submodule의 .git은 디렉터리가 아니라 파일이라
# -name .git으로는 안 걸린다.
if [[ -f "$SOURCE/.gitmodules" ]]; then
  while IFS= read -r sub; do
    [[ -n "$sub" ]] && PRUNE+=( "$SOURCE/$sub" )
  done < <(git -C "$SOURCE" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | sed -n 's/^submodule\..*\.path //p')
fi

build_find_expr "${PRUNE[@]}"
PRUNE_EXPR=( "${FIND_EXPR[@]}" )

copied=0
skipped=0

# 원본의 한 항목을 같은 상대 경로로 옮긴다. 파일이든 디렉터리든 같다.
seed() {
  local rel="$1"

  # rm -rf가 걸리는 자리라 상대 경로임을 먼저 못박는다. repoExtras에 절대
  # 경로나 ..가 섞여 들어와도 여기서 끊긴다. 판정은 경로 컴포넌트 단위로 한다.
  # 문자열 어디든 점 두 개를 막으면 a..b 같은 멀쩡한 이름이 걸린다.
  if [[ -z "$rel" || "$rel" == /* || "$rel" == ".." \
        || "$rel" == ../* || "$rel" == */../* || "$rel" == */.. ]]; then
    die "refusing to seed a suspicious path: $rel"
  fi

  local src="$SOURCE/$rel" dest="$TARGET/$rel"
  [[ -e "$src" ]] || return 0

  # 추적되는 파일은 --force여도 두고 간다. 커밋된 내용을 메인의 더티한 작업
  # 트리로 덮으면 worktree에 출처 모를 수정이 남는다.
  if git -C "$TARGET" ls-files --error-unmatch -- ":(literal)$rel" >/dev/null 2>&1; then
    (( ++skipped ))
    return 0
  fi

  if [[ -e "$dest" && $FORCE -eq 0 ]]; then
    (( ++skipped ))
    return 0
  fi

  if (( DRY_RUN )); then
    printf '  %s+%s %s\n' "$GREEN" "$NC" "$rel"
    (( ++copied ))
    return 0
  fi

  mkdir -p "$(dirname "$dest")"
  rm -rf "$dest"
  cp -R "$src" "$dest"
  printf '  %s+%s %s\n' "$GREEN" "$NC" "$rel"
  (( ++copied ))
}

# find 결과를 상대 경로로 바꿔 seed에 넘긴다. 경로에 공백이 있어도 안전하게
# NUL로 끊는다.
# 파이프도 프로세스 치환도 아니고 임시 파일을 거치는 건 둘 다 하나씩 못 하는
# 게 있어서다. 파이프는 while을 서브셸에 넣어 카운터를 잃고, 프로세스 치환은
# find의 실패를 삼킨다. 명령 치환은 애초에 NUL을 못 담는다.
seed_found() {
  local finder="$1" path rel
  TMPFILE="$(mktemp)" || die "cannot create a temp file"
  "$finder" >"$TMPFILE" || die "failed to scan $SOURCE"
  while IFS= read -r -d '' path; do
    rel="${path#"$SOURCE"/}"
    seed "$rel"
  done <"$TMPFILE"
  rm -f "$TMPFILE"
  TMPFILE=""
}

find_files() {
  build_find_expr "${COPY_FILES[@]}"
  find "$SOURCE" \( "${PRUNE_EXPR[@]}" \) -prune -o \
    \( "${FIND_EXPR[@]}" \) -type f -print0
}

find_dirs() {
  build_find_expr "${COPY_DIRS[@]}"
  find "$SOURCE" \( "${PRUNE_EXPR[@]}" \) -prune -o \
    \( "${FIND_EXPR[@]}" \) -type d -print0
}

seed_found find_files
# 조건을 && 로 붙이지 않는다. set -e 아래에서 조건이 거짓이면 그 줄이 실패로
# 읽혀 스크립트가 통째로 빠진다. dirs 를 안 적은 프로젝트가 기본이라 늘 걸린다.
if (( ${#COPY_DIRS[@]} > 0 )); then
  seed_found find_dirs
fi

# 패턴으로 안 잡히는 레포별 예외. 메인 체크아웃 기준 상대 경로다.
while IFS= read -r rel; do
  [[ -n "$rel" ]] && seed "$rel"
done < <(cfg_map_list setup.repoExtras "$REPO")

if (( copied == 0 && skipped == 0 )); then
  note "nothing to seed"
else
  note "$copied seeded, $skipped left alone (already present or tracked)"
fi

if (( DRY_RUN )); then
  printf '%sdry run, nothing written.%s\n' "$DIM" "$NC"
  exit 0
fi

# 끝났다는 표식. 이 스크립트는 이걸 보고 건너뛰지 않는다 -- 사람은 설정 파일을
# 새로 만든 뒤 일부러 다시 부른다. 읽는 쪽은 Orca 플러그인 하나다. 워크트리
# 생성 이벤트를 늦게 받았을 때 이미 채워진 곳을 또 채우지 않으려고 본다.
mark_done() { date -u '+%Y-%m-%dT%H:%M:%SZ' > "$GITDIR/worktree-setup.done" 2>/dev/null || true; }

if (( WITH_DEPS == 0 )); then
  mark_done
  exit 0
fi

# 의존성은 복사하지 않고 설치한다. node_modules와 .venv는 심링크와 절대 경로를
# 품고 있어 다른 디렉터리로 옮기면 조용히 깨진다. gradle은 여기서 건드리지
# 않는다. 캐시가 사용자 홈에 있어 worktree마다 다시 받지 않는다.
if [[ -f "$TARGET/pnpm-lock.yaml" ]]; then
  printf '%spnpm install%s\n' "$BOLD" "$NC"
  if command -v pnpm >/dev/null 2>&1; then
    (cd "$TARGET" && pnpm install --frozen-lockfile)
  else
    printf '  %spnpm not found, skipped%s\n' "$YELLOW" "$NC"
  fi
fi

if [[ -f "$TARGET/uv.lock" ]]; then
  printf '%suv sync%s\n' "$BOLD" "$NC"
  if command -v uv >/dev/null 2>&1; then
    (cd "$TARGET" && uv sync)
  else
    printf '  %suv not found, skipped%s\n' "$YELLOW" "$NC"
  fi
fi

mark_done
