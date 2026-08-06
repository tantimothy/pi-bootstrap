**What this patch is for.** Unlike the other three, this one adds no
feature — Telegram support ships in upstream NanoClaw itself. It exists
purely to repair wiring that upstream has, at least once, deleted out from
under an existing install, and to keep an orphaned leftover from breaking
the build.

**Files it changes.**

| File | What it does |
|---|---|
| `src/channels/index.ts` | restores `import './telegram.js';` when the dependency genuinely resolves; strips it when it does not |
| `dist/channels/index.js` | same, so the change applies without waiting for a rebuild |
| `src/channels/telegram.ts`, `src/channels/telegram.test.ts` | renamed to `*.orphaned-by-pi-bootstrap` when the dependency does not resolve — renamed, never deleted |

**The two distinct failures this handles.** They look similar and have
completely different fixes, so establish which one you have first:

1. **Runtime: the bot goes silently unresponsive after a deploy.** Upstream
   commit `675a6d87` removed the barrel import; a FAST `git pull --ff-only`
   picks that up with no error anywhere, `registerChannelAdapter('telegram',
   ...)` simply stops running, and messages queue up on Telegram's side
   until it is fixed. Nothing logs an error. The fix is restoring the
   import.
2. **Deploy-time: a CLEAN build fails with `Cannot find module
   '@chat-adapter/telegram'`.** Upstream dropped that dependency from
   `package.json` separately, in commit `25687dc`, months after removing the
   channel code. If a locally-run `/add-telegram`-style skill had planted
   its own `src/channels/telegram.ts` on this install, that file is now
   orphaned — and `tsconfig.json` sets `"include": ["src/**/*"]`, so `tsc`
   type-checks it on its mere presence, whether anything imports it or not.
   Nothing in a normal git sync removes it: `reset --hard` only touches
   tracked files, and an untracked file has no tracked counterpart. The fix
   is quarantining the file out of the compile glob, not just fixing
   imports.

**The shape a correct fix has to have.**

- **The dependency guard has to test resolvability, not `package.json`.**
  A real deploy hit a false SKIP because `package.json` genuinely lacked
  `@chat-adapter/telegram` while the package was still fully present in
  pnpm's virtual store (`node_modules/.pnpm/@chat-adapter+telegram@*/`) —
  only the top-level symlink had been pruned. Grepping `package.json` alone
  treats "not listed" and "not resolvable" as the same thing, and they are
  not. The guard therefore checks in order: (1) does the top-level symlink
  exist (`-e` follows the link, so a dangling one correctly fails); (2) if
  not, is the package in the local pnpm store — if so, recreate just the
  symlink; (3) only then fall back to the `package.json` listing, which is
  the only signal available on a fresh install before `pnpm install` has
  ever run.
- **Quarantine, do not delete.** A `.orphaned-by-pi-bootstrap` suffix is
  enough to get the file out of `tsc`'s include glob, and it keeps the file
  recoverable if someone wants to vendor the adapter themselves.
- **Do not trust this manifest's own status line for this patch.** A
  SKIPPED status here does not mean Telegram is broken — it usually means
  the dependency legitimately is not present and the patch correctly did
  nothing. Verify against the actual adapter-initialization line in the
  orchestrator's logs instead:

```
docker logs <orchestrator-container> 2>&1 | grep -i telegram
```

That check exists because a previous session read SKIPPED at face value and
reported a working bot as broken.
