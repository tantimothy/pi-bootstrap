# 🏗️ Environment Workspace Developer Guide

This guide establishes the layout requirements and integration standards for creating custom application workspaces within the Raspberry Pi Docker Orchestrator. 

By adhering to this blueprint, your application environment will automatically register with the central terminal dashboard, leverage the interactive secret-management forms, and fit cleanly into the system's runtime state machines.

---

## 📂 Workspace Folder Layout Standards

The parent orchestrator maps out application contexts by indexing target subdirectories inside `/environments/`. To create a compliant workspace, populate your folder using one of the three following setup configurations:

```text
environments/
└── custom-workspace-name/
    ├── .env.example              # CRITICAL: Secret Template Blueprint
    │
    ├── Archetype 1: run.sh       # Custom Bash Pipeline
    │   └── Dockerfile
    │
    ├── Archetype 2: compose.yml  # Multi-Container Microservice Engine
    │   └── docker-compose.yml
    │
    └── Archetype 3: Dockerfile   # Standalone Automation Fallback
        └── Dockerfile
```

---

## 🔐 The Metadata Configuration Syntax Blueprint (`.env.example`)

The central dashboard uses your configuration template file to dynamically generate user forms. To ensure your configuration parameters map correctly to the interactive TUI pre-processor, you must structure your `.env.example` according to these strict rules:

1. **Comment Placement:** Every user-configurable key must be preceded immediately by one or more comment lines starting with a single `#`. 
2. **User Documentation:** Write clear, concise structural descriptions inside the comment blocks. This text is pulled dynamically and displayed inside a full-screen scrollable window before user input fields are generated.
3. **Default Assignment:** Define safe, functional fallbacks after the `=` character wherever applicable. If a parameter is highly sensitive or mandatory (e.g., private keys, admin credentials), leave the field blank to force explicit user initialization.

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

---

## 🎯 Container Identity Tracking Specification (`CONTAINER_NAME`)

To prevent state tracking blind spots, **every workspace must explicitly declare its container signatures.** Define the `CONTAINER_NAME` variable inside your `.env.example` file. 

If this variable is missing, the parent engine falls back to using the workspace folder name. This name fallback breaks accurate tracking for compound environments or custom setups.

### Single-Container Tracking Blueprints
For simple standalone applications, assign a single alphanumeric string value:
```ini
CONTAINER_NAME=sdr-dragon-os
```

### Multi-Container Stack Tracking Blueprints (Space-Separated Arrays)
If your workspace deploys a collection of microservices (e.g., Pi-hole coupled with a WireGuard VPN gateway), define **all** container names within a single, space-separated string array:
```ini
CONTAINER_NAME="pihole-service wireguard-vpn wg-easy-dashboard"
```
*Why this matters:* When a user applies a `CLEAN` rebuild policy, the central engine splits this tracking string into a loop array. It will target, stop, and completely purge every single container listed here before letting structural builds fire up. This completely prevents orphaning legacy services or hitting runtime interface bind conflicts.

---

## 🚀 The Three Environment Deployment Archetypes

### Archetype 1: Custom Orchestration Shell (`run.sh`)
Use this configuration whenever an environment requires advanced host system integration, kernel driver modules, or complex device pass-through configurations (e.g., SDR dongles or GPS hardware).

#### Execution Guidelines:
* **Engine Abstraction:** Never call raw `docker` commands directly. You must inherit the parent dashboard's permission model by wrapping operations within the `$DOCKER_CMD` variable fallback.
* **Pipeline TTY Override (For Interactive Environments):** Because the parent orchestrator often runs in a detached pipeline thread (`curl | bash`), standard interactive flags (`-it`) will crash with a "stdin is not a terminal" error. To deploy an interactive foreground TUI or shell, you **must** sever the background pipeline hooks and bind standard streams to the physical terminal using the `exec` command before invoking Docker.
* **Detached Execution (For Background Daemons):** If your environment is purely a background service without a terminal UI, omit `-it` and run detached (`-d`) governed by an active `--restart unless-stopped` health model.
* **Secret Acquisition:** Manually ingest compiled TUI variables by sourcing the generated `.env` configuration file at the start of your script.

```bash
#!/bin/bash
# Inherit engine wrappers from the main dashboard context safely
DOCKER=${DOCKER_CMD:-docker}

# Ingest dynamically generated local secrets
if [ -f ".env" ]; then
    export $(cat .env | xargs)
fi

echo "🛑 Cleaning up active instances..."
$DOCKER stop "$CONTAINER_NAME" 2>/dev/null
$DOCKER rm "$CONTAINER_NAME" 2>/dev/null

echo "⚡ Launching localized structural compilation layer..."
$DOCKER build -t "pi-pentest:latest" .

echo "🚀 Executing non-interactive container with advanced hardware profiles..."
$DOCKER run -it --rm \
  --name "$CONTAINER_NAME" \
  --privileged \
  --net=host \
  -v /dev:/dev \
  -e TARGET_INTERFACE="${WIFI_INTERFACE:-wlan1}" \
  pi-pentest:latest
```

### Archetype 2: Multi-Container Microservice Stack (`docker-compose.yml`)
Best for combining multiple interdependent containers. Docker Compose automatically handles environment generation and tracks shared network configurations:
* Ensure keys in `docker-compose.yml` map directly to parameters defined in `.env.example`.
* Docker Compose automatically picks up variables saved to the generated local `.env` file at runtime.
* To avoid multi-container tracking issues, ensure your service definitions declare explicit `container_name` entries matching the string array values specified inside your workspace `CONTAINER_NAME` variable.

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
```

### Archetype 3: Pure Standalone Fallback (`Dockerfile`)
If your subdirectory contains only a standalone `Dockerfile` without a `run.sh` or a `docker-compose.yml`, the parent orchestrator steps in and executes its automated engine:
1. It reads the local configured variables and compiles the application context under a standard local tag (`$ENV_NAME:latest`).
2. It provisions the container environment and injects variables by appending the `--env-file .env` flag options automatically.
3. It maps internal application processes to port `80` by default. If your container relies on specific non-standard network sockets, you must upgrade your workspace environment to use a custom `run.sh` or `docker-compose.yml` architecture layout.

---

## 💾 Hardware Mappings & Volume Storage Design Patterns

When your containers require persistent host storage bindings or hardware access, your setup assets must follow strict permission safeguards to prevent host access conflicts:

### Pre-emptive Directory Creation Constraint
If a container configuration maps an empty host directory volume binding (e.g., `-v /home/pi/captures:/root/captures`), the Docker daemon will automatically initialize those target paths under **root-ownership permissions** if they do not exist prior to container execution. This locks out normal system users from modifying or copying files locally.

To prevent this permission lockout, your custom `run.sh` scripts must explicitly execute host-level `mkdir -p` assertions *before* spinning up the container initialization pipeline:

```bash
# Pre-emptively generate tracking paths to retain correct host user account permissions
mkdir -p "${HOST_CAPTURES_PATH:-PWD/captures}"
mkdir -p "${HOST_MSF_DATA_PATH:-PWD/.msf4}"

# Now it is completely safe to invoke the virtualization wrapper sequence
$DOCKER run -d \
  --name "$CONTAINER_NAME" \
  -v "${HOST_CAPTURES_PATH:-PWD/captures}:/root/captures" \
  pi-wardriver:latest
```