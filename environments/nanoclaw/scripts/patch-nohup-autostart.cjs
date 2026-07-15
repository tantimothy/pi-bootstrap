#!/usr/bin/env node
// Patches NanoClaw's own setupNohupFallback() (setup/service.ts) to
// actually run the nohup wrapper it generates, not just write it to disk.
//
// On any platform without systemd or launchd — always true in this
// container, since PID 1 is this repo's own entrypoint.sh, not systemd —
// NanoClaw's setup wizard writes start-nanoclaw.sh but never executes it,
// and explicitly reports SERVICE_LOADED: false. Nothing else in its setup
// flow runs that script either (verified directly against its source).
// The wizard's own later steps (e.g. the cli-agent step, which pings
// data/cli.sock) assume the service is already up by the time they run —
// so every fresh setup hits a manual dead end mid-wizard, needing
// start-nanoclaw.sh run by hand before the wizard can proceed.
//
// This is the same root cause run.sh's own post-wizard start-nanoclaw.sh
// call already works around (see run.sh) — that fix runs *after* the
// wizard hands control back, which is too late for the wizard's own
// mid-flow steps that need the service already running. Patching here
// instead means the service is already live by the time any later wizard
// step checks for it, on this same run, with no manual intervention.
//
// Unlike patch-host-gateway.cjs, setup/ scripts run directly via `tsx`
// with no build step — no image/dist rebuild is needed for this to take
// effect, just re-cloning or re-running the wizard.
const fs = require('fs');
const path = require('path');

const installPath = process.argv[2];
if (!installPath) {
  console.error('usage: patch-nohup-autostart.cjs <install-path>');
  process.exit(1);
}

const target = path.join(installPath, 'setup', 'service.ts');
if (!fs.existsSync(target)) {
  console.error(`⚠️  Couldn't find ${target} — NanoClaw's own layout may have changed upstream. Skipping the nohup-autostart patch.`);
  process.exit(0);
}

const SENTINEL = '// pi-bootstrap: nohup-autostart compat patch';
let content = fs.readFileSync(target, 'utf-8');
if (content.includes(SENTINEL)) {
  console.log('✅ nohup-autostart patch already applied.');
  process.exit(0);
}

const oldTail = [
  "  fs.writeFileSync(wrapperPath, wrapper, { mode: 0o755 });",
  "  log.info('Wrote nohup wrapper script', { wrapperPath });",
  "",
  "  emitStatus('SETUP_SERVICE', {",
].join('\n');

if (!content.includes(oldTail)) {
  console.error("⚠️  setupNohupFallback()'s expected body in setup/service.ts has changed upstream. Skipping the nohup-autostart patch — if the setup wizard still hangs on a service that's never running, this is why.");
  process.exit(0);
}

// Built with plain string concatenation, not a template literal, so the
// literal `${...}` in the injected TypeScript (evaluated later, by
// NanoClaw's own process, not by this patcher) can't be mistaken for an
// interpolation in *this* script — that ambiguity is exactly the kind of
// mistake worth avoiding here, not just in the output.
const newTail =
  "  fs.writeFileSync(wrapperPath, wrapper, { mode: 0o755 });\n" +
  "  log.info('Wrote nohup wrapper script', { wrapperPath });\n" +
  "\n" +
  "  " + SENTINEL + "\n" +
  "  // Run it immediately — see this file's own header comment for why\n" +
  "  // writing it alone isn't enough here.\n" +
  "  try {\n" +
  "    execSync('bash ' + JSON.stringify(wrapperPath), { stdio: 'inherit' });\n" +
  "    log.info('Auto-started nohup wrapper', { wrapperPath });\n" +
  "  } catch (err) {\n" +
  "    log.warn('Failed to auto-start nohup wrapper', { err });\n" +
  "  }\n" +
  "\n" +
  "  emitStatus('SETUP_SERVICE', {";

content = content.replace(oldTail, newTail);
fs.writeFileSync(target, content);
console.log('🩹 Patched setup/service.ts: the nohup fallback now starts itself instead of just writing start-nanoclaw.sh and stopping there.');
