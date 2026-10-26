#!/usr/bin/env node
// Makes the OneCLI gateway endpoint that NanoClaw hands to agent containers
// configurable. Upstream's OneCLI gateway provider (installed by the
// /add-onecli skill, src/gateway-providers/onecli.ts) hardcodes
//   endpoint: 'host.docker.internal'
// with no override, unlike the adjacent ONECLI_GATEWAY_CONTAINER. On a host
// where that name resolves to an address nothing listens on (confirmed on an
// OrbStack install: agent containers retried the model API forever while the
// gateway was reachable on the Docker bridge IP), there is no way to fix it
// short of hand-editing skill-owned source — which the next CLEAN reverts.
//
// Resolution order after this patch: process.env.ONECLI_GATEWAY_ENDPOINT,
// then ONECLI_GATEWAY_ENDPOINT in NanoClaw's own .env (read from the
// service's working directory — start-nanoclaw.sh cd's to the install),
// then the original 'host.docker.internal'. Behavior is unchanged unless the
// variable is set.
//
// Usage: node - <install-path> < patch-onecli-endpoint.cjs
// Exit codes: 0 = nothing to do (already at this version, or skipped because
// the file/anchor is absent — says why on stderr), 2 = freshly patched, so
// run.sh rebuilds and restarts. Never exits 1 for a skip: a missing anchor
// must not abort a deploy.
//
// The block is version-marked; bump VERSION whenever BLOCK's text changes,
// or existing installs keep the stale text forever.
const fs = require('fs');
const path = require('path');

const VERSION = 1;
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
${END}
`;

let content = fs.readFileSync(target, 'utf-8');
const ORIGINAL = "endpoint: 'host.docker.internal'";
const PATCHED = 'endpoint: _pbOnecliEndpoint()';

const blockRe = new RegExp(`${START.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(\\d+) >>>[\\s\\S]*?${END.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\n?`);
const existing = content.match(blockRe);

if (existing && Number(existing[1]) === VERSION && content.includes(PATCHED)) {
  console.log(`✅ OneCLI endpoint patch v${VERSION} already applied.`);
  process.exit(0);
}

if (!existing && !content.includes(ORIGINAL)) {
  console.error("⚠️  OneCLI endpoint patch SKIPPED: the anchor \"endpoint: 'host.docker.internal'\" is not in src/gateway-providers/onecli.ts (upstream changed it). Agent containers keep whatever endpoint upstream hardcodes; see templates/patch-details/onecli-endpoint.md.");
  process.exit(0);
}

if (existing) {
  // Stale generation: replace the block in place; the call site is unchanged.
  content = content.replace(blockRe, BLOCK).replace(ORIGINAL, PATCHED);
} else {
  content = content.replace(ORIGINAL, PATCHED);
  content = content.replace(/\n*$/, '\n\n') + BLOCK;
}
fs.writeFileSync(target, content);
console.log(`🩹 OneCLI endpoint patch v${VERSION} applied to src/gateway-providers/onecli.ts (set ONECLI_GATEWAY_ENDPOINT in NanoClaw's .env to override the endpoint).`);
process.exit(2);
