#!/usr/bin/env bash
# 지금 떠 있는 워크트리를 한 자리에 찍는다.
#
#   status.sh              우산 워크트리 안이면 제 것만, 밖이면 전부
#   status.sh --all        우산과 상관없이 전부
#   status.sh shared       한 레포만
#   status.sh --summary    표 끝에 세어 둔 값을 기계가 읽을 꼴로 덧붙인다
#   status.sh --wait       사람이 부를 마디가 설 때까지 기다렸다가 그때 한 번 찍는다
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
WAIT=0
FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --summary) SUMMARY=1; ALL=1 ;;
    --all) ALL=1 ;;
    --mine) ALL=0 ;;
    --wait) WAIT=1 ;;
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

# --wait 는 사람이 부를 마디가 설 때까지 자고, 그때 깨어나 아래 표를 한 번 찍는다.
#
# 오케스트레이터가 status 를 반복해서 치는 대신 이것을 background 로 걸어 둔다.
# 사람에게 폴링을 시키지 않으려는 것이고, 깨어날 자리는 결국 승인이 필요한
# 자리 넷뿐이다 -- 리뷰를 돌릴 것이 섰다, 판정에 blocking 이 남았다, 전부
# 닫혔다, 에이전트가 사람 손에 막혔다.
#
# 세는 것은 제 자신을 --summary 로 다시 불러서 한다. 표를 그리는 코드를 두 벌
# 두지 않으려는 것이고, --mine 을 함께 주는 것은 --summary 가 ALL=1 을 켜기
# 때문이다(앱 플러그인이 우산 없이 부르는 자리라 그렇게 돼 있다).
WAKE=""
if [ "$WAIT" = 1 ]; then
  [ -n "$OWNER" ] || die "--wait 는 우산 워크트리 안에서만 쓴다. 지금은 우산이 안 잡힌다."
  interval="${WAIT_INTERVAL:-60}"
  limit="${WAIT_TIMEOUT:-14400}"
  waited=0
  while :; do
    counts="$("$0" --summary --mine ${FILTER:+"$FILTER"} 2>/dev/null | sed -n '/^--- counts$/,$p')"
    c_of() { printf '%s\n' "$counts" | awk -F= -v k="$1" '$1 == k { print $2 + 0; exit }'; }
    owned="$(c_of owned)"; blocked="$(c_of blocked)"
    ready="$(c_of review_ready)"; hb="$(c_of handback)"; closed="$(c_of closed)"

    if   [ "${owned:-0}" = 0 ];        then WAKE="낸 워크트리가 없다"
    elif [ "${blocked:-0}" != 0 ];     then WAKE="에이전트 ${blocked}개가 사람 손을 기다린다"
    elif [ "${ready:-0}" != 0 ];       then WAKE="리뷰를 돌릴 워크트리 ${ready}개"
    elif [ "${hb:-0}" != 0 ];          then WAKE="blocking 이 남은 워크트리 ${hb}개"
    elif [ "$owned" = "${closed:-0}" ]; then WAKE="내가 낸 ${owned}개가 전부 닫혔다"
    elif [ "$waited" -ge "$limit" ];   then WAKE="${limit}초를 기다렸다 -- 아직 도는 중이다"
    fi
    [ -z "$WAKE" ] || break
    sleep "$interval"
    waited=$((waited + interval))
  done
  printf '▶ 깨어났다: %s (%s초 기다림)\n\n' "$WAKE" "$waited"
fi

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
  printf 'review_ready=%s\n' "${n_ready:-0}"
  printf 'handback=%s\n' "${n_handback:-0}"
  printf 'closed=%s\n' "${n_closed:-0}"
  printf 'self_ahead=%s\n' "${self_ahead:-0}"
}

# 우산이 낸 워크트리 중 몇 개가 닫혔나. 우산 자신은 이 셈에 안 넣는다 --
# 오케스트레이터가 앉아 있는 자리라 늘 더럽고, 섞으면 서브 레포가 다 닫혀도
# "전부 닫혔다"가 영영 안 뜬다.
n_owned=0
n_ready=0
n_handback=0
n_closed=0

# 우산 자신은 따로 본다. 빼 두기만 하면 우산이 제 손으로 짠 것은 아무도 안 묻고,
# 실제로 그래서 사람이 세 번을 먼저 밀었다.
self_ahead=0
self_dirty=0
self_base=""

n_total=0
n_stale=0
n_unreviewed=0
n_dirty=0
n_idle=0
n_blocked=0

# 레포마다 기준 브랜치가 다르다. base_branch_for 는 lib.sh 에 있고 dispatch,
# review, land 도 같은 것을 쓴다 -- status 가 안내한 land 가 실제로 돌게 하려면
# 기준을 한 자리에서 정해야 한다.
# 그 함수를 아래 루프의 명령 치환(서브셸)에서 부르므로 레포 경로 메모가 부모로
# 안 돌아온다. 여기서 한 번 채워 두면 서브셸이 그것을 물려받는다.
repo_paths >/dev/null

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

  # 기준 브랜치가 이 워크트리에 없으면 origin 쪽을 본다. 워크트리는 브랜치를
  # 메인 체크아웃과 나눠 쓰므로, 이 fallback 이 실제로 도는 것은 그 기준 브랜치를
  # 로컬에 한 번도 꺼내 놓은 적 없는 레포뿐이다.
  # 둘 다 없으면 '?' 로 둔다 -- 0 은 "커밋이 없다"라 land 를 안 묻는 값이고,
  # 못 센 것을 0 으로 적으면 그 둘이 같아진다.
  # ponytail: 로컬 기준을 먼저 본다. 메인 체크아웃이 origin 보다 낡아 있으면
  # 이미 land 된 커밋까지 이 워크트리 몫으로 세어진다. land 가 머지하는 대상도
  # 그 로컬 브랜치라 표와 land 가 어긋나지는 않는다. 어긋나면 origin 을 먼저
  # 보게 바꾸고, 그때는 land 쪽도 같이 옮긴다.
  base="$(base_branch_for "$repo")"
  ahead="$(git -C "$dir" rev-list --count "$base..HEAD" 2>/dev/null \
           || git -C "$dir" rev-list --count "origin/$base..HEAD" 2>/dev/null \
           || echo '?')"
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
    "$OWNER")
      self_ahead="${ahead:-0}"
      self_base="$base"
      self_dirty="${dirty:-0}"
      ;;
    *)
      if [ -n "$OWNER" ]; then
        n_owned=$((n_owned + 1))
        # 다음에 무엇을 부를 값인지로 가른다 -- review, handback, land 셋이다.
        # --wait 가 이 셋 중 하나가 서면 깨어난다. 미커밋이 남아 있거나 커밋이
        # 아직 없으면 셋 다 아니다 -- 에이전트가 일하는 중이라 부를 것이 없다.
        if [ "${dirty:-0}" = 0 ] && [ "${ahead:-0}" != 0 ] && [ "${ahead:-?}" != '?' ]; then
          case "$review" in
            # 리뷰어가 도는 중이다. 판정이 떨어질 때까지는 부를 것이 없다.
            *중) ;;
            "안 함"|*낡음) n_ready=$((n_ready + 1)) ;;
            # 여기 오면 판정이 있고 커밋보다 새것이다. blocking 이 갈림길이다.
            *)
              if [ "$(blocking_count "$rf")" = 0 ]; then
                n_closed=$((n_closed + 1))
              else
                n_handback=$((n_handback + 1))
              fi
              ;;
          esac
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
  cline="$(printf '%s\n' "$CARDS" | awk -F'\t' -v p="$dir" '$1==p && !seen {print "["$2"] "$3; seen=1}')"
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
  base="$(base_branch_for "$repo")"
  log="$(git -C "$dir" log --oneline "$base..HEAD" 2>/dev/null \
         || git -C "$dir" log --oneline "origin/$base..HEAD" 2>/dev/null || true)"
  [ -n "$log" ] || continue
  printf '=== %s/%s\n%s\n\n' "$repo" "$name" "$log"
done

# 승인이 필요한 마디를 그대로 짚어 준다. --wait 가 깨어나는 조건과 같은 셈이라,
# 백그라운드로 걸어 두든 사람이 직접 치든 같은 문장을 본다.
if [ "${n_ready:-0}" -gt 0 ]; then
  printf '▶ 리뷰를 돌릴 워크트리 %s개. /orca:review 를 부를지 사람에게 묻는다.\n\n' "$n_ready"
fi
if [ "${n_handback:-0}" -gt 0 ]; then
  printf '▶ 판정에 blocking 이 남은 워크트리 %s개. /orca:handback 이다.\n\n' "$n_handback"
fi

# 다 닫혔으면 그것을 말해 준다. 표만 찍고 말면 오케스트레이터가 계속 폴링하거나
# 혼자 land해 버린다. 무엇을 할지는 여기서 안 정하고 사람에게 넘긴다 --
# 계약이 걸린 변경은 머지 순서가 있고 그건 이 표에 안 보인다.
if [ "${n_owned:-0}" -gt 0 ] && [ "$n_owned" = "$n_closed" ]; then
  printf '▶ 내가 낸 워크트리 %s개가 전부 닫혔다.\n' "$n_owned"
  printf '  진척을 기록하고 land할지 사람에게 묻는다.\n\n'
elif [ "${n_closed:-0}" -gt 0 ]; then
  printf '▶ %s개 중 %s개가 닫혔다. 나머지가 끝나면 land를 묻는다.\n\n' "$n_owned" "$n_closed"
fi

# 우산이 제 손으로 짠 것. 서브 레포와 조건이 다르다 -- 리뷰를 안 거치는 자리라
# 판정 파일을 안 보고, 미커밋이 없고 기준 브랜치보다 앞서 있으면 물을 값이다.
if [ -n "$OWNER" ] && [ "${self_ahead:-0}" != 0 ] && [ "${self_ahead:-?}" != '?' ] \
   && [ "${self_dirty:-0}" = 0 ]; then
  printf '▶ 이 우산 워크트리에도 %s 앞에 커밋 %s개가 서 있다.\n' "${self_base:-$BASE_BRANCH}" "$self_ahead"
  printf '  land할지 사람에게 묻는다. 이 워크트리 안에서 부르면 지우지 않고 머지와 push만 한다.\n\n'
fi

# 카드도 커밋도 못 드는 것 -- 무엇을 왜 그렇게 했는지 -- 이 파일에 쌓인다.
# 컨텍스트가 차 세션을 갈아탈 때 이어갈 자리가 여기다.
if [ -n "$OWNER" ] && [ -f "$(journal_file)" ]; then
  printf '기록 %s\n' "$(journal_file)"
  tail -5 "$(journal_file)" | sed 's/^/  /'
  printf '\n'
fi

emit_counts
