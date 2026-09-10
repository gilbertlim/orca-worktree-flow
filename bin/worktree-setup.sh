#!/usr/bin/env bash
# 새 워크트리의 초기 설정을 준비한다.
#
# Git 추적 대상이 아닌 .env, *-local-mine.yaml, 생성 산출물과 submodule이 없으면
# 빌드나 실행이 실패할 수 있다. 같은 레포의 메인 체크아웃에서 필요한 파일을 복사한다.
# 대상은 프로젝트 루트의 .orca-flow.json에서 읽으며, 없으면 .env 계열 기본값을 사용한다.
#
# 복사 방향은 메인 체크아웃에서 워크트리로 한정한다. 커밋되지 않는 설정을
# 양방향으로 복사하면 어느 쪽이 기준인지 판단하기 어렵다.
# 추적 파일은 --force여도 덮어쓰지 않는다. 커밋된 .env.local 등에 의도하지 않은
# 변경이 생겨 다음 커밋에 포함되는 것을 막는다.
# .claude/settings.local.json은 권한 전파를 막기 위해 --with-agent-settings일 때만 복사한다.
# 도움말과 로그는 한국어로 표시한다. 앱이 판별하는 의존성 누락 표시는 유지한다.

set -euo pipefail

usage() {
  cat <<'EOF'
메인 체크아웃에서 새 Git 워크트리에 필요한 파일을 복사한다.

사용법:
  worktree-setup.sh [path] [options]

  path                    대상 워크트리 (기본: $PWD가 속한 워크트리)

옵션:
  --dry-run               복사할 항목만 표시하고 파일은 쓰지 않음
  --force                 기존 파일 덮어쓰기 (Git 추적 파일은 유지)
  --no-deps               pnpm install과 uv sync 생략
  --with-agent-settings   .claude/settings.local.json도 복사
  -h, --help              도움말 표시

설정:
  메인 체크아웃에서 상위로 검색해 가장 가까운 .orca-flow.json을 읽는다.
  setup의 files, dirs, prune, repoExtras, deny를 사용한다.

종료 코드:
  0   완료 또는 처리할 항목 없음
  1   실패
  75  다른 실행이 이 워크트리의 잠금을 보유 중
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
  printf '%s오류%s %s\n' "$E_RED" "$E_NC" "$1" >&2
  exit 1
}

note() { printf '  %s%s%s\n' "$DIM" "$1" "$NC"; }

# 검색 중 실패해도 임시 파일과 잠금이 남지 않도록 종료 시 함께 정리한다.
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
    -*) die "알 수 없는 옵션: $1" ;;
    *)
      if [[ -n "$ARG_PATH" ]]; then die "인자가 너무 많다"; fi
      ARG_PATH="$1"
      ;;
  esac
  shift
done

# 실패 메시지에 쓸 원본을 따로 붙든다. 명령 치환이 실패하면 대입 대상이 빈
# 문자열로 덮여서, 같은 변수를 메시지에 쓰면 정작 필요한 경로가 사라진다.
WANTED="${ARG_PATH:-$PWD}"
[[ -d "$WANTED" ]] || die "디렉터리가 아니다: $WANTED"

TARGET="$(git -C "$WANTED" rev-parse --show-toplevel 2>/dev/null)" \
  || die "Git 워크트리 안의 경로가 아니다: $WANTED"

# worktree list의 첫 항목인 메인 체크아웃을 원본으로 사용한다.
# 레포별 경로 설정은 필요 없다. --porcelain은 경로를 인용하지 않으므로
# 공백이 있는 경로가 잘리지 않도록 접두만 제거한다.
WT_LIST="$(git -C "$TARGET" worktree list --porcelain)"
SOURCE="$(printf '%s\n' "$WT_LIST" | awk '/^worktree / && !seen {sub(/^worktree /, ""); print; seen=1}')"
[[ -n "$SOURCE" && -d "$SOURCE" ]] || die "메인 체크아웃을 찾을 수 없다: $TARGET"

# bare 클론이면 첫 항목이 작업 트리가 아니라 bare 레포다. 복사할 원본이 없다.
if printf '%s\n' "$WT_LIST" | sed -n '1,/^$/p' | grep -qx 'bare'; then
  die "메인 항목이 bare 레포여서 복사할 원본이 없다: $SOURCE"
fi

REPO="$(basename "$SOURCE")"

if [[ "$SOURCE" == "$TARGET" ]]; then
  printf '%s%s%s: 메인 체크아웃이므로 복사할 항목이 없다.\n' "$BOLD" "$REPO" "$NC"
  exit 0
fi

# 워크트리는 프로젝트 트리 밖(~/orca/workspaces/...)에 있으므로
# 메인 체크아웃에서 상위로 올라가며 설정을 찾는다.
orca_flow_load "$SOURCE"

# 초기 설정을 금지한 레포를 확인한다. 형제 레포를 포함한 우산을 검색하면
# 다른 레포의 산출물 수 MB까지 복사할 수 있다.
while IFS= read -r denied; do
  [[ -n "$denied" && "$denied" == "$REPO" ]] || continue
  die "초기 설정 금지 레포: $REPO (.orca-flow.json의 setup.deny)"
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

# 권한 설정은 명시적으로 요청한 경우에만 복사한다.
if (( WITH_AGENT_SETTINGS )); then
  COPY_FILES+=( '*/.claude/settings.local.json' )
fi

# 재생성에 DB 연결이나 추가 빌드가 필요한 디렉터리는 복사할 수 있다.
# 대상이 프로젝트마다 달라 기본 목록은 비워 둔다.
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

# 패턴 목록을 find 표현식으로 변환한다. 슬래시가 있으면 -path, 없으면 -name 이다.
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

# 잠금은 워크트리의 Git 디렉터리에 둔다. TMPDIR은 호출 환경에 따라 달라
# 같은 워크트리에 서로 다른 잠금을 만들 수 있다. 앱 워커의 환경변수 필터도 영향을 준다.
# dispatch, 앱 생성 이벤트, 직접 실행이 겹쳐 submodule과 의존성을 동시에 설치하지 않도록
# 호출자 대신 이 스크립트가 잠금을 관리한다.
GITDIR="$(git -C "$TARGET" rev-parse --absolute-git-dir)"
if (( DRY_RUN == 0 )); then
  LOCK="$GITDIR/worktree-setup.lock"
  if ! mkdir "$LOCK" 2>/dev/null; then
    HOLDER="$(cat "$LOCK/pid" 2>/dev/null || true)"
    # mkdir 직후 PID를 기록하기 전에 다른 실행이 읽으면 빈 값일 수 있다.
    # 잠금을 잘못 회수하지 않도록 한 번 더 읽는다.
    if [[ -z "$HOLDER" ]]; then
      sleep 0.5
      HOLDER="$(cat "$LOCK/pid" 2>/dev/null || true)"
    fi
    if [[ -n "$HOLDER" ]] && kill -0 "$HOLDER" 2>/dev/null; then
      printf '%s초기 설정 실행 중 (pid %s), 생략:%s %s\n' "$YELLOW" "$HOLDER" "$NC" "$TARGET"
      exit 75
    fi
    # 종료된 프로세스의 잠금을 옮긴 뒤 삭제한다. mv가 원자적이므로
    # 동시 회수 시 하나만 성공하고 다른 실행은 아래 mkdir에서 중단된다.
    if mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null; then
      rm -rf "$LOCK.stale.$$"
    fi
    if ! mkdir "$LOCK" 2>/dev/null; then
      printf '%s다른 실행이 잠금을 확보해 생략:%s %s\n' "$YELLOW" "$NC" "$TARGET"
      exit 75
    fi
  fi
  LOCK_HELD="$LOCK"
  printf '%s' "$$" > "$LOCK/pid"
fi

printf '%s%s%s\n' "$BOLD" "$REPO" "$NC"
note "원본: $SOURCE"
note "대상: $TARGET"
note "설정: ${PROJECT_CONFIG:-없음, 기본값 사용}"

# submodule은 복사보다 먼저 채운다. 빈 디렉터리에 파일이 먼저 놓이면 그 뒤의
# submodule 클론이 non-empty를 이유로 실패한다.
if [[ -f "$TARGET/.gitmodules" && $DRY_RUN -eq 0 ]]; then
  printf '%ssubmodule 초기화%s\n' "$BOLD" "$NC"
  git -C "$TARGET" submodule update --init --recursive
fi

# 원본의 submodule은 검색에서 제외해 해당 설정을 부모 레포의 파일로 복사하지 않는다.
# submodule의 .git은 파일이므로 디렉터리 제외만으로는 처리되지 않는다.
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

  # 삭제 전에 상대 경로인지 확인한다. repoExtras의 절대 경로나 .. 구성 요소는 거부한다.
  # a..b처럼 정상인 이름을 허용하도록 구성 요소 단위로 검사한다.
  if [[ -z "$rel" || "$rel" == /* || "$rel" == ".." \
        || "$rel" == ../* || "$rel" == */../* || "$rel" == */.. ]]; then
    die "허용되지 않는 복사 경로: $rel"
  fi

  local src="$SOURCE/$rel" dest="$TARGET/$rel"
  [[ -e "$src" ]] || return 0

  # 추적 파일은 --force여도 유지한다. 메인 체크아웃의 미커밋 내용으로
  # 덮어쓰면 워크트리에 의도하지 않은 수정이 생길 수 있다.
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

# 검색 결과는 NUL로 구분해 공백이 있는 경로도 안전하게 처리한다.
# 임시 파일을 사용해 파이프의 서브셸에서 카운터를 잃거나 프로세스 치환에서
# find 실패를 놓치는 문제를 피한다. 명령 치환은 NUL을 보관할 수 없다.
seed_found() {
  local finder="$1" path rel
  TMPFILE="$(mktemp)" || die "임시 파일을 만들 수 없다"
  "$finder" >"$TMPFILE" || die "검색에 실패했다: $SOURCE"
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
# 선택 항목인 dirs가 비어 있어도 실패로 종료하지 않도록 if로 검사한다.
# set -e 환경에서 조건 실패가 전체 실행에 영향을 주지 않게 한다.
if (( ${#COPY_DIRS[@]} > 0 )); then
  seed_found find_dirs
fi

# 패턴으로 안 잡히는 레포별 예외. 메인 체크아웃 기준 상대 경로다.
while IFS= read -r rel; do
  [[ -n "$rel" ]] && seed "$rel"
done < <(cfg_map_list setup.repoExtras "$REPO")

if (( copied == 0 && skipped == 0 )); then
  note "복사할 항목이 없다"
else
  note "$copied개 복사, $skipped개 유지 (기존 파일 또는 Git 추적 대상)"
fi

if (( DRY_RUN )); then
  printf '%s미리 보기 완료. 파일은 변경하지 않았다.%s\n' "$DIM" "$NC"
  exit 0
fi

# 초기 설정 완료 표식. 늦게 도착한 생성 이벤트의 중복 실행을 앱 플러그인이 방지한다.
# 설정 변경 후 직접 재실행할 수 있도록 이 스크립트 자체는 표식으로 건너뛰지 않는다.
mark_done() { date -u '+%Y-%m-%dT%H:%M:%SZ' > "$GITDIR/worktree-setup.done" 2>/dev/null || true; }

if (( WITH_DEPS == 0 )); then
  mark_done
  exit 0
fi

# node_modules와 .venv는 심볼릭 링크와 절대 경로를 포함하므로 복사하지 않고 설치한다.
# Gradle은 사용자 홈의 캐시를 공유하므로 여기서 워크트리별로 다시 받지 않는다.
if [[ -f "$TARGET/pnpm-lock.yaml" ]]; then
  printf '%spnpm install%s\n' "$BOLD" "$NC"
  if command -v pnpm >/dev/null 2>&1; then
    (cd "$TARGET" && pnpm install --frozen-lockfile)
  else
    printf '  %spnpm이 없어 설치 생략 (pnpm not found, skipped)%s\n' "$YELLOW" "$NC"
  fi
fi

if [[ -f "$TARGET/uv.lock" ]]; then
  printf '%suv sync%s\n' "$BOLD" "$NC"
  if command -v uv >/dev/null 2>&1; then
    (cd "$TARGET" && uv sync)
  else
    printf '  %suv가 없어 설치 생략 (uv not found, skipped)%s\n' "$YELLOW" "$NC"
  fi
fi

mark_done
