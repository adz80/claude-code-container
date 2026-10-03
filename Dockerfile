# syntax=docker/dockerfile:1
FROM beevelop/claude:latest

# Bake patched entrypoint directly into the image.
# Key differences from beevelop/claude original:
#   - No credentials → sleep infinity (not headless claude login → crash loop)
#   - RC failure     → retry up to 5x with 30s delay, then sleep infinity
#   - RC clean exit  → sleep 10s and restart (keeps container alive)
#   - Org eligibility error → prints actionable fix and retries
#   - CLAUDE_CODE_OAUTH_TOKEN → explicitly warns it cannot be used for RC

USER root

RUN <<'EOF'
cat > /home/developer/bin/entrypoint.sh << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

echo "[claude-entrypoint] Starting Claude Code container..."

# --- SSH deploy key setup ---
if [[ -n "${DEPLOY_KEY_B64:-}" ]]; then
  echo "[claude-entrypoint] Configuring SSH deploy key..."
  echo "${DEPLOY_KEY_B64}" | base64 -d > /home/developer/.ssh/id_ed25519
  chmod 600 /home/developer/.ssh/id_ed25519
  echo "[claude-entrypoint] SSH deploy key configured."
else
  echo "[claude-entrypoint] No deploy key found; skipping SSH setup."
fi

# --- Git user config ---
if [[ -n "${GIT_USER_NAME:-}" ]]; then
  git config --global user.name "${GIT_USER_NAME}"
  echo "[claude-entrypoint] Git user.name set to '${GIT_USER_NAME}'"
fi
if [[ -n "${GIT_USER_EMAIL:-}" ]]; then
  git config --global user.email "${GIT_USER_EMAIL}"
  echo "[claude-entrypoint] Git user.email set to '${GIT_USER_EMAIL}'"
fi

# --- Auto-clone repository ---
if [[ -n "${GIT_REPO:-}" ]]; then
  BRANCH="${GIT_BRANCH:-}"
  if [[ -z "$(ls -A /workspace 2>/dev/null)" ]]; then
    echo "[claude-entrypoint] Cloning ${GIT_REPO}..."
    CLONE_ARGS=("--single-branch")
    if [[ -n "${BRANCH}" ]]; then
      CLONE_ARGS+=("--branch" "${BRANCH}")
    fi
    git clone "${CLONE_ARGS[@]}" "${GIT_REPO}" /workspace
    echo "[claude-entrypoint] Repository cloned."
  else
    echo "[claude-entrypoint] /workspace is not empty; skipping clone."
  fi
fi

# --- One-time init command ---
INIT_MARKER="/home/developer/.claude/.init_done"
if [[ -n "${INIT_COMMAND:-}" ]]; then
  if [[ ! -f "${INIT_MARKER}" ]]; then
    echo "[claude-entrypoint] Running INIT_COMMAND..."
    bash -lc "${INIT_COMMAND}"
    mkdir -p /home/developer/.claude
    touch "${INIT_MARKER}"
    echo "[claude-entrypoint] INIT_COMMAND complete."
  else
    echo "[claude-entrypoint] INIT_COMMAND already completed; skipping."
  fi
fi

echo "[claude-entrypoint] Claude Code version: $(claude --version)"

# --- Workspace trust ---
CLAUDE_JSON="/home/developer/.claude.json"
if [[ -f "${CLAUDE_JSON}" ]]; then
  jq --arg ws "/workspace" \
    '.remoteDialogSeen = true | .projects[$ws].hasTrustDialogAccepted = true' \
    "${CLAUDE_JSON}" > "${CLAUDE_JSON}.tmp" \
    && mv "${CLAUDE_JSON}.tmp" "${CLAUDE_JSON}"
else
  echo '{"hasCompletedOnboarding":true,"remoteDialogSeen":true,"projects":{"/workspace":{"hasTrustDialogAccepted":true}}}' \
    > "${CLAUDE_JSON}"
fi
echo "[claude-entrypoint] Workspace trust accepted for /workspace."

# --- Warn if CLAUDE_CODE_OAUTH_TOKEN is set (cannot be used for Remote Control) ---
if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  echo ""
  echo "[claude-entrypoint] WARNING: CLAUDE_CODE_OAUTH_TOKEN cannot be used for Remote Control."
  echo "[claude-entrypoint] Remove it from your environment. Auth requires: claude auth login"
  echo ""
fi

# --- Authentication check ---
CRED_FILE="/home/developer/.claude/.credentials.json"

if [[ -f "${CRED_FILE}" ]] && [[ -s "${CRED_FILE}" ]]; then
  echo "[claude-entrypoint] Existing credentials found."
else
  echo ""
  echo "=============================================="
  echo "  ACTION REQUIRED: No credentials found."
  echo ""
  echo "  1. Open Portainer console for this container"
  echo "  2. Run: claude auth login"
  echo "  3. Complete browser OAuth on your Mac"
  echo "  4. Restart this container"
  echo "=============================================="
  exec sleep infinity
fi

# --- Build launch args ---
MODE="${CLAUDE_PERMISSION_MODE:-acceptEdits}"
SESSION_NAME="${CLAUDE_SESSION_NAME:-chewbacca-claude}"

LAUNCH_ARGS=("claude" "remote-control"
  "--permission-mode" "${MODE}"
  "--name" "${SESSION_NAME}")

if [[ -n "${CLAUDE_EXTRA_ARGS:-}" ]]; then
  read -ra EXTRA <<< "${CLAUDE_EXTRA_ARGS}"
  LAUNCH_ARGS+=("${EXTRA[@]}")
fi

# --- Launch Remote Control with retry on failure ---
MAX_RETRIES=5
RETRY_DELAY=30
attempt=1

while true; do
  echo "[claude-entrypoint] Launching (attempt ${attempt}): ${LAUNCH_ARGS[*]}"

  set +e
  RC_OUTPUT=$("${LAUNCH_ARGS[@]}" 2>&1)
  RC_EXIT=$?
  set -e

  if [[ ${RC_EXIT} -eq 0 ]]; then
    echo "[claude-entrypoint] Remote Control exited cleanly. Restarting in 10s..."
    sleep 10
    attempt=1
    continue
  fi

  echo "[claude-entrypoint] Remote Control failed (exit ${RC_EXIT}):"
  echo "${RC_OUTPUT}"

  if echo "${RC_OUTPUT}" | grep -q "Unable to determine your organization"; then
    echo ""
    echo "[claude-entrypoint] Fix: exec into container and run:"
    echo "  claude auth logout && claude auth login"
    echo ""
  elif echo "${RC_OUTPUT}" | grep -q "full-scope login token"; then
    echo ""
    echo "[claude-entrypoint] Fix: exec into container and run:"
    echo "  claude auth login"
    echo ""
  elif echo "${RC_OUTPUT}" | grep -q "requires a claude.ai subscription"; then
    echo ""
    echo "[claude-entrypoint] Fix: ensure you have a Pro or Max claude.ai subscription."
    echo "  Then exec into container and run: claude auth login"
    echo ""
  fi

  if [[ ${attempt} -ge ${MAX_RETRIES} ]]; then
    echo "[claude-entrypoint] Failed after ${MAX_RETRIES} attempts. Sleeping to prevent crash loop."
    echo "[claude-entrypoint] Exec into container and fix auth, then restart the container."
    exec sleep infinity
  fi

  echo "[claude-entrypoint] Retrying in ${RETRY_DELAY}s (attempt ${attempt}/${MAX_RETRIES})..."
  sleep "${RETRY_DELAY}"
  attempt=$((attempt + 1))
done
SCRIPT
chmod +x /home/developer/bin/entrypoint.sh
chown developer:developer /home/developer/bin/entrypoint.sh
EOF

USER developer

ENTRYPOINT ["/home/developer/bin/entrypoint.sh"]
