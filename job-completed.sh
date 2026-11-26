#!/usr/bin/env bash
#
# Runs after every job, as `runner`, via ACTIONS_RUNNER_HOOK_JOB_COMPLETED
# (set in the Dockerfile) — host-repo an earlier change, an earlier change.
#
# The working tree and build artifacts (/opt/runner/_work) live in the
# container's ephemeral layer and die with it (docker run --rm).
# Only the clean .git repository is synced back to /var/cache/ci-runner/git/.git
# (the persistent ci-runner-git-$slug volume) so subsequent jobs fetch instead
# of cloning from scratch.
#
# It never fails the job: a cleanup that cannot run is a disk to look at later,
# not a red check on somebody's pull request.
set -u

ws=${GITHUB_WORKSPACE:-}
[ -n "$ws" ] && [ -d "$ws" ] || exit 0

git_work=""
if [ -d "$ws/.git" ]; then
  git_work="$ws"
else
  found=$(find "$ws" -maxdepth 2 -name .git -type d 2>/dev/null | head -1)
  if [ -n "$found" ]; then
    git_work="$(dirname "$found")"
  fi
fi

if [ -n "$git_work" ] && [ -d "$git_work/.git" ]; then
  /usr/local/bin/scrub-git.sh "$git_work"
  rm -f "$git_work/.git/gc.log.lock" "$git_work/.git/gc.pid" "$git_work/.git/index.lock" "$git_work/.git/shallow.lock"
  rm -rf "$git_work/.git/worktrees" 2>/dev/null || true
  # Synchronous gc: gc.autoDetach=false ensures git finishes repacking before
  # the hook exits.
  git -C "$git_work" -c core.hooksPath=/dev/null -c core.fsmonitor=false -c gc.autoDetach=false -c gc.auto=6700 -c gc.autoPackLimit=20 gc --auto --quiet 2>/dev/null || true
  rm -f "$git_work/.git/gc.log.lock" "$git_work/.git/gc.pid"
  if [ -d "/var/cache/ci-runner/git" ]; then
    # Under the exclusive .sync lock, into .git.new, then swapped in:
    # a sync that fails half way leaves the old .git whole, never a mix.
    vol=/var/cache/ci-runner/git
    (
      flock -x 9 || exit 0
      rm -rf "$vol/.git.new"
      if rsync -a --delete "$git_work/.git/" "$vol/.git.new/" 2>/dev/null; then
        rm -rf "$vol/.git.old"
        if [ ! -e "$vol/.git" ] || mv "$vol/.git" "$vol/.git.old"; then
          mv "$vol/.git.new" "$vol/.git" || { [ -e "$vol/.git.old" ] && mv "$vol/.git.old" "$vol/.git"; }
        fi
        rm -rf "$vol/.git.old"
      fi
      rm -rf "$vol/.git.new"
    ) 9>>"$vol/.sync" 2>/dev/null || true
  fi
fi

exit 0
