#!/usr/bin/env bash
#
# Main process of a self-hosted runner container. It runs as root for exactly two
# things, then drops to `runner` and never comes back — the design docs.
#
# There used to be two more. From 2026-09-21 to 2026-11-03, a socat proxy in
# front of the host's docker socket, owned by `runner`, for the repositories
# that carried the ci-local-docker topic; no runner gets the socket any more
#, so there is nothing to proxy. And until an earlier change, repairing the
# ownership of a work folder bind-mounted from the host and scrubbing the
# `.git` the previous job had left in it. The work folder is now the runner's
# own `_work`, inside this container, and goes with it — nothing to repair,
# and no previous job's checkout to distrust.
#
#   1. loopback ports — OFF by default, and the reason is worth keeping.
#      A step that talks to `localhost:<port>` expects a service in its own
#      namespace. This container once forwarded such ports to the host to
#      imitate that. It worked for one job at a time and was wrong as soon as
#      there were two: the host port is contended, and if something unrelated
#      already listens there — a developer's own postgres, say — the
#      connection *succeeds* against the wrong database. A job now starts what
#      it needs inside its own container (demo-app an earlier change). Set
#      CI_RUNNER_LOOPBACK_PORTS only for a service that really lives on the
#      host.
#
#   2. the caches and git pre-population. Named volumes are handed to `runner`,
#      after any is emptied if it has grown past CI_CACHE_CAP_MB (cache-cap.sh,
#      an earlier change); if a saved .git exists in the git volume, it is scrubbed and
#      copied into the runner's workspace; npx's installed trees are cleared;
#      and the read-only seed is linked into the tool cache and Playwright's
#      browser directory — see below and an earlier change.
#
# The runner itself is given its credential as a JIT config: one registration,
# one job, then the process exits and the container with it. There is nothing
# to unregister and no long-lived credential anywhere in the image — see the
# entry for why that is the shape rather than `config.sh --ephemeral`.
set -euo pipefail

: "${JITCONFIG:?JITCONFIG is required — ci-runner.sh mints one per container}"

RUNNER_HOME=/opt/runner
LOOPBACK_PORTS=${CI_RUNNER_LOOPBACK_PORTS-}

for port in $LOOPBACK_PORTS; do
  socat "TCP-LISTEN:${port},bind=127.0.0.1,fork,reuseaddr" \
        "TCP:host.docker.internal:${port}" &
done

# The persistent volumes are the only part of a job that outlives it, so they
# are the only part that needs a bound: 2048 MiB each unless the container is
# given CI_CACHE_CAP_MB. A cap that is not an integer is no cap.
/usr/local/bin/cache-cap.sh "${CI_CACHE_CAP_MB:-2048}" \
  /var/cache/ci-runner/git \
  /home/runner/.npm \
  /home/runner/.cache \
  /home/runner/.local/share/pnpm

for dir in /var/cache/ci-runner/git /home/runner/.npm /home/runner/.cache /home/runner/.local/share/pnpm; do
  [ -d "$dir" ] && chown -R runner:runner "$dir" 2>/dev/null || true
done

# From here until the runner exits, this container is a user of the four
# volumes: a shared lock on <volume>/.inuse, which cache-cap.sh in another
# container needs exclusively to empty one. The descriptors are not
# close-on-exec, so they ride through the exec below into the runner and its
# children, and the lock ends with the last of them.
for dir in /var/cache/ci-runner/git /home/runner/.npm /home/runner/.cache /home/runner/.local/share/pnpm; do
  if [ -d "$dir" ]; then
    # .sync is opened for writing by job-completed.sh, which runs as runner;
    # a root-created one would lock it out of the sync-back.
    : >> "$dir/.sync" && chown runner:runner "$dir/.sync" 2>/dev/null || true
    exec {lockfd}>>"$dir/.inuse" && flock -s "$lockfd" || true
  fi
done

# If a previously saved .git exists in the persistent volume and repo is given,
# pre-populate the runner's workspace with a clean .git so actions/checkout fetches
# instead of cloning from scratch.
repo=${CI_REPO:-}
git_source=""
if [ -d "/var/cache/ci-runner/git/.git" ]; then
  git_source="/var/cache/ci-runner/git/.git"
elif [ -d "/var/cache/ci-runner/git/repo.git" ]; then
  git_source="/var/cache/ci-runner/git/repo.git"
elif [ -d "/var/cache/ci-runner/git/objects" ]; then
  git_source="/var/cache/ci-runner/git"
fi

if [ -n "$repo" ] && [ -n "$git_source" ]; then
  dest="/opt/runner/_work/${repo#*/}/${repo#*/}/.git"
  # The exclusive .sync lock keeps a job-completed.sh sync-back in another
  # container from swapping .git while it is scrubbed and copied out.
  {
    flock -x 9 || true
    rm -f "$git_source/gc.log.lock" "$git_source/gc.pid" "$git_source/index.lock" "$git_source/shallow.lock"
    rm -rf "$git_source/worktrees" 2>/dev/null || true
    /usr/local/bin/scrub-git.sh "$git_source"
    mkdir -p "$dest"
    rsync -a "$git_source/" "$dest/" 2>/dev/null || cp -a "$git_source/." "$dest/" 2>/dev/null || true
  } 9>>/var/cache/ci-runner/git/.sync
  if [ -f "$dest/config" ] && [ "${CI_PARTIAL_CLONE:-1}" != "0" ]; then
    git -C "$dest" config core.repositoryformatversion 1 2>/dev/null || true
    git -C "$dest" config extensions.partialclone origin 2>/dev/null || true
    git -C "$dest" config remote.origin.promisor true 2>/dev/null || true
    git -C "$dest" config remote.origin.partialclonefilter "blob:none" 2>/dev/null || true
  fi
  chown -R runner:runner "/opt/runner/_work" 2>/dev/null || true
elif [ -n "$repo" ] && [ -z "$git_source" ] && [ "${CI_PARTIAL_CLONE:-1}" != "0" ]; then
  # On first checkout, pre-initialize a promisor partial clone so actions/checkout
  # with fetch-depth: 0 downloads commit/tree graphs without historical blobs.
  dest="/opt/runner/_work/${repo#*/}/${repo#*/}/.git"
  mkdir -p "$dest"
  git init -q "$dest"
  git -C "$dest" config core.repositoryformatversion 1 2>/dev/null || true
  git -C "$dest" config extensions.partialclone origin 2>/dev/null || true
  git -C "$dest" config remote.origin.url "https://github.com/$repo" 2>/dev/null || true
  git -C "$dest" config remote.origin.promisor true 2>/dev/null || true
  git -C "$dest" config remote.origin.partialclonefilter "blob:none" 2>/dev/null || true
  git -C "$dest" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" 2>/dev/null || true
  chown -R runner:runner "/opt/runner/_work" 2>/dev/null || true
fi

# npx runs a package straight out of ~/.npm/_npx when a tree there satisfies
# the request, without fetching or checking anything. The volume is this
# repository's, but its jobs are not equally trusted: a pull request's
# dependency could plant chrome-webstore-upload-cli there for the release job
# that runs it with the store's secrets. So every job starts without one.
rm -rf /home/runner/.npm/_npx

# The read-only seed (an earlier change, gate.sh) is linked in, one entry per version, so a
# job finds what was seeded already installed and anything else it downloads
# lands in the container's own writable directory and dies with it. The links
# are the job's to remove; what they point at is not.
link_seed() {
  local from=$1 to=$2 entry
  [ -d "$from" ] || return 0
  mkdir --parents "$to"
  for entry in "$from"/*; do
    if [ -e "$entry" ]; then ln -sfn "$entry" "$to/$(basename "$entry")"; fi
  done
}
for tool in /opt/seed/toolcache/*; do
  if [ -d "$tool" ]; then link_seed "$tool" "/opt/hostedtoolcache/$(basename "$tool")"; fi
done
link_seed /opt/seed/ms-playwright "$PLAYWRIGHT_BROWSERS_PATH"
chown --recursive --no-dereference runner:runner /opt/hostedtoolcache "$PLAYWRIGHT_BROWSERS_PATH"

# Default node/npm/npx/corepack available on PATH like ubuntu-latest.
/usr/local/bin/autolink-node.sh /opt/hostedtoolcache /usr/local/bin
for b in node npm npx corepack; do
  [ -e "/usr/local/bin/$b" ] && chown -h runner:runner "/usr/local/bin/$b" 2>/dev/null || true
done
chown runner:runner /usr/local/bin 2>/dev/null || true

# Propagate container CPU quota to test runners and Node runtime.
if [ -f /usr/local/lib/ci-runner-cgroup.js ]; then
  case "${NODE_OPTIONS:-}" in
    *ci-runner-cgroup.js*) ;;
    *) export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--require /usr/local/lib/ci-runner-cgroup.js" ;;
  esac
fi

cpus_int=""
if [ -n "${CI_CPUS:-}" ]; then
  cpus_int="${CI_CPUS%.*}"
elif [ -f /sys/fs/cgroup/cpu.max ]; then
  read -r quota period _ < /sys/fs/cgroup/cpu.max 2>/dev/null || true
  if [ "${quota:-}" != "max" ] && [ -n "${quota:-}" ] && [ -n "${period:-}" ] && [ "$period" -gt 0 ] 2>/dev/null; then
    cpus_int=$(( quota / period ))
  fi
fi

if [ -n "$cpus_int" ] && [ "$cpus_int" -gt 0 ] 2>/dev/null; then
  export UV_THREADPOOL_SIZE="${UV_THREADPOOL_SIZE:-$cpus_int}"
  export VITEST_MAX_THREADS="${VITEST_MAX_THREADS:-$cpus_int}"
  export VITEST_MIN_THREADS="${VITEST_MIN_THREADS:-$cpus_int}"
  export JEST_WORKERS="${JEST_WORKERS:-$cpus_int}"
  export PLAYWRIGHT_WORKERS="${PLAYWRIGHT_WORKERS:-$cpus_int}"
fi

# --preserve-environment keeps the tool-cache pointer and CI_CPUS, and
# would keep root's HOME with them — which would put npm's cache and
# Playwright's browsers somewhere the volumes are not mounted. Set it first.
export HOME=/home/runner USER=runner

# exec, so docker-init passes launchd's SIGTERM to the process that knows how
# to stop a job rather than to a shell that would drop it.
cd "$RUNNER_HOME"
exec runuser --user runner --preserve-environment -- \
  "$RUNNER_HOME/run.sh" --jitconfig "$JITCONFIG"
