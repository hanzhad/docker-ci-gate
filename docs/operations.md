# Operations Runbook

## 1. GitHub Token Permissions

Create a fine-grained PAT (or one per organization) with:

- **Administration:** Read & Write (needed to register self-hosted JIT runners)
- **Actions:** Read & Write (needed to poll queued jobs and switch `CI_RUNNER` variables)
- **Metadata:** Read-only

Unlock the gate after startup or reboot:

```sh
# Linux / WSL
printf '%s\n' "$GITHUB_GATE_PAT" | ci-runner unlock --stdin

# macOS (reads clipboard)
ci-runner unlock
```

For unattended reboot recovery behind a single PIN, pair with [`pin-vault`](https://github.com/hanzhad/pin-vault) using `ci-runner unlock --stdin` as the receiver command.

## 2. Switching Workflows Without Editing YAML

`ci-runner on <owner>/<repo>` sets repository variables `CI_RUNNER=1` and `CI_RUNNER_LABEL` so workflows can route between GitHub-hosted and local runners without modifying workflow files on every toggle. `ci-runner off <owner>/<repo>` flips `CI_RUNNER=0` immediately.

Use `ci-runner watch <owner>/<repo> --reserve 30` to monitor included GitHub Actions minutes and flip to local runners automatically when the reserve threshold is crossed.

## 3. Windows / WSL2 Keepalive

On Windows/WSL2, WSL shuts down when no Windows process holds it open. Register the hidden keepalive logon task from PowerShell:

```powershell
.\windows\install-tasks.ps1
```

Pair this with [`pin-vault`](https://github.com/hanzhad/pin-vault) (`install-logon-task.ps1`) so the gate unlocks at logon without storing tokens on disk.

## 4. Multi-Machine & Redeploy

- **Second helper machine:** pass `--defer <seconds>` on a secondary host so the primary machine claims jobs first and the secondary picks up overflow.
- **Zero-downtime update:** `ci-runner redeploy` rebuilds images and restarts `ci-gate` cleanly; with `CI_RUNNER_UNLOCK_CMD` (or `pin-vault`) configured, it re-unlocks automatically.

## 5. Common Checks & Troubleshooting

- `ci-runner doctor` — verifies Docker daemon, image freshness, registry entries, and gate lock state.
- `ci-runner status` — shows active `little`/`big`/`mega` runners, core budget usage, and per-repo switch state.
- `docker logs -f ci-gate` — inspect per-tick polling and scheduling decisions.
