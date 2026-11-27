# Architecture & Scheduling

## Two-Container Security Boundary

- **`ci-gate`** (`gate/Dockerfile`, ~30 MB Alpine): holds the GitHub PAT in a `tmpfs` mount (`/run/gate`), polls GitHub Actions every tick, enforces per-machine concurrency and memory ceilings, and spawns ephemeral `ci-runner` containers. It never checks out or executes repository code.
- **`ci-runner`** (`Dockerfile`, ~1.8 GB Ubuntu + Actions runner + Chromium deps): started with `--rm` for exactly one queued job using a single-use JIT registration token. When the job exits, the container and its workspace are destroyed.

## Why `--cpu-shares` Instead of `--cpus`

`--cpus` sets a hard ceiling: a `little` job capped at 1 CPU wastes 9 idle cores when nothing else runs, while two `big` jobs can still starve the host. `docker-ci-gate` prices `big` vs `little` classes with `--cpu-shares` against a single machine-wide `--budget`, letting a lone job burst across idle cores while guaranteeing proportional CPU under contention.

- **`mega` class:** waits for running jobs to drain (blocking new spawns) and claims the full machine budget for monolithic suites.
- **Machine limits:** checks `MemAvailable` and load average before spawning new runners so the host stays responsive.

## Why No Tunnel or Inbound Port

Everything dials GitHub outward over HTTPS:

1. `ci-gate` polls the Actions queued-runs API for registered repositories.
2. When a job is queued, `ci-gate` requests a JIT runner configuration from GitHub and starts `ci-runner`.
3. `ci-runner` connects outbound to GitHub Actions, runs the job, and exits.

No public IP, DNS record, reverse proxy, or firewall hole is required, and a dynamic home/office IP changes nothing.

## Per-Repository Volume Isolation & `flock`

Dependency caches (`pnpm` store, Playwright browsers, tool cache) are isolated per repository and guarded with `flock` (`.inuse` / `.sync`) and `cache-cap.sh` so concurrent jobs cannot corrupt shared caches or grow unboundedly. Read-only tool seeds are pre-populated from `seed.list` via `seed.sh`.

## Status Contract (`status.schema.json`)

`ci-runner.sh status --json` emits a `schema: 1` JSON document describing the gate container, lock state, active runners, and per-repository `CI_RUNNER` switch state for external dashboards such as [`ops-console`](https://github.com/hanzhad/ops-console).
