#!/usr/bin/env node
// Makes the address that agent containers use to reach the OneCLI gateway
// proxy configurable. Upstream's OneCLI gateway provider (installed by the
// /add-onecli skill, src/gateway-providers/onecli.ts) hardcodes
// 'host.docker.internal' in TWO places, and only one of them matters for
// connectivity:
//
//   1. contributionFromConfig() copies config.env verbatim from the gateway
//      service's own container config, whose *_proxy / *_PROXY values point at
//      http://...@host.docker.internal:<port>. THIS is the address agent
//      containers actually dial. (Patched here from v2.)
//   2. networkAccess.endpoint: 'host.docker.internal' is only used for Docker
//      network-policy reconciliation. Patching it alone builds and deploys
//      cleanly and changes nothing — v1 of this patch did exactly that.
//
// On a host where that name resolves, inside a container, to an address that
// refuses connections (confirmed on an OrbStack install: 0.250.250.254, while
// the gateway answered on the Docker bridge IP), every agent model call fails
// with "Connection refused" until the proxy values are rewritten.
//
// Resolution order: process.env.ONECLI_GATEWAY_ENDPOINT, then
// ONECLI_GATEWAY_ENDPOINT in NanoClaw's own .env (read from the service's
// working directory — start-nanoclaw.sh cd's to the install), then
// 'host.docker.internal'. With nothing set, behavior is unchanged.
//
// Usage: node - <install-path> < patch-onecli-endpoint.cjs
// Exit codes: 0 = nothing to do (already at this version, or skipped because
// the file/anchor is absent — says why on stderr), 2 = freshly patched, so
// run.sh rebuilds and restarts. Never exits 1 for a skip: a missing anchor
// must not abort a deploy.
//
// The block is version-marked; bump VERSION whenever BLOCK's text or the
// call site changes, or existing installs keep the stale text forever.
const fs = require('fs');
const path = require('path');

const VERSION = 2;
const installPath = process.argv[2];
if (!installPath) {
  console.error('usage: patch-onecli-endpoint.cjs <install-path>');
  process.exit(1);
}

const target = path.join(installPath, 'src', 'gateway-providers', 'onecli.ts');
if (!fs.existsSync(target)) {
  console.log('ℹ️  OneCLI endpoint patch: src/gateway-providers/onecli.ts not present (OneCLI provider not installed) — nothing to patch.');
  process.exit(0);
}

const START = '// >>> pi-bootstrap:onecli-endpoint v';
const END = '// <<< pi-bootstrap:onecli-endpoint <<<';
const BLOCK = `${START}${VERSION} >>>
import { readFileSync as _pbReadFileSync } from 'node:fs';
function _pbOnecliEndpoint(): string {
  if (process.env.ONECLI_GATEWAY_ENDPOINT) return process.env.ONECLI_GATEWAY_ENDPOINT;
  try {
    const m = _pbReadFileSync(process.cwd() + '/.env', 'utf-8').match(/^ONECLI_GATEWAY_ENDPOINT=(.*)$/m);
    const v = m && m[1].trim().replace(/^['"]|['"]$/g, '');
    if (v) return v;
  } catch {
    // no .env or unreadable: fall through to the upstream default
  }
  return 'host.docker.internal';
}
// Rewrites the proxy values the gateway hands out (HTTPS_PROXY, HTTP_PROXY,
// NO_PROXY and lowercase forms) — see this patch's header for why this, not
// networkAccess.endpoint, is what fixes connectivity.
function _pbRewriteProxyHost(env: Record<string, string>): void {
  const endpoint = _pbOnecliEndpoint();
  if (endpoint === 'host.docker.internal') return;
  for (const [k, v] of Object.entries(env)) {
    if (/proxy/i.test(k) && typeof v === 'string' && v.includes('host.docker.internal')) {
      env[k] = v.split('host.docker.internal').join(endpoint);
    }
  }
}
${END}
`;

const ORIGINAL_ENDPOINT = "endpoint: 'host.docker.internal'";
const PATCHED_ENDPOINT = 'endpoint: _pbOnecliEndpoint()';
const ENV_ANCHOR = 'const env = { ...config.env };';
const CALL_MARK = '// pi-bootstrap:onecli-endpoint call';
const CALL = `  _pbRewriteProxyHost(env); ${CALL_MARK}`;

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const blockRe = new RegExp(`${esc(START)}(\\d+) >>>[\\s\\S]*?${esc(END)}\\n?`);

let content = fs.readFileSync(target, 'utf-8');
const existing = content.match(blockRe);
const upToDate =
  existing && Number(existing[1]) === VERSION && content.includes(PATCHED_ENDPOINT) && content.includes(CALL_MARK);
if (upToDate) {
  console.log(`✅ OneCLI endpoint patch v${VERSION} already applied.`);
  process.exit(0);
}

const notes = [];
let changed = false;

// 1. networkAccess.endpoint (kept for consistency; not what fixes connectivity).
if (content.includes(ORIGINAL_ENDPOINT)) {
  content = content.replace(ORIGINAL_ENDPOINT, PATCHED_ENDPOINT);
  changed = true;
} else if (!content.includes(PATCHED_ENDPOINT)) {
  notes.push("anchor \"endpoint: 'host.docker.internal'\" not found (networkAccess.endpoint left alone)");
}

// 2. The proxy-value rewrite — the part that matters. Needs its call site.
let callOk = content.includes(CALL_MARK);
if (!callOk) {
  const count = content.split(ENV_ANCHOR).length - 1;
  if (count === 1) {
    content = content.replace(ENV_ANCHOR, `${ENV_ANCHOR}\n${CALL}`);
    callOk = true;
    changed = true;
  } else {
    notes.push(`anchor "${ENV_ANCHOR}" found ${count} time(s), expected exactly 1 — the proxy rewrite was NOT applied, so agents keep upstream's proxy address`);
  }
}

// 3. The helper block — only worth having if something calls it or uses it.
if (callOk || content.includes(PATCHED_ENDPOINT)) {
  if (existing) {
    content = content.replace(blockRe, BLOCK);
  } else {
    content = content.replace(/\n*$/, '\n\n') + BLOCK;
  }
  changed = true;
} else {
  console.error(`⚠️  OneCLI endpoint patch SKIPPED: ${notes.join('; ')}. See templates/patch-details/onecli-endpoint.md.`);
  process.exit(0);
}

fs.writeFileSync(target, content);
if (notes.length) {
  console.error(`⚠️  OneCLI endpoint patch v${VERSION} PARTIALLY applied: ${notes.join('; ')}. See templates/patch-details/onecli-endpoint.md.`);
}
console.log(`🩹 OneCLI endpoint patch v${VERSION} applied to src/gateway-providers/onecli.ts (set ONECLI_GATEWAY_ENDPOINT in NanoClaw's .env to override the proxy address).`);
process.exit(changed ? 2 : 0);
