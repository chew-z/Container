# Machine Mode Implementation

## Context

The project wraps Apple's `container` CLI to run Claude Code in sandboxed containers. Currently only ephemeral mode exists (`launch.sh` → `container run --rm`). Apple Container 1.0.0 added `container machine` for persistent VMs. This plan adds `machine-launch.sh` using `--home-mount none` to get persistence + speed **without** surrendering host filesystem isolation.

## Critical CLI Correction

The design doc states credentials go via `--env-file` at `machine create` time. **This is wrong** — `machine create` does NOT support `--env` or `--env-file`. Only `machine run` does. Credentials must be passed at first `machine run` (provisioning) and persisted inside the machine filesystem for subsequent runs.

## Files to Create/Modify

| File | Action | Purpose |
|---|---|---|
| `machine-launch.sh` | **Create** (~500 lines) | Main machine mode entry point |
| `cleanup.sh` | **Modify** (+80 lines) | Add `--machines` command family |
| `container-run.example.toml` | **Modify** (+15 lines) | Add `[machine]` section |
| `RUNNING.md` | **Modify** (+50 lines) | Machine mode docs section |

---

## Task 1 — `machine-launch.sh`: Skeleton + Shared Infrastructure

Reuse from `launch.sh` (copy, not source — scripts are self-contained):
- Symlink-safe `SCRIPT_DIR` resolution (lines 6-12)
- `GLOBAL_CONFIG_DIR`, `resolve_config()` (lines 14-24)
- `toml_get()`, `toml_get_array()` (lines 85-178)
- `project_slug()` (lines 256-258)
- `ensure_system_running()` (adapted from cleanup.sh pattern)

Constants:
```bash
MACHINE_PREFIX="claude-machine-"
BASE_IMAGE="alpine:latest"
PROVISION_SENTINEL="/var/lib/claude-machine-provisioned"
```

## Task 2 — Argument Parsing

Adapt from `launch.sh` parser. **Remove**: `--rebuild`, `--full-rebuild`, `--rw`, `--update-claude`, `--lang`, `--config`. **Add**: `--reprovision`/`--reset` (delete + recreate machine), `--status` (show state), `--shell` (drop to shell), `--spike` (Phase 0 validation). **Keep**: `-C`, `--memory`, `--cpus`, `--template-dir`, `-h`, `-- CLAUDE_ARGS`.

## Task 3 — Config Resolution

Read `container-run.toml` with same layered resolution. Same sections as `launch.sh` plus new `[machine]`:
```toml
[machine]
git_user_name = ""      # fallback when host ~/.gitconfig lacks user.name
git_user_email = ""     # fallback when host ~/.gitconfig lacks user.email
```
Resource precedence: CLI `--memory/--cpus` > `[machine]` > `[resources]` > defaults (4g/4cpus).

## Task 4 — Credential + Git Identity Extraction

- Claude credentials from Keychain (`Claude Code-credentials`) — same as launch.sh
- GH_TOKEN from Keychain (`gh:github.com`) with `go-keyring-base64:` decoding — same as launch.sh
- MCP tokens from Keychain per server — same as launch.sh
- ENABLED_MCP_SERVERS from `~/.claude/settings.local.json` — same as launch.sh
- **Git identity** (new): read host `git config --global user.name/email`, fall back to `[machine]` config, hard-fail if neither
- **Repo URL** (new): `git remote get-url origin` from host project, convert SSH→HTTPS
- **Claude settings** (new): read `~/.claude/settings.json`, `settings.local.json`, `.claude.json` content for injection into machine

## Task 5 — Machine Existence Check + Create-or-Reuse

```bash
machine_exists() {
    container machine list --quiet 2>/dev/null | grep -qx "$MACHINE_NAME"
}
```

Main flow: if `--reprovision` → delete + recreate. If exists → `reenter_machine()`. Else → `create_and_provision_machine()`.

## Task 6 — Machine Creation

```bash
container machine create \
    --name "$MACHINE_NAME" \
    --home-mount none \
    --cpus "$machine_cpus" --memory "$machine_memory" \
    --arch arm64 \
    "$BASE_IMAGE"
```

## Task 7 — Provisioning Script (Core Logic)

Delivered as a **heredoc via stdin** to `container machine run --root --env-file $prov_env_file -e "MULTILINE_VARS..." -- /bin/sh -s`. This