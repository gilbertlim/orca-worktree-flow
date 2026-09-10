#!/usr/bin/env bash
# 프로젝트 설정(.orca-flow.json)을 읽는 공통 함수. 직접 실행하지 않고 source한다.
# lib.sh와 worktree-setup.sh가 사용한다. 초기 설정은 앱 플러그인이 bash로 직접 실행하며,
# 허용된 환경변수만 받아 PATH에 orca가 없을 수 있다. CLI를 요구하는 lib.sh와 분리해
# 초기 설정이 단독 실행되도록 했다. 의존성은 python3뿐이다.

ORCA_FLOW_CONFIG_NAME=".orca-flow.json"

# 기준 디렉터리에서 상위로 올라가며 .orca-flow.json을 찾는다.
# 직접 호출 시 $PWD, 초기 설정 시 메인 체크아웃에서 시작한다.
# 단일 레포는 레포 루트, 여러 레포를 관리하는 프로젝트는 우산에서 설정을 찾는다.
# 개발자별 후보 경로를 나열할 필요가 없다.
orca_flow_find_root() { # start-dir
  local dir
  dir="$(cd "${1:-$PWD}" 2>/dev/null && pwd)" || return 1
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/$ORCA_FLOW_CONFIG_NAME" ]; then
      printf '%s' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# PROJECT_ROOT 와 PROJECT_CONFIG 를 채운다. 못 찾으면 둘 다 빈 문자열이고,
# 그 상태에서도 cfg_get 은 기본값을 돌려주므로 호출하는 쪽이 분기할 필요가 없다.
orca_flow_load() { # start-dir
  PROJECT_ROOT="${ORCA_FLOW_ROOT:-$(orca_flow_find_root "${1:-$PWD}" || true)}"
  PROJECT_CONFIG=""
  if [ -n "$PROJECT_ROOT" ] && [ -f "$PROJECT_ROOT/$ORCA_FLOW_CONFIG_NAME" ]; then
    PROJECT_CONFIG="$PROJECT_ROOT/$ORCA_FLOW_CONFIG_NAME"
  fi
}

# 설정에서 스칼라 하나를 읽는다. 없으면 기본값이다.
# ${projectRoot} 토큰은 여기서 실제 경로로 바뀐다. 설정 파일에 절대 경로를
# 적지 않아도 되게 하려는 것이다.
cfg_get() { # dotted.path [default]
  local def="${2:-}"
  [ -n "${PROJECT_CONFIG:-}" ] || { printf '%s' "$def"; return 0; }
  ORCA_CFG_PATH="$1" ORCA_CFG_DEF="$def" ORCA_CFG_ROOT="${PROJECT_ROOT:-}" \
    python3 -c '
import json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fp:
        node = json.load(fp)
except Exception as exc:
    sys.stderr.write("%s 를 못 읽었다: %s\n" % (sys.argv[1], exc))
    sys.exit(1)
default = os.environ["ORCA_CFG_DEF"]
for key in os.environ["ORCA_CFG_PATH"].split("."):
    if not isinstance(node, dict) or key not in node:
        sys.stdout.write(default)
        sys.exit(0)
    node = node[key]
if node is None or isinstance(node, (dict, list)):
    sys.stdout.write(default)
elif isinstance(node, bool):
    sys.stdout.write("true" if node else "false")
else:
    sys.stdout.write(str(node).replace("${projectRoot}", os.environ.get("ORCA_CFG_ROOT", "")))
' "$PROJECT_CONFIG"
}

# 문자열 배열을 한 줄에 하나씩 출력한다. 없으면 출력하지 않는다.
# 호출자는 빈 결과에 기본 목록을 사용한다. 현재는 목록 전체를 비우는 요구가 없어
# 빈 배열과 키 누락을 구분하지 않는다. 필요해지면 구분해야 한다.
cfg_list() { # dotted.path
  [ -n "${PROJECT_CONFIG:-}" ] || return 0
  ORCA_CFG_PATH="$1" ORCA_CFG_ROOT="${PROJECT_ROOT:-}" \
    python3 -c '
import json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fp:
        node = json.load(fp)
except Exception:
    sys.exit(0)
for key in os.environ["ORCA_CFG_PATH"].split("."):
    if not isinstance(node, dict) or key not in node:
        sys.exit(0)
    node = node[key]
if not isinstance(node, list):
    sys.exit(0)
root = os.environ.get("ORCA_CFG_ROOT", "")
for item in node:
    if isinstance(item, str) and item:
        print(item.replace("${projectRoot}", root))
' "$PROJECT_CONFIG"
}

# 객체의 키에 해당하는 문자열 배열을 읽는다. spring-boot.v2처럼 레포 이름에
# 점이 있으면 dotted path로 구분할 수 없어 키를 별도 인자로 받는다.
cfg_map_list() { # dotted.path key
  [ -n "${PROJECT_CONFIG:-}" ] || return 0
  ORCA_CFG_PATH="$1" ORCA_CFG_KEY="$2" ORCA_CFG_ROOT="${PROJECT_ROOT:-}" \
    python3 -c '
import json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fp:
        node = json.load(fp)
except Exception:
    sys.exit(0)
for key in os.environ["ORCA_CFG_PATH"].split("."):
    if not isinstance(node, dict) or key not in node:
        sys.exit(0)
    node = node[key]
if not isinstance(node, dict):
    sys.exit(0)
node = node.get(os.environ["ORCA_CFG_KEY"])
if isinstance(node, str):
    node = [node]
if not isinstance(node, list):
    sys.exit(0)
root = os.environ.get("ORCA_CFG_ROOT", "")
for item in node:
    if isinstance(item, str) and item:
        print(item.replace("${projectRoot}", root))
' "$PROJECT_CONFIG"
}

# 인용부호 안의 ~는 셸이 확장하지 않으므로 JSON에서 읽은 값을 홈 경로로 치환한다.
expand_home() {
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}
