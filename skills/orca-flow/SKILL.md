---
name: orca-flow
description: 여러 레포에 걸친 작업이나 같은 레포의 동시 작업을 Orca 워크트리별 에이전트에 나눠 맡길 때 사용한다. dispatch, status, review, handback, land 절차와 작업 프롬프트 작성 방법을 안내한다.
---

# Orca 워크트리 병렬 작업

레포별 작업을 Orca 워크트리에 나눠 맡기고 각 워크트리에서 구현과 리뷰를 진행한다. 오케스트레이터 세션은 작업 분배와 머지 시점을 관리하고 코드와 diff는 각 워크트리에서 다룬다.

스크립트는 `${CLAUDE_PLUGIN_ROOT}/bin/`에 있으며 `/orca:dispatch`, `/orca:status`, `/orca:review`, `/orca:handback`, `/orca:land`가 호출한다.

## 준비와 작업 범위

Orca 앱과 `orca` CLI가 필요하다. 레포는 Orca에 등록되어 있어야 하며 경로 대신 등록된 `displayName`을 전달한다. `bin/dispatch.sh --repos`로 확인한다. 프로젝트 루트의 `.orca-flow.json`에서 기준 브랜치, 에이전트 명령과 초기 설정 대상을 읽는다. 파일이 없으면 기본값을 사용한다.

여러 레포의 작업은 우산 레포에서 관리한다. 먼저 우산 레포에도 워크트리를 만든다. 메인 체크아웃에서 작업하면 진행 문서와 계약 초안이 다른 작업과 섞이고, 여러 우산이 만든 서브 워크트리를 구분하기 어렵다.

우산 안에서 dispatch를 실행하면 서브 이름에 `<우산레포>.<우산워크트리>.`가 붙는다.

```
우산:  orca-worktree-flow/orca-check
서브:  orca-worktree-flow-sub-repo/orca-worktree-flow.orca-check.login-api
```

status는 이 접두로 소속을 구분한다. 별도 인덱스는 사용하지 않는다. 사용자가 Orca UI에서 삭제해도 이름이 함께 사라져 목록을 따로 동기화할 필요가 없다. 우산 밖에서는 경고를 출력하고 접두 없이 생성한다. 레포 하나를 혼자 사용하는 경우도 지원하기 위해서다. 우산은 `ORCA_OWNER=<repo>.<name>`으로 지정할 수도 있다.

한 우산 워크트리에서는 기능 하나만 다룬다. 서브 레포가 늘면 컨텍스트가 빨리 차고 요약 과정에서 결정과 근거가 누락될 수 있다. 다음 기능은 새 우산 워크트리에서 시작한다.

구현은 레포마다 워크트리를 만들어 진행하는 것이 기본이고, 메인 체크아웃에서 직접 수정하는 것이 예외다. 메인 체크아웃은 다른 세션이 동시에 사용할 수 있어 미커밋 변경이 섞이고, 오케스트레이터가 diff를 직접 다루면 레포 수만큼 컨텍스트가 소모된다. 워크트리와 리뷰 판정은 세션이 끝나도 남는다.

예외는 두 가지다. 우산 레포 자체의 문서와 진행 기록, 그리고 한두 줄짜리 수정. 워크트리를 만들고 land하는 비용이 수정 비용보다 큰 경우다.

커밋이 생기면 그 워크트리에서 리뷰를 실행한다. 작업 에이전트나 오케스트레이터가 테스트를 직접 돌렸다는 것은 리뷰를 생략할 이유가 아니다.

여러 레포가 함께 커밋돼야 하는 계약 변경은 관련 레포 전부를 함께 dispatch하고 함께 land한다. 하나만 먼저 land하면 계약이 깨진 중간 상태가 기준 브랜치에 남는다.

## 대상 레포와 이름

`dispatch.sh --repos`는 현재 레포와 같은 Orca 프로젝트 그룹의 레포를 `이름<TAB>메인 체크아웃 경로`로 출력한다. `orca repo list`의 `projectGroupId`를 사용하므로 별도 설정이 필요 없다. 그룹이 없으면 필터링하지 않는다. 전체는 `--repos --all`로 조회한다.

```
$ bin/dispatch.sh --repos
orca-worktree-flow           /Users/me/dev/orca-worktree-flow
orca-worktree-flow-sub-repo  /Users/me/dev/orca-worktree-flow-sub-repo
```

각 경로의 `CLAUDE.md`에서 담당 범위를 확인한다. 판단하기 어려우면 작업 설명의 도메인 용어를 후보 레포에서 `grep`으로 검색한다. 후보가 둘 이상 남으면 근거와 함께 사용자에게 선택을 요청한다.

이름은 `<동작>-<대상>` 형식의 케밥케이스로 2~4단어를 사용한다.

```
우산:  orca-worktree-flow/login-refactor              기능 전체
서브:  orca-worktree-flow-sub-repo/orca-worktree-flow.login-refactor.auth-api   해당 레포의 작업
탭:    auth-api
```

서브 이름에는 접두의 기능 이름이나 경로의 레포 이름을 반복하지 않는다. 터미널 탭은 워크트리 안에 있으므로 제목에도 접두 없는 이름만 사용한다. 브랜치 이름은 Orca가 생성하며 Git 사용자명이 앞에 붙을 수 있으므로 추측하지 않는다.

## 작업 순서

```bash
# 0. 우산 워크트리를 만들고 그 안에서 실행한다.
#    Orca UI 또는 orca worktree create --repo "name:<우산레포>" --name <이름> 사용

# 1. 프롬프트 파일 작성
$EDITOR /tmp/shared-trade.md

# 2. 워크트리 생성과 에이전트 실행
${CLAUDE_PLUGIN_ROOT}/bin/dispatch.sh shared migration-platform-trade /tmp/shared-trade.md
#   -> shared/orca-worktree-flow.orca-check.migration-platform-trade

# 3. 진행 상태 확인. 우산 안에서는 소속 워크트리만 표시한다.
${CLAUDE_PLUGIN_ROOT}/bin/status.sh
# 기다릴 때는 아래 명령을 백그라운드로 실행한다.
${CLAUDE_PLUGIN_ROOT}/bin/status.sh --wait

# 4. 커밋 후 해당 워크트리에서 리뷰. 판정은 파일에 저장한다.
${CLAUDE_PLUGIN_ROOT}/bin/review.sh shared orca-worktree-flow.orca-check.migration-platform-trade

# 5. blocking이 있으면 작업 에이전트에게 수정 요청
${CLAUDE_PLUGIN_ROOT}/bin/handback.sh shared orca-worktree-flow.orca-check.migration-platform-trade

# 6. 수정 후 커밋되면 4번 명령으로 재리뷰 요청

# 7. 리뷰 지적 해결 후 기준 브랜치에 머지, push, 워크트리 삭제
${CLAUDE_PLUGIN_ROOT}/bin/land.sh shared orca-worktree-flow.orca-check.migration-platform-trade
```

2번 이후에는 status가 출력한 이름을 그대로 사용한다. 접두가 있으면 다시 붙이지 않는다. 레포가 여럿이면 2번을 각각 병렬로 실행할 수 있다. 디렉터리가 달라 서로의 파일을 수정하지 않는다. 5번과 6번은 리뷰 상한 내에서 반복한다. 리뷰는 각 워크트리에서 진행하고 오케스트레이터는 판정 파일만 읽는다.

## 프롬프트 필수 항목

워크트리에는 해당 레포의 체크아웃만 있어 오케스트레이터 세션의 서브에이전트 정의를 읽을 수 없다. 필요한 역할과 문서를 프롬프트에 명시한다.

| 항목 | 작성 방법과 이유 |
|------|------------------|
| 역할과 담당 범위 | “너는 X 담당이다. 이 워크트리는 Y 레포이며 여기만 수정한다” |
| 역할 정의 파일의 절대 경로 | 기존 정의를 참조하면 담당 범위와 규칙을 반복 작성하지 않고 한 곳에서 관리할 수 있음 |
| 참고 문서의 절대 경로 | 다른 레포의 계약 문서는 워크트리에서 상대 경로로 접근할 수 없음 |
| 결정할 사항 | 계약이 구현자에게 맡긴 사항을 명시해 선택지 나열로 끝나지 않게 함 |
| 제외 범위 | 다른 레포 수정 금지와 이번 단계에서 제외할 작업 |
| 검사 스크립트 | 해당 작업에 필요한 프로젝트 검사 |
| 커밋과 push 범위 | 워크트리 브랜치에 커밋하고 push는 하지 않음. 원격 반영은 사용자 결정 |

아직 머지되지 않은 계약은 해당 브랜치의 워크트리 경로를 지정한다. 메인 체크아웃을 읽으면 이전 이름이나 계약으로 구현할 수 있다. 기본 템플릿은 `${CLAUDE_PLUGIN_ROOT}/templates/prompt-template.md`이며, `.orca-flow.json`의 `promptTemplate`이 있으면 우선 사용한다.

## 카드와 상태 대기

Orca 카드는 코멘트 한 줄과 보드 상태(`todo`, `in-progress`, `in-review`, `completed`)를 표시한다.

| 시점 | 상태 | 카드 문구 |
|------|------|-----------|
| dispatch가 에이전트를 실행한 뒤 | `in-progress` | 에이전트 시작 |
| 에이전트의 작업 단계가 바뀔 때 | 유지 | 에이전트가 작성한 한 줄 |
| review가 리뷰어를 실행한 뒤 | `in-review` | 리뷰 N차 (커밋 M개) |
| 리뷰 판정 파일을 작성한 뒤 | 유지 | 리뷰: blocking N건, 또는 리뷰 통과 |
| handback이 수정을 요청한 뒤 | `in-progress` | 재작업 -- 리뷰 blocking 반영 |
| land가 push를 마친 뒤 | `completed` | 기준 브랜치에 머지, push 완료 |

dispatch와 handback은 카드 갱신 지시를 프롬프트에 추가한다. 에이전트는 “테스트 실행 중”, “FK 문제로 중단”처럼 커밋 수로 알 수 없는 상태를 기록한다. CLI에는 알림 명령이 없으므로 앱 플러그인이 에이전트 중단 이벤트를 받아 카드 문구를 본문 첫 줄로 데스크톱 알림에 표시한다.

대기할 때는 `status.sh --wait`를 백그라운드로 실행한다. 리뷰할 워크트리가 있거나, blocking이 남았거나, 소속 워크트리가 모두 머지할 준비를 마쳤거나, 에이전트가 사용자 입력을 기다리면 표를 한 번 출력한다.

```
대기 종료: 리뷰할 워크트리 2개 (180초 대기)
```

기본 조회 주기는 60초, 상한은 4시간이며 `WAIT_INTERVAL=`, `WAIT_TIMEOUT=`으로 변경한다. 대상을 구분해야 하므로 우산 안에서만 실행한다. 종료 사유와 표를 전달하고 사용자에게 확인받은 뒤 다음 단계를 실행한다.

## 리뷰와 머지 판단

리뷰어를 오케스트레이터의 서브에이전트로 실행하면 여러 레포의 diff가 한 세션에 모여 컨텍스트 한도에 도달할 수 있다. review는 해당 워크트리에 터미널을 추가해 실행한다. 판정은 파일로 저장한다. TUI 출력만 남기면 스피너 화면 갱신으로 스크롤백에서 사라질 수 있다.

서브 워크트리에 커밋이 있고, 미커밋 변경이 없고, 판정이 최신이며, blocking이 0이면 status가 안내한다.

```
소속 워크트리 2개가 모두 머지할 준비가 됐다.
  진행 상황을 기록하고 land할지 사용자에게 묻는다.
```

이때 폴링을 멈추고 워크트리별 작업을 한 줄씩 요약한 뒤 land 여부를 확인한다. 머지 순서는 표에 없으며 계약 문서에 따라 정해야 한다. 여러 레포의 계약이 연결된 변경은 한쪽만 먼저 반영하면 일시적으로 계약이 깨질 수 있다. land는 한 번에 하나만 처리한다. 일부만 준비됐다면 남은 작업의 대기 사유를 안내하고 계속 확인한다.

우산 워크트리는 별도로 확인한다. 리뷰를 거치지 않으므로 판정 파일 대신 미커밋 변경이 없는지, 기준 브랜치보다 앞서 있는지를 본다.

```
이 우산 워크트리에도 main 앞에 커밋 3개가 있다.
  land할지 사용자에게 묻는다. 이 워크트리 안에서 실행하면 삭제하지 않고 머지와 push만 한다.
```

우산에서 직접 작성한 변경도 이 안내에 따라 land 여부를 확인한다.

## 리뷰 횟수와 범위

review는 이전 판정을 `~/orca/reviews/<repo>-<name>.round<N>.md`로 보관한다. 재리뷰가 이전 기록을 덮지 않으며 status에 `3차`처럼 표시된다. 기본 상한은 5차다.

```
리뷰 6차다. 상한 5차를 넘었다.

남은 판정 (~/orca/reviews/shared-orca-worktree-flow.orca-check.trade.md) -- blocking 1건
## blocking
- src/Auth.java:88 토큰 만료 검사가 없다

리뷰를 계속할지 사용자가 판단한다.
  리뷰 계속    FORCE=1 .../bin/review.sh shared ...
  머지 진행    .../bin/land.sh shared ...
```

상한은 `.orca-flow.json`의 `review.maxRounds`, 한 번의 실행은 `MAX_ROUNDS=3` 등으로 조정한다. 상한 전에도 자동으로 계속 반복하지 않는다. 리뷰는 작업 절차이며 최종 확인은 push 때 받는다. 한 작업에서 여섯 차례 리뷰하면서 계속할지 묻지 않은 사례가 있었다. 남은 지적을 구분해 사용자에게 전달한다.

| 지적 종류 | 대응 |
|-----------|------|
| apply 실패, 계약 위반, 데이터 손상 등 실행 문제 | 추가 리뷰로 해결 |
| 서술 정정과 문장 다듬기 | land를 제안하고 잔여 작업으로 기록 |

2차부터는 이전 판정 파일을 읽고 blocking별 해결 여부만 확인한다. 새 발견은 blocking 대신 참고 사항으로 적고 근거 없는 지적을 추가하지 않는다. 리뷰어가 종료돼 새로 실행되더라도 이전 판정을 읽으므로 처음부터 다시 리뷰하지 않는다.

## 터미널 상태와 재시작

status의 터미널 칸은 `1개, 돎`, `1개, 막힘`, `1개, 쉼`, `없음`으로 표시한다. `막힘`은 사용자 입력 대기이므로 해당 탭을 확인한다. 구분하기 어려우면 터미널 tail을 직접 읽는다.

| tail 내용 | 상태 | 대응 |
|-----------|------|------|
| 경과 시간, 도구 호출 수, 토큰 상태줄 | 실행 중 | 카드 갱신을 기다림 |
| `Is this a project you created or one you trust?` | 신뢰 확인 대기 | 빈 텍스트와 `--enter` 전송 |
| `API Error`와 `❯` 프롬프트 | 오류로 중단 | 같은 워크트리에서 재실행 |

처음 만든 워크트리에서는 신뢰 확인을 기다릴 수 있다. 미커밋 변경이 0인 채 오래 쉬는 중이면 먼저 확인한다. `ps -o time`이 몇 초에 머물면 작업 중이 아닐 수 있다.

종료돼도 작업 트리는 남는다. 새 에이전트에는 “앞선 에이전트가 종료됐고 작업은 남아 있다. `git status`와 `git diff`로 확인하고 남은 작업만 마무리하라. 처음부터 다시 작성하지 마라”라고 전달한다.

## 초기 설정과 세션 인계

Git worktree는 추적 파일만 가져온다. `.env` 계열, 개발자별 프로파일, 코드 생성 산출물과 submodule이 없으면 코드 문제가 아닌데도 빌드가 실패할 수 있다. `bin/worktree-setup.sh`가 메인 체크아웃에서 필요한 파일을 복사한다. 대상은 `.orca-flow.json`의 `setup`에서 정한다. dispatch는 초기 설정을 마친 뒤 에이전트를 실행한다.

오케스트레이터 대화가 끝나도 워크트리와 에이전트는 유지된다. 리뷰 판정도 워크스페이스 밖의 `~/orca/reviews/`에 남는다. dispatch, review, handback, land는 우산별 기록 파일에 이력을 추가한다. 카드는 현재 상태만 보관하고 land 후 삭제되므로 완료 이력은 이 파일에서 확인한다. status는 마지막 다섯 줄을 표시한다.

```
~/orca/reviews/.journal/<우산레포>.<우산워크트리>.md

09-10 14:02  dispatch orca-worktree-flow-sub-repo/orca-worktree-flow.orca-check.login-api -- 너는 인증 담당이다
09-10 15:40  review orca-worktree-flow-sub-repo/orca-worktree-flow.orca-check.login-api 1차 (커밋 3개)
09-10 16:11  handback orca-worktree-flow-sub-repo/orca-worktree-flow.orca-check.login-api -- blocking 2건
09-10 17:03  land orca-worktree-flow-sub-repo/orca-worktree-flow.orca-check.login-api -- main 에 머지, push 완료 (커밋 5개, 리뷰 2차)
```

결정 내용과 근거는 자동 기록에 남지 않는다. 컨텍스트를 지우기 전에 다음을 정리한다.

1. status로 커밋과 리뷰 차수를 확인한다. 지적이 해결된 작업은 사용자 확인 후 land하고 나머지는 유지한다.
2. 진행 문서에 변경 내용과 이유, 잔여 작업을 기록한다.
3. 미완료 워크트리별 리뷰 차수와 대기 사유를 남긴다. status는 상태를 보여 주지만 그 이유까지 설명하지는 않는다.

컨텍스트가 차서 요약이 시작되면 새 우산 워크트리에서 다음 기능을 시작한다. 기존 서브 워크트리는 유지한다. 새 우산은 자기 접두가 붙은 작업만 조회하므로 기존 작업과 겹치지 않는다.

세션을 이어받으면 status부터 확인한다. 메인 체크아웃은 origin보다 오래됐을 수 있으므로 `git -C <repo> pull --ff-only`를 실행한다. 워크트리는 origin 기준으로 생성되지만 메인 체크아웃은 자동 갱신되지 않아 다른 세션에서 land한 변경이 없을 수 있다.
