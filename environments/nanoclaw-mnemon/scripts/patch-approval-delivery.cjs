#!/usr/bin/env node
// Patches NanoClaw's own requestApproval() (src/modules/approvals/primitive.ts)
// to stop silently dropping approval cards when getDeliveryAdapter() returns
// falsy.
//
// Confirmed against a real, live install: an agent's install_packages
// self-mod approval request was re-issued 3 times over a week and never
// once appeared in the owner's Telegram DM, with no error anywhere in the
// logs — `pending_approvals` rows just sat there forever with status
// 'pending'. The delivery mechanism itself (adapter.deliver(), exercised
// directly against the real chat, twice) was proven completely sound; the
// bug is the `if (adapter) { try {...} catch {...} }` shape upstream of it
// — with no `else`, a falsy adapter (getDeliveryAdapter() returning null)
// skips the whole delivery attempt silently and falls through to the
// function's own final `log.info('Approval requested', ...)`, logging
// apparent success despite never sending anything.
//
// Fix: treat a missing adapter the same as a delivery failure — log an
// error, delete the dangling pending_approvals row, and notify the
// requesting agent — instead of silently no-op'ing. Also persists
// agent_group_id/channel_type/platform_id on the pending_approvals row
// (previously always NULL for this call site, unlike the sibling OneCLI
// credential-approval flow in onecli-approvals.ts, which already sets
// them) — not itself the delivery bug, but worth fixing for the same
// consistency/observability reasons while touching this call.
//
// Same idempotent text-splice + sentinel mechanism as patch-host-gateway.cjs
// (see that file's own header) — src/ files need a rebuild to take effect,
// unlike setup/ (tsx, no build step). Exit codes: 0 = nothing to do
// (already patched, or skipped because the anchor is missing) — 2 = freshly
// patched just now, meaning an existing install (dist/index.js already
// built from the old, unpatched source) needs a rebuild + restart. See
// run.sh for how that exit code is used.
const fs = require('fs');
const path = require('path');

const installPath = process.argv[2];
if (!installPath) {
  console.error('usage: patch-approval-delivery.cjs <install-path>');
  process.exit(1);
}

const target = path.join(installPath, 'src', 'modules', 'approvals', 'primitive.ts');
if (!fs.existsSync(target)) {
  console.error(`⚠️  Couldn't find ${target} — NanoClaw's own layout may have changed upstream. Skipping the approval-delivery patch.`);
  process.exit(0);
}

const SENTINEL = '// pi-bootstrap: approval-delivery silent-failure patch';
let content = fs.readFileSync(target, 'utf-8');
if (content.includes(SENTINEL)) {
  console.log('✅ approval-delivery patch already applied.');
  process.exit(0);
}

// Built with plain string concatenation (array + join), not a template
// literal — same reasoning as patch-nohup-autostart.cjs's own comment: the
// literal `${action}`/`${target.userId}` in the injected TypeScript
// (evaluated later, by NanoClaw's own process) must not be mistaken for an
// interpolation in *this* script.
const oldBlock = [
  '    title,',
  '    options_json: JSON.stringify(normalizedOptions),',
  '    approver_user_id: approverUserId ?? null,',
  '  });',
  '',
  '  const adapter = getDeliveryAdapter();',
  '  if (adapter) {',
  '    try {',
  '      await adapter.deliver(',
  '        target.messagingGroup.channel_type,',
  '        target.messagingGroup.platform_id,',
  '        null,',
  "        'chat-sdk',",
  '        JSON.stringify({',
  "          type: 'ask_question',",
  '          questionId: approvalId,',
  '          title,',
  '          question,',
  '          options: APPROVAL_OPTIONS,',
  '        }),',
  '      );',
  '    } catch (err) {',
  "      log.error('Failed to deliver approval card', { action, approvalId, err });",
  '      // The single delivery target never saw the card — remove the row so it',
  "      // can't linger as a pending approval nobody can act on.",
  '      deletePendingApproval(approvalId);',
  '      notifyAgent(session, `${action} failed: could not deliver approval request to ${target.userId}.`);',
  '      return;',
  '    }',
  '  }',
  '',
  "  log.info('Approval requested', { action, approvalId, agentName, approver: target.userId });",
].join('\n');

if (!content.includes(oldBlock)) {
  console.error("⚠️  requestApproval()'s expected body in src/modules/approvals/primitive.ts has changed upstream. Skipping the approval-delivery patch — if approval cards silently never arrive, this is why.");
  process.exit(0);
}

const newBlock = [
  '    title,',
  '    options_json: JSON.stringify(normalizedOptions),',
  '    approver_user_id: approverUserId ?? null,',
  '    agent_group_id: session.agent_group_id,',
  '    channel_type: target.messagingGroup.channel_type,',
  '    platform_id: target.messagingGroup.platform_id,',
  '  });',
  '',
  '  ' + SENTINEL,
  '  // No delivery adapter means the card can never reach the approver — treat',
  '  // it the same as a delivery failure rather than silently dropping through',
  '  // to the success log below (a prior bug: this left rows stuck \'pending\'',
  '  // forever with no error anywhere and no notification to the requester).',
  '  const adapter = getDeliveryAdapter();',
  '  if (!adapter) {',
  "    log.error('Failed to deliver approval card: no delivery adapter set', { action, approvalId });",
  '    deletePendingApproval(approvalId);',
  '    notifyAgent(session, `${action} failed: could not deliver approval request to ${target.userId}.`);',
  '    return;',
  '  }',
  '',
  '  try {',
  '    await adapter.deliver(',
  '      target.messagingGroup.channel_type,',
  '      target.messagingGroup.platform_id,',
  '      null,',
  "      'chat-sdk',",
  '      JSON.stringify({',
  "        type: 'ask_question',",
  '        questionId: approvalId,',
  '        title,',
  '        question,',
  '        options: APPROVAL_OPTIONS,',
  '      }),',
  '    );',
  '  } catch (err) {',
  "    log.error('Failed to deliver approval card', { action, approvalId, err });",
  '    // The single delivery target never saw the card — remove the row so it',
  "    // can't linger as a pending approval nobody can act on.",
  '    deletePendingApproval(approvalId);',
  '    notifyAgent(session, `${action} failed: could not deliver approval request to ${target.userId}.`);',
  '    return;',
  '  }',
  '',
  "  log.info('Approval requested', { action, approvalId, agentName, approver: target.userId });",
].join('\n');

content = content.replace(oldBlock, newBlock);
fs.writeFileSync(target, content);
console.log('🩹 Patched src/modules/approvals/primitive.ts: a missing delivery adapter now fails loudly (error log + row cleanup + agent notification) instead of silently dropping the approval card and logging apparent success.');
process.exit(2);
