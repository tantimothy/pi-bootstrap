# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A pure-bash TUI (`deploy.sh`, using `dialog`) for deploying and managing Docker-based "environments" on a Raspberry Pi (and, increasingly, macOS) — each environment is a self-contained folder under `environments/`. No package manager, no build step, no test framework — the codebase is bash scripts + YAML.

## Commands

There is no build/lint/test suite. Verification in this repo is:

```bash
bash -n path/to/script.sh                                   # syntax-check a shell script (the de facto "test" used throughout)
python3 -c "import yaml; yaml.safe_load(open('file.yaml'))" # sanity-check a YAML file parses
yq eval '.some.path' environments/<env>/info.yaml            # query/validate YAML — MUST be go-yq (mikefarah/yq), not the
                                                              # Debian/Ubuntu-packaged Python yq; deploy.sh installs the real
                                                              # one to /usr/local/bin/yq ahead of it on $PATH
docker compose config                                        # validate a docker-compose.yml + .env resolves correctly
./deploy.sh                                                  # the actual entry point — interactive TUI
./install-desktop-entries.sh [--uninstall]                   # (Linux only) register/remove desktop menu entries for all deployed environments
./backup.sh [--no-env] [-o DIR]                               # archive every deployed environment's data + .env
./restore.sh <archive.tar.gz> [<env-name>|all]
./check-updates.sh [--apply]                                  # scan running containers for available image updates
```

No CI exists. Docker-based environments have no automated build validation — issues in a Dockerfile/entrypoint are generally caught by an actual `docker compose build`/`up`, not statically.

## Architecture

### Two deploy archetypes, picked by file presence

`deploy.sh` scans `environments/<name>/` and picks the first match:
1. **`run.sh`** — a custom script, full control. Required when something needs host-level config outside Docker, an interactive attach/reattach session, dynamic container spawning, or CLEAN rollback snapshotting. Must never hardcode `docker` (use `DOCKER=${DOCKER_CMD:-docker}`), must source `.env` with `set -a; source .env; set +a`, must `mkdir -p` volume paths before `docker run`.
2. **`docker-compose.yml`** — generic fallback, no `run.sh` needed. Driven by `lib/deploy-lib.sh`'s shared `deploy_environment()` (also reused by `check-updates.sh --apply`). Primary service's `container_name:` must be `${CONTAINER_NAME:-default}`; every other service in a multi-service stack gets `${CONTAINER_NAME:+${CONTAINER_NAME}-}servicename`.

A third option — a bare `Dockerfile` with neither of the above — is recognized by `lib/deploy-lib.sh` but is a data-loss trap (no `-v` flag on the `docker run` it generates) and nothing in this repo uses it; treat "just a Dockerfile" as "write a one-service `docker-compose.yml` with `build: .`" instead.

Every environment gets a `REBUILD_POLICY` of `FAST` (default — reconcile/reattach without pulling fresh images), `CLEAN` (build/pull *before* touching what's running, so a failed build leaves the old container untouched), `STOP`, `TEARDOWN`, `INFO`, or `WIPE`.

### The `lib/` dispatcher layer

Two YAML files exist per environment for data that's needed regardless of which deploy archetype it uses — **every caller goes through a dispatcher**, never a per-environment path directly:

- `info.yaml` → `lib/run-info.sh <env_dir> <action>` → environment's own `info.sh` override if present, else `lib/info-lib.sh`'s `run_info_yaml`. Drives the post-deploy summary, `INFO`/`WIPE` policies, and `backup.sh`'s manifest (which dirs/volumes to archive).
- `desktop-entries.yaml` → `lib/run-install-desktop.sh <env_dir> [--uninstall]` → environment's own `install-desktop.sh` override if present, else `lib/desktop-lib.sh`'s `run_desktop_install_yaml`. Registers XDG desktop entries (Linux only — no-ops cleanly on macOS).

An `info.sh`/`install-desktop.sh` override only exists where real branching can't be expressed as static YAML (OS-dependent values, feature-flag-gated fields) — it calls the `_load_*_yaml` loader for everything static, overrides just the one dynamic piece, then calls the shared `run_info`/`run_desktop_install` function directly. Only `nanoclaw` and `internet-pi` currently need one.

Both YAML files share a `${VAR}`/`${VAR:-default}` substitution mechanism (resolved against `.env` if present, plus synthetic `SCRIPT_DIR`/`HOST_IP`/`ENV_DIR` — **`.env.example` itself is never sourced**, so every marker needs its own explicit default). Full field-by-field schema for both files: `docs/environment-yaml-schemas.md`. `info.yaml`'s `custom_actions` is the extension point for adding new items to an environment's `deploy.sh` action menu beyond FAST/STOP/CLEAN/etc. — `deploy.sh` reads this field directly, independent of `lib/info-lib.sh`.

`lib/yaml-lib.sh` holds the shared `_yaml_expand`/array-reading primitives both `info-lib.sh` and `desktop-lib.sh` build on. `lib/locale-lib.sh` forces a UTF-8 locale (emoji/em-dash output otherwise breaks under `dialog`/`less` in some non-interactive/SSH contexts).

### `config/environments.yaml`

Controls `deploy.sh`'s Environments submenu display order and category grouping (Host Setup / AI Assistants / Networking & Security / Management). An environment folder not listed here still works and still shows up — just appended alphabetically at the end rather than grouped. Always add a new environment here.

### Bash portability constraint

Every script in this repo must run under **bash 3.2** (macOS's shipped default — GPL licensing means Apple hasn't updated it since 2007), not just modern bash: **no `mapfile`/`readarray`, no associative arrays**. Array-building uses `while IFS= read -r x; do ARR+=("$x"); done < <(...)` instead.

### Cross-cutting root scripts

`backup.sh`/`restore.sh` (data + `.env` archival — see the manually-maintained `is_deployed()` case statement that must be extended per environment), `check-updates.sh` (compares running image IDs against a fresh pull; locally-built apt-based images are checked via live `apt-get update` + Dockerfile `FROM` diff instead), `ollama-watchdog.sh` (health-checks/restarts the host's native Ollama process — not containerized, shared across `nanoclaw-mnemon`/`chat-frontends`/`llm-gateways`).

## Repo-specific documentation conventions

- **`docs/lessons-learned.md`** — repo-wide lessons (git workflow, tooling gotchas). **`docs/lessons-learned/<environment>.md`** — one file per environment, a running "Issue Found & Fixed" log (Status/Summary/Symptom/Root cause/Fix/General Lessons/Related PRs) across that environment's real debugging sessions. Append a new section to the existing file for a new session on the same environment rather than creating a competing file.
- **`docs/future-enhancements/<topic>.md`** — design proposals / hardening plans for features shipped with an explicitly-flagged unverified assumption, or bigger not-yet-built ideas. State a caveat plainly in the code/README at the point it applies, then track the follow-up here — don't silently ship something untested as if confirmed.
- **`docs/refactoring-opportunities.md`** — known, real duplication deliberately deferred, each with why it's deferred and what would justify revisiting it. Remove an entry once acted on; don't leave stale ones.
- **`docs/pending-activities.md`** — a dated, prune-as-you-go snapshot of open follow-ups. GitHub's own PR/issue state is always the actual source of truth.
- When any of the above references something that later gets fixed/verified elsewhere, update or remove the stale reference in the same pass — this has been a recurring real gap (e.g. a "known limitation" surviving in a future-enhancements doc after the underlying code was already fixed by a different PR).

## Git workflow

This repo's sessions work on a long-lived branch that gets a fresh PR opened after each meaningful chunk of work, merged quickly, then restarted. Two non-obvious, easy-to-hit failure modes:

- **A merged PR's branch is done — pushing more commits to it does not get them into `master`.** Check whether your branch's own PR has already merged (`mergeable_state`/`merged` on the PR, or `git merge-base --is-ancestor <your-head> origin/master`) before pushing again. If it has, restart from the new tip: `git checkout -B <branch> origin/master`, keep any not-yet-merged commits by rebasing/re-applying them, open a *new* PR.
- **Other branches merge into `master` independently while yours is mid-task.** `git fetch origin master && git diff --stat HEAD origin/master` before pushing — not just after your own PR merges — catches unrelated work (a sibling PR, a parallel session) your branch never picked up. A plain `git merge origin/master` is normally conflict-free and cheap; do it before opening/updating a PR, not after a confused diff shows up.
