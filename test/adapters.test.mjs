// Adapter tests with synthetic fixtures — never touches real agent data.
// Usage: build first (bash scripts/build.sh), then: node --test test/adapters.test.mjs
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'

const ROOT = path.resolve(import.meta.dirname, '..')
const BIN = process.env.AGENT_ISLAND_BIN ||
  [path.join(ROOT, 'build/AgentIsland.app/Contents/MacOS/AgentIsland'), path.join(ROOT, 'test/tmp/AgentIsland')].find(fs.existsSync)
const now = Date.now()
const iso = (ms) => new Date(ms).toISOString()
const home = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-island-'))
const w = (p, s) => { fs.mkdirSync(path.dirname(path.join(home, p)), { recursive: true }); fs.writeFileSync(path.join(home, p), s) }
const jsonl = (rows) => rows.map((r) => JSON.stringify(r)).join('\n') + '\n'
const sql = (db, s) => { fs.mkdirSync(path.dirname(path.join(home, db)), { recursive: true }); execFileSync('sqlite3', [path.join(home, db), s]) }

function snapshot(agents, env = {}) {
  const out = execFileSync(BIN, ['--snapshot', '--home', home, '--agents', agents], { env: { ...process.env, ...env } })
  return JSON.parse(out)
}
const byTitle = (snap) => Object.fromEntries(snap.sessions.map((s) => [s.title, s]))

// ---------- Claude Code ----------
const cl = (type, content, extra = {}) => ({ type, cwd: '/work/web-app', sessionId: 'x', timestamp: iso(now), message: { role: type, content }, ...extra })
w('.claude/projects/-work-web-app/run.jsonl', jsonl([
  cl('user', 'Refactor the login module'),
  cl('assistant', [{ type: 'tool_use', id: 't1', name: 'Bash', input: { command: 'npm test' } }]),
]))
w('.claude/projects/-work-web-app/ask.jsonl', jsonl([
  cl('user', 'Pick a framework'),
  cl('assistant', [{ type: 'tool_use', id: 't2', name: 'AskUserQuestion', input: { questions: [{ question: 'React or Vue?' }] } }]),
]))
w('.claude/projects/-work-web-app/done.jsonl', jsonl([
  cl('user', 'Write the changelog'),
  cl('assistant', [{ type: 'tool_use', id: 't3', name: 'Read', input: {} }]),
  cl('user', [{ type: 'tool_result', tool_use_id: 't3', content: 'ok' }]),
  cl('assistant', [{ type: 'text', text: 'Done.' }], { message: { role: 'assistant', content: [{ type: 'text', text: 'Done.' }], stop_reason: 'end_turn' } }),
]))
w('.claude/projects/-work-web-app/stop.jsonl', jsonl([
  cl('user', 'Long task'),
  cl('user', [{ type: 'text', text: '[Request interrupted by user]' }]),
]))

test('claude code: running / waiting / done / stopped', () => {
  const s = byTitle(snapshot('claude'))
  assert.equal(s['Refactor the login module'].state, 'running')
  assert.equal(s['Pick a framework'].state, 'waiting')
  assert.equal(s['Pick a framework'].question, 'React or Vue?')
  assert.equal(s['Write the changelog'].state, 'done')
  assert.equal(s['Long task'].state, 'stopped')
  assert.equal(s['Write the changelog'].project, 'web-app')
  assert.equal(s['Write the changelog'].host, 'terminal')
})

// ---------- Codex ----------
const d = new Date(now)
const day = [d.getFullYear(), String(d.getMonth() + 1).padStart(2, '0'), String(d.getDate()).padStart(2, '0')].join('/')
const cx = (type, payload) => ({ timestamp: iso(now), type, payload })
const meta = (id, origin = 'codex_cli_rs') => cx('session_meta', { id, cwd: '/work/api', originator: origin, source: 'cli' })
const rollout = (name) => '.codex/sessions/' + day + '/rollout-' + name + '.jsonl'
w(rollout('a'), jsonl([meta('a'), cx('event_msg', { type: 'user_message', message: 'Add unit tests' }), cx('event_msg', { type: 'task_started' })]))
w(rollout('b'), jsonl([meta('b'), cx('event_msg', { type: 'user_message', message: 'Fix lint' }), cx('event_msg', { type: 'task_started' }), cx('event_msg', { type: 'task_complete' })]))
w(rollout('c'), jsonl([meta('c'), cx('event_msg', { type: 'user_message', message: 'Delete build dir' }), cx('event_msg', { type: 'task_started' }), cx('event_msg', { type: 'exec_approval_request', command: ['rm', '-rf', 'build'] })]))
w(rollout('d'), jsonl([meta('d', 'codex_vscode'), cx('event_msg', { type: 'user_message', message: 'Abort me' }), cx('event_msg', { type: 'turn_aborted', reason: 'interrupted' })]))

test('codex: running / done / waiting / stopped + host', () => {
  const s = byTitle(snapshot('codex'))
  assert.equal(s['Add unit tests'].state, 'running')
  assert.equal(s['Fix lint'].state, 'done')
  assert.equal(s['Delete build dir'].state, 'waiting')
  assert.match(s['Delete build dir'].question, /等你批准/)
  assert.equal(s['Abort me'].state, 'stopped')
  assert.equal(s['Abort me'].host, 'editor')
})

// ---------- Kimi Code ----------
const kimiSession = (sid, title, events) => {
  w('.kimi-code/sessions/wd_demo/' + sid + '/state.json', JSON.stringify({ id: sid, cwd: '/work/deck', title, updatedAt: now, archived: false }))
  w('.kimi-code/server/events/' + sid + '.jsonl', jsonl(events.map((e, i) => ({ kind: 'event', seq: i + 1, envelope: { type: e.type, payload: e } }))))
}
const wc = (busy, pending = 'none', reason) => ({ type: 'event.session.work_changed', busy, pending_interaction: pending, last_turn_reason: reason })
kimiSession('session_run', 'Kimi running', [wc(true)])
kimiSession('session_ok', 'Kimi done', [wc(true), wc(false, 'none', 'completed')])
kimiSession('session_ask', 'Kimi approval', [wc(true), { type: 'permission.approval.requested', toolName: 'Bash', action: 'Running: rm -rf dist' }, wc(true, 'approval')])
kimiSession('session_bad', 'Kimi failed', [wc(true), wc(false, 'none', 'failed')])
// real Kimi order: the question request is journaled right AFTER the state change
kimiSession('session_q', 'Kimi question', [wc(true), wc(true, 'question'), { type: 'event.question.requested', questions: [{ id: 'q_0', question: 'Cats or dogs?' }] }])
w('.kimi-code/server/instances/x.json', JSON.stringify({ pid: 1, heartbeat_at: now }))

test('kimi code: running / done / waiting (approval text) / failed', () => {
  const s = byTitle(snapshot('kimi'))
  assert.equal(s['Kimi running'].state, 'running')
  assert.equal(s['Kimi done'].state, 'done')
  assert.equal(s['Kimi approval'].state, 'waiting')
  assert.equal(s['Kimi approval'].question, '等你批准：Running: rm -rf dist')
  assert.equal(s['Kimi failed'].state, 'failed')
  assert.equal(s['Kimi question'].state, 'waiting')
  assert.equal(s['Kimi question'].question, 'Cats or dogs?')
})

test('kimi code: busy session with a dead app counts as stopped', () => {
  w('.kimi-code/server/instances/x.json', JSON.stringify({ pid: 999999, heartbeat_at: now - 3600e3 }))
  const s = byTitle(snapshot('kimi'))
  assert.equal(s['Kimi running'].state, 'stopped')
  w('.kimi-code/server/instances/x.json', JSON.stringify({ pid: 1, heartbeat_at: now }))
})

// ---------- ZCode ----------
sql('.zcode/v2/tasks-index.sqlite', "CREATE TABLE tasks (workspace_key TEXT, workspace_path TEXT, task_id TEXT, title TEXT, task_status TEXT, " +
  "updated_at INTEGER, archived INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0, cron_automation_id TEXT, meta_json TEXT DEFAULT '{}');" +
  "INSERT INTO tasks (workspace_key, workspace_path, task_id, title, task_status, updated_at) VALUES " +
  "('k','/work/game','sess_1','ZCode running','running'," + now + ")," +
  "('k','/work/game','sess_2','ZCode done','completed'," + now + ")," +
  "('k','/work/game','sess_3','ZCode asks','running'," + now + ")," +
  "('k','/work/game','sess_4','ZCode error','error'," + now + ")," +
  "('k','/work/game','sess_5','ZCode leftover','running'," + (now - 48 * 3600e3) + ");")
sql('.zcode/cli/db/db.sqlite', "CREATE TABLE part (id TEXT, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);" +
  "INSERT INTO part VALUES ('p','m','sess_3'," + now + "," + now + ",'" +
  JSON.stringify({ type: 'tool', tool: 'AskUserQuestion', state: { status: 'running', input: { questions: [{ question: 'Cats or dogs?' }] } } }) + "');")

test('zcode: running / done / waiting / failed, leftovers hidden', () => {
  const s = byTitle(snapshot('zcode', { AGENT_ISLAND_ZCODE_RUNNING: '1' }))
  assert.equal(s['ZCode running'].state, 'running')
  assert.equal(s['ZCode done'].state, 'done')
  assert.equal(s['ZCode asks'].state, 'waiting')
  assert.equal(s['ZCode asks'].question, 'Cats or dogs?')
  assert.equal(s['ZCode error'].state, 'failed')
  assert.equal(s['ZCode leftover'], undefined)
})

test('zcode: app not running → running tasks are stopped', () => {
  const s = byTitle(snapshot('zcode', { AGENT_ISLAND_ZCODE_RUNNING: '0' }))
  assert.equal(s['ZCode running'].state, 'stopped')
})

// ---------- MiniMax Code ----------
sql('.minimax/v2/sqlite/runtime-state.sqlite', "CREATE TABLE local_runtime_sessions (session_id TEXT, title TEXT, status TEXT, project_workspace_dir TEXT, " +
  "workspace_dir TEXT, is_default_workspace INTEGER, updated_at_ms INTEGER, visibility TEXT, session_kind TEXT, parent_session_id TEXT, archived INTEGER);" +
  "CREATE TABLE questionnaire_requests (session_id TEXT, status TEXT, answered_at INTEGER, dismissed_at INTEGER, created_at INTEGER, request_json TEXT);" +
  "INSERT INTO local_runtime_sessions VALUES ('m1','MCode running','started','/work/landing',NULL,0," + now + ",'visible','chat',NULL,0)," +
  "('m2','MCode asks','started','/work/landing',NULL,0," + now + ",'visible','chat',NULL,0);" +
  "INSERT INTO questionnaire_requests VALUES ('m2','pending',NULL,NULL," + now + ",'{\"steps\":[{\"question\":\"Ship it?\"}]}');")

test('minimax code: running / waiting', () => {
  const s = byTitle(snapshot('mcode'))
  assert.equal(s['MCode running'].state, 'running')
  assert.equal(s['MCode asks'].state, 'waiting')
  assert.equal(s['MCode asks'].question, 'Ship it?')
})

test('all agents merged, waiting first, ids namespaced', () => {
  const snap = snapshot('claude,codex,kimi,zcode,mcode', { AGENT_ISLAND_ZCODE_RUNNING: '1' })
  assert.deepEqual([...snap.agents].sort(), ['claude', 'codex', 'kimi', 'mcode', 'zcode'])
  // ids stay unique across agents
  assert.equal(snap.sessions[0].state, 'waiting')
  assert.ok(snap.sessions.every((s) => s.id.startsWith(s.agent + ':')))
  assert.deepEqual(snap.issues, {})
})

// ---------- Icons ----------
const icons = (agents, env = {}, dir) => JSON.parse(execFileSync(BIN, ['--icons', ...(dir ? [dir] : []), '--agents', agents], { env: { ...process.env, ...env } }))
const pngSize = (p) => { const b = fs.readFileSync(p); return [b.readUInt32BE(16), b.readUInt32BE(20)] }

test('icons: monogram fallback when no app icon is available, PNGs written', () => {
  const out = path.join(home, 'icons-out')
  const list = icons('claude,codex,kimi,zcode,mcode', { AGENT_ISLAND_NO_APP_ICONS: '1', AGENT_ISLAND_ICON_DIR: path.join(home, 'none'), AGENT_ISLAND_FETCHED_ICON_DIR: path.join(home, 'none2') }, out)
  assert.deepEqual(list.map((i) => i.source), ['monogram', 'monogram', 'monogram', 'monogram', 'monogram'])
  for (const i of list) assert.deepEqual(pngSize(path.join(out, i.agent + '.png')), [128, 128])
})

test('icons: user override wins over everything', () => {
  const dir = path.join(home, 'icon-override')
  fs.mkdirSync(dir, { recursive: true })
  fs.copyFileSync(path.join(home, 'icons-out', 'kimi.png'), path.join(dir, 'zcode.png'))
  const list = icons('kimi,zcode', { AGENT_ISLAND_NO_APP_ICONS: '1', AGENT_ISLAND_ICON_DIR: dir, AGENT_ISLAND_FETCHED_ICON_DIR: path.join(home, 'none2') })
  assert.equal(list.find((i) => i.agent === 'zcode').source, 'override')
  assert.equal(list.find((i) => i.agent === 'kimi').source, 'monogram')
})

// Real apps on this Mac (skipped when Kimi Code / ZCode are not installed)
for (const [id, app] of [['kimi', '/Applications/Kimi Code.app'], ['zcode', '/Applications/ZCode.app']]) {
  test('icons: ' + id + ' uses the installed app icon', { skip: !fs.existsSync(app) && app + ' not installed' }, () => {
    const i = icons(id, { AGENT_ISLAND_ICON_DIR: path.join(home, 'none') })[0]
    assert.equal(i.source, 'app')
    assert.equal(i.path, app)
  })
}

// ---------- DeepSeek Harness (formats from deepseek-ai/deepseek-harness snapshots) ----------
const dshEv = (type, data) => ({ type, data })
const dshSession = (proj, sid, events, { zstd = false, depth = 0 } = {}) => {
  const lines = [{ type: 'session', version: 4, id: sid, createdAt: now, cwd: '/work/' + proj, isSeeded: false, delegationDepth: depth }, ...events]
  const rel = '.dsh/sessions/' + proj + '/' + sid + '/session.v4.jsonl'
  if (!zstd) return w(rel, jsonl(lines))
  // one zstd frame per append, like dsh does
  const file = path.join(home, rel + '.zstd')
  fs.mkdirSync(path.dirname(file), { recursive: true })
  const frames = lines.map((l) => execFileSync(ZSTD, ['-cq'], { input: JSON.stringify(l) + '\n' }))
  fs.writeFileSync(file, Buffer.concat(frames))
}
const ZSTD = ['/opt/homebrew/bin/zstd', '/usr/local/bin/zstd'].find(fs.existsSync)
dshSession('app', 'run', [dshEv('session/title', { title: 'DSH running' }), dshEv('turn/start', { turn: 1 })])
dshSession('app', 'ok', [dshEv('session/title', { title: 'DSH done' }), dshEv('turn/start', { turn: 1 }), dshEv('turn/end', { reason: { kind: 'completed' } })])
dshSession('app', 'err', [dshEv('session/title', { title: 'DSH error' }), dshEv('turn/start', { turn: 1 }), dshEv('turn/end', { reason: { kind: 'error', error: { message: 'HTTP 401' } } })])
dshSession('app', 'abort', [dshEv('session/title', { title: 'DSH aborted' }), dshEv('turn/start', { turn: 1 }), dshEv('turn/end', { reason: { kind: 'aborted', reason: { kind: 'user' } } })])
dshSession('app', 'appr', [dshEv('session/title', { title: 'DSH approval' }), dshEv('turn/start', { turn: 1 }),
  dshEv('approval/asked', { id: 'a1', toolName: 'run_code', reason: 'escalate sandbox to workspace-write' })])
dshSession('app', 'ask', [dshEv('session/title', { title: 'DSH ask' }), dshEv('turn/start', { turn: 1 }),
  dshEv('tool/call', { callId: 'c1', name: 'ask_user_question', arguments: JSON.stringify({ questions: [{ id: 'q', question: 'Which color?' }] }) })])
dshSession('app', 'answered', [dshEv('session/title', { title: 'DSH answered' }), dshEv('turn/start', { turn: 1 }),
  dshEv('approval/asked', { id: 'a2', toolName: 'bash' }), dshEv('approval/decided', { id: 'a2', outcome: 'allowed-once' })])
dshSession('app', 'child', [dshEv('session/title', { title: 'DSH child' }), dshEv('turn/start', { turn: 1 })], { depth: 1 })
if (ZSTD) dshSession('app', 'z', [dshEv('session/title', { title: 'DSH zstd' }), dshEv('turn/start', { turn: 1 }), dshEv('turn/end', { reason: { kind: 'completed' } })], { zstd: true })

test('deepseek harness: running / done / failed / stopped / waiting, sub-agents hidden', () => {
  const s = byTitle(snapshot('dsh'))
  assert.equal(s['DSH running'].state, 'running')
  assert.equal(s['DSH done'].state, 'done')
  assert.equal(s['DSH error'].state, 'failed')
  assert.equal(s['DSH aborted'].state, 'stopped')
  assert.equal(s['DSH approval'].state, 'waiting')
  assert.equal(s['DSH approval'].question, '等你批准：escalate sandbox to workspace-write')
  assert.equal(s['DSH ask'].question, 'Which color?')
  assert.equal(s['DSH answered'].state, 'running')
  assert.equal(s['DSH child'], undefined)
  assert.equal(s['DSH done'].project, 'app')
})

test('deepseek harness: zstd-compressed logs (one frame per append)', { skip: !ZSTD && 'zstd CLI not installed' }, () => {
  const s = byTitle(snapshot('dsh'))
  assert.equal(s['DSH zstd'].state, 'done')
})

// ---------- Gemini CLI (formats from google-gemini/gemini-cli chatRecordingService) ----------
const gm = (slug, name, rows) => w('.gemini/tmp/' + slug + '/chats/session-2026-10-27T12-00-' + name + '.jsonl', jsonl(rows))
w('.gemini/projects.json', JSON.stringify({ projects: { '/work/site': 'site' } }))
const gmeta = (id) => ({ sessionId: id, projectHash: 'h', startTime: iso(now), lastUpdated: iso(now), kind: 'main' })
const gmsg = (id, type, content, toolCalls) => ({ id, timestamp: iso(now), type, content, ...(toolCalls ? { toolCalls } : {}) })
gm('site', 'a', [gmeta('a'), gmsg('1', 'user', [{ text: 'Gemini running' }]), gmsg('2', 'gemini', '', [{ id: 't', name: 'run_shell_command', args: {}, status: 'executing' }])])
gm('site', 'b', [gmeta('b'), gmsg('1', 'user', [{ text: 'Gemini approval' }]), gmsg('2', 'gemini', '', [{ id: 't', name: 'write_file', displayName: 'WriteFile', args: {}, status: 'awaiting_approval' }])])
gm('site', 'c', [gmeta('c'), gmsg('1', 'user', [{ text: 'Gemini ask' }]), gmsg('2', 'gemini', '', [{ id: 't', name: 'ask_user', args: { questions: [{ question: 'Tabs or spaces?' }] }, status: 'executing' }])])
gm('site', 'd', [gmeta('d'), gmsg('1', 'user', [{ text: 'Gemini error' }]), gmsg('2', 'error', 'quota exceeded')])
// the same message id re-appended with updated tool status: last line wins
gm('site', 'e', [gmeta('e'), gmsg('1', 'user', [{ text: 'Gemini rewritten' }]),
  gmsg('2', 'gemini', '', [{ id: 't', name: 'write_file', args: {}, status: 'awaiting_approval' }]),
  gmsg('2', 'gemini', '', [{ id: 't', name: 'write_file', args: {}, status: 'executing' }])])

test('gemini cli: running / waiting (approval + ask_user) / failed, last line per id wins', () => {
  const s = byTitle(snapshot('gemini'))
  assert.equal(s['Gemini running'].state, 'running')
  assert.equal(s['Gemini approval'].state, 'waiting')
  assert.equal(s['Gemini approval'].question, '等你批准：WriteFile')
  assert.equal(s['Gemini ask'].question, 'Tabs or spaces?')
  assert.equal(s['Gemini error'].state, 'failed')
  assert.equal(s['Gemini rewritten'].state, 'running')
  assert.equal(s['Gemini running'].project, 'site')
  assert.equal(s['Gemini running'].ws, '/work/site')
})

// ---------- Qwen Code (formats from QwenLM/qwen-code chatRecordingService) ----------
const qr = (type, extra = {}) => ({ uuid: Math.random().toString(36).slice(2), parentUuid: null, sessionId: 's', timestamp: iso(now), type, cwd: '/work/qwen-app', ...extra })
const qtext = (role, text) => ({ message: { role, parts: [{ text }] } })
w('.qwen/projects/-work-qwen-app/chats/q1.jsonl', jsonl([qr('user', qtext('user', 'Qwen running')), qr('assistant', { message: { role: 'model', parts: [{ functionCall: { id: 'f1', name: 'run_shell_command', args: {} } }] } })]))
w('.qwen/projects/-work-qwen-app/chats/q2.jsonl', jsonl([qr('user', qtext('user', 'Qwen done')), qr('assistant', qtext('model', 'ok')), qr('system', { subtype: 'turn_result', systemPayload: { promptId: 'p', state: 'completed', endedAt: now } })]))
w('.qwen/projects/-work-qwen-app/chats/q3.jsonl', jsonl([qr('user', qtext('user', 'Qwen cancelled')), qr('system', { subtype: 'turn_result', systemPayload: { promptId: 'p', state: 'cancelled', endedAt: now } })]))
w('.qwen/projects/-work-qwen-app/chats/q4.jsonl', jsonl([qr('user', qtext('user', 'Qwen error')), qr('system', { subtype: 'turn_result', systemPayload: { promptId: 'p', state: 'error', endedAt: now, error: { message: 'x' } } })]))
w('.qwen/projects/-work-qwen-app/chats/q5.jsonl', jsonl([qr('user', qtext('user', 'Qwen ask')), qr('assistant', { message: { role: 'model', parts: [{ functionCall: { id: 'f2', name: 'ask_user_question', args: { questions: [{ question: 'Deploy now?' }] } } }] } })]))

test('qwen code: running / done / stopped / failed / waiting', () => {
  const s = byTitle(snapshot('qwen'))
  assert.equal(s['Qwen running'].state, 'running')
  assert.equal(s['Qwen done'].state, 'done')
  assert.equal(s['Qwen cancelled'].state, 'stopped')
  assert.equal(s['Qwen error'].state, 'failed')
  assert.equal(s['Qwen ask'].state, 'waiting')
  assert.equal(s['Qwen ask'].question, 'Deploy now?')
  assert.equal(s['Qwen done'].project, 'qwen-app')
})

// ---------- OpenCode (schema from sst/opencode packages/core/src/session/sql.ts) ----------
sql('.local/share/opencode/opencode.db', "CREATE TABLE session_v2 (id TEXT, parent_id TEXT, title TEXT, directory TEXT, time_created INTEGER, time_updated INTEGER, " +
  "time_idle INTEGER, idle_outcome TEXT, time_archived INTEGER);" +
  "INSERT INTO session_v2 VALUES ('o1',NULL,'OC running','/work/oc'," + now + "," + now + ",NULL,NULL,NULL)," +
  "('o2',NULL,'OC done','/work/oc'," + now + "," + (now - 5000) + "," + now + ",'succeeded',NULL)," +
  "('o3',NULL,'OC failed','/work/oc'," + now + "," + (now - 5000) + "," + now + ",'failed',NULL)," +
  "('o4',NULL,'OC interrupted','/work/oc'," + now + "," + (now - 5000) + "," + now + ",'interrupted',NULL)," +
  "('o5',NULL,'OC busy again','/work/oc'," + now + "," + now + "," + (now - 60000) + ",'succeeded',NULL)," +
  "('o6','o1','OC child','/work/oc'," + now + "," + now + ",NULL,NULL,NULL);")

test('opencode (session_v2): running / done / failed / stopped, children hidden', () => {
  const s = byTitle(snapshot('opencode'))
  assert.equal(s['OC running'].state, 'running')
  assert.equal(s['OC done'].state, 'done')
  assert.equal(s['OC failed'].state, 'failed')
  assert.equal(s['OC interrupted'].state, 'stopped')
  assert.equal(s['OC busy again'].state, 'running')
  assert.equal(s['OC child'], undefined)
})

// ---------- Notch ownership & version ----------
test('notch: a running notch app is reported as a conflict', () => {
  const out = JSON.parse(execFileSync(BIN, ['--conflicts'], { env: { ...process.env, AGENT_ISLAND_FAKE_CONFLICT: 'OtherIsland' } }))
  assert.equal(out.conflicts[0].name, 'OtherIsland')
  assert.ok('owns' in out && Array.isArray(out.suspended))
})

test('version string carries build and commit', () => {
  const v = execFileSync(BIN, ['--version']).toString().trim()
  assert.match(v, /^\d+\.\d+\.\d+ \(build \d+(\.\d+)?, [0-9a-z]+\)$|^dev \(build 0, local\)$/)
})

test.after(() => fs.rmSync(home, { recursive: true, force: true }))
