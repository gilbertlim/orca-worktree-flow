#!/usr/bin/env bash
# 지금 떠 있는 워크트리를 한 자리에 찍는다.
#
#   status.sh              우산 워크트리 안이면 제 것만, 밖이면 전부
#   status.sh --all        우산과 상관없이 전부
#   status.sh shared       한 레포만
#   status.sh --summary    표 끝에 세어 둔 값을 기계가 읽을 꼴로 덧붙인다
#
# 기본이 "제 것만"인 이유는, 서브 레포 하나를 우산 여럿이 겨눌 수 있어서다.
# 남의 워크트리가 표에 섞이면 다음 마디를 남의 것에 대고 부르게 된다.
# 제 것인지는 이름의 "<우산레포>.<우산워크트리>." 접두로 가른다.
#
# --summary 는 앱 플러그인이 쓴다. 알림 본문은 비례폭이라 이 표의 칸 정렬이
# 통째로 무너지고 배너는 두어 줄에서 잘리므로, 거기엔 표가 아니라 수를 싣는다.
# 플러그인은 앱 프로세스에서 부르므로 우산이 없고, 그래서 늘 전부를 센다.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUMMARY=0
ALL=0
FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --summary) SUMMARY=1; ALL=1 ;;
    --all) ALL=1 ;;
    --mine) ALL=0 ;;
    *) FILTER="$1" ;;
  esac
  shift
done

OWNER=""
[ "$ALL" = 1 ] || OWNER="$(owner_id)"

# 이 워크트리가 내 것인가. 내가 만든 서브 레포 워크트리와, 내가 앉아 있는
# 우산 워크트리 자신이 여기 걸린다.
mine() { # repo name
  [ -n "$OWNER" ] || return 0
  case "$1.$2" in "$OWNER") return 0 ;; esac
  case "$2" in "$OWNER".*) return 0 ;; esac
  return 1
}

# --summary 일 때만 찍는다. 표 뒤에 붙으므로 사람이 그냥 부르면 안 보인다.
emit_counts() {
  [ "$SUMMARY" = 1 ] || return 0
  printf -- '--- counts\n'
  printf 'worktrees=%s\n' "${n_total:-0}"
  printf 'review_stale=%s\n' "${n_stale:-0}"
  printf 'review_none=%s\n' "${n_unreviewed:-0}"
  printf 'dirty=%s\n' "${n_dirty:-0}"
  printf 'no_terminal=%s\n' "${n_idle:-0}"
  printf 'blocked=%s\n' "${n_blocked:-0}"
  printf 'owned=%s\n' "${n_owned:-0}"
  printf 'closed=%s\n' "${n_closed:-0}"
}

# 우산이 낸 워크트리 중 몇 개가 닫혔나. 우산 자신은 안 센다 -- 오케스트레이터가
# 앉아 있는 자리라 늘 더럽고, 그것 때문에 "다 닫혔다"가 영영 안 뜬다.
n_owned=0
n_closed=0

n_total=0
n_stale=0
n_unreviewed=0
n_dirty=0
n_idle=0
n_blocked=0

# preview 는 TUI 마지막 줄이다. 도는 중인지를 추가 호출 없이 여기서 가른다.
TERMS="$(orca terminal list --json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for t in d.get("result", {}).get("terminals", []):
    if t.get("orphaned"):
        continue
    # 값이 JSON null 로 오는 때가 있다(에이전트가 쉬면 Orca가 제목을 안 준다).
    # get 의 기본값은 키가 있고 값이 null 이면 안 걸린다.
    print("%s\t%s\t%s\t%s" % (
        t.get("worktreePath") or "",
        t.get("handle") or "",
        (t.get("title") or "").replace("\t", " "),
        (t.get("preview") or "").replace("\t", " "),
    ))
' || true)"

# 카드에 적힌 것. 커밋 수와 달리 이건 에이전트가 스스로 쓴 것이라,
# git이 못 보는 것("테스트 도는 중", "FK에 막힘")이 여기 앉는다.
CARDS="$(orca worktree list --json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for w in d.get("result", {}).get("worktrees", []):
    c = (w.get("comment") or "").replace("\n", " ").strip()
    if c:
        print("%s\t%s\t%s" % (w.get("path") or "", w.get("workspaceStatus") or "", c))
' || true)"

if [ -n "$OWNER" ]; then
  printf '우산 %s -- 제 것만 찍는다 (전부는 --all)\n\n' "$OWNER"
fi

printf '%-40s %-6s %-7s %-14s %s\n' "워크트리" "커밋" "미커밋" "리뷰" "터미널"
printf '%s\n' "--------------------------------------------------------------------------------"

found=0
for dir in "$ORCA_WORKSPACES"/*/*; do
  [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || continue
  repo="$(basename "$(dirname "$dir")")"
  name="$(basename "$dir")"
  [ -n "$FILTER" ] && [ "$repo" != "$FILTER" ] && continue
  mine "$repo" "$name" || continue
  found=1

  ahead="$(git -C "$dir" rev-list --count "$BASE_BRANCH..HEAD" 2>/dev/null || echo '?')"
  dirty="$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"

  # 터미널은 개수만으로는 못 읽는다. 도는 중과 승인을 기다리는 중이 같은 "1개"다.
  rows="$(printf '%s\n' "$TERMS" | awk -F'\t' -v p="$dir" '$1==p')"
  tcount="$(printf '%s\n' "$rows" | grep -c . || true)"
  if [ "${tcount:-0}" = 0 ]; then
    term="없음"
  else
    states=""
    while IFS=$'\t' read -r _ h _ preview; do
      [ -n "$h" ] || continue
      st="$(terminal_state "$h" "$preview")"
      [ "$st" = "막힘" ] && n_blocked=$((n_blocked + 1))
      states="${states:+$states, }$st"
    done <<< "$rows"
    term="${tcount}개 · ${states:-?}"
  fi

  # 리뷰는 몇 차까지 돌았는지가 곧 처지다. 마지막 커밋보다 판정이 오래됐으면
  # 고친 뒤 재리뷰를 안 돌린 것이다.
  rf="$(review_file "$repo" "$name")"
  rounds="$(rounds_done "$repo" "$name")"
  if [ "$rounds" = 0 ]; then
    review="안 함"
  elif [ ! -f "$rf" ]; then
    # 판정 파일이 밀려 있고 새것이 아직 없다 -- 다음 라운드가 도는 중이다.
    review="$((rounds + 1))차 중"
  else
    rt="$(stat -f %m "$rf" 2>/dev/null || stat -c %Y "$rf" 2>/dev/null || echo 0)"
    ct="$(git -C "$dir" log -1 --format=%ct 2>/dev/null || echo 0)"
    if [ "$rt" -lt "$ct" ]; then review="${rounds}차 낡음"; else review="${rounds}차"; fi
  fi

  # 닫힘: 커밋이 서 있고, 미커밋이 없고, 판정이 최신이고, blocking이 0.
  # 넷 다 맞아야 land를 물을 값이다.
  case "$repo.$name" in
    "$OWNER") ;;
    *)
      if [ -n "$OWNER" ]; then
        n_owned=$((n_owned + 1))
        if [ "${dirty:-0}" = 0 ] && [ "${ahead:-0}" != 0 ] && [ "${ahead:-?}" != '?' ] \
           && [ -f "$rf" ] && [ "$review" = "${rounds}차" ] \
           && [ "$(blocking_count "$rf")" = 0 ]; then
          n_closed=$((n_closed + 1))
        fi
      fi
      ;;
  esac

  n_total=$((n_total + 1))
  case "$review" in *낡음) n_stale=$((n_stale + 1)) ;; esac
  [ "$review" = "안 함" ] && n_unreviewed=$((n_unreviewed + 1))
  [ "${dirty:-0}" != 0 ] && n_dirty=$((n_dirty + 1))
  [ "${tcount:-0}" = 0 ] && n_idle=$((n_idle + 1))

  printf '%-40s %-6s %-7s %-14s %s\n' "$repo/$name" "$ahead" "$dirty" "$review" "$term"

  # 카드 줄은 표에 넣지 않고 아래에 붙인다. 길이가 제각각이라 칸에 넣으면 정렬이 무너진다.
  cline="$(printf '%s\n' "$CARDS" | awk -F'\t' -v p="$dir" '$1==p {print "["$2"] "$3}' | head -1)"
  if [ -n "$cline" ]; then
    printf '%-40s %s\n' "" "└ ${cline}"
  fi
done

if [ "$found" != 1 ]; then
  if [ -n "$OWNER" ]; then
    printf '%s 가 만든 워크트리가 없다. 전부 보려면 --all 이다.\n' "$OWNER"
  else
    printf '떠 있는 워크트리가 없다.\n'
  fi
  emit_counts
  exit 0
fi

printf '\n'
for dir in "$ORCA_WORKSPACES"/*/*; do
  [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || continue
  repo="$(basename "$(dirname "$dir")")"
  name="$(basename "$dir")"
  [ -n "$FILTER" ] && [ "$repo" != "$FILTER" ] && continue
  mine "$repo" "$name" || continue
  log="$(git -C "$dir" log --oneline "$BASE_BRANCH..HEAD" 2>/dev/null)"
  [ -n "$log" ] || continue
  printf '=== %s/%s\n%s\n\n' "$repo" "$name" "$log"
done

# 다 닫혔으면 그것을 말해 준다. 표만 찍고 말면 오케스트레이터가 계속 폴링하거나
# 혼자 land해 버린다. 무엇을 할지는 여기서 안 정하고 사람에게 넘긴다 --
# 계약이 걸린 변경은 머지 순서가 있고 그건 이 표에 안 보인다.
if [ "${n_owned:-0}" -gt 0 ] && [ "$n_owned" = "$n_closed" ]; then
  printf '▶ 내가 낸 워크트리 %s개가 전부 닫혔다.\n' "$n_owned"
  printf '  진척을 기록하고 land할지 사람에게 묻는다.\n\n'
elif [ "${n_closed:-0}" -gt 0 ]; then
  printf '▶ %s개 중 %s개가 닫혔다. 나머지가 끝나면 land를 묻는다.\n\n' "$n_owned" "$n_closed"
fi

# 카드도 커밋도 못 드는 것 -- 무엇을 왜 그렇게 했는지 -- 이 파일에 쌓인다.
# 컨텍스트가 차 세션을 갈아탈 때 이어갈 자리가 여기다.
if [ -n "$OWNER" ] && [ -f "$(journal_file)" ]; then
  printf '기록 %s\n' "$(journal_file)"
  tail -5 "$(journal_file)" | sed 's/^/  /'
  printf '\n'
fi

emit_counts
