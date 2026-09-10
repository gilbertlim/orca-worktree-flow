---
description: 리뷰 결과를 작업 에이전트에게 전달해 수정을 요청한다
argument-hint: '<repo> <worktree-name>'
allowed-tools: Read, Bash(${CLAUDE_PLUGIN_ROOT}/bin/*), Bash(orca:*), Bash(git:*)
---

리뷰 결과를 작업 에이전트에게 전달해 수정을 요청한다.

인자: `$ARGUMENTS`

## 실행 순서

1. 판정 파일을 읽고 남은 blocking을 사용자에게 한 줄로 요약한다.
2. 리뷰 이후 외부 변경이 있으면 `NOTE`로 전달한다. 다른 워크트리의 계약 변경으로 판정의 전제가 달라질 수 있다.
3. 다음 명령을 실행한다.

```
${CLAUDE_PLUGIN_ROOT}/bin/handback.sh <repo> <worktree-name>
NOTE="<리뷰 이후 변경 사항>" ${CLAUDE_PLUGIN_ROOT}/bin/handback.sh <repo> <worktree-name>
```

4. 수정 후 커밋되면 `/orca:review`로 재리뷰한다. blocking이 없어질 때까지 수정과 리뷰를 반복한다.

작업 에이전트가 종료됐으면 같은 워크트리에 새로 실행한다. 브랜치와 커밋은 유지된다. 리뷰어가 잘못 판단했다면 에이전트는 수정 대신 근거를 제시한다. 지적을 받았다는 이유만으로 코드를 바꾸지 않는다.
