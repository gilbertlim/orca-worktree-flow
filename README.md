# orca-plugin

한 작업이 레포 여럿에 걸릴 때, 각 레포의 몫을 [Orca](https://github.com/stablyai/orca) 워크트리에 하나씩 떼어 에이전트를 붙이고 리뷰와 머지까지 그 워크트리 안에서 끝내는 절차다. <br>
오케스트레이터 세션은 작업 분배와 머지 시점만 관리하고, 코드와 diff는 각 워크트리 안에서 다룬다.

이 레포에서 두 플러그인을 함께 관리한다. 설치 위치는 각각 다르다.

| 무엇 | 어디에 붙나 | 무엇을 하나 |
|------|-------------|-------------|
| Claude Code 플러그인 | Claude Code | 슬래시 커맨드 다섯과 절차를 가르치는 스킬 |
| Orca 앱 플러그인 | Orca 앱 | UI에서 만든 워크트리 셋업, 에이전트가 멈추면 데스크톱 알림 |

## 전제

- **Orca 앱과 `orca` CLI.** 스크립트 실행에 필요하다.
- **레포가 Orca에 등록돼 있어야 한다.** 스크립트는 레포를 경로가 아니라 등록된 displayName으로 받는다. `bin/dispatch.sh --repos`로 확인한다.
- `git`, `python3`, `bash`. python3는 표준 라이브러리만 쓴다.

## 설치

**Claude Code 쪽.**

```
/plugin marketplace add gilbertlim/orca-plugin
/plugin install orca@orca-plugin
```

**Orca 앱 쪽.** 설정 → Plugins → 마켓플레이스 소스에서 Git URL로 `https://github.com/gilbertlim/orca-plugin`, ref로 `main`을 준다. 소스가 읽는 것은 루트의 `orca-marketplace.json`이고, 그 안에서 플러그인 자체는 태그(`v1.2.0`)에 고정돼 있다. `main`을 소스 ref로 두는 것은 새 판을 낼 때 마켓플레이스 파일만 고치면 되게 하려는 것이다.

로컬 경로로 붙이려면 클론한 뒤 설정 → Plugins → Installed에서 그 디렉터리를 지정한다.

```bash
git clone git@github.com:gilbertlim/orca-plugin.git ~/orca-plugin
```

**프로젝트 쪽.** 쓸 프로젝트의 루트에 `.orca-flow.json`을 둔다. `templates/orca-flow.json`을 복사해 고치면 되고, 없으면 기본값을 사용한다.

## 우산 레포에서 시작한다

여러 레포에 걸친 작업은 우산 레포에서 관리하고 서브 레포에 나눠 맡긴다. 그때 **우산 레포에도 먼저 워크트리를 딴다.** 오케스트레이터가 메인 체크아웃에서 작업하면 진행 문서와 계약 초안이 다른 작업의 브랜치와 섞인다. 우산 작업이 둘 이상이면 서브 워크트리의 소유도 구분하기 어렵다.

우산 워크트리 안에서 `dispatch.sh`를 부르면 만들어지는 이름 앞에 `<우산레포>.<우산워크트리>.` 가 붙는다.

```
우산:  orca-plugin/orca-check
서브:  shared/orca-plugin.orca-check.migration-platform-trade
```

접두는 워크트리의 소유를 나타낸다. `status.sh`가 그것으로 남의 워크트리를 걸러낸다. 별도 인덱스 파일을 안 두는 이유도 여기 있다 — 사람이 Orca UI에서 워크트리를 지우면 인덱스는 곧 실제와 어긋나지만, 이름은 워크트리와 같이 사라진다.

우산 밖에서 불러도 돌아간다. 접두 없이 만들고 경고 한 줄이 나가며, 손으로 지정하려면 `ORCA_OWNER=<repo>.<name>`이다. 레포 하나를 혼자 쓰는 쓰임을 안 깨려고 막지 않았다.

접두는 워크트리 이름에만 붙고 터미널 탭 제목에는 안 붙는다. 탭이 이미 그 워크트리 안에 앉으므로 제목에는 사람이 준 이름(`greet`)만 남는다.

**한 우산 워크트리에서는 기능 하나만 다룬다.** 서브 레포가 많을수록 오케스트레이터의 컨텍스트가 빨리 차고, 요약 과정에서 결정과 근거가 누락된다. 두 번째 기능은 우산 레포에 워크트리를 새로 따서 거기서 시작한다. 이미 떠 있는 서브 워크트리는 그대로 두면 되고, 새 우산은 제 접두가 붙은 것만 보므로 겹쳐 만질 일이 없다.

## 어느 레포에 시킬지, 이름을 무엇으로 할지

`dispatch.sh --repos`가 **지금 서 있는 레포와 같은 Orca 프로젝트 그룹**의 레포만 `이름<TAB>메인 체크아웃 경로`로 찍는다. 한 머신에 무관한 프로젝트가 여럿 등록돼 있어도 후보가 그 프로젝트 안으로 좁혀진다. 그룹은 Orca가 이미 들고 있는 값(`orca repo list`의 `projectGroupId`)이라 따로 적을 것이 없고, 그룹에 안 넣은 레포에서 부르면 거르지 않는다.

```
$ bin/dispatch.sh --repos
orca-plugin           /Users/me/dev/orca-plugin
orca-plugin-sub-repo  /Users/me/dev/orca-plugin-sub-repo
```

경로를 함께 주는 것은 오케스트레이터가 각 레포의 `CLAUDE.md`를 읽고 담당 경계를 봐야 하기 때문이다. 그것으로 안 갈리면 작업 설명의 도메인 용어를 후보 레포에서 `grep`한다. 그래도 둘 이상 남으면 근거와 함께 사람에게 고르게 한다. 그룹 밖까지 봐야 하면 `--repos --all`이다.

**워크트리 이름은 `<동작>-<대상>` 케밥케이스 2~4단어다.**

```
우산:  orca-plugin/login-refactor              기능 전체
서브:  orca-plugin-sub-repo/orca-plugin.login-refactor.auth-api   그 레포가 맡는 몫
탭:    auth-api
```

서브 이름에 기능 이름을 다시 넣지 않는다. 접두에 이미 들어 있다. 레포 이름도 안 넣는다. 경로 앞칸이 이미 레포다. 브랜치 이름은 짓지 않는다 — Orca가 워크트리 이름에서 만들고 git 사용자명을 앞에 붙이는 일이 있다.

## 기다릴 때는 status를 반복해 치지 않는다

`status.sh --wait`를 백그라운드로 걸어 두면 사람이 부를 마디가 설 때까지 자다가 그때 깨어나 표를 한 번 찍는다. 깨어나는 조건은 넷이다 — 리뷰를 돌릴 워크트리가 섰다, 판정에 blocking이 남았다, 내가 낸 것이 전부 닫혔다, 에이전트가 사람 손에 막혔다.

```
▶ 깨어났다: 리뷰를 돌릴 워크트리 2개 (180초 기다림)
```

기본 주기는 60초, 상한은 4시간이고 `WAIT_INTERVAL=`, `WAIT_TIMEOUT=`으로 바꾼다. 우산 워크트리 안에서만 돈다 — 밖에서는 누구 것을 기다릴지가 안 정해진다. <br>
깨어난 뒤 다음 단계를 혼자 부르지는 않는다. 무엇 때문에 깨어났는지를 전하고 사람에게 확인받는다.

## 한 사이클

우산 워크트리 안에서 슬래시 커맨드로 하면 이렇다.

```
/orca:dispatch shared migration-platform-trade  플랫폼 거래 컬럼을 판다
     -> shared/orca-plugin.orca-check.migration-platform-trade
/orca:status
/orca:review shared orca-plugin.orca-check.migration-platform-trade
/orca:handback shared orca-plugin.orca-check.migration-platform-trade   # blocking이 있으면
/orca:review shared orca-plugin.orca-check.migration-platform-trade     # 재리뷰, 2차로 센다
/orca:land shared orca-plugin.orca-check.migration-platform-trade
```

스크립트를 직접 부르면 이렇다.

```bash
bin/dispatch.sh shared migration-platform-trade /tmp/prompt.md
bin/status.sh
bin/review.sh shared orca-plugin.orca-check.migration-platform-trade
bin/handback.sh shared orca-plugin.orca-check.migration-platform-trade
bin/land.sh shared orca-plugin.orca-check.migration-platform-trade
```

dispatch 뒤로는 `status.sh`가 찍어 준 이름을 그대로 복사해 넘긴다. 이미 접두가 붙은 이름은 다시 안 붙는다.

레포가 넷이면 dispatch를 넷 나란히 부른다. 디렉터리가 겹치지 않아 서로를 안 건드린다. <br>
handback과 review는 blocking이 없어질 때까지 돌되 상한이 있다. 도는 자리는 언제나 그 워크트리 안이고, 오케스트레이터는 판정 파일(`~/orca/reviews/<repo>-<name>.md`)만 읽는다.

## 스크립트

| 스크립트 | 하는 일 |
|----------|---------|
| `dispatch.sh <repo> <name> <prompt-file>` | 워크트리를 만들고, gitignore된 파일을 메인 체크아웃에서 채우고, 에이전트를 띄운다 |
| `dispatch.sh --repos [--all]` | 같은 프로젝트 그룹의 후보 레포를 이름과 메인 체크아웃 경로로 찍는다. 워크트리는 안 만든다 |
| `review.sh <repo> <name> [prompt-file]` | 그 워크트리 안에 리뷰어를 띄운다. 이미 떠 있으면 새로 안 띄우고 재리뷰를 시킨다 |
| `handback.sh <repo> <name> [review-file]` | 리뷰 결과를 작업 에이전트에게 되돌려 고치게 한다. 죽었으면 새로 띄운다 |
| `status.sh [repo\|--all\|--wait]` | 워크트리별 커밋 수, 미커밋 수, 리뷰 라운드, 터미널 상태(돎/막힘/쉼), 카드에 적힌 줄. 우산 워크트리 안이면 제 것만. `--wait`는 부를 마디가 설 때까지 기다렸다 찍는다 |
| `land.sh <repo> <name>` | 리뷰 판정을 찍어 보이고 `--no-ff`로 머지, push까지 한 뒤 워크트리를 지운다 |
| `worktree-setup.sh [path]` | 새 워크트리에 gitignore된 파일을 메인 체크아웃에서 채운다. dispatch가 자동으로 부른다 |

환경변수로 동작을 조정할 수 있다. `AGENT_CMD`, `BASE_BRANCH`, `NO_SETUP=1`, `KEEP=1`, `NO_PUSH=1`, `FORCE=1`, `NOTE`(handback에 실을 메모), `NEW=1`(리뷰어를 새로 띄운다), `MAX_ROUNDS`(리뷰 상한), `ORCA_OWNER`(우산을 손으로 지정한다), `WAIT_INTERVAL`과 `WAIT_TIMEOUT`(`--wait`의 주기와 상한)이다.

## 리뷰 왕복에는 상한이 있다

`review.sh`가 라운드를 센다. 한 번 돌 때마다 앞 판정을 `~/orca/reviews/<repo>-<name>.round<N>.md`로 밀어 두므로, 재리뷰가 앞 판정을 덮어 무엇이 지적이었는지 사라지던 자리가 막힌다. 밀어 둔 파일 수가 곧 라운드 수이고, `status.sh`의 리뷰 칸에 `3차`로 앉는다.

기본 상한은 5다. 넘기면 스크립트가 남은 blocking을 찍고 멈춘다.

```
리뷰 6차다. 상한 5차를 넘었다.

남은 판정 (~/orca/reviews/shared-orca-plugin.orca-check.trade.md) -- blocking 1건
## blocking
- src/Auth.java:88 토큰 만료 검사가 없다

왕복을 더 쓸 값인지 사람이 판단한다.
  계속 돌린다   FORCE=1 .../bin/review.sh shared ...
  여기서 닫는다 .../bin/land.sh shared ...
```

2차부터는 프롬프트에 리뷰 범위를 명시한다. 앞 라운드 파일을 읽고 거기 blocking이 항목마다 닫혔는지만 보라고 하며, 새로 눈에 띈 것은 blocking으로 올리지 말라고 못 박는다. 라운드가 늘수록 억지 지적이 붙던 것을 막는 자리다.

## 다 닫혔을 때 혼자 land하지 않는다

우산이 낸 워크트리가 전부 커밋이 서고, 미커밋이 없고, 판정이 최신이고, blocking이 0이면 `status.sh`가 마지막에 그 줄을 찍는다.

```
▶ 내가 낸 워크트리 2개가 전부 닫혔다.
  진척을 기록하고 land할지 사람에게 묻는다.
```

우산 워크트리는 집계에서 제외한다. 오케스트레이터가 작업하는 곳이라 미커밋 변경이 계속 남아 전체 완료 조건을 충족할 수 없기 때문이다.

셈에서만 빼고 제 줄은 따로 갖는다. 리뷰를 안 거치는 자리라 판정 파일은 안 보고, 미커밋이 없고 기준 브랜치보다 앞서 있으면 `▶ 이 우산 워크트리에도 main 앞에 커밋 3개가 서 있다`가 뜬다. 그 자리의 `main`은 박힌 값이 아니라 그 레포의 기준 브랜치다. 이 줄이 없으면 우산이 제 손으로 짠 것은 아무도 안 묻는다.

그 줄이 뜨면 오케스트레이터가 폴링을 멈추고 사람에게 묻는다. **머지 순서가 그 표에 안 보이기 때문이다** — 여러 레포가 함께 커밋돼야 하는 변경은 한쪽만 먼저 들어가면 계약이 깨진 중간 상태가 남는다. 일부만 닫혔으면(`▶ 3개 중 2개가 닫혔다`) 아직 안 묻고 남은 것이 무엇을 기다리는지만 짚는다.

## 무엇을 했는지는 기록 파일에 쌓인다

카드는 지금 처지 한 줄만 든다. 앞 줄은 덮여 사라지고, land가 워크트리를 지우면 카드도 같이 간다. 그래서 dispatch, review, handback, land가 우산마다 파일 하나에 한 줄씩 남긴다.

```
~/orca/reviews/.journal/orca-plugin.orca-check.md

09-10 14:02  dispatch shared/orca-plugin.orca-check.trade -- 너는 거래 컬럼 담당이다
09-10 15:40  review shared/orca-plugin.orca-check.trade 1차 (커밋 3개)
09-10 16:11  handback shared/orca-plugin.orca-check.trade -- blocking 2건
09-10 17:03  land shared/orca-plugin.orca-check.trade -- main 에 머지, push 완료 (커밋 5개, 리뷰 2차)
```

`status.sh`가 표 아래에 마지막 다섯 줄을 붙인다. 세션을 갈아탔으면 그 줄부터 읽는다.

## 설정

프로젝트별 설정은 루트의 `.orca-flow.json`에 모아 둔다. 없으면 기본값을 사용한다. <br>
`${projectRoot}`는 그 파일이 있는 디렉터리로 바뀐다. 절대 경로를 안 적어도 되므로 이 파일을 커밋해도 남의 머신에서 그대로 돈다.

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

| 키 | 기본값 | 무엇 |
|----|--------|------|
| `baseBranch` | `main` | 워크트리를 딸 기준이자 land할 대상. **레포마다 그 레포의 메인 체크아웃에서 따로 읽는다** |
| `agentCmd` | `claude --permission-mode auto` | 워크트리에 띄울 에이전트 명령. Codex를 쓰면 여기를 바꾼다 |
| `workspaces` | `~/orca/workspaces` | Orca가 워크트리를 만드는 곳 |
| `reviews` | `~/orca/reviews` | 리뷰 판정과 터미널 핸들, claim을 저장하는 곳 |
| `setup.enabled` | `true` | `false`면 dispatch도 앱 플러그인도 셋업을 안 돌린다 |
| `setup.script` | 플러그인의 `bin/worktree-setup.sh` | 프로젝트 전용 셋업 스크립트. 프로젝트 루트 기준 상대 경로 |
| `setup.files` | `.env` 계열과 `*-local-mine.yaml` | 복사할 파일 패턴. 슬래시가 있으면 `-path`, 없으면 `-name` |
| `setup.dirs` | 없음 | 통째로 옮길 디렉터리. 코드 생성 산출물처럼 다시 만들기 비싼 것만 |
| `setup.prune` | 빌드 산출물과 의존성 트리 | 훑지 않을 디렉터리 |
| `setup.repoExtras` | 없음 | 패턴으로 안 잡히는 레포별 예외. 키는 레포 디렉터리 이름 |
| `setup.deny` | 없음 | 워크트리로 가르면 안 되는 레포 |
| `review.context` | 없음 | 기본 리뷰 프롬프트에 추가할 내용. 여러 줄이어도 되고, 리뷰 기준을 적은 파일의 절대 경로를 여기서 가리켜도 된다 |
| `review.maxRounds` | `5` | 리뷰 왕복 상한. 넘으면 `review.sh`가 남은 blocking을 찍고 멈춘다. `MAX_ROUNDS=`로 한 번만 다르게, `FORCE=1`로 넘겨 돌린다 |
| `promptTemplate` | 플러그인의 `templates/prompt-template.md` | dispatch 프롬프트의 뼈대 |

**설정을 어떻게 찾나.** 기준점에서 위로 올라가며 `.orca-flow.json`을 찾는다. 사람이 부르면 `$PWD`에서, 워크트리 셋업에서는 그 워크트리의 **메인 체크아웃**에서 올라간다. <br>
워크트리는 워크스페이스 디렉터리 아래 있어 프로젝트 트리 밖이므로 워크트리에서 올라가면 아무것도 못 찾는다. 메인 체크아웃에서 올라가면 레포가 곧 프로젝트인 경우는 레포 루트에서 잡히고, 우산 아래 레포가 여럿인 경우는 우산에서 잡힌다. 그래서 후보 경로를 열거하는 자리가 이 플러그인에 하나도 없다.

**기준 브랜치는 레포마다 따로 읽는다.** `status.sh`는 여러 레포의 워크트리를 한 표에 찍는데, 기준을 하나로 잡으면 기준이 `main`이 아닌 레포는 커밋 칸이 통째로 `?`가 되고 아래 커밋 목록도 빈다. 그래서 `lib.sh`의 `base_branch_for`가 레포 이름으로 그 레포의 **메인 체크아웃**을 찾아 거기서 `.orca-flow.json`을 올라가며 읽는다. dispatch, review, land도 같은 함수를 쓴다 -- status가 "닫혔다"고 안내한 것을 land가 실제로 머지하려면 둘이 같은 기준을 봐야 한다. <br>
우선순위는 환경변수 `BASE_BRANCH` > 그 레포의 설정 > 호출한 자리에서 정해진 값이다.

**호스트 수준 설정(`~/.orca-flow.json`).** Orca 앱 플러그인은 워커의 env가 허용 목록으로 스크럽돼 와서 `ORCA_REVIEWS` 같은 환경변수를 못 본다. 워크스페이스나 리뷰 디렉터리를 기본값에서 옮겼다면 여기에도 적어야 앱 플러그인이 같은 자리를 본다. `pathPrepend`로 자식 PATH에 디렉터리를 더 얹을 수도 있다.

## 새 워크트리는 그대로 못 쓴다

git worktree는 추적하는 파일만 가져오는데, 앱을 띄우고 테스트를 돌리는 데 필요한 것 상당수가 gitignore 대상이다. `.env` 계열, 개발자별 프로파일, 코드 생성 산출물, submodule이 빈 채로 남는다. 그 상태로 빌드하면 원인이 코드처럼 보이는 오류가 난다.

`worktree-setup.sh`가 그 빈자리를 같은 레포의 메인 체크아웃에서 채운다. 복사 원본은 `git worktree list`의 첫 항목이라 레포별 경로를 적어 둘 필요가 없다.

**`orca.yaml`의 setup 훅으로는 안 된다.** 훅은 워크트리 대상 레포의 것만 읽어서, 레포 여럿을 우산 하나가 품는 배치에서는 우산에 둬도 형제 레포에 안 걸린다. 게다가 커밋돼 있어야 한다 — 워크트리는 커밋된 트리를 체크아웃하므로 추적되지 않는 `orca.yaml`은 딸려오지 않고 훅도 안 돈다(2026-07-28 확인). <br>
레포마다 커밋해 넣는 방법이 남지만 그건 도구 설정을 남의 레포에 밀어 넣는 일이고, submodule로 물려 있거나 담당자가 따로 있는 레포에서는 그럴 자리가 아니다. <br>
플러그인은 호스트에 한 번 붙고 레포를 가리지 않으므로, 레포에 아무것도 커밋하지 않고 그 자리를 대신한다.

- 이미 있는 파일은 건너뛴다. 워크트리에서 일부러 다르게 잡아 둔 값을 조용히 덮어쓰지 않기 위해서다.
- **추적되는 파일은 `--force`를 줘도 두고 간다.** 커밋된 `.env.local`이 섞여 있는 레포가 있어서, 덮으면 워크트리에 출처를 모를 수정이 남고 다음 커밋에 딸려 나간다.
- 정본은 언제나 메인 체크아웃이고 반대 방향으로는 안 돌려보낸다. 그 파일들은 커밋되지 않아 리뷰를 못 거치는데, 양방향으로 열어 두면 어느 쪽이 맞는 설정인지 판정할 근거가 사라진다.
- 에이전트 권한 허용 목록(`.claude/settings.local.json`)은 기본으로 안 옮긴다. 한 작업 트리에서 승인한 권한이 조용히 번지는 걸 막기 위해서고, 필요하면 `--with-agent-settings`다.
- 의존성은 복사하지 않고 설치한다. `node_modules`와 `.venv`는 심링크와 절대 경로를 품고 있어 다른 디렉터리로 옮기면 조용히 깨진다.

**셋업이 끝나야 에이전트가 뜬다는 순서가 dispatch의 존재 이유다.** Orca UI에서 만든 워크트리는 dispatch를 안 거치므로 앱 플러그인이 같은 스크립트를 부르는데, 플러그인은 같은 생성 이벤트를 받으니 그대로 두면 둘이 같은 워크트리를 다툰다. 플러그인이 먼저 잡으면 dispatch 쪽 호출이 75로 즉시 돌아오고, 셋업이 백그라운드로 도는 중에 에이전트가 뜬다.

그래서 dispatch는 워크트리를 **만들기 전에** `<reviews>/.claims/<repo>-<name>`에 표식을 놓는다. 이벤트보다 항상 먼저 놓이므로 플러그인은 dispatch가 만든 워크트리에서 늘 물러선다. 표식은 dispatch가 끝날 때 사라지고, 늦게 도착한 플러그인은 셋업이 남긴 `worktree-setup.done`을 보고 또 물러선다. <br>
사람이 손으로 부른 것과 겹치는 경우가 마지막에 남는데, 그건 `worktree-setup.sh` 자신이 그 워크트리의 git 디렉터리에 든 잠금이 가른다. 진 쪽은 75로 빠지고, dispatch는 75를 받으면 실패로 읽지 않고 잠금이 풀릴 때까지 기다렸다 에이전트를 띄운다.

## 진행은 Orca 카드에 앉는다

Orca 워크스페이스 카드에 한 줄짜리 코멘트와 보드 상태(`todo`, `in-progress`, `in-review`, `completed`)가 붙는다. 스크립트와 워크트리의 에이전트가 각 작업 단계에서 코멘트와 상태를 갱신한다.

| 언제 | 상태 | 카드에 표시되는 문구 |
|------|------|----------------|
| `dispatch.sh`가 에이전트를 붙일 때 | `in-progress` | 에이전트 투입 |
| 작업 에이전트가 단계를 마칠 때 | 그대로 | 그 에이전트가 직접 쓴 한 줄 |
| `review.sh`가 리뷰어를 띄울 때 | `in-review` | 리뷰 중 (커밋 N개) |
| 리뷰어가 판정 파일을 다 썼을 때 | 그대로 | 리뷰: blocking N건, 또는 리뷰 통과 |
| `handback.sh`가 되돌릴 때 | `in-progress` | 재작업 -- 리뷰 blocking 반영 |
| `land.sh`가 push까지 끝냈을 때 | `completed` | 머지, push 완료 |

둘째 행은 에이전트가 직접 작성하므로 커밋 수만으로 알 수 없는 상태("테스트 도는 중", "FK에 막힘")도 표시한다. `dispatch.sh`와 `handback.sh`가 프롬프트 끝에 그 지시를 붙여 보내므로 오케스트레이터가 챙길 필요는 없다.

한동안은 git을 2초마다 긁어 데스크톱 알림을 띄우는 워처를 따로 돌렸다. 상태를 밖에서 추측하는 물건이라 커밋 수와 미커밋 수 너머는 못 봤다. 카드는 방향이 반대다. 상태를 실제로 바꾸는 쪽이 그 자리에서 쓴다.

카드는 조용히 바뀐다. Orca를 안 보고 있으면 바뀐 줄 모르고, CLI에는 알림을 쏘는 명령이 없다. 그 자리를 Orca 앱 플러그인이 메운다 — 에이전트가 멈추면(`done`, `waiting`, `blocked`) 데스크톱 알림이 뜨고, 카드에 적힌 줄이 본문 첫 줄로 실린다. 폴링이 아니라 훅이 올려 준 상태 변화를 받는다. <br>
코멘트를 비우는 것은 안 된다. 빈 문자열을 주면 CLI가 그 인자를 무시해 지난 줄이 그대로 남는다. 덮어쓰기만 되고, 다음 단계가 자기 줄을 남기는 것으로 그 자리를 메운다.

## 리뷰가 워크트리 안에서 도는 이유

리뷰어를 오케스트레이터 세션의 서브에이전트로 띄우면 레포 수만큼의 diff가 그 세션 컨텍스트로 올라온다. 레포 넷이면 그게 곧 한도다. <br>
`review.sh`는 작업이 있는 그 워크트리에 터미널을 하나 더 열고 거기서 돌린다. 오케스트레이터는 판정 파일만 읽는다.

### 판정은 반드시 파일로 받는다

`<reviews>/<repo>-<name>.md`이고 `review.sh`가 그 지시를 프롬프트 뒤에 자동으로 붙인다. 워크트리 밖에 두는 것은 안에 쓰면 작업 트리가 더러워져 다음 커밋에 딸려 나가기 때문이다.

**TUI에만 출력하면 사라진다.** 실제로 그랬다. 리뷰어 넷이 판정을 다 냈는데 Claude Code의 스피너 재도색이 스크롤백을 밀어내, `orca terminal read`로 2000줄을 긁어도 남은 것이 `Sautéed for 5m 39s` 한 줄이었다. <br>
살아 있는 에이전트에게 "방금 낸 결과를 파일로 써라"를 보내 겨우 되찾았다. 컨텍스트가 아직 있어서 됐던 것이고, 세션이 끝났으면 5분치 리뷰 넷이 통째로 날아갔다.

### blocking은 되돌려 고친다

`handback.sh`가 판정 파일 경로를 그 워크트리의 작업 에이전트에게 보낸다. 그 에이전트는 자기가 쓴 코드의 맥락을 아직 들고 있어서, 새로 띄우는 것보다 싸고 정확하다. <br>
되돌리는 메시지에 "리뷰어가 틀렸다고 판단되면 고치지 말고 근거를 대라"가 들어간다. 지적을 받았다는 이유만으로 코드를 바꾸면 리뷰가 품질을 낮춘다.

작업 에이전트를 다시 찾는 데 탭 제목을 쓰지 않는다. 에이전트가 제목을 자기 작업 요약으로 갈아 버려서(`REVIEW caller-identity`가 `리뷰: API 게이트웨이 거래 경로 변경`이 된다) 제목으로는 역할을 구분하지 못한다. <br>
그래서 `dispatch.sh`와 `review.sh`가 터미널 핸들을 `<reviews>/.handles/`에 적어 두고 `handback.sh`가 그것을 읽는다.

### 리뷰어가 죽으면 앞 판정이 사라지던 자리

handback을 받은 작업 에이전트가 고치고 커밋한 뒤 종료하면 그 워크트리의 터미널이 함께 사라진다. 리뷰어도 같이 죽는다. <br>
그 상태로 `review.sh`를 부르면 새 리뷰어가 뜨는데, 그 리뷰어는 무엇이 지적이었는지 모른 채 처음부터 훑는다. **닫혔는지를 견주지 못하니 재리뷰가 아니라 1차가 한 번 더 도는 것이다.** 게다가 출력 경로가 앞 판정과 같은 파일이라, 덮어쓰면 무엇을 되돌렸는지의 기록도 사라진다.

한동안은 재리뷰 전에 사람이 `cp`로 옮겨 두게 했다. 지금은 `review.sh`가 뜨기 전에 앞 판정을 `.round<N>.md`로 밀고, 2차부터는 그 경로를 프롬프트에 실어 항목마다 닫혔는지 확인하라고 지시한다. 리뷰어가 살아 있든 죽었든 같은 문장이 나가므로 갈래가 하나다.

라운드별 판정은 워크트리를 지워도 그대로 둔다. "이건 왜 이렇게 됐나"를 나중에 물을 때 그것이 유일한 기록이다.

### 라운드가 늘면 억지 지적을 막는다

라운드가 셋을 넘어가면 남는 것이 대개 문장 다듬기다. 그때도 리뷰어는 뭔가를 내려 한다. <br>
2차부터 프롬프트에 범위가 좁혀져 나가고 "새 지적을 억지로 만들지 않는다. 없으면 없다고 적는다"가 함께 실린다. 네 라운드를 돈 워크트리에서 그 문장을 넣은 4라운드부터 판정이 짧아졌다.

그리고 5차가 상한이다. 넘으면 `review.sh`가 남은 blocking을 찍고 멈춘다.

### 왕복을 어디서 멈출지는 오케스트레이터가 혼자 정하지 않는다

blocking이 없어질 때까지 자동으로 계속 돌리지 않는다. **두세 라운드를 넘기면 멈추고 계속할지 지금 land할지를 사람에게 묻는다.** <br>
리뷰는 관행이고 최종 게이트는 push 확인이다. 오케스트레이터가 리뷰를 게이트처럼 운용하면 왕복이 계속 이어지고, 그 사이 사람은 무엇을 기다리는지 모른다.

한 배치에서 그랬다. 한 레포가 여섯 라운드, 다른 하나가 세 라운드를 돌았다. 지적은 매번 실체가 있었지만 — `kms:CreateGrant` 누락은 plan을 통과하고 apply가 키를 만든 뒤 클러스터 갱신에서 죽는 것이었다 — 계속 돌릴지를 한 번도 묻지 않았다.

확인을 요청할 때는 남은 지적을 종류별로 보여 준다.

| 종류 | 어떻게 |
|------|--------|
| 실행을 깨는 것 (apply 실패, 계약 위반, 데이터 손상) | 라운드를 더 써서 닫는다 |
| 서술 정정과 문장 다듬기 | land를 추천하고 나머지는 잔여 작업으로 기록한다 |

안 고치고 넘긴 것은 프로젝트의 잔여 작업 문서에 적어 잃지 않게 한다. 판정 파일은 워크트리가 지워져도 남지만 아무도 다시 열지 않는다.

## 머지 순서는 계약이 정한다

레포가 갈렸다고 머지까지 갈리지는 않는다. <br>
API 계약을 사이에 둔 양쪽, 공유 마이그레이션과 그것을 읽는 서비스, 템플릿 copy-sync는 한쪽만 머지되면 계약이 깨진 중간 상태가 남는다.

한 배치가 그 예다. helm의 NetworkPolicy가 먼저 서고 그다음 서비스 표면과 질의와 공유 표가 함께 갔다. 질의 쪽만 먼저 머지되면 entitlement 게이트가 fail-closed라 소비자 실행이 전부 500으로 죽는다.

그래서 `land.sh`는 워크트리 하나씩만 처리하고 순서를 알아서 정하지 않는다. 순서는 계약 문서가 들고 있다.

## 알아 둘 것

**카드의 「쉬는 중」으로는 셋이 구분되지 않는다.** 일하는 중, 프롬프트에 막힘, 죽음이 같은 문구로 보인다. <br>
`status.sh`의 터미널 칸이 그것을 `돎`, `막힘`, `쉼`, `없음`으로 가른다. 도는 중인지는 `orca terminal list`가 주는 preview(TUI 마지막 줄)로 추가 호출 없이 갈리고, 쉬는 것으로 보일 때만 tail을 읽어 사람 손을 기다리는 프롬프트가 떠 있는지 본다. 칸이 애매하면 직접 읽는다.

```bash
source bin/lib.sh
H=$(load_handle ai-runtime caller-identity work)
orca terminal read --terminal "$H" --json
```

| tail에 무엇이 보이나 | 무슨 상태 |
|--------------------|----------|
| Claude Code 상태줄(경과 시간, 도구 호출 수, 토큰) | 돈다. 카드 문구는 늦게 갱신될 뿐이다 |
| `Is this a project you created or one you trust?` | **막혔다.** Enter를 보내야 시작한다 |
| `API Error`와 `❯` 프롬프트 | **죽었다.** 작업 트리는 온전하니 같은 워크트리에 다시 넣는다 |

둘째는 **그 레포에 처음 워크트리를 딸 때** 난다. Claude Code가 새 디렉터리를 신뢰할지 묻고 거기서 통째로 멈춘다. 미커밋이 0인 채 오래 「쉬는 중」이면 이쪽을 먼저 본다.

```bash
orca terminal send --terminal "$H" --text "" --enter --json
```

셋째는 죽어도 잃는 것이 없다는 것이 중요하다. 한 에이전트가 1시간 32분 만에 `ENOTFOUND`로 죽었는데 미커밋 아홉 파일 135줄이 그대로 남아 있었다. 새 에이전트를 같은 워크트리에 넣고 **"앞선 에이전트가 죽었고 작업은 온전하다, `git status`와 `git diff`로 확인하고 남은 것만 마무리해라, 처음부터 다시 하지 마라"**를 프롬프트에 적었다. 이 문장이 없으면 처음부터 다시 짠다.

**`land.sh`는 push까지 한다.** 사람이 최종 게이트인 것은 맞지만 그 게이트는 커밋 훅의 확인 프롬프트가 잡는다. <br>
스크립트가 push를 아예 안 하면 "닫았다"고 말한 작업이 로컬에만 남고, 그게 실제로 났다 — 레포 둘을 land해 놓고 원격에는 아무것도 없는 상태를 한참 몰랐다. <br>
push가 실패하면 워크트리를 안 지운다. 지우면 되돌릴 자리가 사라진다. 일부러 로컬에만 두려면 `NO_PUSH=1`이고, 그때도 워크트리는 남는다.

**메인 체크아웃이 낡았을 수 있다.** 워크트리는 origin 기준으로 서는데 메인 체크아웃은 그렇지 않다. <br>
이로 인해 잘못 판단한 사례가 있다. 메인 체크아웃에 계약 문서가 없어 "아직 안 썼다"고 판정했는데 origin/main에는 PR 둘이 이미 머지돼 있었다. 시작 전에 `git -C <repo> pull --ff-only`를 한 번 돌린다.

**`--agent claude`에는 플래그를 못 싣는다.** 그래서 `dispatch.sh`가 워크트리를 만든 뒤 `orca terminal create --command`로 에이전트를 따로 띄운다. auto 모드가 거기서 붙는다.

**`.claude/`를 커밋해 둔 레포는 첫 기동에서 말없이 선다.** 워크스페이스가 신뢰되지 않은 상태에서 `.claude/settings.json`을 만나면 Claude Code가 신뢰 확인을 띄우고 키 입력을 기다린다. <br>
그 화면에서는 대화가 한 턴도 시작되지 않아 `~/.claude/projects/` 아래에 디렉터리조차 안 생기고, 터미널은 출력이 없어 멀쩡히 일하는 것과 구분되지 않는다. <br>
실제로 그랬다. 프로세스는 95분을 살아 있었고 그동안 쓴 CPU가 23초였다. **살았나 죽었나를 커밋 수가 아니라 CPU 시간으로 본다** — `ps -o time`이 몇 초에 머물러 있으면 일하는 중이 아니다. <br>
푸는 것은 `~/.claude.json`의 `projects[<메인 체크아웃 경로>].hasTrustDialogAccepted`를 `true`로 두는 것이다. 키가 워크트리 경로가 아니라 메인 체크아웃 경로인 것은 claude가 git common dir로 접어 보기 때문이고, 그래서 한 번 신뢰하면 그 레포의 워크트리 전부에 걸린다.

**터미널 핸들은 `result.terminal.handle`에 온다.** `orca terminal create --json`의 응답 모양이 그렇고, `lib.sh`의 `terminal_handle`이 `result.handle`만 보던 동안 `dispatch.sh`와 `review.sh`가 핸들을 조용히 못 남겼다. <br>
그러면 나중에 `handback.sh`가 작업 에이전트를 못 찾아 컨텍스트를 버리고 새로 띄운다. 실패가 그 자리에서 안 드러나고 한 사이클 뒤에 드러나는 형태라, 띄운 뒤 `<reviews>/.handles/`에 파일이 생겼는지 한 번 본다.

**병렬 브랜치는 이음매를 남긴다.** 같은 계약을 두 워크트리가 나눠 쓰면 같은 사실이 두 이름으로 남는다. <br>
그 이음매를 닫는 워크트리를 하나 더 띄워야 했던 적이 있다. 문서 하나가 커밋 경계 하나면 가르지 않는 편이 싸다.

**워크트리를 지우기 전에 머지를 확인한다.** `land.sh`는 머지 뒤에 지우지만, `orca worktree rm`을 직접 부르면 커밋이 브랜치에만 남은 채 사라질 수 있다. `status.sh`로 커밋 수를 먼저 본다.

**`status.sh`의 리뷰 칸이 `낡음`이면 재리뷰가 안 돌았다는 뜻이다.** 판정 파일이 마지막 커밋보다 오래됐다는 것이고, handback으로 고친 뒤 `review.sh`를 안 부른 자리가 그렇게 보인다. 그 상태로 land하면 고치기 전 스냅샷에 대한 판정으로 머지하게 된다.

**리뷰 기록은 워크트리를 지워도 남는다.** `<reviews>/<repo>-<name>.md`는 워크스페이스 밖이라 `land.sh`가 안 지운다. 나중에 "이건 왜 이렇게 됐나"를 물을 때 그것이 유일한 기록이다.

## 환경 관련

**PATH가 앱 플러그인에서는 다르다.** Finder나 Dock에서 뜬 Orca의 PATH는 launchd 기본(`/usr/bin:/bin:/usr/sbin:/sbin`)이다. `git`과 `bash`는 거기 있지만 `orca`, `pnpm`, `uv`는 대개 그 밖이다. 그대로 두면 셋업이 의존성을 "not found, skipped"로 넘기고 0으로 끝나서 `node_modules` 없는 워크트리에 완료 알림이 뜬다. 그래서 자식 PATH에 흔한 자리(`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`)를 얹는데, 머신마다 다르면 `~/.orca-flow.json`의 `pathPrepend`로 더 넣는다. <br>
실행에 문제가 생기면 플러그인 로그의 `자식 PATH` 줄과 `도구:` 줄부터 확인한다.

**env는 허용 목록으로 스크럽돼 온다.** 앱 플러그인 워커에는 `PATH`, `HOME`, `LANG`, `TMPDIR` 정도만 넘어온다. 셸에서 export한 값은 전달되지 않으므로 `AWS_PROFILE` 같은 것에 기대는 스크립트를 셋업에 붙이면 조용히 다르게 돈다.

**긴 셋업은 알림을 놓칠 수 있다.** 이벤트 핸들러는 5분에 끊기고 워커는 유휴 5분에 수거된다. 자식은 detached로 띄우므로 `pnpm install`이 중간에 죽지는 않지만, 4분을 넘기면 "백그라운드로 계속 돈다"는 알림으로 바뀐다.

**플러그인 `id`에 `orca`를 쓰면 설치가 거부된다.** 이 플러그인의 id가 `worktree-flow`인 이유다. 처음에 `orca-flow`로 뒀다가 설치가 계속 실패했고, 오류는 "플러그인 설치에 실패했습니다. 소스를 확인하고 다시 시도하세요" 한 줄뿐이었다. <br>
로그에도 아무것도 안 남는다 — `main.trace.ndjson`에 설치 경로가 아예 추적되지 않고 `plugins-data/audit.log`는 이미 도는 플러그인의 호출만 적는다. 그래서 매니페스트 스키마, 디렉터리 배치, 부모 경로, `.git` 유무, 하위 디렉터리, 실행 비트를 차례로 의심하게 된다. 어느 것도 원인이 아니었다. <br>
원인은 **설치되는 설정에서 한 번에 한 줄씩 바꿔** 확인했다. 설치되는 매니페스트를 하나 확보하고 `id`, `publisher`, `name`, `description`을 각각 하나만 바꾼 디렉터리 넷을 만들어 보면 `id`에서 걸린다. `publisher`가 무엇이든 상관없다.

**소스에 제어문자가 있으면 거부된다.** 같은 오류 문구로 나온다. ANSI 이스케이프를 다루는 코드에서 나기 쉽다 — 정규식에 `\u001b`를 이스케이프 표기로 적어야 하는데 실제 ESC 바이트가 파일에 박히면, JS로는 유효하고 `node --check`도 통과하며 `cat -A`로 봐도 정상처럼 보인다. <br>
의심되면 바이트로 센다.

```bash
python3 -c "
b=open('main.mjs','rb').read()
print([hex(c) for c in sorted(set(c for c in b if c<9 or 13<c<32))] or '없음')"
```

**플러그인 API는 문서가 없다.** 근거는 [plugin-host-api.ts](https://github.com/stablyai/orca/blob/main/src/shared/plugins/plugin-host-api.ts)와 [plugin-manifest.ts](https://github.com/stablyai/orca/blob/main/src/shared/plugins/plugin-manifest.ts), 예제 [hello-orca](https://github.com/stablyai/orca/tree/main/examples/plugins/hello-orca)뿐이고, 소스 주석이 `pluginApi` 1이 얼기 전까지 호환을 보장하지 않는다고 적어 뒀다. Orca를 올린 뒤 안 뜨면 매니페스트 스키마부터 본다.

## 배치

```
.claude-plugin/     Claude Code 매니페스트와 마켓플레이스 (이 레포가 곧 마켓플레이스다)
orca-plugin.json    Orca 앱 매니페스트
orca-marketplace.json  Orca 앱 마켓플레이스 소스. 플러그인을 태그에 고정한다
main.mjs            Orca 앱 워커
bin/                스크립트. config.sh 가 설정을 읽고 lib.sh 가 Orca 를 감싼다
commands/           슬래시 커맨드 다섯
skills/orca-flow/   절차를 가르치는 스킬
templates/          설정과 프롬프트의 출발점
```

`config.sh`를 `lib.sh`에서 갈라 둔 것은 `worktree-setup.sh`가 혼자서도 돌아야 하기 때문이다. Orca 앱 플러그인이 그 스크립트를 직접 띄우는데, `lib.sh`는 맨 위에서 `orca` CLI를 요구하므로 거기 얹으면 셋업이 "orca가 없다"로 죽는다.
