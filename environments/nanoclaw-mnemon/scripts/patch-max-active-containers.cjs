#!/usr/bin/env node
// Caps simultaneously-running agent containers (default 4) and lets an incoming
// chat preempt a running task container when the cap is full
// (NANOCLAW_MAX_ACTIVE_CONTAINERS). RECONCILE_CONCURRENCY alone does not bound
// this: reconcileSession() -> wakeContainer() returns as soon as a spawn is
// requested, so even 2 sweep workers drain a backlog of due sessions in
// seconds while the containers they spawned keep running for minutes. On a host
// where each container is CPU-heavy that starved OneCLI's own API, NanoClaw
// declared the gateway unavailable and killed every session, in a loop (see
// docs/lessons-learned/nanoclaw-mnemon.md, 2026-11-02 second session).
//
// wakeContainer() gets one early return, placed after the "already running" and
// "wake already in flight" short-circuits and before spawnContainer(): when the
// number of distinct sessions that are running OR mid-spawn is at the cap, it
// logs and returns false. The caller ignores the value, so the due message is
// untouched (no tries penalty, no backoff) and the next sweep tick retries.
// Already-running containers are never killed or counted against a new spawn
// of a session that is already running, except that a chat wake at the cap
// kills the longest-running task container (thread_id 'system:tasks:*') and
// respawns the chat on its exit. Task wakes defer for 90s after a chat was
// refused. src/reconcile-session.ts skips the tries++ reset once for a
// preempted session. v1 -> v2 upgrades replace the call site in place.
//
// Resolution: process.env.NANOCLAW_MAX_ACTIVE_CONTAINERS, then the same key in
// NanoClaw's .env (service cwd), else 4. Integer 1-64; 0 disables the cap;
// anything else warns and uses 4. Touches src/container-runner.ts (+ one line pair in
// src/reconcile-session.ts) and does not
// depend on src/config.ts (config.ts is owned by the Ollama patch).
//
// Usage: node - <install-path> < patch-max-active-containers.cjs
// Exit: 0 = nothing to do / skipped (reason on stderr), 2 = freshly patched.
// Bump VERSION whenever BLOCK or the call site changes.
const fs = require('fs');
const path = require('path');

const VERSION = 3;
const installPath = process.argv[2];
if (!installPath) {
  console.error('usage: patch-max-active-containers.cjs <install-path>');
  process.exit(1);
}
const target = path.join(installPath, 'src', 'container-runner.ts');
if (!fs.existsSync(target)) {
  console.log('ℹ️  Max-active-containers patch: src/container-runner.ts not present — nothing to patch.');
  process.exit(0);
}

const START = '// >>> pi-bootstrap:max-active-containers v';
const END = '// <<< pi-bootstrap:max-active-containers <<<';
const BLOCK = `${START}${VERSION} >>>
import { readFileSync as _pbReadFileSync } from 'node:fs';
function _pbMaxActiveContainers(): number {
  let raw = process.env.NANOCLAW_MAX_ACTIVE_CONTAINERS || '';
  if (!raw) {
    try {
      const m = _pbReadFileSync(process.cwd() + '/.env', 'utf-8').match(/^NANOCLAW_MAX_ACTIVE_CONTAINERS=(.*)$/m);
      raw = (m && m[1].trim().replace(/^['"]|['"]$/g, '')) || '';
    } catch {
      // no .env or unreadable: unbounded
    }
  }
  if (!raw) return 4;
  if (raw === '0') return 0;
  const n = Number(raw);
  if (Number.isInteger(n) && n >= 1 && n <= 64) return n;
  log.warn('NANOCLAW_MAX_ACTIVE_CONTAINERS=' + raw + ' is not an integer in 0-64; using 4');
  return 4;
}
const _pbTaskSessions = new Set<string>();
const _pbPreempted = new Set<string>();
const _pbPendingChats = new Set<string>();
let _pbChatWaitingAt = 0;
export function _pbConsumePreempted(sessionId: string): boolean {
  return _pbPreempted.delete(sessionId);
}
function _pbAtContainerCap(session: Session): boolean {
  const cap = _pbMaxActiveContainers();
  if (!cap) return false;
  const sessionId = session.id;
  const isTask = !!session.thread_id && session.thread_id.startsWith('system:tasks:');
  if (isTask) _pbTaskSessions.add(sessionId);
  const live = new Set<string>([...activeContainers.keys(), ...wakePromises.keys()]);
  if (isTask) {
    if (Date.now() - _pbChatWaitingAt < 90_000) {
      log.info('Deferring task spawn — chat waiting', { sessionId, cap, active: live.size });
      return true;
    }
    if (live.size < cap) return false;
    log.info('Deferring container spawn — active-container cap reached', { sessionId, cap, active: live.size });
    return true;
  }
  if (live.size < cap) {
    _pbChatWaitingAt = 0;
    return false;
  }
  if (_pbPendingChats.has(sessionId)) return true;
  _pbChatWaitingAt = Date.now();
  let victim: string | undefined;
  let oldest = Infinity;
  for (const [id, rt] of activeContainers) {
    if (!_pbTaskSessions.has(id) || _pbPreempted.has(id)) continue;
    if (rt.startedAtMs < oldest) {
      oldest = rt.startedAtMs;
      victim = id;
    }
  }
  if (!victim) {
    log.info('Deferring chat spawn — cap reached, no task container to preempt', { sessionId, cap, active: live.size });
    return true;
  }
  _pbPreempted.add(victim);
  _pbPendingChats.add(sessionId);
  log.info('Preempting task container for chat', { sessionId, victim, cap, active: live.size });
  killContainer(victim, 'preempted-by-chat', () => {
    _pbPendingChats.delete(sessionId);
    void wakeContainer(session);
  });
  return true;
}
${END}
`;

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const ANCHOR = '  const promise = spawnContainer(session)\n';
const CALL_MARK = '// pi-bootstrap:max-active-containers call';
const CALL = `  if (_pbAtContainerCap(session)) return Promise.resolve(false); ${CALL_MARK}\n`;
const CALL_RE = new RegExp(`^.*${esc(CALL_MARK)}\\n`, 'm');

// Second sub-patch: src/reconcile-session.ts skips the tries++ reset for a
// session whose container was just preempted, so preemption never counts
// toward MAX_TRIES. Applied only when the container-runner block (which
// exports _pbConsumePreempted) is in place.
const RS_IMPORT = "import { getContainerStartedAtMs, isContainerRunning, killContainer } from './container-runner.js';";
const RS_IMPORT_NEW = "import { getContainerStartedAtMs, isContainerRunning, killContainer, _pbConsumePreempted } from './container-runner.js';";
const RS_ANCHOR = "    resetStuckProcessingRows(mailbox, mailbox, session, 'container not running');";
const RS_NEW = "    if (!_pbConsumePreempted(session.id)) resetStuckProcessingRows(mailbox, mailbox, session, 'container not running'); // pi-bootstrap:max-active-containers preempt";
function patchReconcileSession() {
  const rs = path.join(installPath, 'src', 'reconcile-session.ts');
  if (!fs.existsSync(rs)) return 'missing';
  let c = fs.readFileSync(rs, 'utf-8');
  if (c.includes('pi-bootstrap:max-active-containers preempt')) return 'already';
  if (c.split(RS_IMPORT).length - 1 !== 1 || c.split(RS_ANCHOR).length - 1 !== 1) return 'anchor';
  c = c.replace(RS_IMPORT, RS_IMPORT_NEW).replace(RS_ANCHOR, RS_NEW);
  fs.writeFileSync(rs, c);
  return 'applied';
}

const blockRe = new RegExp(`${esc(START)}(\\d+) >>>[\\s\\S]*?${esc(END)}\\n?`);

let content = fs.readFileSync(target, 'utf-8');
const existing = content.match(blockRe);
const blockCurrent = !!existing && Number(existing[1]) === VERSION;
const callCurrent = content.includes(CALL);
let changed = false;
if (!blockCurrent || !callCurrent) {
  if (content.includes(CALL_MARK)) {
    content = content.replace(CALL_RE, CALL);
  } else {
    const count = content.split(ANCHOR).length - 1;
    if (count !== 1) {
      console.error(
        `⚠️  Max-active-containers patch SKIPPED: anchor "${ANCHOR.trim()}" found ${count} time(s), expected exactly 1 — no cap is enforced. See templates/patch-details/max-active-containers.md.`,
      );
      process.exit(0);
    }
    content = content.replace(ANCHOR, CALL + ANCHOR);
  }
  if (existing) content = content.replace(blockRe, () => BLOCK);
  else content = content.replace(/\n*$/, '\n\n') + BLOCK;
  fs.writeFileSync(target, content);
  changed = true;
}
const rs = patchReconcileSession();
if (rs === 'applied') changed = true;
const rsNote =
  rs === 'applied' || rs === 'already'
    ? 'preempted tasks do not count a try'
    : `⚠️  reconcile-session sub-patch ${rs}: a preempted task counts one try (see templates/patch-details/max-active-containers.md)`;
if (!changed) {
  console.log(`✅ Max-active-containers patch v${VERSION} already applied (${rsNote}).`);
  process.exit(0);
}
console.log(`🩹 Max-active-containers patch v${VERSION} applied (default cap 4, chats preempt tasks; ${rsNote}).`);
process.exit(2);
