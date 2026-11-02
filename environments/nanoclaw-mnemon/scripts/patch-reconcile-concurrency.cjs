#!/usr/bin/env node
// Makes the host sweep's reconcile fan-out configurable. Upstream's
// src/host-sweep.ts hardcodes `export const RECONCILE_CONCURRENCY = 8;`, sized
// (per its own comment) for cheap, network-bound reconciles. On an install
// where many scheduled tasks share one cron slot, each "reconcile" is a full
// agent container doing real tool-use work: 8 at once saturated an 8-core host,
// starved the OneCLI gateway's own Postgres, made /v1/agents time out, and
// NanoClaw then killed every session with reason="gateway-unavailable" — a
// self-sustaining thrash (see docs/lessons-learned/nanoclaw-mnemon.md).
//
// Resolution order: process.env.NANOCLAW_RECONCILE_CONCURRENCY, then the same
// key in NanoClaw's own .env (read from the service's working directory, as
// patch-onecli-endpoint.cjs does), then 8. Integer 1-64; anything else falls
// back to 8 with a warning. Unset = unchanged behavior.
//
// Deliberately touches ONLY src/host-sweep.ts. The admin session's original
// hand fix also edited src/config.ts, but that file is owned by the Ollama
// patch and excluded from CLEAN's local-edit snapshot, so such an edit would be
// lost while a reapplied host-sweep.ts still imported the missing export.
//
// Usage: node - <install-path> < patch-reconcile-concurrency.cjs
// Exit: 0 = nothing to do (up to date, or skipped — reason on stderr),
// 2 = freshly patched (run.sh rebuilds + restarts). Never 1 for a skip.
//
// Version-marked block: bump VERSION whenever BLOCK's text changes.
const fs = require('fs');
const path = require('path');

const VERSION = 1;
const installPath = process.argv[2];
if (!installPath) {
  console.error('usage: patch-reconcile-concurrency.cjs <install-path>');
  process.exit(1);
}

const target = path.join(installPath, 'src', 'host-sweep.ts');
if (!fs.existsSync(target)) {
  console.log('ℹ️  Reconcile-concurrency patch: src/host-sweep.ts not present — nothing to patch.');
  process.exit(0);
}

const START = '// >>> pi-bootstrap:reconcile-concurrency v';
const END = '// <<< pi-bootstrap:reconcile-concurrency <<<';
const ANCHOR = 'export const RECONCILE_CONCURRENCY = 8;';
const BLOCK = `${START}${VERSION} >>>
import { readFileSync as _pbReadFileSync } from 'node:fs';
export const RECONCILE_CONCURRENCY: number = (() => {
  const DEFAULT = 8;
  let raw = process.env.NANOCLAW_RECONCILE_CONCURRENCY || '';
  if (!raw) {
    try {
      const m = _pbReadFileSync(process.cwd() + '/.env', 'utf-8').match(/^NANOCLAW_RECONCILE_CONCURRENCY=(.*)$/m);
      raw = (m && m[1].trim().replace(/^['"]|['"]$/g, '')) || '';
    } catch {
      // no .env or unreadable: fall through to the upstream default
    }
  }
  if (!raw) return DEFAULT;
  const n = Number(raw);
  if (Number.isInteger(n) && n >= 1 && n <= 64) return n;
  console.warn('NANOCLAW_RECONCILE_CONCURRENCY=' + raw + ' is not an integer in 1-64; using ' + DEFAULT);
  return DEFAULT;
})();
${END}
`;

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const blockRe = new RegExp(`${esc(START)}(\\d+) >>>[\\s\\S]*?${esc(END)}\\n?`);

let content = fs.readFileSync(target, 'utf-8');
const existing = content.match(blockRe);
if (existing && Number(existing[1]) === VERSION) {
  console.log(`✅ Reconcile-concurrency patch v${VERSION} already applied.`);
  process.exit(0);
}
if (existing) {
  content = content.replace(blockRe, BLOCK);
} else {
  const count = content.split(ANCHOR).length - 1;
  if (count !== 1) {
    console.error(
      `⚠️  Reconcile-concurrency patch SKIPPED: anchor "${ANCHOR}" found ${count} time(s), expected exactly 1 (already hand-edited, or upstream changed it) — fan-out stays at whatever the file says. See templates/patch-details/reconcile-concurrency.md.`,
    );
    process.exit(0);
  }
  content = content.replace(ANCHOR, BLOCK.replace(/\n$/, ''));
}
fs.writeFileSync(target, content);
console.log(`🩹 Reconcile-concurrency patch v${VERSION} applied to src/host-sweep.ts (set NANOCLAW_RECONCILE_CONCURRENCY in NanoClaw's .env; default 8).`);
process.exit(2);
