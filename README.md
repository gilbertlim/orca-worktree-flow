# orca-worktree-flow

여러 레포에 걸친 작업을 [Orca](https://github.com/stablyai/orca) 워크트리에 나눠 맡기고, 각 워크트리에서 구현과 리뷰를 진행한 뒤 머지하는 도구다. 오케스트레이터 세션은 작업 분배와 머지 시점을 관리한다. 코드와 diff는 각 워크트리에서 다룬다.

이 저장소는 설치 위치가 다른 두 플러그인을 관리한다.

| 플러그인 | 설치 위치 | 기능 |
|----------|-----------|------|
| Claude Code 플러그인 | Claude Code | 슬래시 명령 5개와 작업 절차를 안내하는 스킬 |
| Orca 앱 플러그인 | Orca 앱 | UI에서 만든 워크트리 초기 설정, 에이전트가 멈췄을 때 데스크톱 알림 |

## 사용 조건과 설치

Orca 앱과 `orca` CLI, `git`, `python3`, `bash`가 필요하다. Python은 표준 라이브러리만 사용한다. 레포는 Orca에 등록되어 있어야 하며, 스크립트에는 경로 대신 등록된 `displayName`을 전달한다. `bin/dispatch.sh --repos`로 등록 목록을 확인할 수 있다.

Claude Code에서는 다음 명령으로 설치한다.

```
/plugin marketplace add gilbertlim/orca-worktree-flow
/plugin install orca@orca-worktree-flow
```

Orca 앱에서는 설정 → Plugins → 마켓플레이스 소스에 Git URL `https://github.com/gilbertlim/orca-worktree-flow`와 ref `main`을 입력한다. 앱은 루트의 `orca-marketplace.json`을 읽고, 그 파일에 지정된 태그(`v1.2.1`)의 플러그인을 설치한다. 소스 ref를 `main`으로 두면 새 버전 배포 시 마켓플레이스 파일에서 태그를 갱신할 수 있다.

로컬 설치는 아래처럼 클론한 뒤 설정 → Plugins → Installed에서 해당 디렉터리를 지정한다.

```bash
git clone git@github.com:gilbertlim/orca-worktree-flow.git ~/orca-worktree-flow
```

사용할 프로젝트의 루트에는 `.orca-flow.json`을 둔다. `templates/orca-flow.json`을 복사해 수정하면 된다. 설정 파일이 없으면 기본값을 사용한다.

## 우산 워크트리와 작업 범위

여러 레포의 작업을 관리하는 레포를 우산 레포라고 부른다. 먼저 우산 레포에 워크트리를 만들고 그 안에서 작업을 분배한다. 메인 체크아웃에서 관리하면 진행 문서와 계약 초안이 다른 작업의 브랜치와 섞이고, 여러 우산 작업이 만든 서브 워크트리도 구분하기 어렵다.

우산 워크트리 안에서 `dispatch.sh`를 실행하면 서브 워크트리 이름 앞에 `<우산레포>.<우산워크트리>.`가 붙는다.

```
우산:  orca-worktree-flow/orca-check
서브:  shared/orca-worktree-flow.orca-check.migration-platform-trade
```

`status.sh`는 이 접두로 현재 우산에 속한 워크트리를 구분한다. 별도 인덱스 파일은 사용하지 않는다. 사용자가 Orca UI에서 워크트리를 삭제해도 이름이 함께 사라지므로 별도로 목록을 동기화할 필요가 없다.

우산 밖에서도 실행할 수 있다. 이 경우 접두 없이 워크트리를 만들고 경고를 출력한다. 레포 하나를 혼자 사용하는 경우를 지원하기 위해서다. 우산을 직접 지정하려면 `ORCA_OWNER=<repo>.<name>`을 사용한다.

한 우산 워크트리에서는 기능 하나만 다룬다. 서브 레포가 많아지면 오케스트레이터의 컨텍스트가 빨리 차고, 요약 과정에서 결정과 근거가 누락될 수 있다. 다음 기능은 새 우산 워크트리에서 시작한다. 기존 서브 워크트리는 유지해도 된다. 새 우산은 자기 접두가 붙은 워크트리만 조회한다.

## 대상 레포와 워크트리 이름

`dispatch.sh --repos`는 현재 레포와 같은 Orca 프로젝트 그룹의 레포를 `이름<TAB>메인 체크아웃 경로`로 출력한다. 그룹은 `orca repo list`의 `projectGroupId`를 사용하므로 별도 설정이 필요 없다. 현재 레포가 그룹에 속하지 않으면 필터링하지 않는다. 그룹 밖까지 보려면 `--repos --all`을 사용한다.

```
$ bin/dispatch.sh --repos
orca-worktree-flow           /Users/me/dev/orca-worktree-flow
orca-worktree-flow-sub-repo  /Users/me/dev/orca-worktree-flow-sub-repo
```

오케스트레이터는 각 경로의 `CLAUDE.md`를 읽고 담당 범위를 확인한다. 판단하기 어려우면 후보 레포에서 작업 설명의 도메인 용어를 `grep`으로 검색한다. 후보가 둘 이상 남으면 근거와 함께 사용자에게 선택을 요청한다.

워크트리 이름은 `<동작>-<대상>` 형식의 케밥케이스로, 2~4단어를 사용한다.

```
우산:  orca-worktree-flow/login-refactor              기능 전체
서브:  orca-worktree-flow-sub-repo/orca-worktree-flow.login-refactor.auth-api   해당 레포의 작업
탭:    auth-api
```

서브 이름에는 접두에 포함된 기능 이름이나 경로에 포함된 레포 이름을 반복하지 않는다. 터미널 탭 제목에도 접두를 제외한 이름만 표시한다. 브랜치 이름은 Orca가 생성하며, Git 사용자명이 앞에 붙을 수 있으므로 직접 추측하지 않는다.

## 작업 순서

우산 워크트리 안에서 슬래시 명령을 실행한다.

```
/orca:dispatch shared migration-platform-trade  플랫폼 거래 컬럼을 추가한다
     -> shared/orca-worktree-flow.orca-check.migration-platform-trade
/orca:status
/orca:review shared orca-worktree-flow.orca-check.migration-platform-trade
/orca:handback shared orca-worktree-flow.orca-check.migration-platform-trade   # blocking이 있으면
/orca:review shared orca-worktree-flow.orca-check.migration-platform-trade     # 재리뷰, 2차로 집계
/orca:land shared orca-worktree-flow.orca-check.migration-platform-trade
```

스크립트를 직접 실행할 수도 있다.

```bash
bin/dispatch.sh shared migration-platform-trade /tmp/prompt.md
bin/status.sh
bin/review.sh shared orca-worktree-flow.orca-check.migration-platform-trade
bin/handback.sh shared orca-worktree-flow.orca-check.migration-platform-trade
bin/land.sh shared orca-worktree-flow.orca-check.migration-platform-trade
```

dispatch 이후에는 `status.sh`가 출력한 이름을 그대로 전달한다. 이미 접두가 있으면 다시 붙이지 않는다. 레포가 여럿이면 dispatch를 각각 병렬로 실행할 수 있다. 디렉터리가 달라 서로의 파일을 수정하지 않는다.

handback과 review는 blocking이 없어질 때까지 반복하되 리뷰 횟수에 상한을 둔다. 리뷰는 해당 워크트리에서 진행하며, 오케스트레이터는 판정 파일(`~/orca/reviews/<repo>-<name>.md`)만 읽는다.

| 스크립트 | 기능 |
|----------|------|
| `dispatch.sh <repo> <name> <prompt-file>` | 워크트리를 만들고 메인 체크아웃에서 gitignore 대상 파일을 복사한 뒤 에이전트 실행 |
| `dispatch.sh --repos [--all]` | 후보 레포 이름과 메인 체크아웃 경로 조회. 워크트리는 생성하지 않음 |
| `review.sh <repo> <name> [prompt-file]` | 해당 워크트리에서 리뷰어 실행. 기존 리뷰어가 있으면 재리뷰 요청 |
| `handback.sh <repo> <name> [review-file]` | 작업 에이전트에 수정 요청. 에이전트가 종료됐으면 새로 실행 |
| `status.sh [repo\|--all\|--wait]` | 커밋 수, 미커밋 수, 리뷰 차수, 터미널 상태(돎/막힘/쉼), 카드 문구 조회. 우산 안에서는 소속 워크트리만 조회. `--wait`는 다음 작업이 필요할 때 출력 |
| `land.sh <repo> <name>` | 리뷰 판정을 보여 주고 `--no-ff` 머지와 push 후 워크트리 삭제 |
| `worktree-setup.sh [path]` | 메인 체크아웃에서 gitignore 대상 파일 복사. dispatch가 자동 실행 |

환경변수로 한 번의 실행을 조정할 수 있다. `AGENT_CMD`, `BASE_BRANCH`, `NO_SETUP=1`, `KEEP=1`, `NO_PUSH=1`, `FORCE=1`, `NOTE`(handback 메모), `NEW=1`(새 리뷰어 실행), `MAX_ROUNDS`(리뷰 상한), `ORCA_OWNER`(우산 지정), `WAIT_INTERVAL`과 `WAIT_TIMEOUT`(대기 주기와 상한)을 지원한다.

## 상태 확인과 대기

`status.sh --wait`를 백그라운드로 실행하면 반복 조회를 직접 할 필요가 없다. 리뷰할 워크트리가 있거나, blocking이 남았거나, 소속 워크트리가 모두 머지할 준비를 마쳤거나, 에이전트가 사용자 입력을 기다리면 상태 표를 한 번 출력한다.

```
대기 종료: 리뷰할 워크트리 2개 (180초 대기)
```

기본 조회 주기는 60초, 대기 상한은 4시간이다. `WAIT_INTERVAL`과 `WAIT_TIMEOUT`으로 바꾼다. 대상을 구분해야 하므로 우산 워크트리 안에서만 실행된다. 대기가 끝나면 이유와 표를 전달하고, 다음 단계를 실행하기 전에 사용자에게 확인받는다.

소속 서브 워크트리에 커밋이 있고, 미커밋 변경이 없고, 판정이 최신이며, blocking이 0이면 다음 안내가 나온다.

```
소속 워크트리 2개가 모두 머지할 준비가 됐다.
  진행 상황을 기록하고 land할지 사용자에게 묻는다.
```

우산 워크트리는 이 집계에서 제외한다. 오케스트레이터의 진행 문서 등에 미커밋 변경이 남아 전체 완료 조건을 충족하지 못할 수 있기 때문이다. 대신 미커밋 변경이 없고 기준 브랜치보다 앞서 있으면 별도로 안내한다. 우산은 리뷰를 거치지 않으므로 판정 파일은 확인하지 않는다.

```
이 우산 워크트리에도 main 앞에 커밋 3개가 있다.
  land할지 사용자에게 묻는다. 이 워크트리 안에서 실행하면 삭제하지 않고 머지와 push만 한다.
```

`main`은 고정 문구가 아니라 해당 레포의 기준 브랜치다. 이 안내가 나오면 폴링을 멈추고 각 워크트리의 작업을 한 줄씩 요약한 뒤 land 여부를 확인한다. 일부만 준비됐다면(`3개 중 2개가 머지할 준비가 됐다`) 남은 작업의 대기 사유를 확인한다. 여러 레포의 계약이 연결된 경우 머지 순서에 따라 일시적으로 계약이 깨질 수 있으므로 표만 보고 순서를 정하지 않는다.

## 작업 기록

카드는 현재 상태 한 줄만 보관하고 워크트리와 함께 삭제된다. dispatch, review, handback, land는 이력을 우산별 파일에 추가한다.

```
~/orca/reviews/.journal/orca-worktree-flow.orca-check.md

09-10 14:02  dispatch shared/orca-worktree-flow.orca-check.trade -- 너는 거래 컬럼 담당이다
09-10 15:40  review shared/orca-worktree-flow.orca-check.trade 1차 (커밋 3개)
09-10 16:11  handback shared/orca-worktree-flow.orca-check.trade -- blocking 2건
09-10 17:03  land shared/orca-worktree-flow.orca-check.trade -- main 에 머지, push 완료 (커밋 5개, 리뷰 2차)
```

`status.sh`는 표 아래에 마지막 다섯 줄을 표시한다. 세션을 이어받을 때 먼저 읽는다. 자동 기록에는 결정 근거까지 남지 않으므로 별도 진행 문서에 작성한다.

## 설정

프로젝트별 설정은 루트의 `.orca-flow.json`에서 읽는다. `${projectRoot}`는 설정 파일이 있는 디렉터리로 치환된다. 개발자별 절대 경로를 넣지 않아도 되어 설정 파일을 공유할 수 있다.

```json
{
  "baseBranch": "main",
  "agentCmd": "claude --permission-mode auto",
  "workspaces": "~/orca/workspaces",
  "reviews": "~/orca/reviews",
  "setup": {
    "enabled": true,
    "script": "scripts/my-worktree-setup.sh",
    "files": ["*-local-mine.yaml", ".env", ".env.local", ".env.*.local"],
    "dirs": ["*/src/generated", "*/app/types/generated"],
    "prune": [".git", "node_modules", "build", ".venv", "dist"],
    "repoExtras": { "terraform": ["secrets/dev/values"] },
    "deny": ["my-umbrella-repo"]
  },
  "review": {
    "context": "계약 정본은 ${projectRoot}/repos/architecture/specs/ 아래에 있다.",
    "maxRounds": 5
  },
  "promptTemplate": "orca/prompt-template.md"
}
```

| 키 | 기본값 | 설명 |
|----|--------|------|
| `baseBranch` | `main` | 워크트리 생성 기준이자 land 대상. 레포별 메인 체크아웃에서 읽음 |
| `agentCmd` | `claude --permission-mode auto` | 에이전트 실행 명령. Codex를 사용하면 변경 |
| `workspaces` | `~/orca/workspaces` | 워크트리 저장 경로 |
| `reviews` | `~/orca/reviews` | 리뷰 판정, 터미널 핸들, claim 저장 경로 |
| `setup.enabled` | `true` | `false`이면 dispatch와 앱 플러그인 모두 초기 설정 생략 |
| `setup.script` | 플러그인의 `bin/worktree-setup.sh` | 프로젝트 전용 스크립트. 프로젝트 루트 기준 상대 경로 |
| `setup.files` | `.env` 계열과 `*-local-mine.yaml` | 복사할 파일 패턴. 슬래시가 있으면 `-path`, 없으면 `-name` |
| `setup.dirs` | 없음 | 통째로 복사할 디렉터리. 재생성 비용이 큰 코드 생성 산출물 등 |
| `setup.prune` | 빌드 산출물과 의존성 트리 | 검색에서 제외할 디렉터리 |
| `setup.repoExtras` | 없음 | 패턴으로 지정하기 어려운 레포별 추가 경로. 키는 레포 디렉터리 이름 |
| `setup.deny` | 없음 | 워크트리로 분리하지 않을 레포 |
| `review.context` | 없음 | 기본 리뷰 프롬프트에 추가할 내용. 여러 줄이나 리뷰 기준 파일의 절대 경로 사용 가능 |
| `review.maxRounds` | `5` | 리뷰 상한. 초과하면 남은 blocking을 출력하고 중단. `MAX_ROUNDS=`로 일회 변경, `FORCE=1`로 초과 실행 |
| `promptTemplate` | 플러그인의 `templates/prompt-template.md` | dispatch 프롬프트 템플릿 |

설정 파일은 기준 디렉터리에서 상위로 올라가며 찾는다. 직접 실행할 때는 `$PWD`, 워크트리 초기 설정에서는 메인 체크아웃이 기준이다. 워크트리는 프로젝트 트리 밖에 있으므로 그 경로에서 검색하면 프로젝트 설정을 찾지 못한다. 메인 체크아웃을 기준으로 검색하면 단일 레포 프로젝트와 우산 아래 여러 레포가 있는 프로젝트를 모두 지원할 수 있다.

기준 브랜치는 `lib.sh`의 `base_branch_for`가 레포별 메인 체크아웃에서 읽는다. 모든 레포에 같은 브랜치를 적용하면 `main`을 쓰지 않는 레포의 커밋 수가 `?`로 나오고 커밋 목록이 비게 된다. dispatch, review, status, land가 같은 함수를 사용해 조회 기준과 머지 대상을 맞춘다. 우선순위는 환경변수 `BASE_BRANCH` > 해당 레포 설정 > 실행 위치에서 정한 값이다.

앱 플러그인에는 허용된 환경변수만 전달되므로 `ORCA_REVIEWS` 같은 셸 설정을 읽을 수 없다. 워크스페이스나 리뷰 경로를 바꿨다면 호스트 설정 `~/.orca-flow.json`에도 적는다. `pathPrepend`로 자식 프로세스의 PATH에 경로를 추가할 수 있다.

## 워크트리 초기 설정

Git worktree는 추적 파일만 가져온다. `.env` 계열, 개발자별 프로파일, 코드 생성 산출물과 submodule이 없으면 코드 문제가 아닌데도 빌드가 실패할 수 있다. `worktree-setup.sh`는 같은 레포의 메인 체크아웃에서 필요한 파일을 복사한다. 원본은 `git worktree list`의 첫 항목으로 찾는다.

`orca.yaml`의 setup 훅은 대상 레포에 커밋된 파일만 사용한다. 우산 레포에 두어도 형제 레포에는 적용되지 않으며, 추적되지 않는 파일은 새 워크트리에 없으므로 훅이 실행되지 않는다(2026-07-28 확인). 각 레포에 커밋할 수도 있지만, submodule이나 다른 담당자의 레포에 도구 설정을 추가하기 어려울 수 있다. 앱 플러그인은 호스트에 한 번 설치하면 레포를 수정하지 않고 초기 설정을 실행한다.

- 이미 있는 파일은 건너뛴다. 워크트리에서 변경한 설정을 덮어쓰지 않기 위해서다.
- 추적 파일은 `--force`를 줘도 덮어쓰지 않는다. 커밋된 `.env.local` 등을 덮으면 의도하지 않은 수정이 다음 커밋에 포함될 수 있다.
- 복사 방향은 메인 체크아웃에서 워크트리로 한정한다. 커밋되지 않아 리뷰할 수 없는 파일을 양방향으로 복사하면 어느 설정이 기준인지 판단하기 어렵다.
- `.claude/settings.local.json`은 기본으로 복사하지 않는다. 승인한 권한이 다른 작업에 적용되는 것을 막기 위해서다. 필요하면 `--with-agent-settings`를 지정한다.
- `node_modules`와 `.venv`는 심볼릭 링크와 절대 경로를 포함하므로 복사하지 않고 의존성을 설치한다.

dispatch는 초기 설정을 마친 뒤 에이전트를 실행한다. 앱 플러그인과 중복 실행되지 않도록 워크트리 생성 전에 `<reviews>/.claims/<repo>-<name>` 표식을 만든다. 생성 이벤트를 받은 플러그인은 이 표식을 보고 실행을 생략한다. dispatch가 종료되면 claim을 지우고, 이후 도착한 이벤트는 `worktree-setup.done` 표식으로 완료 여부를 확인한다.

직접 실행한 스크립트와 겹치는 경우는 워크트리의 Git 디렉터리에 둔 잠금으로 처리한다. 잠금을 얻지 못한 실행은 코드 75로 종료한다. dispatch는 이를 실패로 취급하지 않고 잠금이 풀릴 때까지 기다린 뒤 에이전트를 실행한다.

## Orca 카드와 알림

카드는 한 줄 코멘트와 보드 상태(`todo`, `in-progress`, `in-review`, `completed`)를 표시한다. 스크립트와 에이전트가 작업 단계에 맞춰 갱신한다.

| 시점 | 상태 | 카드 문구 |
|------|------|-----------|
| dispatch가 에이전트를 실행한 뒤 | `in-progress` | 에이전트 시작 |
| 작업 에이전트의 상태가 바뀔 때 | 유지 | 에이전트가 작성한 한 줄 |
| review가 리뷰어를 실행한 뒤 | `in-review` | 리뷰 N차 (커밋 M개) |
| 리뷰어가 판정 파일을 작성한 뒤 | 유지 | 리뷰: blocking N건, 또는 리뷰 통과 |
| handback이 수정을 요청한 뒤 | `in-progress` | 재작업 -- 리뷰 blocking 반영 |
| land가 push를 마친 뒤 | `completed` | 머지, push 완료 |

에이전트는 “테스트 실행 중”, “FK 문제로 중단”처럼 커밋 수로 알 수 없는 상태를 작성한다. dispatch와 handback이 이 지시를 프롬프트에 추가한다. 이전에는 Git을 2초마다 조회하는 별도 워처를 사용했지만, 커밋 수와 미커밋 수만으로는 이런 상태를 알 수 없었다.

카드 변경 자체는 알림을 보내지 않고 CLI에도 알림 명령이 없다. 앱 플러그인은 훅의 상태 변경 이벤트를 받아 에이전트가 `done`, `waiting`, `blocked`가 되면 데스크톱 알림을 표시한다. 카드 문구가 본문 첫 줄에 들어간다. 코멘트에 빈 문자열을 주면 CLI가 무시하므로 지울 수 없으며, 다음 단계에서 새 문구로 덮어쓴다.

## 리뷰와 재작업

리뷰어를 오케스트레이터의 서브에이전트로 실행하면 모든 레포의 diff가 한 세션에 모여 컨텍스트 한도에 도달할 수 있다. `review.sh`는 해당 워크트리에 터미널을 추가하고 리뷰를 실행한다.

판정은 `<reviews>/<repo>-<name>.md`에 저장한다. 이 지시는 스크립트가 프롬프트에 추가한다. 워크트리 밖에 저장하므로 다음 커밋에 포함되지 않는다. TUI 출력만으로는 기록을 보존할 수 없다. 리뷰어 4개의 결과가 스피너 화면 갱신으로 스크롤백에서 사라져, `orca terminal read`로 2000줄을 읽어도 `Sautéed for 5m 39s`만 남은 사례가 있었다. 당시에는 실행 중인 에이전트에 파일 저장을 요청해 복구했지만, 세션이 끝났다면 각각 5분 걸린 리뷰 결과를 잃었을 것이다.

`handback.sh`는 기존 작업 에이전트에 판정 파일 경로를 전달한다. 구현 맥락을 유지하므로 새 에이전트보다 맥락을 다시 파악하는 비용과 오해를 줄일 수 있다. 요청에는 “리뷰어가 틀렸다고 판단되면 수정하지 말고 근거를 제시하라”는 지시가 포함된다.

터미널은 탭 제목 대신 `<reviews>/.handles/`에 저장한 핸들로 찾는다. 에이전트가 `REVIEW caller-identity` 같은 제목을 `리뷰: API 게이트웨이 거래 경로 변경`처럼 바꿀 수 있어 제목으로 역할을 식별하기 어렵기 때문이다.

작업 에이전트가 수정 후 종료하면서 터미널과 리뷰어가 함께 종료되는 경우가 있다. 새 리뷰어도 이전 지적을 확인할 수 있도록 `review.sh`는 기존 판정을 `.round<N>.md`로 보관하고 2차부터 그 경로를 전달한다. 과거에는 사용자가 재리뷰 전에 `cp`로 보관했지만 지금은 자동 처리한다. 보관 파일과 현재 판정으로 차수를 집계하며, `status.sh`에 `3차`처럼 표시한다. 판정 파일은 워크트리를 삭제해도 남는다.

2차부터는 이전 blocking이 해결됐는지 항목별로 확인하고, 새 발견은 blocking 대신 참고 사항으로 적도록 지시한다. 근거 없는 지적을 추가하지 않도록 범위를 제한한다. 네 차례 리뷰한 작업에서 이 지시를 추가한 4차부터 판정이 짧아진 사례가 있었다.

기본 상한은 5차다. 넘으면 남은 blocking을 출력하고 중단한다.

```
리뷰 6차다. 상한 5차를 넘었다.

남은 판정 (~/orca/reviews/shared-orca-worktree-flow.orca-check.trade.md) -- blocking 1건
## blocking
- src/Auth.java:88 토큰 만료 검사가 없다

리뷰를 계속할지 사용자가 판단한다.
  리뷰 계속    FORCE=1 .../bin/review.sh shared ...
  머지 진행    .../bin/land.sh shared ...
```

상한 전이라도 자동으로 반복하지 않는다. 두세 차례를 넘기면 계속 리뷰할지 land할지 사용자에게 묻는다. 리뷰는 작업 절차이고 최종 확인은 push 시점에 받는다. 한 작업에서 두 레포를 각각 6차와 3차까지 리뷰하면서 계속할지 묻지 않은 사례가 있었다. `kms:CreateGrant` 누락처럼 plan은 통과하지만 apply에서 키 생성 후 클러스터 갱신에 실패하는 실제 문제도 있었으므로, 남은 지적을 구분해서 전달해야 한다.

| 남은 지적 | 대응 |
|-----------|------|
| apply 실패, 계약 위반, 데이터 손상 등 실행 문제 | 추가 리뷰로 해결 |
| 서술 정정과 문장 다듬기 | land를 제안하고 잔여 작업으로 기록 |

수정하지 않은 항목은 프로젝트의 잔여 작업 문서에 남긴다. 판정 파일만 보관하면 후속 작업에서 놓칠 수 있다.

## 머지와 정리

`land.sh`는 한 번에 워크트리 하나를 처리하며 머지 순서를 정하지 않는다. API 계약의 양쪽 구현, 공유 마이그레이션과 이를 읽는 서비스, 템플릿 copy-sync는 한쪽만 머지하면 일시적으로 계약이 깨질 수 있다. 순서는 계약 문서에 따라 정한다.

예를 들어 helm의 NetworkPolicy를 먼저 적용하고 서비스 인터페이스, 질의, 공유 테이블 변경을 함께 반영한 작업이 있었다. 질의만 먼저 머지하면 entitlement 게이트의 fail-closed 동작 때문에 소비자 실행이 모두 500 오류로 실패하는 경우였다.

land는 머지 후 push까지 실행하고, 훅의 사용자 확인 프롬프트에서 최종 확인을 받는다. 과거에는 두 레포를 land하고도 원격에 반영되지 않은 사실을 뒤늦게 발견했다. push가 실패하면 복구할 수 있도록 워크트리를 남긴다. 의도적으로 로컬에만 머지하려면 `NO_PUSH=1`을 사용한다. `KEEP=1`은 push까지 진행하고 워크트리를 남긴다.

이미 머지된 워크트리에도 land를 다시 실행할 수 있다. 머지를 건너뛰고 push와 정리만 진행한다. 현재 워크트리 안에서 실행하면 셸의 작업 디렉터리가 사라지지 않도록 워크트리를 유지한다.

`orca worktree rm`을 직접 실행하기 전에는 머지 여부와 `status.sh`의 커밋 수를 확인한다. 머지하지 않은 작업을 삭제하면 커밋이 해당 브랜치에만 남을 수 있다.

## 문제 확인

카드의 “쉬는 중”만으로는 실행 중인지, 입력 대기인지, 종료됐는지 구분하기 어렵다. `status.sh`는 터미널을 `돎`, `막힘`, `쉼`, `없음`으로 표시한다. `orca terminal list`의 preview에서 실행 표시를 확인하고, 쉬는 것으로 보일 때만 tail을 읽어 입력 대기를 판별한다. 모호하면 직접 확인한다.

```bash
source bin/lib.sh
H=$(load_handle ai-runtime caller-identity work)
orca terminal read --terminal "$H" --json
```

| tail 내용 | 상태와 대응 |
|-----------|-------------|
| Claude Code 상태줄의 경과 시간, 도구 호출 수, 토큰 | 실행 중. 카드 갱신이 늦을 수 있음 |
| `Is this a project you created or one you trust?` | 신뢰 확인 대기. Enter를 보내면 시작 |
| `API Error`와 `❯` 프롬프트 | 오류로 중단. 작업 트리를 확인하고 같은 워크트리에서 에이전트 재실행 |

처음 만든 워크트리에서는 새 디렉터리의 신뢰 확인을 기다릴 수 있다. 미커밋 변경이 0인 채 오래 쉬는 중이면 먼저 확인한다.

```bash
orca terminal send --terminal "$H" --text "" --enter --json
```

에이전트가 종료돼도 작업 파일은 남는다. 1시간 32분 뒤 `ENOTFOUND`로 종료됐지만 미커밋 파일 9개, 135줄이 유지된 사례가 있다. 새 에이전트에는 “앞선 에이전트가 종료됐고 작업은 남아 있다. `git status`와 `git diff`로 확인하고 남은 작업만 마무리하라. 처음부터 다시 작성하지 마라”라고 전달한다.

메인 체크아웃은 origin보다 오래됐을 수 있다. 워크트리는 origin 기준으로 생성되지만 메인 체크아웃은 자동 갱신되지 않는다. 메인에 계약 문서가 없어 미작성으로 판단했으나 origin/main에는 PR 2개가 머지돼 있던 사례가 있다. 시작 전에 `git -C <repo> pull --ff-only`를 실행한다.

`--agent claude`에는 플래그를 전달할 수 없어 dispatch는 워크트리 생성 후 `orca terminal create --command`로 에이전트를 실행한다. auto 모드도 이 명령에 지정한다.

`.claude/`를 커밋한 레포는 첫 실행에서 신뢰 확인을 기다릴 수 있다. 대화가 시작되기 전이라 `~/.claude/projects/`에 디렉터리도 생기지 않고, 터미널 출력도 없을 수 있다. 95분 동안 프로세스가 유지됐지만 CPU 사용 시간은 23초였던 사례가 있다. `ps -o time`이 몇 초에 머무는지 확인한다. 신뢰 설정은 `~/.claude.json`의 `projects[<메인 체크아웃 경로>].hasTrustDialogAccepted`를 `true`로 지정한다. Claude가 Git common dir 기준으로 경로를 처리하므로 한 번의 신뢰 설정이 해당 레포의 모든 워크트리에 적용된다.

`orca terminal create --json`의 핸들은 `result.terminal.handle`에 있다. `lib.sh`가 `result.handle`만 읽던 때에는 핸들을 저장하지 못해 다음 handback에서 에이전트를 새로 실행했다. 실행 후 `<reviews>/.handles/`에 파일이 생겼는지 확인한다.

같은 계약을 여러 브랜치에서 작성하면 같은 개념에 다른 이름을 붙일 수 있다. 이를 통일하기 위한 워크트리를 추가로 만든 사례도 있다. 문서 하나를 한 커밋으로 반영해야 한다면 작업을 나누지 않는 편이 낫다.

리뷰 칸의 `낡음`은 판정 파일보다 최신 커밋이 있다는 뜻이다. handback으로 수정한 뒤 재리뷰하지 않은 경우 이렇게 표시된다. 이 상태에서 land하면 수정 전 코드의 판정으로 머지하게 된다.

## 앱 실행 환경과 설치 오류

Finder나 Dock에서 실행한 Orca의 PATH는 launchd 기본값(`/usr/bin:/bin:/usr/sbin:/sbin`)이다. `git`, `bash`와 달리 `orca`, `pnpm`, `uv`는 여기에 없을 수 있다. 의존성 설치를 `not found, skipped`로 건너뛰고 코드 0으로 종료하면 `node_modules` 없이 완료 알림이 뜰 수 있다. 플러그인은 `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` 등 일반적인 경로를 자식 PATH에 추가한다. 다른 경로는 `~/.orca-flow.json`의 `pathPrepend`에 지정한다. 문제 발생 시 플러그인 로그의 `자식 PATH`와 `도구:`를 확인한다.

앱 플러그인 워커에는 `PATH`, `HOME`, `LANG`, `TMPDIR` 등 허용된 환경변수만 전달된다. 셸에서 export한 `AWS_PROFILE` 등에 의존하는 스크립트는 앱에서 다르게 실행될 수 있다.

이벤트 핸들러는 5분 뒤 종료되고 워커는 5분간 유휴 상태면 정리된다. 자식 프로세스는 detached로 실행해 `pnpm install` 등이 계속 진행되지만 완료 알림을 놓칠 수 있다. 초기 설정이 4분을 넘기면 백그라운드에서 계속 실행 중이라는 알림을 표시한다.

플러그인 `id`의 `orca-` 접두는 stablyai 전용이다. 다른 플러그인이 사용하면 `isReservedPluginIdentity`가 설치를 거부한다(`shared/plugins/plugin-marketplace.js`의 `OFFICIAL_PLUGIN_ID_PREFIX`). 이 저장소의 id가 `worktree-flow`인 이유다. 처음 `orca-flow`로 지정했을 때는 “플러그인 설치에 실패했습니다. 소스를 확인하고 다시 시도하세요”만 표시됐다.

이 설치 실패는 `main.trace.ndjson`에 기록되지 않으며, `plugins-data/audit.log`는 실행 중인 플러그인의 호출만 기록한다. 당시 매니페스트 스키마, 디렉터리 구성, 부모 경로, `.git` 유무, 하위 디렉터리와 실행 권한을 확인했지만 원인이 아니었다. 설치되는 매니페스트를 기준으로 `id`, `publisher`, `name`, `description`을 하나씩 바꾼 디렉터리 4개를 비교해 `id`가 원인임을 확인했다. `publisher` 값은 영향을 주지 않았다.

소스의 제어문자도 같은 설치 오류를 일으킬 수 있다. ANSI 정규식에는 실제 ESC 바이트 대신 `\u001b`를 적는다. 실제 바이트가 있어도 JavaScript 문법 검사와 `node --check`를 통과하고 `cat -A`로 구분하기 어려울 수 있다. 다음 명령으로 확인한다.

```bash
python3 -c "
b=open('main.mjs','rb').read()
print([hex(c) for c in sorted(set(c for c in b if c<9 or 13<c<32))] or '없음')"
```

플러그인 API는 별도 문서 대신 [plugin-host-api.ts](https://github.com/stablyai/orca/blob/main/src/shared/plugins/plugin-host-api.ts), [plugin-manifest.ts](https://github.com/stablyai/orca/blob/main/src/shared/plugins/plugin-manifest.ts), [hello-orca 예제](https://github.com/stablyai/orca/tree/main/examples/plugins/hello-orca)를 참고한다. 소스 주석은 `pluginApi` 1 확정 전 호환성을 보장하지 않는다고 명시한다. Orca 업데이트 후 실행되지 않으면 매니페스트 스키마부터 확인한다.

## 파일 구성

```
.claude-plugin/        Claude Code 매니페스트와 마켓플레이스
orca-plugin.json      Orca 앱 매니페스트
orca-marketplace.json Orca 앱 마켓플레이스 소스, 설치 태그 지정
main.mjs              Orca 앱 워커
bin/                  실행 스크립트, 설정 처리(config.sh), Orca 공통 함수(lib.sh)
commands/             슬래시 명령 5개
skills/orca-flow/      작업 절차 스킬
templates/            설정과 프롬프트 템플릿
```

이 저장소 자체가 Claude Code 마켓플레이스다. `config.sh`는 `worktree-setup.sh`가 단독 실행될 수 있도록 `lib.sh`에서 분리했다. 앱 플러그인은 초기 설정 스크립트를 직접 실행하며, 이때 PATH에 `orca`가 없을 수 있다. `lib.sh`는 시작할 때 CLI를 요구하므로 함께 로드하면 초기 설정도 실패한다.
