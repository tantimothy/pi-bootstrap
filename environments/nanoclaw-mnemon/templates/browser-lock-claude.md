## Shared browser

The `mcp__browser__*` tools — and `agent-browser connect` / `--cdp` — drive ONE
persistent browser shared by every agent session. Two sessions using it at once
corrupt each other's pages.

- Before the first command that touches the shared browser, run `browser-lock acquire`.
  If it exits non-zero, do not use the shared browser; retry later or tell the user.
- Run `browser-lock release` the moment you are done — also on an early return or error.
- If you do not need its saved logins, use the private `agent-browser open` instead (no lock).
- The lock is advisory and expires after a TTL, so keep the locked section short.
