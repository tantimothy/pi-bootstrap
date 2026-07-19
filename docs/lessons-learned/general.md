# General Lessons Learned

Cross-cutting things discovered the hard way while working on this repo —
kept separate from any single environment's own file in this directory
because they generalize beyond it (git workflow, `lib/*.sh` internals,
documentation practice), not because they're a lower tier of finding. Add
to this file when something costs real debugging time and would save it
for the next person (or agent) who hits the same shape of problem; don't
add routine bug fixes here, those belong in the relevant environment's own
README/commit history, or that environment's own file in this directory
(e.g. `claude-cli.md`, `nanoclaw-mnemon.md`) if it's a real debugging
session specific to one environment.

---

## A long-lived feature branch can silently diverge from `master` between your *own* PR merges

**What happened:** this repo's workflow restarts a working branch from
`master` only after *that branch's own* PR merges. Multiple times this
session, a *different* branch (a sibling PR, working on `claude-cli`'s
multi-instance support, or `mac-terminal-setup`, or a `desktop-lib.sh`
`.webloc` fix) merged into `master` while this branch was mid-task. Since
nothing about "my own PR merged" was true yet, the branch never picked
those commits up on its own — `git log`/`git diff` against `origin/master`
showed real, unrelated content the branch was missing, discovered only by
explicitly fetching and diffing before pushing, not by assuming the
branch was current.

**The lesson:** before pushing a batch of work — not just after your own
PR merges — `git fetch origin master && git diff --stat HEAD
origin/master` to check what else has landed. A clean `git merge
origin/master` is cheap and safe when there are no real conflicts (as it
was every time this session); catching the divergence *before* opening a
PR is much cheaper than discovering it from a confused diff after the
fact.

---

## Grep for content, but also just `ls` the directory — an established convention can be missed by a single search pattern

**What happened:** asked whether "future enhancements" documentation
existed anywhere in this repo, a content grep for the literal phrase
across `*.md` files came back empty — but `docs/future-enhancements/`
already existed as an established directory convention (two substantial
design docs in it), just never containing that exact phrase in running
text. The initial "no, nothing like that exists" answer was wrong.

**The lesson:** a targeted content grep answers "does this exact phrase
appear," not "does this concept have a home." For "is there already a
place for X," check the directory structure itself (`ls docs/`, `find . -iname
'*<topic>*'`) before concluding a convention doesn't exist — cheaper than
being wrong, and this repo in particular tends to already have a
convention for most documentation needs.

---

## `docker compose up -d` picks up a changed `.env` value without a rebuild

**Useful, not a mistake:** Compose recreates a container when its
*resolved* config (including `${VAR}`-interpolated environment values from
`.env`) differs from what's currently running — confirmed directly while
building `scripts/point-to-gateway.sh`/`scripts/revert-to-claude.sh` for
`claude-cli`. Writing a new value into `.env` and running `docker compose
up -d` (exactly what `deploy.sh`'s `FAST` policy already does) is enough
to apply an environment-variable-only change; no `CLEAN`/rebuild needed.
Worth remembering before reaching for a heavier redeploy path for a
config-only change.

---

## A `${VAR}`-expansion helper applied to "some" fields is easy to mistake for "all" fields

**What happened:** `lib/desktop-lib.sh`'s `_load_desktop_entries_yaml` only
ran `_yaml_expand` on `entries[].target` — `menu.id`, `entries[].id`, and
`info.id` were read as plain literals, even though the function's own doc
comment claimed "any string value may contain `${VAR}` markers." That gap
is exactly what caused `claude-cli`'s desktop-entry IDs to collide across
instances: two copies of the environment both wrote the same `.desktop`
filenames, silently overwriting each other's shortcuts. The same category
of bug turned up independently in `lib/info-lib.sh`'s `_load_info_yaml`
moments later: `named_volumes[].name` wasn't expanded either, even though
every sibling field in that same function (`data_dirs`, `install_dirs`,
`wipe_parent_dirs`) was — meaning `INFO`/`WIPE`/`backup.sh` for a second
`claude-cli` instance would have silently operated on the *first*
instance's `claude_home`/`ssh_host_keys` volumes instead of its own.

**The lesson:** a loader function's own doc comment describing its
contract ("any string value supports `${VAR}`") is aspirational, not
verified — it describes intent, not necessarily every field's actual
implementation. When adding a new templated field to a schema like this,
re-read the loader's *code* field by field rather than trusting its
comment; and when fixing one field's missing expansion, check every
sibling field pulled by the same function for the identical gap — this
exact omission happened twice, independently, in two different loaders
within one session.

---

## A YAML field with no matching code in the "obvious" file might still be read somewhere else entirely

**What happened:** `info.yaml`'s `custom_actions` field was declared
unused/dead after grepping `lib/info-lib.sh` (the file that owns
`info.yaml`'s documented schema) and finding no reference to it. That was
wrong — `deploy.sh` itself reads `custom_actions` directly, independent of
`lib/info-lib.sh`, and surfaces each entry as a real, interactive item in
its own policy menu (tagged `ACTION_<index>`, alongside FAST/STOP/CLEAN/
etc.). The mistake led to building a new feature (`claude-cli`'s "create a
new instance" action) as an XDG desktop entry instead — a real, working,
but strictly worse fit for this repo's SSH-first, headless-friendly usage
— and then having to redo that work once the field's actual behavior came
to light.

**The lesson:** one YAML file can have more than one independent consumer
(`info.yaml` is read by both `lib/info-lib.sh` *and* `deploy.sh` here).
Before calling any field dead, grep the *whole* repo for its name, not
just the file that conventionally "should" own it — the same failure mode
as this doc's "grep for content, but also just `ls` the directory" entry
above, just one layer deeper (missing a consumer, not missing a
directory).

---

## Pushing more commits to an already-merged PR's branch does not get them into `master`

**What happened:** two follow-up commits (a `deploy.sh` keyboard-shortcut
fix, and moving `claude-cli`'s new-instance action into `custom_actions`)
were pushed to `claude/multiple-claude-cli-configs-9pw0ws` *after* that
branch's own PR had already merged, with `head.sha` frozen at an earlier
commit. Both commits sat on `origin` indefinitely, invisible to `master`
and to anyone pulling it — not because of a bug, just because a merged PR
is done, and pushing more to its branch doesn't reopen or re-merge it.
Diagnosed only by explicitly running `git merge-base --is-ancestor
<commit> origin/master` for each suspect commit, after the user reported
not seeing either change on their own machine.

**The lesson:** after any PR merges, check whether its branch is still a
valid place to keep committing — it isn't. The fix (already this repo's
own stated workflow, easy to forget mid-task) is to restart the branch
from the new `master` tip, rebase any not-yet-merged commits onto it, and
open a *new* PR — never keep pushing to a branch whose PR already shows
`merged: true`. Related to, but sharper than, this doc's "long-lived
feature branch can silently diverge" entry above: that one is about a
branch falling *behind* `master`; this one is about continuing to *commit*
to a branch that's already fully landed and closed.
