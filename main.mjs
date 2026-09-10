/**
 * Orca 앱에서 워크트리 초기 설정과 에이전트 중단 알림을 처리한다.
 *
 * Git worktree에 없는 .env, submodule, 생성 소스는 bin/worktree-setup.sh로 준비한다.
 * 초기 설정이 빠지면 코드 문제로 오인하기 쉬운 빌드 오류가 발생할 수 있다.
 * orca.yaml 훅은 대상 레포에 커밋해야 하지만, 앱 플러그인은 레포 수정 없이 설치할 수 있다.
 *
 * done, waiting, blocked 상태 변경은 훅 이벤트로 받는다. CLI에 알림 명령이 없어
 * 터미널 출력을 반복 조회하던 방식을 대신한다.
 * 워커는 Electron이 아닌 Node 자식 프로세스이며 PATH, HOME 등 허용된 환경변수만 받는다.
 * 셸의 export 값에 의존할 수 없어 경로 설정은 파일에서 읽는다.
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

/** 이벤트 핸들러의 5분 제한 전에 응답하도록 대기 시간을 정한다. */
const SETUP_WAIT_MS = 4 * 60_000
/** 명령 호출의 30초 제한 전에 응답하도록 조회 시간을 정한다. */
const COMMAND_WAIT_MS = 25_000
/** worktree-setup.sh에서 다른 실행이 잠금을 보유했을 때 반환하는 코드. */
const SETUP_LOCKED = 75
/** 알림과 로그에 표시할 출력 끝부분의 최대 길이. */
const TAIL_MAX = 6_000
/**
 * 프로그램이 읽는 stdout은 별도로 보관한다. 앞부분이 잘리면 JSON 파싱이 실패하거나
 * status 표가 불완전해지므로 알림용 출력보다 큰 상한을 사용한다.
 */
const OUT_MAX = 256 * 1024

// ---------------------------------------------------------------------------
// 설정
// ---------------------------------------------------------------------------

/**
 * bin/config.sh와 같은 규칙으로 .orca-flow.json을 읽는다.
 * ${projectRoot}는 설정 파일이 있는 디렉터리로 치환한다.
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

/** 기준 디렉터리에서 상위로 올라가며 설정을 찾는다. bin/config.sh의 orca_flow_find_root와 같다. */
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
 * 호스트 설정(~/.orca-flow.json)에서 워크트리와 무관한 값을 읽는다.
 * 워크스페이스나 리뷰 경로를 바꾸면 여기도 갱신해야 한다.
 * 워커에는 ORCA_WORKSPACES 같은 셸 환경변수가 전달되지 않는다.
 */
const hostConfig = HOME ? readConfig(HOME) : null
const hostData = hostConfig?.data ?? {}

const expandHome = (value) =>
  typeof value === 'string' && value.startsWith('~/') ? join(HOME, value.slice(2)) : value

const WORKSPACES = expandHome(hostData.workspaces) || join(HOME, 'orca', 'workspaces')
const REVIEWS = expandHome(hostData.reviews) || join(HOME, 'orca', 'reviews')

const ANSI_RE = /\u001b\[[0-9;?]*[a-zA-Z]/g
const stripAnsi = (text) => text.replace(ANSI_RE, '')

/** 배너가 몇 줄만 표시하므로 알림 본문의 줄 수를 제한한다. */
const BODY_LINES = 4

/**
 * 알림에서 렌더링되지 않는 마크다운과 구분선을 제거한다.
 * 비례폭 글꼴에서는 구분선 길이가 일정하지 않다.
 * 빌드 오류가 주로 끝에 있으므로 마지막 몇 줄을 남긴다.
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
 * Finder나 Dock에서 실행한 앱은 launchd 기본 PATH를 사용한다.
 * /usr/bin:/bin:/usr/sbin:/sbin에는 git과 bash가 있지만 orca, pnpm, uv는 없을 수 있다.
 * 이 경우 의존성을 건너뛴 채 코드 0으로 끝나거나 CLI 조회 결과가 비어 있을 수 있다.
 * 호스트 설정의 pathPrepend와 일반적인 도구 경로 중 존재하는 디렉터리를 추가한다.
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
 * 워커가 유휴 5분 뒤 종료돼도 pnpm install이 계속되도록 자식을 detached로 실행한다.
 * 워커 종료 후에는 완료 알림을 보낼 수 없다.
 * 경고가 JSON에 섞이지 않도록 stdout과 stderr를 분리한다.
 * 짧은 조회에는 killOnTimeout을 적용하고 초기 설정은 제한 시간이 지나도 계속 실행한다.
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
      // 시간 제한으로 응답한 뒤 종료된 작업도 로그에 남긴다.
      if (settled) {
        onLateExit?.(code, tail)
        return
      }
      finish({ code, out, tail, timedOut: false })
    })
  })
}

/**
 * 알림 제목은 <워크트리> — <상태> 순서로 작성해 대상을 먼저 확인할 수 있게 한다.
 * 특정 워크트리가 없는 status나 setup 오류는 상태만 표시한다.
 * 본문은 평문이며 비례폭 글꼴을 사용하므로 마크다운 표나 코드 정렬을 사용하지 않는다.
 * status는 집계만 표시하고 배너에서 잘리지 않도록 짧게 작성한다.
 * 에이전트의 카드 문구와 빌드 로그에 포함된 마크다운은 plainBody에서 제거한다.
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

/** 워크트리 id의 <repoId>::<path> 형식에서 경로를 추출한다. */
function pathFromWorktreeId(worktreeId) {
  if (typeof worktreeId !== 'string') {
    return null
  }
  const index = worktreeId.indexOf('::')
  const path = index >= 0 ? worktreeId.slice(index + 2) : ''
  return path.startsWith('/') ? path : null
}

/** <workspaces>/<repo>/<name>에서 repo/name을 추출한다. */
function worktreeLabel(path) {
  if (!path) {
    return null
  }
  const match = /\/workspaces\/([^/]+)\/([^/]+)\/?$/.exec(path)
  return match ? { repo: match[1], name: match[2], label: `${match[1]}/${match[2]}` } : null
}

/**
 * 알림 제목용 이름. 일반적인 형식이 아닌 경로도 마지막 두 구성 요소만 사용한다.
 * 제목은 120자에서 잘리므로 절대 경로 전체를 넣지 않는다.
 */
function shortName(path) {
  if (!path) {
    return '워크트리 밖'
  }
  return worktreeLabel(path)?.label ?? path.split('/').filter(Boolean).slice(-2).join('/')
}

/**
 * 워크트리는 프로젝트 트리 밖에 있으므로 메인 체크아웃에서 상위로 설정을 검색한다.
 * 스크립트의 orca_flow_load와 같은 방식이다.
 */
async function projectConfigFor(path) {
  const listed = await run('git', ['-C', path, 'worktree', 'list', '--porcelain'], {
    timeoutMs: 5_000
  })
  const main = /^worktree (.+)$/m.exec(listed.out)?.[1]
  return main ? findConfig(main) : null
}

/**
 * 리뷰 이후 새 커밋 없이 에이전트가 멈추면 안내한다. 작업이나 커밋 누락을 확인할 수 있다.
 * 첫 dispatch 뒤의 "안 함"과 수정 커밋 뒤의 "낡음"은 반복 안내하지 않는다.
 * 예상 가능한 문구가 카드 내용을 가리지 않도록 리뷰 상태는 status 표에서 확인한다.
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
 * dispatch의 claim 또는 초기 설정 완료 표식이 있으면 이벤트 처리를 생략한다.
 * claim은 워크트리 생성 전에 기록해 플러그인이 먼저 초기 설정을 실행하지 않게 한다.
 * 그렇지 않으면 dispatch가 코드 75를 받고 초기 설정 도중 에이전트를 실행할 수 있다.
 * 표식은 이벤트에서만 검사한다. 사용자의 재실행 요청은 완료 표식이 있어도 처리한다.
 * 동시 실행은 스크립트 내부 잠금이 막으며, 잠금이 있으면 코드 75로 종료한다.
 */
async function alreadyHandled(orca, path) {
  const parts = worktreeLabel(path)
  const claim = parts ? join(REVIEWS, '.claims', `${parts.repo}-${parts.name}`) : null
  if (claim && existsSync(claim)) {
    // dispatch가 SIGKILL로 종료되면 claim이 남을 수 있어 PID를 확인한다.
    // 이름 재사용 시 남은 claim 때문에 초기 설정이 생략되지 않게 한다.
    // 존재 확인과 읽기 사이에 EXIT trap이 파일을 삭제할 수 있어 예외를 처리한다.
    // 읽지 못하면 중복 실행을 피하도록 사용 중인 것으로 취급한다.
    let owner = null
    try {
      owner = Number(readFileSync(claim, 'utf8').trim())
    } catch {
      return 'dispatch.sh에서 처리 중 (claim 읽기 중 파일 삭제)'
    }
    if (!Number.isInteger(owner) || owner <= 0 || alive(owner)) {
      return 'dispatch.sh에서 처리 중'
    }
    orca.log(`종료된 프로세스의 claim 무시: ${claim}`)
  }
  const gitdir = await run('git', ['-C', path, 'rev-parse', '--absolute-git-dir'], {
    timeoutMs: 5_000
  })
  const dir = gitdir.out.trim()
  if (dir && existsSync(join(dir, 'worktree-setup.done'))) {
    return '셋업이 이미 완료됐다'
  }
  return null
}

/** PID가 실행 중인지 확인한다. EPERM도 프로세스가 존재한다는 뜻이다. */
function alive(pid) {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return error?.code === 'EPERM'
  }
}

/**
 * dispatch, review와 에이전트가 작성한 카드 문구를 읽는다.
 * "FK 문제로 중단"처럼 커밋 수에 드러나지 않는 상태를 알림에 표시한다.
 */
async function cardComment(orca, path) {
  const shown = await run('orca', ['worktree', 'show', '--worktree', `path:${path}`, '--json'], {
    timeoutMs: 8_000
  })
  try {
    const comment = JSON.parse(shown.out)?.result?.worktree?.comment
    return typeof comment === 'string' ? comment.replace(/\s+/g, ' ').trim() : ''
  } catch (error) {
    // 파싱 오류를 기록해 카드 조회 실패와 도구 누락을 구분할 수 있게 한다.
    orca.log(`카드 조회 실패 (${error?.message ?? error}): ${shown.tail.slice(-200)}`)
    return ''
  }
}

/**
 * 초기 설정 실패만 카드에 기록한다. 성공 문구는 dispatch의 시작 문구와 덮어쓸 수 있다.
 * 실패를 기록하지 않으면 빌드할 수 없는 워크트리도 정상으로 보인다.
 * 기존 코멘트가 있으면 에이전트의 상태를 지우지 않도록 로그에만 남긴다.
 * 카드 API는 필드 전체를 덮어쓰므로 코멘트를 병합할 수 없다.
 */
async function stampCard(orca, path, comment) {
  const current = await cardComment(orca, path)
  if (current && current !== comment) {
    orca.log(`기존 카드 문구를 유지한다("${current}"). 기록할 문구: ${comment}`)
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
  // 사용자의 명령에는 실행 여부를 알린다. 자동 이벤트는 불필요한 알림을 생략한다.
  const byHand = origin === 'command'
  /**
   * 실행을 생략한 이유를 제목에 표시한다. 다른 실행을 기다리는 경우와
   * 워크트리가 없는 오류를 알림 목록에서 구분할 수 있다.
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
    await standDown('셋업 실행 중', '이미 실행 중', '완료 후 카드와 알림을 확인한다.')
    return { ok: false, reason: 'inflight' }
  }
  if (!(await waitForDir(path, 15_000))) {
    await standDown('초기 설정 대상 워크트리가 없다', '워크트리 디렉터리가 생성되지 않았다', '15초 안에 디렉터리가 생성되지 않았다.')
    return { ok: false, reason: 'missing' }
  }

  // 프로젝트의 초기 설정 활성화 여부와 스크립트를 읽는다. dispatch.sh와 같은 설정을 사용한다.
  const project = await projectConfigFor(path)
  const setup = project?.data?.setup ?? {}
  if (setup.enabled === false) {
    await standDown(
      '셋업이 비활성화됐다',
      '프로젝트에서 셋업을 비활성화했다 (setup.enabled=false)',
      `${project.file}: setup.enabled가 false로 설정되어 있다.`
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
    await standDown('셋업 스크립트가 없다', '셋업 스크립트를 찾지 못했다', script)
    return { ok: false, reason: 'no-script' }
  }

  // 완료 표식은 이벤트에서만 확인한다. 재실행 명령은 완료된 워크트리에서도 실행한다.
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
      // 시간 제한 후에도 초기 설정을 계속 실행해 submodule 클론이 중간에 끊기지 않게 한다.
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
      await stampCard(orca, path, '셋업 대기 시간 초과 — 백그라운드에서 계속 실행 중이다')
      await notify(orca, `${name} — 셋업 대기 시간 초과`, '백그라운드에서 계속 실행 중이다. 완료 후 빌드를 실행한다.')
    } else if (result.code === SETUP_LOCKED) {
      // 진행 상태는 잠금을 보유한 실행이 표시한다. 생성 이벤트는 claim에서 이미
      // 걸러지므로 이 경로에서는 직접 실행한 명령의 중복을 안내한다.
      await standDown('다른 프로세스에서 셋업 실행 중', '다른 프로세스가 잠금 보유 중', '해당 실행이 끝난 뒤 다시 시도한다.')
    } else if (result.code === 0) {
      // 도구 누락으로 의존성을 설치하지 못했다면 초기 설정 완료와 함께 안내한다.
      // 그렇지 않으면 node_modules가 없어 나중에 빌드가 실패할 수 있다.
      const skipped = [...result.tail.matchAll(/(\w+) not found, skipped/g)].map((m) => m[1])
      if (skipped.length) {
        await notify(
          orca,
          `${name} — 셋업 완료`,
          `${skipped.join(', ')} 도구가 없어 의존성 설치를 건너뛰었다. 직접 설치한다.`
        )
      } else if (byHand) {
        // 직접 실행한 경우에만 완료를 알린다. 자동 성공 알림이 반복돼 실패 알림을 놓치지 않게 한다.
        await notify(orca, `${name} — 셋업 완료`, '초기 설정이 완료됐다. 빌드와 실행을 진행한다.')
      } else {
        orca.log(`setup 완료, 알림 생략: ${path}`)
      }
    } else {
      await stampCard(orca, path, '셋업 실패 — 빌드 전에 직접 확인한다')
      // 본문 끝의 빈 줄을 제거한다. 400자 제한으로 줄 중간이 잘릴 수 있어 자른 뒤에도 공백을 정리한다.
      const detail = result.tail.trim().slice(-400).trim()
      await notify(orca, `${name} — 셋업 실패`, detail || `종료 코드 ${result.code}`)
    }
    return { ok: result.code === 0, code: result.code, timedOut: Boolean(result.timedOut) }
  } finally {
    inflight.delete(path)
  }
}

/**
 * status.sh --summary의 집계 블록을 읽는다. 표 너비에 의존하지 않도록 표는 파싱하지 않는다.
 * 블록이 없으면 null을 반환해 이전 형식의 출력이나 실행 실패를 처리하게 한다.
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

/** 확인이 필요한 상태만 집계한다. 전체 상태를 나열하면 문제를 다시 찾아야 하므로 생략한다. */
function summaryBody(counts) {
  const review = [
    counts.review_stale ? `리뷰 낡음 ${counts.review_stale}` : '',
    counts.review_none ? `리뷰 안 함 ${counts.review_none}` : ''
  ].filter(Boolean)
  const work = [
    // 사용자가 응답할 때까지 작업이 멈추므로 승인 대기를 먼저 표시한다.
    counts.blocked ? `승인 대기 ${counts.blocked}` : '',
    counts.dirty ? `미커밋 ${counts.dirty}` : '',
    counts.no_terminal ? `터미널 없음 ${counts.no_terminal}` : ''
  ].filter(Boolean)
  const lines = [review.join(', '), work.join(', ')].filter(Boolean)
  return lines.length ? lines.join('\n') : '모든 워크트리의 리뷰가 완료됐다.'
}

/** 확인이 필요한 상태만 알린다. working은 알리지 않는다. */
const NOTIFY_STATES = {
  done: '작업 완료',
  waiting: '응답 대기',
  blocked: '입력 필요'
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
    // 중단 사유가 담긴 카드 문구를 먼저 표시하고 리뷰 상태를 덧붙인다.
    const [comment, note] = await Promise.all([
      cardComment(orca, path),
      state === 'done' ? reviewNote(path) : Promise.resolve('')
    ])
    const body = [comment, note].filter(Boolean).join('\n')
    await notify(orca, `${shortName(path)} — ${NOTIFY_STATES[state]}`, body)
  })

  /** 초기 설정 재실행은 명령의 30초 제한을 넘길 수 있어 즉시 반환하고 결과는 알림으로 보낸다. */
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
      await notify(orca, '초기 설정 대상 워크트리를 확인할 수 없다', '워크트리를 열고 다시 실행한다.')
      return { started: false }
    }
    void runSetup(orca, path, { origin: 'command' })
    return { started: true, path }
  })

  /** status 표는 로그에 기록하고 알림에는 집계만 표시한다. */
  orca.commands.register('status', async () => {
    // 전역 조회에는 대상 프로젝트가 없으므로 호스트 설정을 사용한다. 없으면 기본값을 사용한다.
    const env = hostConfig ? { ...childEnv(), ORCA_FLOW_ROOT: hostConfig.root } : childEnv()
    const result = await run('bash', [STATUS_SCRIPT, '--summary'], { env, timeoutMs: COMMAND_WAIT_MS })
    orca.log(`status\n${result.tail}`.slice(0, 8_000))
    const missing = existsSync(WORKSPACES) ? '' : ' (워크스페이스 없음)'
    const counts = parseCounts(result.out)
    if (!counts) {
      // 함께 배포하는 status.sh에 집계 블록이 없으면 실행 실패로 보고 로그 확인을 안내한다.
      await notify(orca, '워크트리 현황 조회 실패', 'status.sh 출력이 예상과 다르다. 플러그인 로그를 확인한다.')
      return { ok: false }
    }
    if (!counts.worktrees) {
      await notify(orca, `워크트리 현황${missing}`, '워크트리가 없다.')
      return { ok: result.code === 0 }
    }
    await notify(orca, `워크트리 ${counts.worktrees}개${missing}`, summaryBody(counts))
    return { ok: result.code === 0 }
  })

  // 도구 누락을 진단할 수 있도록 실행 시 PATH를 로그에 남긴다.
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
