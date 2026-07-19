# Generalizing `claude-cli`'s Multi-Instance Pattern to Other Environments

**Status:** design idea — not implemented beyond `claude-cli`. No other
environment has actually been evaluated for whether this pattern fits its
own constraints; this doc only claims the mechanism isn't inherently
`claude-cli`-specific, not that any particular other environment needs it.

## Problem

Several environments in this repo could plausibly want more than one
independently-running copy — `dragonos-sdr` for two different attached SDR
devices, `nanoclaw`/`nanoclaw-mnemon` for separate conversation-group
deployments, `llm-gateways` for more than one gateway configuration. But
the `${CONTAINER_NAME}`-templating trick that makes two `claude-cli`
instances not collide (named volumes, desktop-entry IDs, `custom_actions`
labels) and the `new-instance.sh` wizard that automates creating one were
both built bespoke to `claude-cli`. Nothing about either is
`claude-cli`-specific in principle, but nothing generalizes them either —
a second environment wanting the same capability today means re-copying
`new-instance.sh` line-by-line and independently re-discovering every
place its own YAML files need `${CONTAINER_NAME}` expansion, the same way
that coverage was found missing (twice, independently) for `claude-cli`
itself (see `docs/lessons-learned.md`'s `${VAR}`-expansion entry).

## Current state (what actually exists today, specific to `claude-cli`)

- **`docker-compose.yml`**'s named volumes: `${CONTAINER_NAME:-claude-cli}_claude_home`
  / `_ssh_host_keys` — Compose's own `${VAR}` substitution, nothing
  `lib/*.sh`-specific.
- **`desktop-entries.yaml`**'s `menu.id`/`entries[].id`/`info.id`:
  `${CONTAINER_NAME:-claude-cli}`-expanded via `lib/desktop-lib.sh`'s
  `_load_desktop_entries_yaml`.
- **`info.yaml`**'s `named_volumes[].name`: same expansion, via
  `lib/info-lib.sh`'s `_load_info_yaml`.
- **`new-instance.sh`**: a self-contained wizard — prompts for an instance
  name/SSH port/workspace path, copies the environment folder, writes the
  new `.env`, registers the copy in `config/environments.yaml`, deploys it
  via `lib/deploy-lib.sh`'s `deploy_environment`, and installs its own
  desktop entries.
- **`info.yaml`**'s `custom_actions`: the actual surfaced entry point —
  `deploy.sh` lists "New Claude CLI Instance..." in `claude-cli`'s own
  policy menu.

## Proposed generalization

1. **Document the `${CONTAINER_NAME}`-templating convention by name** in
   `docs/environment-yaml-schemas.md` — a "multi-instance-safe fields"
   section listing exactly which fields (named volumes, desktop-entry IDs,
   `container_name:` itself) need it, so a new environment author applies
   it from the start instead of discovering the gap only after someone
   actually tries to run two copies — which is how it was found for
   `claude-cli` in the first place.
2. **Extract only the genuinely environment-agnostic part of
   `new-instance.sh`** — the copy + `.env`-write + `config/environments.yaml`-
   registration + deploy + desktop-install skeleton — into a small shared
   helper (e.g. `lib/new-instance-lib.sh`), parameterized by which `.env`
   keys to prompt for. The deploy and desktop-install steps are *already*
   fully generic (`deploy_environment`/`lib/run-install-desktop.sh` both
   already take an arbitrary `env_dir`); only the copy/`.env`/registration
   logic is currently duplicated-by-hand if a second environment wanted
   this.
3. **Leave the prompting logic itself per-environment.** Each
   environment's `.env.example` fields genuinely differ (`claude-cli`
   needs `SSH_PORT`/`CLAUDE_WORKSPACE_PATH`; `dragonos-sdr` would need
   something entirely different, e.g. a specific USB device path) — a
   shared wizard can't sensibly guess what to prompt for without becoming
   a generic `.env.example`-driven form (already exists, as `deploy.sh`'s
   own bulk form compiler) rather than a purpose-built one.

## Sketch of what would change in this repo

- `docs/environment-yaml-schemas.md` gains a short "multi-instance-safe
  fields" section, cross-referenced from both `info.yaml`'s and
  `desktop-entries.yaml`'s existing schema sections.
- `lib/new-instance-lib.sh` (new): `_new_instance_copy_and_register()`
  taking `template_dir`, `new_name`, and an associative-array-like list of
  `.env` key/value pairs to write — returns the new instance's absolute
  path. `environments/claude-cli/new-instance.sh` becomes a thin wrapper:
  its own prompts, then a call into this helper, then the existing
  deploy/desktop-install calls.
- A second environment adopting this would add its own `new-instance.sh`
  (its own prompts, calling the shared helper) plus a `custom_actions`
  entry in its own `info.yaml` pointing at it — no changes to `deploy.sh`
  or the shared libs beyond what step 2 above already added once.

## Open questions for whoever picks this up

- **Should `${CONTAINER_NAME}`-templating be checked, not just
  documented?** It was missed twice, independently, in one session, even
  by the person who'd just introduced the pattern for the first field. A
  lint step (e.g. flagging a literal `claude_home`/`claude-cli`-shaped
  string in a YAML field that has a `${CONTAINER_NAME}`-templated sibling
  elsewhere in the same file) might catch this class of bug earlier than
  "someone tries a second instance and something silently collides" —
  worth designing once there's a second real environment to validate the
  check against, not from one example.
- **Whether extracting `lib/new-instance-lib.sh` is worth it before a
  second environment actually needs it** — matching this repo's own
  stated bar in `docs/refactoring-opportunities.md` ("needs one more real
  use case before the right abstraction is obvious"). This doc exists so
  that when that second use case shows up, the shape of the extraction
  doesn't need re-deriving from scratch.
- **Which environments would actually benefit** — not evaluated here.
  `dragonos-sdr`/`nanoclaw`/`llm-gateways` are named above only as
  plausible candidates by shape (each *could* want more than one
  instance), not as environments anyone has confirmed actually want this.
