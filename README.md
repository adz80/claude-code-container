# claude-code-container

24/7 Claude Code container for Portainer with Remote Control support. Drive it from the Claude iOS/Android app or claude.ai/code.

Builds on top of [beevelop/docker-claude](https://github.com/beevelop/docker-claude) with a patched entrypoint that:
- Never crash-loops on auth or RC failure
- Retries Remote Control up to 5x with 30s delay on failure
- Keeps the container alive (sleep infinity) when action is required
- Prints clear fix instructions in logs for every failure mode

## How it works

```
iPhone (Claude app → Code tab)
    ↕  HTTPS via Anthropic relay (outbound only, no inbound ports)
claude-code container on chewbacca.dev
    └─ claude remote-control --name chewbacca-claude
    └─ /home/developer/.claude  ← named volume (auth + sessions persist)
    └─ /workspace               ← named volume (clone repos here)
```

## Prerequisites

- Portainer running on your home server
- Claude Pro or Max subscription (Remote Control requires it)
- Claude app on your phone (iOS or Android)

## Deployment via Portainer

### 1. Push this repo to GitHub

```bash
cd /path/to/claude-code-container
git remote add origin https://github.com/adz80/claude-code-container.git
git push -u origin main
```

### 2. Deploy in Portainer

1. Portainer → **Stacks → Add stack**
2. Select **Repository** tab
3. Fill in:
   - **Repository URL**: `https://github.com/adz80/claude-code-container`
   - **Branch**: `main`
   - **Compose file path**: `docker-compose.yml`
4. Click **Deploy the stack**

Portainer pulls the repo, builds the image from the `Dockerfile`, and deploys. No manual `docker build` needed.

### 3. First-time auth (one-time setup)

The container starts but Remote Control needs a full OAuth login first.

1. In Portainer → **Containers → claude-code → Console → Connect**
2. Run:
   ```bash
   claude auth login
   ```
3. Copy the URL it prints and open it in your browser on your Mac
4. Complete the OAuth login with your claude.ai account
5. Back in the console — you'll see `Login successful`
6. **Restart the container** in Portainer

On restart the container finds your credentials, launches `claude remote-control`, and the session appears in your Claude app.

### 4. Connect from your phone

1. Open the Claude app → **Code** tab
2. Find the session named `chewbacca-claude`
3. Connect and start coding

## Credentials persistence

Auth is stored in the `claude-config` named volume at `/home/developer/.claude/.credentials.json`. It persists across:
- Container restarts
- Stack redeployments
- Image rebuilds

You should only need to re-auth once a year (tokens last ~12 months).

## Troubleshooting

### Logs show: `Unable to determine your organization for Remote Control eligibility`

Stale cached account info. Exec into the container and run:
```bash
claude auth logout && claude auth login
```
Then restart the container.

### Logs show: `ACTION REQUIRED: No credentials found`

Container is waiting — exec in and run:
```bash
claude auth login
```
Then restart.

### Logs show: `requires a full-scope login token`

You have `CLAUDE_CODE_OAUTH_TOKEN` set — this token type cannot be used for Remote Control. Remove it from your environment and use `claude auth login` instead.

### Container keeps restarting

Check logs in Portainer. The patched entrypoint will retry RC 5 times then switch to `sleep infinity` — container stays alive and stops crash-looping. Exec in, fix auth, restart.

### Session doesn't appear in Claude app

- Check logs for `Launching: claude remote-control` — if you see it, wait 10-15 seconds
- Ensure you have a Pro or Max claude.ai subscription
- Remote Control requires `api.anthropic.com` access (no proxies/custom base URLs)

## Updating

When a new version of Claude Code ships, rebuild the image in Portainer:

**Stacks → claude-code → Editor → Update the stack**

Or pull the latest base image and redeploy:
```bash
docker pull beevelop/claude:latest
```
Then redeploy via Portainer.

## Volumes

| Volume | Mount | Purpose |
|---|---|---|
| `claude-config` | `/home/developer/.claude` | Auth credentials, sessions, settings |
| `claude-workspace` | `/workspace` | Your git repos and code |

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `TZ` | `Australia/Melbourne` | Container timezone |
| `CLAUDE_SESSION_NAME` | `chewbacca-claude` | Session name shown in Claude app |
| `CLAUDE_PERMISSION_MODE` | `acceptEdits` | `acceptEdits`, `default`, or `bypassPermissions` |
| `GIT_USER_NAME` | `adz80` | Git commit author name |
| `GIT_USER_EMAIL` | `adamboyce.home@gmail.com` | Git commit author email |
| `GIT_REPO` | _(unset)_ | Optional: SSH/HTTPS URL to auto-clone into `/workspace` on first start |
| `CLAUDE_EXTRA_ARGS` | _(unset)_ | Extra flags passed to `claude remote-control` |
| `INIT_COMMAND` | _(unset)_ | One-time shell command run on first container start |
