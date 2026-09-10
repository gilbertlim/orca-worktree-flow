#!/usr/bin/env bash
# 워크트리 상태를 조회한다.
#
#   status.sh            우산 안에서는 소속만, 밖에서는 전체 조회
#   status.sh --all      우산과 관계없이 전체 조회
#   status.sh shared     해당 레포 조회
#   status.sh --summary  프로그램이 읽을 집계 블록 추가
#   status.sh --wait     다음 작업이 필요할 때까지 대기 후 한 번 출력
#
# <우산레포>.<우산워크트리>. 접두로 소속을 구분한다.
# 같은 서브 레포를 여러 우산이 사용할 때 다른 작업과 혼동하지 않기 위해서다.
# 앱 플러그인은 --summary로 전체를 집계한다. 알림의 비례폭 글꼴과 짧은 배너에는
# 표를 정렬하기 어려워 집계만 표시한다.

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

# 현재 우산 자체와 그 우산이 만든 서브 워크트리인지 확인한다.
mine() { # repo name
  [ -n "$OWNER" ] || return 0
  case "$1.$2" in "$OWNER") return 0 ;; esac
  case "$2" in "$OWNER".*) return 0 ;; esac
  return 1
}

# --wait는 다음 작업이 필요한 상태까지 대기한다. 반복 조회 대신 백그라운드로 실행한다.
# 리뷰 준비, blocking 잔여, 전체 머지 준비 완료, 사용자 입력 대기를 확인한다.
# 집계는 자신을 --summary로 호출해 재사용한다. --summary는 앱의 전체 조회용이므로
# --mine을 함께 지정해 현재 우산으로 한정한다.
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

    if   [ "${owned:-0}" = 0 ];        then WAKE="소속 워크트리가 없다"
    elif [ "${blocked:-0}" != 0 ];     then WAKE="에이전트 ${blocked}개가 사용자 입력을 기다린다"
    elif [ "${ready:-0}" != 0 ];       then WAKE="리뷰할 워크트리 ${ready}개"
    elif [ "${hb:-0}" != 0 ];          then WAKE="blocking이 남은 워크트리 ${hb}개"
    elif [ "$owned" = "${closed:-0}" ]; then WAKE="소속 워크트리 ${owned}개가 모두 머지할 준비가 됐다"
    elif [ "$waited" -ge "$limit" ];   then WAKE="${limit}초를 기다렸다 -- 아직 작업 중이다"
    fi
    [ -z "$WAKE" ] || break
    sleep "$interval"
    waited=$((waited + interval))
  done
  printf '대기 종료: %s (%s초 대기)\n\n' "$WAKE" "$waited"
fi

# --summary 일 때만 출력한다. 표 뒤에 붙으므로 사람이 그냥 부르면 안 보인다.
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

# 소속 서브 워크트리의 머지 준비 상태를 집계한다. 우산은 진행 문서 등에
# 미커밋 변경이 계속 생길 수 있어 전체 완료 집계에서 제외한다.
n_owned=0
n_ready=0
n_handback=0
n_closed=0

# 우산의 직접 변경도 머지 여부를 확인할 수 있도록 별도로 집계한다.
# 이 안내가 없어 사용자가 세 번 먼저 요청했던 사례가 있다.
self_ahead=0
self_dirty=0
self_base=""

n_total=0
n_stale=0
n_unreviewed=0
n_dirty=0
n_idle=0
n_blocked=0

# 레포별 기준 브랜치는 dispatch, review, land와 같은 base_branch_for로 읽는다.
# 명령 치환의 서브셸에서 만든 캐시는 부모에게 전달되지 않으므로
# 반복 조회 전에 repo_paths 캐시를 채워 상속한다.
repo_paths >/dev/null

# preview는 TUI 마지막 줄이다. 추가 호출 없이 실행 여부를 확인한다.
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

# 에이전트가 작성한 카드 문구. 테스트나 FK 문제처럼 Git 조회로 알 수 없는 상태를 표시한다.
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
  printf '우산 %s -- 소속 워크트리만 표시한다 (전체 조회는 --all)\n\n' "$OWNER"
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

  # 로컬 기준 브랜치가 없으면 origin을 사용한다. 브랜치는 메인 체크아웃과 공유하므로
  # 로컬에 기준 브랜치를 만든 적이 없는 레포에서만 대체 경로를 사용한다.
  # 둘 다 없으면 커밋 없음(0)과 구분하도록 ?를 표시한다.
  # 로컬이 origin보다 오래되면 이미 land한 커밋도 집계되지만, land 대상도 로컬이므로
  # 조회와 머지 기준은 일치한다. origin 우선으로 바꿀 때는 land도 함께 검토해야 한다.
  base="$(base_branch_for "$repo")"
  ahead="$(git -C "$dir" rev-list --count "$base..HEAD" 2>/dev/null \
           || git -C "$dir" rev-list --count "origin/$base..HEAD" 2>/dev/null \
           || echo '?')"
  dirty="$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"

  # 터미널 개수만으로는 실행 중과 승인 대기를 구분할 수 없어 상태도 조회한다.
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
    term="${tcount}개, ${states:-?}"
  fi

  # 리뷰 차수와 최신 여부를 표시한다. 판정보다 최신 커밋이 있으면 재리뷰가 필요하다.
  rf="$(review_file "$repo" "$name")"
  rounds="$(rounds_done "$repo" "$name")"
  if [ "$rounds" = 0 ]; then
    review="안 함"
  elif [ ! -f "$rf" ]; then
    # 이전 판정만 보관돼 있고 새 판정이 없으면 다음 리뷰가 진행 중이다.
    review="$((rounds + 1))차 중"
  else
    rt="$(stat -f %m "$rf" 2>/dev/null || stat -c %Y "$rf" 2>/dev/null || echo 0)"
    ct="$(git -C "$dir" log -1 --format=%ct 2>/dev/null || echo 0)"
    if [ "$rt" -lt "$ct" ]; then review="${rounds}차 낡음"; else review="${rounds}차"; fi
  fi

  # 머지 준비 조건: 커밋 있음, 미커밋 변경 없음, 최신 판정, blocking 0건.
  # 네 조건을 모두 만족하면 land 여부를 확인한다.
  case "$repo.$name" in
    "$OWNER")
      self_ahead="${ahead:-0}"
      self_base="$base"
      self_dirty="${dirty:-0}"
      ;;
    *)
      if [ -n "$OWNER" ]; then
        n_owned=$((n_owned + 1))
        # review, handback, land 중 다음 작업을 구분한다. --wait도 이 조건을 사용한다.
        # 미커밋 변경이 있거나 커밋이 없으면 작업 중이므로 어느 단계도 요청하지 않는다.
        if [ "${dirty:-0}" = 0 ] && [ "${ahead:-0}" != 0 ] && [ "${ahead:-?}" != '?' ]; then
          case "$review" in
            # 리뷰 진행 중에는 판정이 나올 때까지 다음 작업을 요청하지 않는다.
            *중) ;;
            "안 함"|*낡음) n_ready=$((n_ready + 1)) ;;
            # 최신 판정의 blocking 유무로 수정 요청과 머지 준비를 구분한다.
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
    printf '워크트리가 없다.\n'
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

# --wait와 같은 조건으로 사용자 확인이 필요한 다음 작업을 안내한다.
if [ "${n_ready:-0}" -gt 0 ]; then
  printf '리뷰할 워크트리 %s개. /orca:review 실행 여부를 사용자에게 묻는다.\n\n' "$n_ready"
fi
if [ "${n_handback:-0}" -gt 0 ]; then
  printf '판정에 blocking이 남은 워크트리 %s개. /orca:handback으로 수정을 요청한다.\n\n' "$n_handback"
fi

# 머지 준비가 끝나면 사용자 판단이 필요함을 안내한다.
# 불필요한 폴링과 자동 land를 막는다. 계약에 따른 머지 순서는 이 표에 없기 때문이다.
if [ "${n_owned:-0}" -gt 0 ] && [ "$n_owned" = "$n_closed" ]; then
  printf '소속 워크트리 %s개가 모두 머지할 준비가 됐다.\n' "$n_owned"
  printf '  진행 상황을 기록하고 land할지 사용자에게 묻는다.\n\n'
elif [ "${n_closed:-0}" -gt 0 ]; then
  printf '%s개 중 %s개가 머지할 준비가 됐다. 나머지가 끝나면 land를 묻는다.\n\n' "$n_owned" "$n_closed"
fi

# 우산의 직접 변경은 판정 파일 없이 확인한다.
# 미커밋 변경이 없고 기준 브랜치보다 앞서 있으면 머지 여부를 묻는다.
if [ -n "$OWNER" ] && [ "${self_ahead:-0}" != 0 ] && [ "${self_ahead:-?}" != '?' ] \
   && [ "${self_dirty:-0}" = 0 ]; then
  printf '이 우산 워크트리에도 %s 앞에 커밋 %s개가 있다.\n' "${self_base:-$BASE_BRANCH}" "$self_ahead"
  printf '  land할지 사용자에게 묻는다. 이 워크트리 안에서 실행하면 삭제하지 않고 머지와 push만 한다.\n\n'
fi

# 우산별 작업 이력을 표시한다. 세션을 이어받을 때 참고한다.
# 결정 내용과 근거는 자동 기록되지 않으므로 별도 문서에 남겨야 한다.
if [ -n "$OWNER" ] && [ -f "$(journal_file)" ]; then
  printf '기록 %s\n' "$(journal_file)"
  tail -5 "$(journal_file)" | sed 's/^/  /'
  printf '\n'
fi

emit_counts
