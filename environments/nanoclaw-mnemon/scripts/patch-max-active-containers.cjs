#!/usr/bin/env node
// Adds an opt-in cap on simultaneously-running agent containers
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
// of a session that is already running.
//
// Resolution: process.env.NANOCLAW_MAX_ACTIVE_CONTAINERS, then the same key in
// NanoClaw's .env (service cwd), else unbounded. Integer 1-64; anything else
// warns and means unbounded. Touches only src/container-runner.ts and does not
// depend on src/config.ts (config.ts is owned by the Ollama patch).
//
// Usage: node - <install-path> < patch-max-active-containers.cjs
// Exit: 0 = nothing to do / skipped (reason on stderr), 2 = freshly patched.
// Bump VERSION whenever BLOCK or the call site changes.
const fs = require('fs');
const path = require('path');

const VERSION = 1;
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
  if (!raw) return 0;
  const n = Number(raw);
  if (Number.isInteger(n) && n >= 1 && n <= 64) return n;
  log.warn('NANOCLAW_MAX_ACTIVE_CONTAINERS=' + raw + ' is not an integer in 1-64; cap disabled');
  return 0;
}
function _pbAtContainerCap(sessionId: string): boolean {
  const cap = _pbMaxActiveContainers();
  if (!cap) return false;
  const live = new Set<string>([...activeContainers.keys(), ...wakePromises.keys()]);
  if (live.size < cap) return false;
  log.info('Deferring container spawn — active-container cap reached', { sessionId, cap, active: live.size });
  return true;
}
${END}
`;

const ANCHOR = '  const promise = spawnContainer(session)\n';
const CALL_MARK = '// pi-bootstrap:max-active-containers call';
const CALL = `  if (_pbAtContainerCap(session.id)) return Promise.resolve(false); ${CALL_MARK}\n`;

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const blockRe = new RegExp(`${esc(START)}(\\d+) >>>[\\s\\S]*?${esc(END)}\\n?`);

let content = fs.readFileSync(target, 'utf-8');
const existing = content.match(blockRe);
if (existing && Number(existing[1]) === VERSION && content.includes(CALL_MARK)) {
  console.log(`✅ Max-active-containers patch v${VERSION} already applied.`);
  process.exit(0);
}
if (!content.includes(CALL_MARK)) {
  const count = content.split(ANCHOR).length - 1;
  if (count !== 1) {
    console.error(
      `⚠️  Max-active-containers patch SKIPPED: anchor "${ANCHOR.trim()}" found ${count} time(s), expected exactly 1 — no cap is enforced. See templates/patch-details/max-active-containers.md.`,
    );
    process.exit(0);
  }
  content = content.replace(ANCHOR, CALL + ANCHOR);
}
if (existing) content = content.replace(blockRe, BLOCK);
else content = content.replace(/\n*$/, '\n\n') + BLOCK;
fs.writeFileSync(target, content);
console.log(`🩹 Max-active-containers patch v${VERSION} applied to src/container-runner.ts (set NANOCLAW_MAX_ACTIVE_CONTAINERS in NanoClaw's .env; unset = unbounded).`);
process.exit(2);
