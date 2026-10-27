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
w('.kimi-code/server/instances/x.json', JSON.stringify({ pid: 1, heartbeat_at: now }))

test('kimi code: running / done / waiting (approval text) / failed', () => {
  const s = byTitle(snapshot('kimi'))
  assert.equal(s['Kimi running'].state, 'running')
  assert.equal(s['Kimi done'].state, 'done')
  assert.equal(s['Kimi approval'].state, 'waiting')
  assert.equal(s['Kimi approval'].question, '等你批准：Running: rm -rf dist')
  assert.equal(s['Kimi failed'].state, 'failed')
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
  assert.equal(snap.sessions[0].state, 'waiting')
  assert.ok(snap.sessions.every((s) => s.id.startsWith(s.agent + ':')))
  assert.deepEqual(snap.issues, {})
})

test.after(() => fs.rmSync(home, { recursive: true, force: true }))
