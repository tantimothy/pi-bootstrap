#!/usr/bin/env bash
# Installs or refreshes NanoClaw's upstream Codex provider payload without
# entering its OAuth walkthrough. This is the non-interactive half of:
#
#   pnpm exec tsx setup/index.ts --step provider-auth codex
#
# The upstream provider-auth step deliberately combines installation and
# authentication. CLEAN must remain headless, so this script calls the same
# exported directive engine used by that step, then stops before runAuth().
#
# Usage:
#   install-codex-provider.sh /absolute/path/to/nanoclaw

set -euo pipefail

INSTALL_PATH="${1:?Usage: $0 /absolute/path/to/nanoclaw}"
SKILL_DIR=".claude/skills/add-codex"

if [ ! -d "$INSTALL_PATH/.git" ] || [ ! -f "$INSTALL_PATH/$SKILL_DIR/SKILL.md" ]; then
    echo "❌ Current NanoClaw source does not contain $SKILL_DIR/SKILL.md." >&2
    echo "   Run CLEAN again after updating pi-bootstrap/NanoClaw." >&2
    exit 1
fi

if [ ! -f "$INSTALL_PATH/setup/providers/install.ts" ]; then
    echo "❌ Current NanoClaw source has no provider directive installer." >&2
    echo "   Refusing to hand-copy provider files from a potentially incompatible release." >&2
    exit 1
fi

cd "$INSTALL_PATH"

# A freshly-cloned checkout has no node_modules yet. This is still headless;
# the later NanoClaw setup/build reuses the installed dependency tree.
pnpm install

# NanoClaw installs the OneCLI CLI into the machine running setup. In this
# environment that "machine" is the disposable orchestrator container, so
# CLEAN removes the CLI even though the separate OneCLI gateway and its
# encrypted data volume correctly survive. Restore the upstream-pinned CLI
# through NanoClaw's own install-only remote-gateway path when a persistent
# ONECLI_URL already exists. A completely fresh install has no URL yet; its
# normal first-run wizard owns initial OneCLI setup.
if ! command -v onecli >/dev/null 2>&1; then
    ONECLI_URL=""
    if [ -f .env ]; then
        ONECLI_URL=$(sed -n 's/^ONECLI_URL=//p' .env | tail -1)
        ONECLI_URL="${ONECLI_URL#\'}"
        ONECLI_URL="${ONECLI_URL%\'}"
        ONECLI_URL="${ONECLI_URL#\"}"
        ONECLI_URL="${ONECLI_URL%\"}"
    fi
    if [ -n "$ONECLI_URL" ]; then
        echo "🔐 Restoring NanoClaw's pinned OneCLI CLI for the persistent vault..."
        pnpm exec tsx setup/index.ts --step onecli --remote-url "$ONECLI_URL"
    else
        echo "ℹ️  OneCLI is not initialized yet; the first-run wizard will install it."
    fi
fi

echo "🤖 Installing/refreshing NanoClaw's Codex provider payload (authentication deferred)..."
pnpm exec tsx -e '
void (async () => {
  const { applyProviderSkill } = await import("./setup/providers/install.ts");
  const result = await applyProviderSkill(".claude/skills/add-codex", process.cwd());
  if (result.blockers.length) {
    console.error(`Codex provider install blocked: ${result.blockers.join("; ")}`);
    process.exit(1);
  }
  console.log(result.changed
    ? "Codex provider payload updated."
    : "Codex provider payload already current.");
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
'

# These are the upstream skill's install-complete invariants. Keep this check
# independent of OAuth: an unauthenticated but fully prepared runtime is the
# intended post-CLEAN state.
required_files=(
    src/providers/codex.ts
    src/providers/codex-agents-md.ts
    container/agent-runner/src/providers/codex.ts
    container/agent-runner/src/providers/codex-app-server.ts
    setup/providers/codex.ts
    container/cli-tools.json
)
for required_file in "${required_files[@]}"; do
    if [ ! -f "$required_file" ]; then
        echo "❌ Codex provider install incomplete: missing $required_file" >&2
        exit 1
    fi
done

for barrel in \
    src/providers/index.ts \
    container/agent-runner/src/providers/index.ts \
    setup/providers/index.ts; do
    if ! grep -Fq "import './codex.js';" "$barrel"; then
        echo "❌ Codex provider install incomplete: $barrel is not wired." >&2
        exit 1
    fi
done

if ! grep -Fq '"@openai/codex"' container/cli-tools.json; then
    echo "❌ Codex provider install incomplete: @openai/codex is absent from container/cli-tools.json." >&2
    exit 1
fi

# The manifest above installs Codex in spawned agent images. OAuth itself is
# performed by NanoClaw's host-side setup step, which means the disposable
# orchestrator needs the same pinned CLI as well. Derive the version from
# upstream's manifest rather than carrying a second pin in pi-bootstrap.
CODEX_CLI_VERSION=$(node -e '
const tools = JSON.parse(require("fs").readFileSync("container/cli-tools.json", "utf8"));
const codex = tools.find((tool) => tool && tool.name === "@openai/codex");
if (!codex || !codex.version) process.exit(1);
process.stdout.write(String(codex.version));
')
echo "📦 Installing host-side @openai/codex@$CODEX_CLI_VERSION for the later OAuth action..."
npm install -g "@openai/codex@$CODEX_CLI_VERSION"
codex --version

echo "✅ Codex provider source and both CLI surfaces are ready; OAuth remains unconfigured."
