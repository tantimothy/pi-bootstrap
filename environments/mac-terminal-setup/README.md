# Mac Terminal Setup — Personal Mac Terminal Bootstrap

Deploys this Mac's terminal setup — a colored, git-aware bash prompt, tmux
auto-attach on login, fastfetch system info, and (optionally) a set of
whimsical login extras — to any Mac. It's the macOS/Homebrew counterpart to
`pi-barebones` (which does the same job for a fresh Raspberry Pi OS install):
installs packages from `packages.txt`/`packages-whimsy.txt`, drops
`.tmux.conf`/`.bash_profile` into your home directory, and injects
marker-delimited `.bashrc` blocks.

This is not a Docker environment — it runs directly on the host and has no
containers.

---

## ⚙️ Why This Needs a Custom `run.sh`

Same reasoning as `pi-barebones`: `deploy.sh`'s generic fallback only knows
how to build/run a Docker image or `docker compose up` a stack. This
environment has neither — everything it does is host-level dotfile/package
management:

- **`brew install`** of packages listed in `packages.txt` (always) and
  `packages-whimsy.txt` (only if whimsy extras are enabled) — direct host
  package management, not a container image build.
- **Idempotent `.bashrc` injection** — four independently-positioned
  marker-delimited blocks (prompt, tmux, fastfetch, whimsy), always
  reassembled in that order on every run.
- **Backing up and overwriting real dotfiles** in `$HOME`
  (`.bash_profile`, `.tmux.conf`, and — only for whimsy — a handful of
  scripts under `~/bin`). No Docker archetype has any notion of "edit the
  host user's shell rc files."

---

## What It Does

1. **Installs Homebrew** if missing (asks first).
2. **Asks once** whether to include whimsical login extras (fortune,
   cowsay, BOFH excuses, calendar, weather) — the answer is written to
   `.env` and remembered on future runs. Skip the prompt by pre-setting
   `WHIMSY_ENABLED=true`/`false` in `.env` yourself (see `.env.example`).
3. **Installs packages** — always `packages.txt` (`tmux`, `fastfetch`);
   additionally `packages-whimsy.txt` (`cbonsai`, `cmatrix`, `asciiquarium`,
   `cowsay`, `fortune`, `lolcat`) plus the `Acme::Scurvy::Whoreson::BilgeRat`
   CPAN module if whimsy is enabled.
4. **Notes whether MacPorts is installed** — no automated installer exists
   for it (unlike Homebrew's one-liner), so this is informational only; the
   MacPorts `PATH` lines in `.bash_profile` are harmless no-ops without it.
5. **Deploys `.tmux.conf` and `.bash_profile`**, and — only if whimsy is
   enabled — the bundled `~/bin` scripts and calendar data.
6. **Injects four `.bashrc` blocks**, always reassembled in this order:
   `prompt` → `tmux` → `fastfetch` → `whimsy` (only if enabled). The whole
   injected region is guarded behind `[[ $- == *i* ]] || return`, so
   non-interactive shells (scripts, `ssh host command`, this repo's own
   tooling) are unaffected.

Every step that would overwrite an existing file backs it up first — see
**Backups** below.

---

## 🗄️ Backups

Before overwriting anything already at its destination, `run.sh` copies the
existing version into a fresh, timestamped directory:

```
~/.pi-bootstrap-backups/mac-terminal-setup-<YYYYMMDD-HHMMSS>/
```

This covers `~/.bash_profile`, `~/.bashrc` (snapshotted whole before any
block injection touches it), `~/.tmux.conf`, and — when whimsy assets are
deployed — everything under `~/bin` that gets replaced. Files that don't
already exist, or that are byte-identical to what's about to be deployed,
aren't backed up (nothing changed). `run.sh` prints the backup directory
path at the end if it wrote anything.

To restore: copy the file(s) you want back out of the relevant
`~/.pi-bootstrap-backups/mac-terminal-setup-*/` directory.

---

## 🎭 Whimsical Login Extras

Off by default. When enabled, a new interactive shell runs — strictly
*after* tmux and fastfetch — one randomly-picked splash (`cbonsai`,
`cmatrix`, `asciiquarium`, or a `cowsay`+`fortune`+`lolcat` combo with a
"press any key" pause), then `fortune`, a BOFH excuse, a couple of
network-sourced insults, today's entries from a bundled calendar-facts
database, and the weather via `wttr.in`.

**Toggling it:**
- Re-run `./run.sh` and answer differently — but it only asks once, so:
- Use the **"Toggle whimsical login extras"** action in `./deploy.sh`'s
  menu for this environment, or
- Hand-edit `WHIMSY_ENABLED` in `environments/mac-terminal-setup/.env`
  and re-run `./run.sh`.

Turning it off removes the `WHIMSY` block from `~/.bashrc` (so nothing runs)
but deliberately leaves the already-copied `~/bin` scripts in place —
they're inert once nothing calls them, and re-enabling later is instant.

---

## Customising the Package List

Edit `packages.txt` (always installed) or `packages-whimsy.txt` (whimsy
only). One Homebrew formula per line, comments with `#`. Run `./run.sh`
again after editing — `brew install` is idempotent so already-installed
formulas are skipped.

---

## Deployment

```bash
chmod +x run.sh
./run.sh
```

Then open a new terminal tab (or `source ~/.bash_profile`) to see the
changes take effect.

---

## 🎛️ Deployment Policies

Like `pi-barebones`, `run.sh` never branches on `$REBUILD_POLICY` — it
always runs the same idempotent setup. `deploy.sh`'s policy menu detects
this (a `run.sh` with zero `POLICY` references, paired with `info.yaml`
declaring no `data_dirs`/`named_volumes`) and only presents the policies
that actually do something:

| Policy | Action |
|--------|--------|
| `FAST` | Install missing packages and update dotfiles/`.bashrc` blocks — safe to re-run any time |
| `INFO` | No persistent data directories — shows useful commands |

Plus the custom action described above (toggle whimsy).

---

## 💡 Useful Commands

```bash
# Re-run setup after editing packages.txt / packages-whimsy.txt
./run.sh

# Attach to the tmux session
tmux attach

# View current .bashrc injected blocks
grep -A3 'MAC TERMINAL PROMPT START' ~/.bashrc
grep -A3 'MAC TERMINAL WHIMSY START' ~/.bashrc

# Current whimsy on/off setting
cat environments/mac-terminal-setup/.env

# Most recent backups from this environment
ls -t ~/.pi-bootstrap-backups/ | head
```
