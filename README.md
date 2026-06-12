# 🐳 Raspberry Pi Multi-Environment Docker Orchestrator Documentation

This document contains the complete technical specifications and developer guidelines for the Raspberry Pi Docker Orchestrator framework, split into two primary reference manuals:
1. **Main Orchestrator Dashboard Specification (`/README.md`)**
2. **Environment Workspace Developer Guide (`/environments/README.md`)**

All notation, syntax structures, and shell scripting templates have been escaped to prevent terminal parse errors or layout rendering breaks.

***

# MANUAL 1: MAIN ORCHESTRATOR DASHBOARD SPECIFICATION (`/README.md`)

An automated, stateless, and lightweight TUI (Terminal User Interface) deployment hub designed for managing diverse containerized applications on ARM architectures.

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

***

# MANUAL 2: ENVIRONMENT WORKSPACE DEVELOPER GUIDE (`/environments/README.md`)

This guide establishes the layout requirements, security boundaries, and integration standards for creating custom application workspaces within the Raspberry Pi Docker Orchestrator framework.

By adhering to this blueprint, your application environment will automatically register with the central terminal user interface (TUI) dashboard, leverage dynamic metadata-driven secret management forms, and conform cleanly to the system's underlying runtime state-machine operations.

## 📂 Workspace Folder Layout Standards

The parent orchestrator evaluates and maps out application contexts by indexing target subdirectories natively within the `./environments/` directory. When loading an environment, the engine uses an explicit, deterministic evaluation priority chain to decide which archetype deployment routing to execute:

```text
environments/
└── custom-workspace-name/
    ├── .env.example              # CRITICAL: Secret Template Blueprint & Form Generator
    │
    ├── Archetype 1 (Priority 1): run.sh        # Custom Bash Pipeline (Overrides Compose/Dockerfile)
    │   └── Dockerfile
    │
    ├── Archetype 2 (Priority 2): compose.yml   # Multi-Container Microservice Stack
    │   └── docker-compose.yml (or compose.yml)
    │
    └── Archetype 3 (Priority 3): Dockerfile    # Standalone Automation Engine Fallback
        └── Dockerfile
```

## 🔐 The Metadata Configuration Syntax Blueprint (`.env.example`)

The central dashboard parses your configuration template file line-by-line to dynamically generate interactive input fields using `dialog` form windows. To ensure your configuration parameters map correctly to the interactive TUI pre-processor, you must structure your `.env.example` file according to these strict rules:

1. **Comment Placement:** Every user-configurable configuration variable key must be preceded immediately by a comment line (or lines) starting with a single `#`.
2. **User Documentation:** Write clear, user-friendly structural explanations inside these comment blocks. The parser extracts this metadata dynamically and displays it directly inside a scrollable TUI dialog box prior to variable input collection.
3. **Default Assignment:** Provide a logical fallback value as an active default assignment after the `=` symbol wherever applicable. If a parameter is highly sensitive or mandatory (e.g., private keys, admin passwords), leave the field blank after the `=` to force explicit user initialization.

```ini
# The identification tracking string used by the main dashboard to evaluate container states.
CONTAINER_NAME=pihole-dns-core

# The administrative communication port routed through to the internal web dashboard interface.
WEB_PORT=8080

# The external upstream DNS lookup block used to filter recursive packet evaluations.
UPSTREAM_DNS=1.1.1.1

# The underlying cryptographic token string allocated from your cloud API account engine.
API_SECRET_KEY=
```

## 🎯 Container Identity Tracking Specification (`CONTAINER_NAME`)

To prevent runtime state-tracking blind spots, **every workspace must explicitly declare its target container signatures.** Define the `CONTAINER_NAME` variable inside your `.env.example` template file.

If this variable is missing, the parent engine falls back to using the workspace folder name as a container signature. *Note: This folder fallback breaks accurate state evaluation for compound environments, multi-container layouts, or custom setups.*

### Single-Container Tracking Blueprints
For simple standalone applications or shell wrappers, assign a single alphanumeric string value:
```ini
CONTAINER_NAME=sdr-dragon-os
```

### Multi-Container Stack Tracking Blueprints (Space-Separated Arrays)
If your workspace deploys a collection of interdependent microservices (e.g., Pi-hole coupled with a WireGuard VPN gateway), define **all** active container names within a single, space-separated string array:
```ini
CONTAINER_NAME="pihole-service wireguard-vpn wg-easy-dashboard"
```
*Why this matters:* When a user applies a `CLEAN` rebuild policy, the central orchestration engine splits this space-separated string into a localized loop array. It targets, stops, and completely purges every single container listed here sequentially. This completely prevents orphaning rogue legacy services or hitting runtime interface network bind conflicts.

## ⚙️ Deployment Caching & Rebuild Policies

The dashboard orchestrator relies on two primary deployment policies designed to balance hardware performance and system health during deployment phases:

1. **`FAST` Policy (Default State):** Maximizes application uptime and protects your Raspberry Pi's hardware lifespan. It preserves already running containers where possible and reuses the local image cache to skip time-consuming, resource-intensive ARM compilations.
2. **`CLEAN` Policy (Aggressive Teardown):** Forces a rigorous system purge. It tears down active deployments, drops existing container layers, evicts the local image cache from memory (`docker rmi`), and triggers a pristine `--no-cache` build sequence.

### 🤖 Automated Script-Driven Policy Overrides
While a user can manually set these strategies via the UI dashboard, the parent orchestration framework automatically flags a deployment context as `CLEAN` behind the scenes if it flags any of the following technical anomalies:
* **Missing System Integrity Assets:** If critical local configurations, storage volume tracking layouts, or mandatory dependent environment assets have been wiped or modified.
* **Git Hash Code Mismatch:** If the parent orchestration engine completes a secure fetch routine against the remote GitHub repository and detects that the upstream `Dockerfile` or script `entrypoint.sh` code has changed compared to your active local workspace copy. It programmatically overrides the `FAST` policy to enforce a clean execution loop, ensuring outdated codebase components never persist in production.

## 🚀 The Three Environment Deployment Archetypes

### Archetype 1: Custom Orchestration Shell (`run.sh`)
Use this configuration whenever an environment requires advanced host system manipulation, kernel driver orchestration, specialized system networking, or direct pass-through mapping to hardware components (such as an external RTL-SDR radio dongle, monitor-mode Wi-Fi card, or physical USB GPS receivers).

#### Execution Design Guidelines:
* **Engine Abstraction:** Never hardcode raw `docker` or `sudo docker` engine execution hooks. You must inherit the framework's native permissions wrapper model by routing all engine queries directly through the `$DOCKER_CMD` variable fallback.
* **Strict Non-Interactive Execution:** Do not include interactive execution flags like `-it`, `-t`, or direct TTY piping (such as `< /dev/tty`). The container environment must deploy using the detached daemon flag (`-d`), governed securely by an active `--restart unless-stopped` health state policy.
* **Secret Acquisition:** Manually ingest your compiled, user-configured local environment variables by explicitly sourcing the generated `.env` file at the beginning of your runtime logic.

```bash
#!/bin/bash
# 1. Inherit context permissions wrappers from the main framework cleanly
DOCKER=${DOCKER_CMD:-docker}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 2. Ingest dynamically compiled local user secrets
if [ -f "$SCRIPT_DIR/.env" ]; then
    export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
fi

# 3. Handle policy routing state-machine constraints
IMAGE_NAME="pi-pentest:latest"
IMAGE_EXISTS="$($DOCKER images -q "$IMAGE_NAME" 2>/dev/null)"

echo "🛑 Tearing down active instances of $CONTAINER_NAME..."
$DOCKER stop "$CONTAINER_NAME" 2>/dev/null
$DOCKER rm "$CONTAINER_NAME" 2>/dev/null

# 4. Trigger localized compilation branches
if [ "$REBUILD_POLICY" = "CLEAN" ] || [ -z "$IMAGE_EXISTS" ]; then
    echo "🛠️ Policy Engine Action: Running pristine compilation..."
    $DOCKER build --no-cache -t "$IMAGE_NAME" "$SCRIPT_DIR"
    if [ $? -ne 0 ]; then
        echo "❌ ERROR: Local structural compilation failed!"
        exit 1
    fi
else
    echo "📦 [FAST Policy] Found matching cached image tag. Skipping build layer."
fi

# 5. Pre-emptively generate data structures before container initialization
mkdir -p "${HOST_CAPTURES_PATH:-$SCRIPT_DIR/captures}"
mkdir -p "${HOST_MSF_DATA_PATH:-$SCRIPT_DIR/.msf4}"

# 6. Execute detached daemon container with advanced profiles
echo "⚡ Launching container in background..."
$DOCKER run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  --privileged \
  --net=host \
  --pid=host \
  -v /dev:/dev \
  -v "${HOST_CAPTURES_PATH:-$SCRIPT_DIR/captures}:/root/captures" \
  -v "${HOST_MSF_DATA_PATH:-$SCRIPT_DIR/.msf4}:/root/.msf4" \
  -e WIRELESS_INTERFACE="${WIRELESS_INTERFACE:-wlan1}" \
  "$IMAGE_NAME"
```

### Archetype 2: Multi-Container Microservice Stack (`docker-compose.yml`)
Best suited for environments that group multiple interdependent services over localized network definitions (e.g., a Pi-hole core resolver coupled directly with a containerized WireGuard VPN gateway server).
* Ensure all active variable mappings used within `docker-compose.yml` point directly to parameters explicitly declared inside your `.env.example` configuration file.
* Docker Compose automatically reads and binds variables saved to your uncommitted, generated workspace `.env` file at runtime.
* **Tracking Rule Alignment:** To maintain synchronization with the orchestrator's state dashboard, ensure your service definitions declare explicit `container_name` parameters matching the string entries listed in your workspace `CONTAINER_NAME` array template.

```yaml
version: '3.8'
services:
  pihole:
    container_name: pihole-service
    image: pihole/pihole:latest
    ports:
      - "${WEB_PORT:-80}:80/tcp"
    environment:
      - TZ=UTC
      - WEBPASSWORD=${ADMIN_PASSWORD}
    restart: unless-stopped

  wireguard:
    container_name: wireguard-vpn
    image: ghcr.io/wg-easy/wg-easy:latest
    environment:
      - WG_HOST=${VPN_ENDPOINT_IP}
    volumes:
      - ./wireguard_data:/etc/wireguard
    restart: unless-stopped
```

### Archetype 3: Pure Standalone Fallback (`Dockerfile`)
If your target directory contains only a standalone `Dockerfile` without an accompanying custom `run.sh` script or `docker-compose.yml` config matrix, the parent orchestrator intercepts operations and invokes its automated deployment pipeline engine:
1. **Automated Compilation:** It extracts your workspace properties, builds the context path natively, and sets up a standard framework deployment tag (`$ENV_NAME:latest`).
2. **Environment Injection:** It provisions the container runtime state and dynamically injects every key-value configuration variable pair by appending the `--env-file .env` option string options automatically.
3. **Network Mapping Assumption:** By default, the fallback engine builds standard inbound application traffic structures targeting network port `80`. If your application container exposes custom protocols or expects complex non-standard interface maps, you must upgrade your workspace configuration layout to use an **Archetype 1 (`run.sh`)** or **Archetype 2 (`docker-compose.yml`)** architecture blueprint.

## 💾 Hardware Mappings & Volume Storage Design Patterns

When configuring container storage layouts that communicate with persistent host tracking folders or raw hardware endpoints, your scripts must apply the following structural precaution:

### Pre-emptive Directory Creation Constraint
If a container configuration maps an empty host directory volume binding (e.g., `-v /home/pi/captures:/root/captures`), and that path does not exist on the host filesystem prior to execution, the Docker engine daemon automatically creates that target structure under **root-ownership permissions**. This locks out local, unprivileged system users from modifying, editing, or copying captured metrics.

To prevent this host directory lockout anomaly, any custom script engine running within your workspace layout must explicitly fire off host-level `mkdir -p` validation checks *before* letting the container invocation loop initialize:

```bash
# Explicitly assert host-level structure generation prior to deployment initialization
mkdir -p "${HOST_CAPTURES_PATH:-$SCRIPT_DIR/captures}"
mkdir -p "${HOST_MSF_DATA_PATH:-$SCRIPT_DIR/.msf4}"

# With safe file ownership established, the engine can invoke virtualization bindings
$DOCKER run -d   --name "$CONTAINER_NAME"   -v "${HOST_CAPTURES_PATH:-$SCRIPT_DIR/captures}:/root/captures"   -v "${HOST_MSF_DATA_PATH:-$SCRIPT_DIR/.msf4}:/root/.msf4"   pi-wardriver:latest
```