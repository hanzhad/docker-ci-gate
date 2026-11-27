#!/usr/bin/env bash
#
# cache-cap.sh <cap-MiB> <dir>… — empty each cache directory that has grown
# past the cap. entrypoint.sh runs it as root before the job, on the two
# caches that outlive a job: this repository's ~/.npm and ~/.cache volumes
#.
#
# A cache rebuilt once is cheaper than a disk nobody watches. Until the
# only thing that outlived a job besides these was the work folder, and
# nothing bounded it: a project's reached 5.5 GB. The volumes are smaller
# (598 MB and 333 MB on 2026-11-06) and were just as unbounded — npm's
# _cacache keeps every tarball every lockfile ever named.
#
# The directory itself stays, its contents go: it is a volume's mount point.
# A cap that is not an integer, or a directory that is not there, changes
# nothing. Never fails: a cap that cannot be applied is a disk to look at, not
# a red check on somebody's pull request.
set -u

cap=${1:-}; shift || true
case "$cap" in ''|*[!0-9]*) exit 0 ;; esac

for dir in "$@"; do
  [ -d "$dir" ] || continue
  used=$(du -sm "$dir" 2>/dev/null | cut -f1)
  case "$used" in ''|*[!0-9]*) continue ;; esac
  [ "$used" -gt "$cap" ] || continue
  # Every running job holds a shared lock on .inuse; emptying a volume
  # under one would pull the cache out from beneath it. Only the exclusive
  # lock, taken without waiting, says nobody is on it. The lock files stay.
  exec 8>>"$dir/.inuse" 2>/dev/null || continue
  if ! flock -n -x 8; then
    echo "▸ $dir holds ${used} MiB, over the ${cap} MiB cap — in use by another runner, left alone"
    exec 8>&-
    continue
  fi
  echo "▸ $dir holds ${used} MiB, over the ${cap} MiB cap — emptied; this job fills it again"
  find "$dir" -mindepth 1 -maxdepth 1 ! -name .inuse ! -name .sync -exec rm -rf {} + 2>/dev/null
  exec 8>&-
done

exit 0
