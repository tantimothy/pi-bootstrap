# Environment YAML schemas: `desktop-entries.yaml` and `info.yaml`

Every environment under `environments/<name>/` can declare two YAML files:

| File | Drives | Read by |
|---|---|---|
| `desktop-entries.yaml` | Application-menu / Desktop entries for that environment | `lib/desktop-lib.sh`'s `run_desktop_install_yaml` (via `lib/run-install-desktop.sh`) |
| `info.yaml` | The `INFO`/`WIPE` data listing, the generated `post-deploy-info.html`, and what `backup.sh` archives | `lib/info-lib.sh`'s `run_info_yaml` (via `lib/run-info.sh`) |

Neither file is required. An environment with no desktop entries at all
(`internet-pi`, `pi-barebones`) simply has no `desktop-entries.yaml`, and
`lib/run-install-desktop.sh` silently no-ops. An environment with no
persistent data or web UI to report could equally omit `info.yaml`, though
in practice every environment has one today.

Both files are consumed through `lib/yaml-lib.sh`, which requires **go-yq**
(`github.com/mikefarah/yq`) specifically — not the Python jq-wrapper some
distros package under the same `yq` name. `./deploy.sh` installs the
correct one automatically; `lib/yaml-lib.sh`'s `_require_yq` is the runtime
guard if one of these files is read some other way.

## Environments with real branching: override scripts

Two environments have logic that can't be expressed as static YAML data,
so they keep a thin override script instead of relying purely on the
generic driver:

- **`nanoclaw`**: `install-desktop.sh` detects host-vs-container deploy
  mode (OS-dependent) and sets `DEPLOYED_CHECK_KIND`/`DEPLOYED_CHECK_VALUE`
  itself, calling `_load_desktop_entries_yaml` for everything else and
  `run_desktop_install` directly (never `run_desktop_install_yaml`).
  `info.sh` picks an OS-dependent command block
  (`useful_commands_host`/`useful_commands_macos` — see below) and
  prepends it to the YAML-sourced `useful_commands`.
- **`internet-pi`**: `info.sh` builds `WEB_UI_NAMES`/`WEB_UI_URLS`
  conditionally on the `PIHOLE_ENABLE`/`MONITORING_ENABLE` flags from its
  Ansible-driven `.env`, so `web_uis` is omitted from its `info.yaml`
  entirely and built in bash instead.

Every other environment's `install-desktop.sh`/`info.sh` either doesn't
exist (nothing left to say once the YAML has the data) or is a fixed
~5-line shim that just loads the YAML and calls the generic driver — see
`environments/ntopng/info.sh` for the shortest example of each.

---

## The `${VAR}` / `${VAR:-default}` substitution mechanism

Any string value in either file may contain markers resolved by
`_yaml_expand` (`lib/yaml-lib.sh`) **after** yq extracts the raw text —
YAML itself never interprets these, they're just characters in a string
until the loader processes them.

- `${VAR}` → the value of real bash variable `VAR` if set, else empty.
- `${VAR:-default}` → `VAR`'s value if set and non-empty, else the literal
  text `default`.
- A bare `$VAR` (no braces) is **not** a marker and passes through
  completely untouched — this is intentional, used where a command shown
  to the user needs to keep a literal `$VAR` for their own shell to
  evaluate later (see "Literal vs. substituted `$VAR`" below).
- Only plain parameter expansion is supported — no command substitution,
  no arithmetic, no nested markers. The source is a YAML file the loader
  has no more reason to trust than any other repo-authored input, so the
  implementation deliberately avoids `eval` or anything that could execute
  arbitrary text.
- A string may contain multiple markers; all of them get resolved.

### What variables are actually available to resolve against

Both loaders source `.env` (if present) via `set -a; source .env; set +a`
before doing any substitution — so **every key `.env` sets is available by
name**. `.env.example` is documentation only; it is never sourced by these
loaders. This matters because `.env` isn't guaranteed to be complete or even
present — someone can run `run.sh` directly (bypassing `deploy.sh`'s config
form, which is what fully rewrites `.env` from `.env.example` on every
deploy), hand-trim `.env` to only the keys they care about, or be running
against an `.env` that predates a newly-added `.env.example` key.

On top of that:

| Variable | Available in | Set to |
|---|---|---|
| `ENV_DIR` | `desktop-entries.yaml` | The environment's own absolute directory path |
| `SCRIPT_DIR` | `info.yaml` | Same absolute path, different name (matches what `info.sh` always called it) |
| `HOST_IP` | `info.yaml` only | The host's LAN IP (`ip route get` / `hostname -I`, falling back to `"localhost"`) — desktop entries deliberately use `localhost` literally instead, since they only ever open in a browser on the same machine |
| any `.env` key | both | Whatever the user has actually set in `.env` |

If a marker names something that's not in `.env` nor one of the synthetic
variables above, it resolves using the marker's own `:-default` (or to
empty, if it has none) — never an error.

**Practical effect: always write an explicit `:-default` for every
`.env`-driven marker**, matching that variable's `.env.example` default
(e.g. `"${CONTAINER_NAME:-ntopng}"`, not `"${CONTAINER_NAME}"`). Since
`.env` alone is the only thing sourced, a marker with no default silently
renders blank whenever `.env` doesn't define that key — this bit
`pihole-wireguard/info.yaml`'s `${WG_PORT}` for a long time before it was
given one; don't reintroduce that.

### Literal vs. substituted `$VAR`

Because only `${VAR}` (braced) is a marker, a plain `$VAR` can appear in a
string and stay exactly as written — used for command snippets meant to be
copy-pasted and run by the user in a *different* context, where the
variable should resolve there, not here. Two real examples:

```yaml
# nanoclaw-mnemon/info.yaml — $NANOCLAW_INSTALL_PATH is evaluated by the
# container's own shell when the printed command actually runs, not by
# this script when it builds the display text:
useful_commands: |2
     docker exec -it nanoclaw-mnemon bash -lc "cd $NANOCLAW_INSTALL_PATH && claude"
```

```yaml
# pihole-wireguard/info.yaml — $(pwd) is meant to be the user's own
# current directory when THEY run this command later, not this
# environment's directory:
useful_commands: |2
     docker run --rm -v pihole-wireguard_prometheus_data:/data -v $(pwd):/backup alpine tar czf /backup/prometheus_data.tar.gz /data
```

If either of those had used `${NANOCLAW_INSTALL_PATH}` or `${pwd}` (braced),
the loader would have tried to resolve them immediately against its own
scope instead of leaving them for later.

---

## `desktop-entries.yaml` reference

```yaml
menu:
  id: <string>            # required — also becomes the Categories=
                           # tag (X-PiBootstrap-<id>;) and the submenu
                           # directory name
  name: <string>           # required — submenu display name
  icon: <string>           # optional, default "utilities-terminal"

deployed_check:             # optional — omit entirely if an override
                             # script sets DEPLOYED_CHECK_KIND/VALUE itself
  kind: container | marker | systemd
  value: <string>           # for marker/systemd, or container without Compose
  # — OR, for a container-kind check on a docker-compose.yml-based
  #   environment, use this instead of value: —
  from_compose_service: <service-key>

entries:                    # list, omit or leave empty if there are none
  - id: <string>             # required — becomes the .desktop filename
                              # and, combined with menu.id, its ownership tag
    name: <string>            # required — display name
    comment: <string>         # required — one-line description
    icon: <string>            # required
    kind: link | exec
    target: <string>          # required — meaning depends on kind, see below
    terminal: true | false    # exec only, optional, default false

info:
  id: <string>               # required — this environment's "<Name> Info" entry
  name: <string>              # required
```

### `deployed_check`

Before creating (or leaving in place) any desktop entries, the generic
driver checks whether the environment is actually running — an
undeployed environment gets its entries swept away instead. `kind`
selects *how*:

| `kind` | Checks | Typical `value` |
|---|---|---|
| `container` | A Docker container by this name exists (`docker ps -a --filter name=...`) | `"${CONTAINER_NAME:-<default>}"`, or use `from_compose_service` instead — see below |
| `marker` | A file exists | `"${ENV_DIR}/.deployed"` — used by `dragonos-sdr`/`kali-pentest`, which run with `--rm` and leave no lingering container; `run.sh` touches this file right before launching |
| `systemd` | A systemd unit is registered | A literal unit name, e.g. `"nanoclaw.service"` |

**`from_compose_service`** (container-kind only, docker-compose.yml-based
environments): instead of restating the container name's default as a
second copy of `docker-compose.yml`'s own `container_name:` field, name
the service key to read it from directly:

```yaml
deployed_check:
  kind: container
  from_compose_service: portainer   # reads docker-compose.yml's
                                     # services.portainer.container_name,
                                     # then resolves any ${VAR} markers in it
```

This only works for the *one* service a multi-service compose file's
desktop entries actually check — e.g. `pihole-wireguard` has 13 services
but only checks `pihole` (the stack's own DNS resolver and de facto
"is this stack up" signal). Use `value: "${CONTAINER_NAME:-<default>}"`
instead of `from_compose_service:` for `run.sh`-based environments that
call `docker run` directly rather than `docker compose` (`nanoclaw`,
`nanoclaw-mnemon`) — there's no `docker-compose.yml` to read the name
from, so the default has to be typed here to match `run.sh`'s own
`CONTAINER_NAME="${CONTAINER_NAME:-nanoclaw-mnemon}"` fallback.

### `entries[].kind`

- **`link`**: opens a URL. `target` is that URL (typically
  `"http://localhost:${PORT_VAR:-<default>}"`). Rendered as
  `install_link_icon` — two flavors of `.desktop` file (a
  `Type=Application` one with a browser-fallback `Exec=` chain for the
  menu, a `Type=Link` one for the Desktop icon).
- **`exec`**: runs a command. `target` is the full `Exec=` command string
  (e.g. `bash -c "..."`), written as a raw `Type=Application` `.desktop`
  file. `terminal: true` sets `Terminal=true` (used for anything that
  needs an interactive terminal, like launching `run.sh`).

---

## `info.yaml` reference

```yaml
data_dirs:                     # optional, default none
  - path: <string>
    description: <string>
data_dirs_label: <string>      # optional, default "📁 Persistent Data Directories:"

install_dirs:                  # optional, default none
  - path: <string>
    description: <string>
install_dirs_label: <string>   # optional, default "📂 Install Directories:"

named_volumes:                 # optional, default none
  - name: <string>              # a real Docker volume name, not a marker
    description: <string>

wipe_parent_dirs:               # optional, default none
  - <string>                     # parent dirs rm -rf'd after data_dirs,
                                  # e.g. "${HOME}/internet-monitoring"

delete_install_dirs: true | false   # optional, default false —
                                     # whether WIPE also removes install_dirs

delete_confirm_msg: <string>    # optional — shown in the WIPE confirmation
                                 # prompt; may contain a real newline via
                                 # YAML's own "\n" escape in a double-quoted
                                 # string, e.g. "line one.\nline two."
no_data_msg: <string>           # optional — shown when data_dirs is empty
no_delete_msg: <string>         # optional — shown when there's nothing to delete

web_uis:                        # optional, default none
  - name: <string>
    url: <string>                # typically "http://${HOST_IP}:${PORT:-<default>}"

custom_actions:                 # optional, default none — see its own
  - label: <string>              # section below
    command: <string>            # MUST be a single line — see below

useful_commands: |               # optional block scalar — see the
  ...                            # indentation section below before writing one
```

Every field is optional; an environment can have as little as an empty
file. `data_dirs`/`install_dirs`/`named_volumes` (combined) also decide
`deploy.sh`'s `POLICY_HAS_WIPABLE_DATA` flag — if all three are empty,
`WIPE` is hidden from that environment's policy menu entirely
(`pi-barebones` is the one environment where this applies today).

### `custom_actions`

The fixed lifecycle policies (`FAST`/`STOP`/`TEARDOWN`/`CLEAN`/`INFO`/`WIPE`)
are the only things `deploy.sh`'s own per-environment action menu shows by
default — there's no way for an environment to add a brand-new item of its
own to that list otherwise. `custom_actions` is that extension point:

```yaml
custom_actions:
  - label: "Scaffold a Wiki for a Group"
    command: 'read -rp "Group folder name (under groups/): " GROUP; bash ${ENV_DIR}/scripts/scaffold-wiki.sh "$GROUP"'
  - label: "Check / Restart Ollama"
    command: "bash ${PROJECT_DIR}/ollama-watchdog.sh"
```

Each entry appears as its own item in `deploy.sh`'s policy menu (alongside
`FAST`/`STOP`/etc., using `label` as the displayed text), tagged internally
as `ACTION_<index>` — never a real policy name, so there's no risk of a
label colliding with `FAST`/`CLEAN`/etc. Selecting one runs `command`
directly via `bash -c`, in the environment's own directory, with `.env`
already sourced — fully interactive (a `read` prompt, a `docker exec -it`
handoff) works exactly as if typed at the terminal, since this is run
unwrapped, the same way `run.sh`'s own interactive handoffs are (see
`lib/deploy-lib.sh`'s comment on `_run_logged` for why). One consequence
of that: unlike `INFO`/`WIPE`/`FAST`/`CLEAN`, a custom action's output
isn't saved to `environments/<env>/logs/`.

`${VAR}`/`${VAR:-default}` markers in `command` are resolved the same way
as everywhere else in this file (see the substitution section up top) —
`ENV_DIR` is set to the environment's own absolute path, and since this
runs from inside `deploy.sh` itself (not a fresh subshell), any of
`deploy.sh`'s own real bash variables are available too, notably
`PROJECT_DIR` (the repo root) — useful for invoking a repo-root script
like `ollama-watchdog.sh` that isn't itself part of any one environment.

**`command` must be a single line.** Confirmed directly against go-yq's
own output for a multi-line block-scalar `command`: it prints embedded
newlines *and* a blank-line separator between array elements, which the
loader's line-by-line array reader would silently split into extra
entries, misaligning every `command` against its `label` from that point
on. Chain multiple statements with `;` or `&&` instead, or point `command`
at a real script file if the logic is more than a line or two.

### `useful_commands` and the block-scalar indentation trap

`useful_commands` is free text, not further structured data —
`lib/info-lib.sh`'s `_tag_mixed_content` renders it by convention: a line
with **zero** leading spaces starts a new "code" section, except for a
line that's *exactly* `📌 Notes:`, which switches into "prose" mode; within
prose, a line indented **8 or more spaces** drops back into "code" styling
(an embedded command snippet inside a note). The real, rendered output
generally looks like:

```
   docker logs -f sometthing                                       # a command
   another command

📌 Notes:
   🔑 A note, at 3 spaces.
      A wrapped continuation line, at 6 spaces.
      Do a thing:
        docker some-command-shown-as-code   # this one at 8+ spaces
```

**The trap:** YAML's plain `|` block scalar strips whatever indentation is
*common to every line in the block* — inferred from the least-indented
non-blank line. If your block is uniformly indented (no `📌 Notes:` line to
break the pattern), a plain `|` silently strips it down to **zero** on
every line, destroying the 3-space indentation the rendered output needs.

**The fix:** always use an explicit indentation indicator — `|2` — rather
than a bare `|`. `|2` pins the strip amount to exactly 2 spaces (this
file's own YAML nesting level for a top-level key's block value),
regardless of which line happens to be least-indented. Write every line at
`2 + <desired output spaces>`:

```yaml
useful_commands: |2
     docker logs -f something                                      # 3 desired -> 5 in the file

  📌 Notes:                                                          # 0 desired -> 2 in the file
     🔑 A note.                                                      # 3 desired -> 5 in the file
        A continuation.                                              # 6 desired -> 8 in the file
```

Every `useful_commands` block in this repo uses `|2` for exactly this
reason — do the same for any new one, even if it looks uniform today (a
future edit adding a `📌 Notes:` section would otherwise silently break the
existing lines' indentation along with it).

### `nanoclaw`'s extra keys

`nanoclaw/info.yaml` has two keys the shared schema doesn't otherwise use,
read directly by `nanoclaw/info.sh` (not by `_load_info_yaml`) and
prepended to the YAML-sourced `useful_commands`:

```yaml
useful_commands_host: |2
     ...    # shown on Linux (systemd) deploy mode
useful_commands_macos: |2
     ...    # shown on macOS (container-only) deploy mode
```

This is the pattern to follow for any future environment that needs an
OS- or mode-dependent *prefix* to its command list: give it its own
override script (see `nanoclaw/info.sh`), keep the OS-independent tail in
the shared `useful_commands` key, and read the extra key(s) directly with
`_yq`/`_yaml_expand` (both already in scope once `lib/info-lib.sh` is
sourced).

---

## Adding a new environment's entries

1. Write `environments/<name>/desktop-entries.yaml` and/or `info.yaml`
   following the schemas above.
2. If there's no real branching to do, don't add `install-desktop.sh`/
   `info.sh` at all — `lib/run-install-desktop.sh` and `lib/run-info.sh`
   (which every caller in this repo already goes through) fall back to the
   generic YAML-driven driver automatically.
3. If there genuinely is branching (OS detection, feature flags, a
   deployed-check that can't be expressed as `value`/`from_compose_service`),
   write a short override script — see `nanoclaw/install-desktop.sh` or
   `internet-pi/info.sh` as templates. Call `_load_desktop_entries_yaml`/
   `_load_info_yaml` first for everything that *is* static, then only
   override what genuinely varies, then call `run_desktop_install`/
   `run_info` directly.
4. Test with `bash lib/run-install-desktop.sh environments/<name>` and
   `bash lib/run-info.sh environments/<name> list` — both print progress
   or output directly, no special setup needed beyond a deployed
   environment (or a `--uninstall`/not-deployed dry run, which works even
   without one).
