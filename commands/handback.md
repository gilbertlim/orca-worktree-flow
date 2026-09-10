---
description: 리뷰 판정을 그 워크트리의 작업 에이전트에게 되돌려 고치게 한다
argument-hint: '<repo> <worktree-name>'
allowed-tools: Read, Bash(${CLAUDE_PLUGIN_ROOT}/bin/*), Bash(orca:*), Bash(git:*)
---

리뷰 결과를 작업 에이전트에게 넘긴다.

인자: `$ARGUMENTS`

## 순서

1. 먼저 판정 파일을 읽는다. 어떤 blocking이 났는지 사람에게 한 줄로 요약한다.
2. 리뷰 이후 외부 변경이 있으면 `NOTE`로 전달한다. 다른 워크트리에서 계약을 수정하면 판정의 전제가 바뀔 수 있다.
3. 실행한다.

```
${CLAUDE_PLUGIN_ROOT}/bin/handback.sh <repo> <worktree-name>
NOTE="<리뷰 뒤에 달라진 것>" ${CLAUDE_PLUGIN_ROOT}/bin/handback.sh <repo> <worktree-name>
```

4. 고쳐서 커밋되면 `/orca:review`로 재리뷰한다. blocking이 없어질 때까지 이 왕복이 돈다.

## 알아 둘 것

- 작업 에이전트가 죽었으면 같은 워크트리에 새로 띄운다. 워크트리에 브랜치와 커밋이 그대로 남아 있다.
- 리뷰어가 틀렸다고 판단되면 에이전트가 고치지 않고 근거를 대게 돼 있다. 지적을 받았다는 이유만으로 코드가 바뀌면 안 된다.
