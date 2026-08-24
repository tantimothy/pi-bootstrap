# Ollama — Shared Native Model Runtime

Installs and starts Ollama directly on the macOS or Linux host, then exposes
model-management ACTION entries in `deploy.sh`. One native daemon is shared by
NanoClaw Mnemon, chat frontends, LLM gateways, and direct API clients at
`http://localhost:11434`.

Ollama is deliberately not containerized here. Native installation gives an M1
Mac direct Metal/unified-memory access and avoids running a second model server
for every consumer.

## Supported hosts

| Host | Install/start path | Resource detection | Inference |
|---|---|---|---|
| Apple Silicon Mac (macOS) | Homebrew service or Ollama.app | `sysctl` + `vm_stat` unified memory | Metal acceleration |
| Raspberry Pi 4/5 (64-bit Linux) | Official ARM64 installer + systemd (or `ollama serve` fallback) | `/proc/meminfo` | CPU-only |

All scripts stay compatible with macOS's stock Bash 3.2: they do not use
associative arrays, `mapfile`, or GNU-only command flags. Raspberry Pi requires
a **64-bit OS**; the setup stops with a clear error on 32-bit ARM instead of
attempting an incompatible install.

## Setup

Select **AI Assistants → ollama → FAST** in `./deploy.sh`. If Ollama is missing,
the script asks before installing it:

- macOS: Homebrew (`brew install ollama`)
- Linux/Raspberry Pi OS: Ollama's official install script

The setup is idempotent. If the API is already responsive it leaves the running
daemon alone; otherwise it starts the Homebrew service, Ollama.app, the Linux
systemd unit, or a bare `ollama serve` process as appropriate.

## Lifecycle and teardown

The normal environment lifecycle applies to the one shared native daemon:

| Policy | Behavior |
|---|---|
| FAST | Install when missing (with confirmation), then start/reuse Ollama |
| STOP | Stop the daemon but keep the runtime and every downloaded model |
| TEARDOWN | Stop and remove the recognized Homebrew/Ollama.app or official Linux runtime; preserve downloaded models |
| CLEAN | TEARDOWN followed by a fresh install/start; preserve downloaded models |
| INFO | Show model-management and watchdog commands |

Because every frontend, gateway, and Mnemon shares this daemon, STOP,
TEARDOWN, and CLEAN briefly affect all of them. `~/.ollama` and the official
Linux service's `/usr/share/ollama` model store are deliberately preserved.
There is no bulk WIPE action; use **Delete an Installed Model** to remove model
weights individually with confirmation.

## Model ACTION entries

The Ollama environment adds these entries alongside its lifecycle policies:

| Action | Behavior |
|---|---|
| List Installed Models | Runs `ollama list` |
| List Running Models | Runs `ollama ps` |
| Show Host Resources / Model RAM | Shows total/available RAM, memory pressure, CPU count, model-storage disk space, and loaded models |
| Stop a Running Model | Selects a loaded model and unloads it with `ollama stop` |
| Delete an Installed Model | Selects and confirms before `ollama rm` |
| Pull a Recommended Model | Browses the curated catalog by hardware tier or suggested use |
| Run an Installed Model | Starts an interactive `ollama run` session |
| Check / Restart Ollama | Uses the repository's API-level watchdog |

Stop and delete always require a confirmation. Pulling downloads a model but
does not load it into RAM.

## Pull catalog and RAM comparison

`models.tsv` translates the two supplied local-model articles into valid Ollama
tags and groups them in two independent ways:

See [`MODEL-MATRIX.md`](MODEL-MATRIX.md) for a single pivot-style hardware and
use-case table. Each model appears once under the minimum tier that introduces
it, making the additional models unlocked by 8GB and 16GB hardware explicit.
The final column summarizes what each model is best suited for.

- Hardware: Apple Silicon Mac 16GB, Apple Silicon Mac 8GB, Raspberry Pi 4/5
  8GB, and Raspberry Pi 4/5 4GB.
- Suggested use: wiki Q&A, Mnemon/RAG embeddings, general chat, coding,
  reasoning/math, fast/minimal, multilingual, and long-context work.

The supplied wiki-model article's recommendations are represented explicitly:
`phi4-mini`, `gemma4:e4b`, `qwen3.5:2b`, `qwen3.5:4b`, and
`llama3.2:3b`. Gemma 4 E4B's current Ollama artifact is much larger than the
article anticipated, so it is limited to the 16GB Mac tier and marked as tight.
The separate `gemma3:4b` recommendation from the hardware article remains in
the catalog as its own model.

The 16GB Mac hardware tier intentionally contains the entire catalog. The
native dialog selector scrolls through the list and sorts it by live assessment
(`FITS`, `CAUTION`, then `EXCEEDS`) and projected minimum RAM. The smaller
hardware tiers filter out models whose projected working set is not practical
for that class.

Before a pull, the menu shows:

- each model tag, live fit label, suggested uses, and projected working-RAM
  range (weights plus runtime overhead and a modest context) on one row;
- a description in dialog's bottom help line that changes with the highlighted
  model;
- full model description and download size after selecting a model;
- live host total and available RAM;
- live memory pressure (`memory_pressure -Q` on macOS and kernel PSI on Linux);
- a `FITS`, `CAUTION`, or `EXCEEDS` assessment.

Low pressure can produce `CAUTION` rather than `EXCEEDS` when the immediately
available figure is below the model estimate, because macOS may still have
reclaimable or compressible capacity. Elevated pressure keeps the stricter
assessment, and a projected minimum larger than physical RAM always remains
`EXCEEDS`.

The RAM range and pressure bands are guidance, not a reservation or benchmark.
Very long contexts, parallel requests, higher-precision variants, and other
applications increase real usage. On Raspberry Pi, all generation is
CPU-bound; active cooling is strongly recommended.

`nomic-embed-text` is present in every hardware tier because Mnemon uses it for
semantic recall. It is an embedding-only model, so the run action rejects it as
an interactive chat choice.

## Direct use

```bash
bash environments/ollama/scripts/manage-models.sh
bash environments/ollama/scripts/manage-models.sh --resources
bash environments/ollama/scripts/manage-models.sh --pull phi4-mini

bash ollama-watchdog.sh --check     # is it responding right now?
bash ollama-watchdog.sh --status    # bind address, schedule, health, listeners
bash ollama-watchdog.sh --install   # schedule automatic checks
bash ollama-watchdog.sh --stop      # kill any in-flight run and unschedule
```

Exit an interactive model chat with `/exit` or `Ctrl+D`.

**Why a watchdog when Homebrew/systemd already supervises Ollama?** Because
they catch different failures. A service supervisor restarts a process that
*exited*; the incident this was built for had the process alive and only its
HTTP API wedged, which no `KeepAlive` can see. They compose: the supervisor owns
the process, the watchdog owns API health, and the watchdog now restarts through
`brew services`/`systemctl` where those manage the daemon rather than `pkill`-ing
something the supervisor immediately brings back.

## Coming back after a reboot (macOS)

Ollama has no boot autostart of its own on a Mac once this repo has taken it out
of Homebrew's supervision — which it does whenever `OLLAMA_SERVE_HOST` is set and
Homebrew's service definition refuses to honour it (see the bind-address note
above). The scheduled watchdog is what brings it back: its LaunchAgent has
`RunAtLoad`, so it fires at login, finds nothing answering, and starts Ollama.

Three prerequisites, none of which announce themselves when missing:

- **The watchdog has to actually be scheduled.** `./deploy.sh` → Environments →
  ollama → *Watchdog: Schedule Automatic Checks*. A watchdog that was never
  installed is documentation, not a safeguard — that is exactly how the
  2026-08-15 outage happened.
- **The Mac has to log in on its own.** A LaunchAgent loads at *user login*, not
  at boot. On a host that reboots to the login window and waits there, neither
  Ollama nor the watchdog comes back. Auto-login is therefore load-bearing here;
  turning it off silently re-opens the gap.
- **The installed LaunchAgent has to be current.** The plist is written once at
  install time and never re-read, so a fix to its *contents* reaches nobody who
  already installed it. `ollama-watchdog.sh --status` prints
  `Plist version: OUTDATED` when that has happened; re-run the schedule action to
  pick it up. The 2026-08-24 reboot failure was two such content bugs — launchd
  runs jobs with a PATH that excludes Homebrew, so the scheduled run could not
  find `ollama` at all, and launchd killed the daemon a tick had just started,
  seconds after that tick logged the restart as a success.

`--status` is the one command that answers "will this survive the next reboot?":
it reports the schedule, the plist version, the bind address, and what is
actually listening.
