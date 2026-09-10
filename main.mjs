/**
 * Orca 앱 플러그인. 둘을 한다.
 *
 * 1. 워크트리가 생기면 셋업 스크립트를 돌린다.
 *    git worktree는 추적되는 파일만 가져오므로 .env 계열과 submodule, generated
 *    소스가 빈 채로 남고 그 상태로 빌드하면 원인이 코드처럼 보이는 오류가 난다.
 *    그걸 메인 체크아웃에서 채우는 것이 bin/worktree-setup.sh 다.
 *    orca.yaml의 setup 훅은 대상 레포에 커밋돼 있어야 도는데, 남의 레포에
 *    도구 설정을 밀어 넣기 어려운 자리가 많다. 플러그인은 호스트에 한 번 붙고
 *    레포를 가리지 않으므로 레포에 아무것도 커밋하지 않고 그 자리를 대신한다.
 *
 * 2. 에이전트가 멈추면(done, waiting, blocked) 알림을 띄운다.
 *    Orca에는 알림을 쏘는 명령이 없어 터미널 tail을 폴링하는 수밖에 없었다.
 *    여기서는 훅이 올려 준 상태 변화를 그대로 받는다.
 *
 * 워커는 Electron이 아니라 평범한 Node fork이고 env는 허용 목록(PATH, HOME 등)
 * 으로 스크럽돼 온다. 셸에 export해 둔 값은 넘어오지 않으므로, 스크립트가
 * 그것을 요구하면 여기서는 안 돈다. 경로 설정을 env가 아니라 파일에서 읽는
 * 이유가 이것이다.
 */

import { spawn } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { stat } from 'node:fs/promises'
import { dirname, join, parse as parsePath } from 'node:path'
import { fileURLToPath } from 'node:url'

const HOME = process.env.HOME || process.env.USERPROFILE || ''
const PLUGIN_ROOT = dirname(fileURLToPath(import.meta.url))
const SETUP_SCRIPT = join(PLUGIN_ROOT, 'bin', 'worktree-setup.sh')
const STATUS_SCRIPT = join(PLUGIN_ROOT, 'bin', 'status.sh')
const CONFIG_NAME = '.orca-flow.json'

/** 워커 이벤트 핸들러는 5분에 끊기므로 그 안에서 끝낼 만큼만 붙잡고 있는다. */
const SETUP_WAIT_MS = 4 * 60_000
/** 커맨드 호출은 30초에 끊긴다. 그 안에 답이 나와야 하는 것만 여기 맞춘다. */
const COMMAND_WAIT_MS = 25_000
/** worktree-setup.sh가 "다른 실행이 이미 잡고 있다"에 쓰는 코드. */
const SETUP_LOCKED = 75
/** 사람이 볼 꼬리. 알림 본문과 로그로만 가므로 짧게 든다. */
const TAIL_MAX = 6_000
/**
 * 프로그램이 읽는 stdout. JSON과 status 표가 여기로 오는데 둘 다 앞이 잘리면
 * 못 쓴다. JSON은 파싱이 실패하고 표는 머리가 날아간 조각이 알림에 실린다.
 * 그래서 꼬리와 상한을 따로 둔다.
 */
const OUT_MAX = 256 * 1024

// ---------------------------------------------------------------------------
// 설정
// ---------------------------------------------------------------------------

/**
 * .orca-flow.json 을 읽는다. bin/config.sh 와 같은 규칙이다 -- ${projectRoot}
 * 토큰을 그 파일이 있는 디렉터리로 바꾼다.
 */
function readConfig(root) {
  const file = join(root, CONFIG_NAME)
  try {
    const raw = readFileSync(file, 'utf8').replaceAll('${projectRoot}', root)
    const parsed = JSON.parse(raw)
    return parsed && typeof parsed === 'object' ? { root, file, data: parsed } : null
  } catch {
    return null
  }
}

/** 기준점에서 위로 올라가며 설정을 찾는다. bin/config.sh 의 orca_flow_find_root 와 같다. */
function findConfig(startDir) {
  let dir = startDir
  const { root } = parsePath(startDir)
  while (dir && dir !== root) {
    if (existsSync(join(dir, CONFIG_NAME))) {
      return readConfig(dir)
    }
    dir = dirname(dir)
  }
  return null
}

/**
 * 호스트 수준 설정(~/.orca-flow.json). 워크트리와 무관한 값이 여기 온다.
 * 워크스페이스와 리뷰 디렉터리를 기본값에서 옮겼다면 여기에도 적어야 한다.
 * 스크립트 쪽은 ORCA_WORKSPACES 같은 환경변수로도 옮길 수 있지만, 이 워커는
 * env가 스크럽돼 와서 그 값을 볼 방법이 없다.
 */
const hostConfig = HOME ? readConfig(HOME) : null
const hostData = hostConfig?.data ?? {}

const expandHome = (value) =>
  typeof value === 'string' && value.startsWith('~/') ? join(HOME, value.slice(2)) : value

const WORKSPACES = expandHome(hostData.workspaces) || join(HOME, 'orca', 'workspaces')
const REVIEWS = expandHome(hostData.reviews) || join(HOME, 'orca', 'reviews')

const ANSI_RE = /\u001b\[[0-9;?]*[a-zA-Z]/g
const stripAnsi = (text) => text.replace(ANSI_RE, '')

/** 알림 본문에 남길 줄 수. 배너가 어차피 두어 줄에서 끊으므로 그 언저리로 둔다. */
const BODY_LINES = 4

/**
 * 알림 본문을 평문으로 만든다. 마크다운 표시는 렌더되지 않고 글자 그대로 뜨며,
 * `-----` 같은 구분선은 비례폭이라 길이가 제각각인 채 줄만 차지한다.
 * 여러 줄에서 뒤쪽만 남기는 것은 빌드 로그 때문이다 -- 원인은 대개 끝에 있다.
 */
function plainBody(body) {
  if (!body) {
    return ''
  }
  return String(body)
    .replace(/```+/g, ' ')
    .replace(/[`*_#>]/g, '')
    .replace(/[-=~─—]{3,}/g, ' ')
    .split('\n')
    .map((line) => line.replace(/[ \t]+/g, ' ').trim())
    .filter(Boolean)
    .slice(-BODY_LINES)
    .join('\n')
}

/**
 * Finder나 Dock에서 뜬 앱의 PATH는 launchd 기본(`/usr/bin:/bin:/usr/sbin:/sbin`)
 * 이다. git과 bash는 거기 있지만 orca, pnpm, uv 는 대개 그 밖이다. 그대로 두면
 * worktree-setup.sh가 의존성을 "not found, skipped"로 넘기고 0으로 끝나서
 * node_modules 없는 워크트리에 완료 알림이 뜨고, orca CLI를 부르는 자리는
 * 조용히 빈손으로 돌아온다. 그래서 자식에게 주는 PATH를 여기서 넓힌다.
 * 머신마다 자리가 다르므로 호스트 설정의 pathPrepend 로 더 얹을 수 있다.
 * 있는 디렉터리만 붙여 PATH가 없는 자리를 가리키지 않게 한다.
 */
const EXTRA_PATH = [
  ...(Array.isArray(hostData.pathPrepend) ? hostData.pathPrepend.map(expandHome) : []),
  '/opt/homebrew/bin',
  '/opt/homebrew/sbin',
  '/usr/local/bin',
  join(HOME, '.local', 'bin')
].filter((dir) => typeof dir === 'string' && dir)

let childEnvCache
function childEnv() {
  if (childEnvCache) {
    return childEnvCache
  }
  const current = (process.env.PATH || '').split(':').filter(Boolean)
  const extra = EXTRA_PATH.filter((dir) => existsSync(dir) && !current.includes(dir))
  childEnvCache = { ...process.env, PATH: [...extra, ...current].join(':') }
  return childEnvCache
}

/**
 * 자식은 detached로 띄운다. 워커가 유휴 5분에 수거돼도 pnpm install이 중간에
 * 끊기지 않게 하려는 것이다. 대신 그때는 완료 알림이 사라진다.
 *
 * stdout과 stderr를 따로 담는 것은 `--json`을 읽는 자리 때문이다. 경고 한 줄이
 * 섞이면 JSON.parse가 실패하고, 그 실패는 "카드 줄이 비었다"로만 보인다.
 * killOnTimeout은 짧은 조회에만 준다. 셋업은 시간이 지나도 계속 돌아야 한다.
 */
function run(file, args, { cwd, env, timeoutMs, killOnTimeout = true, onLateExit } = {}) {
  return new Promise((resolve) => {
    let child
    try {
      child = spawn(file, args, {
        cwd,
        env: env ?? childEnv(),
        detached: true,
        stdio: ['ignore', 'pipe', 'pipe']
      })
    } catch (error) {
      resolve({ code: -1, out: '', tail: String(error?.message ?? error), timedOut: false })
      return
    }
    let out = ''
    let tail = ''
    child.stdout.on('data', (chunk) => {
      const text = stripAnsi(String(chunk))
      out = (out + text).slice(-OUT_MAX)
      tail = (tail + text).slice(-TAIL_MAX)
    })
    child.stderr.on('data', (chunk) => {
      tail = (tail + stripAnsi(String(chunk))).slice(-TAIL_MAX)
    })

    let settled = false
    const finish = (result) => {
      if (settled) {
        return
      }
      settled = true
      clearTimeout(timer)
      resolve(result)
    }
    const timer = timeoutMs
      ? setTimeout(() => {
          if (killOnTimeout) {
            child.kill()
          }
          finish({ code: null, out, tail, timedOut: true })
        }, timeoutMs)
      : null
    child.on('error', (error) =>
      finish({ code: -1, out, tail: `${tail}\n${error.message}`, timedOut: false })
    )
    child.on('close', (code) => {
      // 타임아웃으로 이미 답을 냈어도 늦게 끝난 것은 알린다. 안 그러면
      // "백그라운드로 계속 돈다"고 해 놓고 그 뒤로 아무 기록이 없다.
      if (settled) {
        onLateExit?.(code, tail)
        return
      }
      finish({ code, out, tail, timedOut: false })
    })
  })
}

/**
 * 제목은 `<워크트리> — <사건>` 순으로 짓는다. 알림이 여러 개 쌓이면 왼쪽 끝만
 * 훑어 어느 워크트리인지부터 갈라내고 사건은 그다음에 읽는 순서가 되기 때문이다.
 * 워크트리를 겨누지 않는 것(status, 워크트리를 못 정한 setup)만 사건으로 시작한다.
 *
 * **본문은 평문이다.** 마크다운도 고정폭 정렬도 안 먹는다. 표나 코드펜스를 넣으면
 * 글자가 그대로 뜨고, 비례폭이라 칸도 맞지 않는다. 그래서 status는 표가 아니라
 * 세어 둔 수를 싣는다. 여러 줄은 되지만 배너가 두어 줄에서 끊으므로 짧게 든다.
 *
 * 본문은 plainBody 를 지나간다. 우리가 쓰는 문구만 있으면 필요 없겠지만, 카드
 * 코멘트는 에이전트가 쓴 글이고 셋업 실패 본문은 빌드 로그라 마크다운과 구분선이
 * 섞여 든다. 걷어내는 자리를 여기 하나로 둔다.
 */
async function notify(orca, title, body) {
  const plain = plainBody(body)
  try {
    await orca.host.call('notifications.show', {
      title: String(title).slice(0, 120),
      ...(plain ? { body: plain.slice(0, 1000) } : {})
    })
  } catch (error) {
    orca.log(`알림 실패: ${error?.message ?? error}`)
  }
}

/** 워크트리 id는 `<repoId>::<path>` 꼴이라 경로가 그 안에 들어 있다. */
function pathFromWorktreeId(worktreeId) {
  if (typeof worktreeId !== 'string') {
    return null
  }
  const index = worktreeId.indexOf('::')
  const path = index >= 0 ? worktreeId.slice(index + 2) : ''
  return path.startsWith('/') ? path : null
}

/** <workspaces>/<repo>/<name> 에서 repo/name 을 뽑는다. */
function worktreeLabel(path) {
  if (!path) {
    return null
  }
  const match = /\/workspaces\/([^/]+)\/([^/]+)\/?$/.exec(path)
  return match ? { repo: match[1], name: match[2], label: `${match[1]}/${match[2]}` } : null
}

/**
 * 알림 제목에 넣을 이름. 관례를 벗어난 경로도 마지막 두 마디로 줄인다.
 * 제목은 120자에서 잘리므로 긴 절대 경로를 그대로 넣으면 뒤가 날아간다.
 */
function shortName(path) {
  if (!path) {
    return '워크트리 밖'
  }
  return worktreeLabel(path)?.label ?? path.split('/').filter(Boolean).slice(-2).join('/')
}

/**
 * 그 워크트리가 속한 프로젝트의 설정. 워크트리는 워크스페이스 디렉터리 아래
 * 있어 프로젝트 트리 밖이므로, 메인 체크아웃을 먼저 구하고 거기서 위로 올라간다.
 * 스크립트 쪽 orca_flow_load 가 하는 것과 같은 일이다.
 */
async function projectConfigFor(path) {
  const listed = await run('git', ['-C', path, 'worktree', 'list', '--porcelain'], {
    timeoutMs: 5_000
  })
  const main = /^worktree (.+)$/m.exec(listed.out)?.[1]
  return main ? findConfig(main) : null
}

/**
 * 리뷰가 돈 뒤로 새 커밋이 하나도 없는데 에이전트가 멈췄을 때만 한 줄 얹는다.
 * 아무것도 안 했거나 커밋을 빠뜨린 상태라 사람이 볼 값이 있다.
 *
 * 나머지 둘은 안 싣는다. 첫 dispatch 뒤에는 리뷰 파일이 없어서 늘 "안 함"이고
 * handback 뒤에는 고쳐서 커밋했으니 늘 "낡음"이다 -- 상황이 정해 놓은 값이라
 * 읽히지 않고, 안 읽히는 줄이 매번 붙으면 그 위의 카드 줄까지 같이 묻힌다.
 * 리뷰 상태를 훑는 자리는 status.sh 표의 리뷰 칸이다.
 */
async function reviewNote(path) {
  const parts = worktreeLabel(path)
  if (!parts) {
    return ''
  }
  const file = join(REVIEWS, `${parts.repo}-${parts.name}.md`)
  if (!existsSync(file)) {
    return ''
  }
  const [reviewedAt, commit] = await Promise.all([
    stat(file)
      .then((info) => info.mtimeMs / 1000)
      .catch(() => 0),
    run('git', ['-C', path, 'log', '-1', '--format=%ct'], { timeoutMs: 5_000 })
  ])
  const committedAt = Number(commit.out.trim())
  if (!Number.isFinite(committedAt) || committedAt <= 0) {
    return ''
  }
  return reviewedAt < committedAt ? '' : '새 커밋 없음'
}

/**
 * dispatch.sh가 "셋업은 내가 맡는다"고 미리 놓아 둔 표식과, worktree-setup.sh가
 * 끝나며 남긴 표식. 둘 중 하나라도 있으면 물러선다.
 *
 * claim은 워크트리를 만들기 전에 놓이므로 이 이벤트보다 항상 먼저다. 그래서
 * dispatch 경로에서는 우리가 절대 먼저 잡지 않는다. 그게 중요한 이유는
 * dispatch가 셋업을 동기로 끝낸 뒤에 에이전트를 띄우기 때문이다 -- 우리가
 * 먼저 잡으면 그쪽이 75로 즉시 돌아오고, 반쯤 채워진 워크트리에 에이전트가 뜬다.
 *
 * **이벤트로 왔을 때만 본다.** 사람이 커맨드로 부른 것은 이미 채워졌든 아니든
 * 부른 대로 돌아야 한다. `worktree-setup.done`은 성공한 워크트리마다 남으므로,
 * 커맨드에까지 걸면 "다시 돌리기"가 한 번 채워진 뒤로는 영영 안 도는 버튼이 된다.
 * 겹침은 그래도 안전하다. 잠금이 스크립트 안에 있어 남이 돌고 있으면 75로 빠진다.
 */
async function alreadyHandled(orca, path) {
  const parts = worktreeLabel(path)
  const claim = parts ? join(REVIEWS, '.claims', `${parts.repo}-${parts.name}`) : null
  if (claim && existsSync(claim)) {
    // 죽은 claim은 안 센다. dispatch가 SIGKILL되면 파일이 남는데 워크트리 이름은
    // 재사용되므로, 그대로 두면 그 이름이 영영 침묵한다.
    //
    // 읽기는 감싼다. 지우는 쪽이 dispatch의 EXIT trap이라 존재 확인과 읽기 사이가
    // 실재하는 창이고, 여기서 던지면 예외가 이벤트 핸들러 밖으로 나가 워커가 죽는다.
    // 못 읽으면 살아 있는 것으로 친다. 물러서는 쪽이 안전한 방향이다.
    let owner = null
    try {
      owner = Number(readFileSync(claim, 'utf8').trim())
    } catch {
      return 'dispatch.sh가 맡았다 (claim을 읽는 중에 사라졌다)'
    }
    if (!Number.isInteger(owner) || owner <= 0 || alive(owner)) {
      return 'dispatch.sh가 맡았다'
    }
    orca.log(`죽은 claim이라 안 센다: ${claim}`)
  }
  const gitdir = await run('git', ['-C', path, 'rev-parse', '--absolute-git-dir'], {
    timeoutMs: 5_000
  })
  const dir = gitdir.out.trim()
  if (dir && existsSync(join(dir, 'worktree-setup.done'))) {
    return '이미 셋업이 끝나 있다'
  }
  return null
}

/** 그 pid가 살아 있나. EPERM은 남의 프로세스라는 뜻이니 살아 있는 것이다. */
function alive(pid) {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return error?.code === 'EPERM'
  }
}

/**
 * 카드에 앉은 한 줄. dispatch.sh와 review.sh, 그리고 워크트리 안의 에이전트가
 * 마디마다 여기에 쓴다("FK에 막힘" 같은 것). 커밋 수가 못 담는 것이 여기 있으므로
 * 알림 본문에 그대로 얹는다.
 */
async function cardComment(orca, path) {
  const shown = await run('orca', ['worktree', 'show', '--worktree', `path:${path}`, '--json'], {
    timeoutMs: 8_000
  })
  try {
    const comment = JSON.parse(shown.out)?.result?.worktree?.comment
    return typeof comment === 'string' ? comment.replace(/\s+/g, ' ').trim() : ''
  } catch (error) {
    // 출력이 예상과 다를 때다. 삼키면 "카드 줄이 안 뜬다"로만 보이고, 그건
    // 도구를 못 찾은 것과 증상이 같아서 활성화 로그로도 안 갈린다.
    orca.log(`카드를 못 읽었다 (${error?.message ?? error}): ${shown.tail.slice(-200)}`)
    return ''
  }
}

/**
 * 셋업이 실패했을 때만 카드에 남긴다. 성공은 안 남긴다. dispatch.sh가 셋업
 * 직후 "에이전트 투입"을 쓰므로, 여기서 성공을 쓰면 둘 중 하나가 상대를 덮는다.
 * 실패는 반대다. 그 줄이 없으면 카드가 투입됐다고만 말하고 status에도 아무
 * 표시가 없어, 빌드가 깨진 워크트리가 멀쩡한 것처럼 보인다.
 *
 * 이미 남의 줄이 앉아 있으면 덮지 않는다. `card`는 필드 단위 덮어쓰기뿐이라
 * 합쳐 쓸 자리가 없어서, 늦게 도착한 우리 줄이 에이전트가 쓴 "FK에 막힘"을
 * 통째로 지운다. 그때는 로그에만 남긴다.
 */
async function stampCard(orca, path, comment) {
  const current = await cardComment(orca, path)
  if (current && current !== comment) {
    orca.log(`카드에 이미 다른 줄이 있어 안 덮는다("${current}"). 남기려던 것: ${comment}`)
    return
  }
  await run(
    'orca',
    ['worktree', 'set', '--worktree', `path:${path}`, '--comment', comment, '--json'],
    { timeoutMs: 8_000 }
  )
}

async function waitForDir(path, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (existsSync(path)) {
      return true
    }
    await new Promise((resolve) => setTimeout(resolve, 500))
  }
  return existsSync(path)
}

const inflight = new Set()

async function runSetup(orca, path, { origin }) {
  // 사람이 누른 커맨드는 조용히 죽으면 안 된다. 눌렀는데 아무 일도 안 일어나면
  // 돌았는지 안 돌았는지 알 방법이 없다. 이벤트는 반대로 조용한 편이 낫다.
  const byHand = origin === 'command'
  /**
   * 물러설 때 부른다. headline이 제목에 그대로 들어간다 -- 물러서는 이유가
   * 기다리면 되는 것(남이 돌고 있다)과 고장난 것(워크트리가 없다)으로 갈리는데,
   * 제목을 하나로 묶어 두면 그 둘이 알림 목록에서 구분되지 않는다.
   */
  const standDown = async (headline, reason, body) => {
    orca.log(`${reason}: ${path}`)
    if (byHand) {
      await notify(orca, `${shortName(path)} — ${headline}`, body ?? reason)
    }
  }

  if (!path) {
    return { ok: false, reason: 'no-path' }
  }
  if (inflight.has(path)) {
    await standDown('셋업이 이미 돌고 있다', '이미 돌고 있다', '끝나면 카드와 알림으로 온다.')
    return { ok: false, reason: 'inflight' }
  }
  if (!(await waitForDir(path, 15_000))) {
    await standDown('셋업할 워크트리가 없다', '워크트리 디렉터리가 안 생겼다', '15초를 기다려도 디렉터리가 안 생겼다.')
    return { ok: false, reason: 'missing' }
  }

  // 프로젝트가 셋업을 끄거나 제 스크립트를 지정했을 수 있다. dispatch.sh 와
  // 같은 설정을 보므로 둘이 다른 것을 돌리는 일이 없다.
  const project = await projectConfigFor(path)
  const setup = project?.data?.setup ?? {}
  if (setup.enabled === false) {
    await standDown(
      '셋업을 껐다',
      '프로젝트가 셋업을 껐다 (setup.enabled=false)',
      `${project.file} 의 setup.enabled 가 false 다.`
    )
    return { ok: true, reason: 'disabled' }
  }
  const script =
    typeof setup.script === 'string' && setup.script
      ? setup.script.startsWith('/')
        ? setup.script
        : join(project.root, setup.script)
      : SETUP_SCRIPT
  if (!existsSync(script)) {
    await standDown('셋업 스크립트가 없다', '셋업 스크립트를 못 찾았다', script)
    return { ok: false, reason: 'no-script' }
  }

  // 표식은 이벤트에만 건다. 커맨드는 "다시 돌리기"라 이미 채워졌어도 돌아야 한다.
  const handled = byHand ? null : await alreadyHandled(orca, path)
  if (handled) {
    orca.log(`${handled}, 건너뛴다: ${path}`)
    return { ok: true, reason: 'handled' }
  }

  const name = shortName(path)
  inflight.add(path)
  orca.log(`setup 시작 (${origin}): ${path} — ${script}`)
  try {
    const result = await run('bash', [script, path], {
      cwd: project?.root,
      timeoutMs: SETUP_WAIT_MS,
      // 셋업은 타임아웃에도 계속 둔다. 죽이면 submodule 클론이 반만 된 채 남는다.
      killOnTimeout: false,
      onLateExit: (code, tail) =>
        orca.log(`늦게 끝난 setup ${code} — ${path}\n${tail}`.slice(0, 8_000))
    })
    orca.log(`setup 결과 ${result.code} — ${path}\n${result.tail}`.slice(0, 8_000))
    await orca.host
      .call('storage.set', {
        key: `setup:${path}`.slice(0, 256),
        value: { at: new Date().toISOString(), code: result.code, timedOut: Boolean(result.timedOut) }
      })
      .catch(() => undefined)

    if (result.timedOut) {
      await stampCard(orca, path, '셋업이 길어진다 — 백그라운드로 계속 돈다')
      await notify(orca, `${name} — 셋업이 길어진다`, '백그라운드로 계속 돈다. 끝날 때까지 빌드는 미룬다.')
    } else if (result.code === SETUP_LOCKED) {
      // 이벤트로 왔으면 조용히 빠진다. 잡고 있는 쪽 화면이 이미 진행을 찍고 있고,
      // dispatch 경로는 위의 claim에서 걸러진 뒤라 여기 오는 것은 사람이 부른 것뿐이다.
      await standDown('셋업은 다른 실행이 돌고 있다', '다른 실행이 잡고 있다', '그 실행이 끝나면 다시 누른다.')
    } else if (result.code === 0) {
      // "not found, skipped"로 넘어간 의존성이 있으면 완료라고만 말하면 안 된다.
      // 그 워크트리는 node_modules 없이 서 있고, 빌드는 나중에 깨진다.
      const skipped = [...result.tail.matchAll(/(\w+) not found, skipped/g)].map((m) => m[1])
      if (skipped.length) {
        await notify(
          orca,
          `${name} — 셋업 완료`,
          `${skipped.join(', ')}를 못 찾아 의존성은 건너뛰었다. 손으로 설치한다.`
        )
      } else if (byHand) {
        // 사람이 누른 것에만 답한다. 워크트리를 만들면 셋업이 도는 것은 정해진
        // 일이라, 될 때마다 우는 알림은 정작 봐야 할 실패까지 같이 흘려보낸다.
        await notify(orca, `${name} — 셋업 완료`, '이제 빌드와 기동이 된다.')
      } else {
        orca.log(`setup 완료, 알림은 안 띄운다: ${path}`)
      }
    } else {
      await stampCard(orca, path, '셋업 실패 — 빌드 전에 손으로 확인한다')
      // 꼬리 개행이 붙은 채로 실으면 본문 끝에 빈 줄이 남는다. 자른 뒤에도 한 번
      // 더 다듬는 것은 400자 경계가 줄 가운데를 지날 수 있어서다.
      const detail = result.tail.trim().slice(-400).trim()
      await notify(orca, `${name} — 셋업 실패`, detail || `종료 코드 ${result.code}`)
    }
    return { ok: result.code === 0, code: result.code, timedOut: Boolean(result.timedOut) }
  } finally {
    inflight.delete(path)
  }
}

/**
 * status.sh --summary 가 표 뒤에 붙여 준 블록을 읽는다. 표 자체는 안 판다 --
 * 칸 너비가 바뀌면 그때마다 깨지는 파서가 되기 때문이다. 블록이 없으면 null이고,
 * 부르는 쪽이 옛 스크립트로 보고 물러선다.
 */
function parseCounts(out) {
  const index = out.lastIndexOf('--- counts')
  if (index < 0) {
    return null
  }
  const counts = {}
  for (const line of out.slice(index).split('\n').slice(1)) {
    const [key, value] = line.split('=')
    if (key && value !== undefined && Number.isFinite(Number(value))) {
      counts[key.trim()] = Number(value)
    }
  }
  return Number.isFinite(counts.worktrees) ? counts : null
}

/**
 * 손이 가야 하는 것만 센다. 멀쩡한 워크트리는 안 적는다 -- 전부 적으면 그중
 * 무엇이 문제인지 다시 골라 읽어야 하고, 그럴 거면 표를 보는 것과 같다.
 */
function summaryBody(counts) {
  const review = [
    counts.review_stale ? `리뷰 낡음 ${counts.review_stale}` : '',
    counts.review_none ? `리뷰 안 함 ${counts.review_none}` : ''
  ].filter(Boolean)
  const work = [
    // 승인 대기가 맨 앞이다. 나머지는 나중에 봐도 되지만 이건 사람이 답할 때까지
    // 그 워크트리가 통째로 멈춰 있는 것이다.
    counts.blocked ? `승인 대기 ${counts.blocked}` : '',
    counts.dirty ? `미커밋 ${counts.dirty}` : '',
    counts.no_terminal ? `터미널 없음 ${counts.no_terminal}` : ''
  ].filter(Boolean)
  const lines = [review.join(', '), work.join(', ')].filter(Boolean)
  return lines.length ? lines.join('\n') : '전부 리뷰까지 닫혔다.'
}

/** 사람이 볼 이유가 있는 상태만 띄운다. working은 조용히 지나간다. */
const NOTIFY_STATES = {
  done: '끝났다',
  waiting: '답을 기다린다',
  blocked: '막혔다'
}

export default function activate(orca) {
  const lastState = new Map()

  orca.events.on('worktree.created', async (payload) => {
    await runSetup(orca, payload?.path, { origin: 'worktree.created' })
  })

  orca.events.on('agent.status.changed', async (payload) => {
    const state = payload?.state
    const paneKey = payload?.paneKey ?? ''
    const previous = lastState.get(paneKey)
    lastState.set(paneKey, state)
    if (previous === state || !NOTIFY_STATES[state]) {
      return
    }
    const path = pathFromWorktreeId(payload?.worktreeId)
    if (!path) {
      await notify(orca, `워크트리 밖 — ${NOTIFY_STATES[state]}`)
      return
    }
    // 카드 줄이 본문의 첫 줄이다. 왜 멈췄는지는 에이전트가 거기 써 뒀고,
    // 리뷰 판정은 그다음이다.
    const [comment, note] = await Promise.all([
      cardComment(orca, path),
      state === 'done' ? reviewNote(path) : Promise.resolve('')
    ])
    const body = [comment, note].filter(Boolean).join('\n')
    await notify(orca, `${shortName(path)} — ${NOTIFY_STATES[state]}`, body)
  })

  /**
   * 셋업을 손으로 다시 돌린다. 30초 안에 안 끝나므로 기다리지 않고 돌려주고,
   * 결과는 알림으로 온다.
   */
  orca.commands.register('setup', async (args) => {
    let path = typeof args?.path === 'string' ? args.path : null
    if (!path) {
      const current = await run('orca', ['worktree', 'current', '--json'], {
        timeoutMs: COMMAND_WAIT_MS
      })
      try {
        path = JSON.parse(current.out)?.result?.worktree?.path ?? null
      } catch {
        path = null
      }
    }
    if (!path) {
      await notify(orca, '셋업할 워크트리를 못 정했다', '워크트리를 하나 열고 다시 부른다.')
      return { started: false }
    }
    void runSetup(orca, path, { origin: 'command' })
    return { started: true, path }
  })

  /** status 표는 로그로 보내고 알림에는 세어 둔 수만 싣는다. */
  orca.commands.register('status', async () => {
    // 워크트리를 안 겨눈 전역 조회라 프로젝트 설정을 고를 근거가 없다.
    // 호스트 설정이 있으면 그것을 읽게 하고(baseBranch 같은 것), 없으면 기본값이다.
    const env = hostConfig ? { ...childEnv(), ORCA_FLOW_ROOT: hostConfig.root } : childEnv()
    const result = await run('bash', [STATUS_SCRIPT, '--summary'], { env, timeoutMs: COMMAND_WAIT_MS })
    orca.log(`status\n${result.tail}`.slice(0, 8_000))
    const missing = existsSync(WORKSPACES) ? '' : ' (워크스페이스 없음)'
    const counts = parseCounts(result.out)
    if (!counts) {
      // status.sh 는 이 플러그인에 같이 실리므로 블록이 없을 이유가 없다.
      // 없으면 스크립트가 중간에 죽은 것이니 표를 싣지 말고 그렇다고 말한다.
      await notify(orca, '워크트리 현황을 못 읽었다', 'status.sh 출력이 예상과 다르다. 플러그인 로그를 본다.')
      return { ok: false }
    }
    if (!counts.worktrees) {
      await notify(orca, `워크트리 현황${missing}`, '떠 있는 워크트리가 없다.')
      return { ok: result.code === 0 }
    }
    await notify(orca, `워크트리 ${counts.worktrees}개${missing}`, summaryBody(counts))
    return { ok: result.code === 0 }
  })

  // PATH를 찍어 둔다. 도구를 못 찾는 것이 이 플러그인의 가장 조용한 고장 방식이라,
  // 뭔가 안 될 때 제일 먼저 볼 줄이 이것이다.
  orca.log(`활성화됨. 셋업 스크립트: ${SETUP_SCRIPT}`)
  orca.log(`호스트 설정: ${hostConfig?.file ?? '없음 (기본값)'}`)
  orca.log(`워크스페이스: ${WORKSPACES} / 리뷰: ${REVIEWS}`)
  orca.log(`자식 PATH: ${childEnv().PATH}`)
  void Promise.all(
    ['orca', 'pnpm', 'uv', 'git'].map((tool) =>
      run('/usr/bin/which', [tool], { timeoutMs: 5_000 }).then(
        (r) => `${tool}=${r.out.trim() || '없음'}`
      )
    )
  ).then((found) => orca.log(`도구: ${found.join(' ')}`))
}
