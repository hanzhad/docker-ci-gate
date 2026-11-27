# Agent Rules (hanzhad/docker-ci-gate)

- **Workflow:** Work on a feature branch, open a pull request with full context, and ensure CI (`test` + `scan`) passes before merging.
- **Commits:** Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`, `test:`).
- **Public safety:** Every change must pass `python3 scripts/scan.py --tree .` and `python3 scripts/scan.py --history`. Never commit tokens, credentials, personal emails, private repo references, or host-specific home paths.
- **Dependencies:** Keep runtime dependencies minimal (Bash, Docker, `curl`, `jq`, Python 3 stdlib for tooling) and portable across Linux and macOS.
