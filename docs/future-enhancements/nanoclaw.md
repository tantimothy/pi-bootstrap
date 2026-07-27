# NanoClaw Environment — Future Enhancements & Refactoring Opportunities

**Status:** ideas only — none of this is implemented as a fix, just
tracked so an untested assumption doesn't quietly get treated as verified
fact. See `docs/lessons-learned/nanoclaw.md` for this environment's actual
debugging history.

## Future Enhancements

### 1. Live-verify the admin-session tmux wrapper and `CLAUDE_MODEL`

`scripts/open-claude-session.sh`'s host-mode tmux branch and container-mode
`nanoclaw-claude-tmux.sh` wrapper (grouped-session pattern, same mechanism
as the standalone `claude-cli` environment's own login shell and the
sibling `nanoclaw-mnemon` environment's identical `claude-tmux.sh`), plus
`CLAUDE_MODEL` passthrough (`docker run -e` in container mode, direct
`.env` sourcing in host mode), were written and syntax-checked
(`bash -n`) but not exercised against a real deploy in either deploy mode.
Not yet live-confirmed:

- Two simultaneous connections (two terminals running "Open a Claude
  Session," or one plus a direct `docker exec`/`tmux attach`) actually land
  on independent tmux windows sharing one `claude --continue` conversation,
  in both `host` and `container` mode.
- The host-mode fallback to a plain, non-tmux `claude` launch actually
  triggers correctly when `tmux` isn't installed (the expected case on a
  fresh macOS host before this environment does anything to install it).
- `scripts/choose-model.sh` actually carries the new `CLAUDE_MODEL` value
  through to the next session in both modes — container-mode recreation,
  and host-mode's "no restart needed, `.env` is read fresh" claim.

Confirm all three on the first real deploy after this change. If the
grouped-session fallback doesn't behave as documented (e.g.
`destroy-unattached on` not cleaning up a detached grouped session, or the
base session not falling through correctly on a cold start), this needs a
follow-up fix, not just doc corrections. Same caveat applies to the
identical mechanism in the `claude-cli` and `nanoclaw-mnemon` environments
— see their own `docs/future-enhancements/` entries.

**Update — the sibling `nanoclaw-mnemon` environment's first real deploy
surfaced the same three bugs here (container mode is the identical
mechanism):** `deploy.sh`'s own config form dropping `CLAUDE_MODEL` on
redeploy, the admin session's history never actually being persisted, and
an unconfirmed report of a chosen model not taking effect (see
`docs/future-enhancements/nanoclaw-mnemon.md`'s own updated entry and
`docs/lessons-learned/general.md` for the full account). The first two are
fixed here too — `${CONTAINER_NAME}_claude_home` named volume and a
regenerated `/root/CLAUDE.md` in container mode's `run.sh`/
`scripts/entrypoint.sh` — still needing the same live confirmation.
