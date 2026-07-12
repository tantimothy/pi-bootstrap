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

Both loaders `source` the environment's `.env` (if present, via `set -a`)
before doing any substitution, so **every key in that environment's
`.env` is available by name**. On top of that:

| Variable | Available in | Set to |
|---|---|---|
| `ENV_DIR` | `desktop-entries.yaml` | The environment's own absolute directory path |
| `SCRIPT_DIR` | `info.yaml` | Same absolute path, different name (matches what `info.sh` always called it) |
| `HOST_IP` | `info.yaml` only | The host's LAN IP (`ip route get` / `hostname -I`, falling back to `"localhost"`) — desktop entries deliberately use `localhost` literally instead, since they only ever open in a browser on the same machine |
| any `.env` key | both | Whatever `.env` has, e.g. `CONTAINER_NAME`, `NTOPNG_PORT` |

If a marker names something that's neither in `.env` nor one of the
synthetic variables above, it resolves using the marker's own `:-default`
(or to empty, if it has none) — never an error.

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
     docker exec -it nanoclaw-mnemon bash -lc "cd $NANOCLAW_INSTALL_PATH && bash setup/add-whatsapp.sh"
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
"is this stack up" signal). Use `value:` instead of `from_compose_service:`
for `run.sh`-based environments that call `docker run` directly rather
than `docker compose` (`nanoclaw`, `nanoclaw-mnemon`) — there's no
`docker-compose.yml` to read from, so the default has to be restated
(that duplication is accepted as the smaller cost; parsing the default out
of `run.sh`'s bash source would be far more fragile than parsing YAML).

### `entries[].kind`

- **`link`**: opens a URL. `target` is that URL (typically
  `"http://localhost:${PORT_VAR:-default}"`). Rendered as
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
    url: <string>                # typically "http://${HOST_IP}:${PORT:-default}"

useful_commands: |               # optional block scalar — see the
  ...                            # indentation section below before writing one
```

Every field is optional; an environment can have as little as an empty
file. `data_dirs`/`install_dirs`/`named_volumes` (combined) also decide
`deploy.sh`'s `POLICY_HAS_WIPABLE_DATA` flag — if all three are empty,
`WIPE` is hidden from that environment's policy menu entirely
(`pi-barebones` is the one environment where this applies today).

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
