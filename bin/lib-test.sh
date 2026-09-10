#!/usr/bin/env bash
# lib.sh 의 최소 자체 점검. bash bin/lib-test.sh 로 돌린다.
#
# blocking 절이 자를 줄 수보다 길 때 pipefail + set -e 아래에서 부른 쪽이
# 조용히 죽지 않는지를 본다. 예전에 `| head -20` 이 그렇게 죽였다.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
RF="$TMP/verdict.md"
{
  printf '# 리뷰 판정\n\n## Blocking\n'
  for i in $(seq 1 200); do printf -- '- 항목 %s. %s\n' "$i" "$(head -c 400 </dev/zero | tr '\0' 'x')"; done
  printf '\n## Non-blocking\n- 곁다리\n'
} > "$RF"

out="$(blocking_section "$RF" 20)"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 20 ] || { echo "20줄로 안 잘렸다"; exit 1; }
if printf '%s\n' "$out" | grep -q 'Non-blocking'; then echo "다음 절까지 새어 나왔다"; exit 1; fi
[ "$(blocking_count "$RF")" = 200 ] || { echo "blocking_count 가 틀렸다: $(blocking_count "$RF")"; exit 1; }
[ "$(blocking_section "$RF" | wc -l | tr -d ' ')" = 202 ] || { echo "무제한 호출이 절 전체를 안 준다"; exit 1; }

echo "ok"
