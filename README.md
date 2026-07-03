# 🐳 Raspberry Pi Multi-Environment Docker Orchestrator

An automated, stateless, and lightweight TUI (Terminal User Interface) deployment hub designed for managing diverse containerized applications on ARM architectures.

> For the environment workspace developer guide (how to create a new environment), see [`environments/README.md`](environments/README.md).

The framework operates under a **local compilation paradigm**: instead of maintaining bulky pre-built images inside external registries, it pulls raw blueprints directly from GitHub and compiles them natively on the Raspberry Pi. This minimizes bandwidth consumption and ensures total optimization for host-specific ARM constraints.

## 🏗️ Core Architectural Capabilities

### 1. Bulletproof Permission Wrapper
The core execution engine (`deploy.sh`) never makes hardcoded calls to `docker` or assumes the executing user belongs to the `docker` group. On initialization, it runs a validation check on the UNIX socket interface:
* It tests write access to `/var/run/docker.sock`.
* If access is denied, it automatically upgrades operations by shifting to a secure `sudo docker` structural alias.
* The resolved runtime engine is exported to child environments via the `$DOCKER_CMD` variable, allowing all downstream setups to run seamlessly on fresh OS installations without requiring shell re-logs.

### 2. Secure Git Sync & Header Injection
To enable secure remote execution without exposing credentials, `deploy.sh` utilizes an advanced token-forwarding mechanism:
* When executed via remote piping, Personal Access Tokens (PATs) are accepted strictly through HTTP headers to keep them clean from shell execution histories (`.bash_history`).
* The orchestrator captures this token internally and forwards it into subsequent Git actions using custom headers: `git -c http.extraHeader="Authorization: token $GITHUB_TOKEN"`.
* This setup guarantees that nested application modules and secondary repository fetches authenticate silently without ever breaking character into interactive terminal credential prompts.

### 3. Metadata-Driven Secret Pre-Processor
Environment configuration is handled entirely at runtime through a stateless parsing engine that interprets `.env.example` tracking blueprints:
1. **The Legend Screen:** It reads syntax comment blocks (`#`) immediately preceding any variable key to generate a full-screen, scrollable information card detailing what each input parameter represents.
2. **The Consolidated TUI Form:** It parses key-value pairings (`KEY=DEFAULT`) to dynamically generate a unified `dialog` form, pre-populating fields with default placeholders.
3. **Draft Separation:** All verified user configurations are saved to an uncommitted, local `.env` file. If a user cancels out of the form, all working drafts are securely wiped to prevent data leakage.

### 4. Advanced State-Machine Policy Matrix
Deployments are governed by two distinct structural paths passed down to control nodes:

| Policy | Target Evaluation Pattern | Container Lifecycle Routing | Image Optimization Routine |
| :--- | :--- | :--- | :--- |
| **`FAST`** *(Default)* | Loops across all identifiers declared in `$CONTAINER_NAME`. | • If active: Skips rebuilds to maximize uptime.<br>• If dormant: Runs `docker start`.<br>• If missing: Rebuilds missing segments. | Reuses local Docker layer caches to bypass slow ARM physical processing steps. |
| **`CLEAN`** | Forcefully loops across all target container arrays. | Stops and completely destroys matching running or dormant containers. | Triggers a strict `--no-cache` execution to pull pristine updates from zero-state. |

## 🛠️ Dynamic Routing Topology

When a folder workspace is selected from the primary menu interface, `deploy.sh` interrogates its file tree sequentially and routes execution through the following strict priority checklist:

```text
Selected Workspace Folder
│
├── 1. [Found run.sh] ──────────► Executes Custom Bash Router Script
│                                  (Delegates lifecycle mechanics entirely to script)
│
├── 2. [Found docker-compose.yml] ► Executes Multi-Container Compose Route
│                                  (Runs `$DOCKER_CMD compose up -d`)
│
└── 3. [Found Dockerfile] ───────► Executes Pure Standalone Fallback Route
                                   (Runs automated container compilation engine)
```

## 🚀 System Installation & Initialization

### Mode A: Stateless Remote Execution (Zero-Setup Remote Curl)
For automated setups on vanilla systems, execute the deployment dashboard remotely without cloning the utility layout manually. Pass your GitHub token through the secure header template below:

```bash
curl -sSL -H "Authorization: token <your_github_token>" \
-H "Accept: application/vnd.github.v3.raw" \
https://tantimothy:<your_github_token>@raw.githubusercontent.com/tantimothy/pi-bootstrap/master/deploy.sh | bash
```

### Mode B: Local Repository Execution
If you are developing custom environments or editing orchestration configurations locally on the host Pi filesystem:

```bash
chmod +x deploy.sh
./deploy.sh
```

## 📊 Minimum Host Prerequisites
* **Operating System:** Raspberry Pi OS (Debian 11 Bullseye / 12 Bookworm recommended).
* **Architecture:** `arm64` or `armhf` structural kernels.
* **Core Utilities:** `bash`, `git`, `curl` available within the system `$PATH`.
* *(Note: The TUI rendering package `dialog` and the underlying Docker virtualization engine are automatically verified, bootstrapped, and configured by the master script on execution).*
