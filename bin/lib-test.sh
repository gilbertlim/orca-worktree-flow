#!/usr/bin/env bash
# lib.sh 자체 검사. bash bin/lib-test.sh로 실행한다.
# 긴 blocking 절을 잘라도 pipefail과 set -e로 호출자가 종료되지 않는지 확인한다.
# 이전의 | head -20 방식에서 발생했던 SIGPIPE 문제를 검사한다.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
RF="$TMP/verdict.md"
{
  printf '# 리뷰 판정\n\n## Blocking\n'
  for i in $(seq 1 200); do printf -- '- 항목 %s. %s\n' "$i" "$(head -c 400 </dev/zero | tr '\0' 'x')"; done
  printf '\n## Non-blocking\n- 참고 사항\n'
} > "$RF"

out="$(blocking_section "$RF" 20)"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 20 ] || { echo "출력이 20줄로 제한되지 않았다"; exit 1; }
if printf '%s\n' "$out" | grep -q 'Non-blocking'; then echo "다음 절이 출력에 포함됐다"; exit 1; fi
[ "$(blocking_count "$RF")" = 200 ] || { echo "blocking_count 가 틀렸다: $(blocking_count "$RF")"; exit 1; }
[ "$(blocking_section "$RF" | wc -l | tr -d ' ')" = 202 ] || { echo "줄 수 제한이 없는 호출에서 절 일부가 누락됐다"; exit 1; }

echo "ok"
