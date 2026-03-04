# Troubleshooting

## "Not logged in" inside container

- Verify host login: `claude login`
- Check Keychain: `security find-generic-password -s "Claude Code-credentials" -w | jq .`

## "Image not found"

- Build first: `./launch.sh --rebuild`

## Build OOM ("cannot allocate memory")

- Increase builder memory: `BUILD_MEMORY=12g ./launch.sh --rebuild`

## 401 "invalid x-api-key" errors

- Your project's `.env` file likely contains `ANTHROPIC_API_KEY`. Claude Code autoloads `.env`, overriding OAuth with a stale key.
- Both scripts set `ANTHROPIC_API_KEY=` (empty) to prevent this.

## GitHub push/PR not working inside container

- Verify `gh auth status` on host
- Check SSH key: `ssh -T git@github.com` inside container
- Ensure `gh:github.com` entry exists in Keychain: `security find-generic-password -s "gh:github.com"`

## Container system not running

- Start the runtime: `container system start`

## "Query closed before response received" in Zed

- Ensure `CLAUDE_CODE_EXECUTABLE` is **not** set in Zed's env block
- Check ACP logs: `tail -f /tmp/zed-claude-acp.log`
