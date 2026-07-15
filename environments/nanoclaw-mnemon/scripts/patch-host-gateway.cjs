#!/usr/bin/env node
// Patches NanoClaw's own hostGatewayArgs() (src/container-runtime.ts) to
// compute the real bridge gateway IP directly instead of trusting Docker's
// `host-gateway` --add-host special value.
//
// Docker's own `host-gateway` convention assumes it resolves to the same
// address as the bridge network's own gateway — true on real bare-metal
// Docker, but not under OrbStack: OrbStack resolves it to its own
// 0.250.250.254 pseudo-address (meant for reaching the real macOS host
// directly), not this bridge network's actual gateway. Every per-group
// agent container NanoClaw spawns relies on that alias to reach the
// OneCLI gateway container (a sibling container, published on the real
// bridge gateway) for credential injection — under OrbStack that alias
// resolves to an address nothing is listening on, so every agent
// container fails outright.
//
// Confirmed directly against a live install: `docker inspect` showed an
// agent container resolving host.docker.internal to 0.250.250.254 while
// the actual bridge gateway was 192.168.215.1 — curl to the real gateway
// worked, curl through the alias didn't. Computing the real gateway
// ourselves is correct on real bare-metal Docker too, since there
// `host-gateway` and the bridge gateway already are the same address —
// this doesn't change behavior there, it just stops trusting a token
// that's specifically broken under OrbStack.
//
// Run once, post-clone, before NanoClaw's own first build (see run.sh) —
// idempotent (checks its own sentinel comment) and non-fatal if
// NanoClaw's source has moved on upstream (warns and leaves the file
// untouched rather than guessing).
const fs = require('fs');
const path = require('path');

const installPath = process.argv[2];
if (!installPath) {
  console.error('usage: patch-host-gateway.cjs <install-path>');
  process.exit(1);
}

const target = path.join(installPath, 'src', 'container-runtime.ts');
if (!fs.existsSync(target)) {
  console.error(`⚠️  Couldn't find ${target} — NanoClaw's own layout may have changed upstream. Skipping the OrbStack host-gateway patch.`);
  process.exit(0);
}

// Exit codes: 0 = nothing to do (already patched, or skipped because the
// file/anchor is missing) — 2 = freshly patched just now. run.sh uses 2 to
// decide whether an existing install (dist/index.js already built from the
// old, unpatched source) needs a rebuild + restart to actually pick this
// up, versus a fresh install where the wizard's own first build already
// will.
const SENTINEL = '// pi-bootstrap: OrbStack host-gateway compat patch';
let content = fs.readFileSync(target, 'utf-8');
if (content.includes(SENTINEL)) {
  console.log('✅ OrbStack host-gateway patch already applied.');
  process.exit(0);
}

const oldFn = `export function hostGatewayArgs(): string[] {
  // On Linux, host.docker.internal isn't built-in — add it explicitly
  if (os.platform() === 'linux') {
    return ['--add-host=host.docker.internal:host-gateway'];
  }
  return [];
}`;

if (!content.includes(oldFn)) {
  console.error("⚠️  hostGatewayArgs()'s expected body in src/container-runtime.ts has changed upstream. Skipping the OrbStack host-gateway patch — if agent containers can't reach the OneCLI gateway under OrbStack, this is why.");
  process.exit(0);
}

const newFn = SENTINEL + `
export function hostGatewayArgs(): string[] {
  // On Linux, host.docker.internal isn't built-in — add it explicitly.
  if (os.platform() === 'linux') {
    // Docker's own host-gateway special value is broken under OrbStack —
    // see this file's own header comment for the full story. Compute the
    // real gateway directly instead of trusting the token.
    try {
      const gw = execSync("ip -4 route show default | awk '{print $3; exit}'", { encoding: 'utf-8' }).trim();
      if (gw) return ['--add-host=host.docker.internal:' + gw];
    } catch {
      // fall through to the token below
    }
    return ['--add-host=host.docker.internal:host-gateway'];
  }
  return [];
}`;

content = content.replace(oldFn, newFn);
fs.writeFileSync(target, content);
console.log("🩹 Patched src/container-runtime.ts: agent containers now reach host.docker.internal via the real bridge gateway, not OrbStack's broken host-gateway token.");
process.exit(2);
