# 🐳 Raspberry Pi Multi-Environment Docker Deployer

A smart, stateless, and lightweight TUI (Terminal User Interface) deployment dashboard for managing multi-environment Docker configurations on a Raspberry Pi. 

This repository allows you to skip hosting large Docker images in external registries. Instead, it pulls raw code or environment workspaces directly from GitHub and compiles them locally using the Raspberry Pi's native ARM processor.

---

## 🏗️ Repository Structure

Organize your project into isolated workspace folders inside the `environments/` directory. Each folder can contain its own independent setup assets, localized configuration files (`.env`), or custom hardware-access profiles.

```text
├── deploy.sh                 # The main deployment orchestrator script
├── README.md                 # This documentation file
└── environments/             # Isolated app workspaces
    ├── dev-compose/          # Setup Type 1: Docker Compose
    │   └── docker-compose.yml
    ├── prod-custom-run/      # Setup Type 2: Custom Bash Run Execution
    │   ├── Dockerfile
    │   └── run.sh
    └── standalone-app/       # Setup Type 3: Pure Dockerfile Fallback
        └── Dockerfile
```

## 🚀 Interactive Deployment Modes

You can run the deployment routine in two flexible configurations:

**Mode A: Stateless Execution (Zero-Setup Remote Curl)**

Perfect for brand new or stateless Pis. You do not even need to copy the deployment script manually. Run this single command to pull down, update, and launch the deployment suite:

```bash
curl -sSL [https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME/main/deploy.sh](https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME/main/deploy.sh) | bash
```

_(If your repository is private, pass your Personal Access Token in the header like this:)_

```bash
curl -sSL -H "Authorization: token YOUR_GITHUB_TOKEN" \
[https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME/main/deploy.sh](https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME/main/deploy.sh) | bash
```

**Mode B: Local Repository Execution**

If you clone this repository down to your Pi to test edits manually, the script automatically detects it is inside a valid git working directory. It will bypass generic fallback paths and target your active working path directly:

```bash
chmod +x deploy.sh
./deploy.sh
```

## 🛠️ Supported Environment Types

When an environment workspace is selected from the menu interface, the orchestration engine evaluates files sequentially and selects the best matching routine:
1. Custom Shell (`run.sh`): Best for advanced options (e.g., matching Raspberry Pi hardware access arrays like `--device /dev/gpiomem`).
2. Docker Compose (`docker-compose.yml`): Best for multi-container microservice stacks.
3. Pure Dockerfile (`Dockerfile`): Universal automated build fallback (maps internal app services automatically to port `80`).

## ⚙️ Host System Architecture Requirements

To run this pipeline cleanly out of the box, log into your Raspberry Pi and complete the initial setup:

1. **Core Engine Setup (Docker)**

```bash
curl -fsSL [https://get.docker.com](https://get.docker.com) -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER
```
_(Log out and back in to apply new user system permissions)._

2. **Boot Persistence Assurance**

Docker starts up automatically when your Raspberry Pi boots up. To ensure your deployed apps also restart automatically after system reboots or unexpected power cuts, verify that your compose files or run scripts use an explicit restart flag:

 - **Docker Compose**: Include `restart: unless-stopped` under your service configs.
 - **Custom Scripts**: Add `--restart unless-stopped` to your raw `docker run` execution lines.

3. **(Optional) Run Dashboard on SSH Login**

If you want this interactive environment chooser to instantly welcome you every single time you connect to your Pi over SSH, append the launch line to your user terminal profile:

```bash
echo "curl -sSL [https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME/main/deploy.sh](https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME/main/deploy.sh) | bash" >> ~/.bashrc
```

## 🧹 Automated System Maintenance
Raspberry Pi micro-SD storage configurations fill up rapidly during local builds. To mitigate this risk, this orchestration script forces a strict teardown policy (`docker compose down`) followed by a comprehensive background garbage collection process (`docker image prune -a -f`) upon every environment swap. This ensures completely vacant network port assignments and deletes orphaned base build cache layers safely.
