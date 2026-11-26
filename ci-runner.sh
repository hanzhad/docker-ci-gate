#!/usr/bin/env bash
# BEGIN-USAGE
# Run a repository's GitHub Actions on this machine, in Docker — nothing kept
# warm, a runner raised only when GitHub has work queued — and switch between
# here and GitHub without a commit.
#
# Usage:
#   ci-runner adopt  <path|owner/repo>   let this machine serve it, and report
#                                    what the repository still needs
#   ci-runner forget <path|owner/repo>   stop serving it
#   ci-runner list                   the registry, read from GitHub
#   ci-runner install [up flags]     build and seed if the images are missing,
#                                    remember the flags for `up`, and put a
#                                    `ci-runner` command in ~/.local/bin
#   ci-runner build                  build both images, then seed
#   ci-runner redeploy [--yes]       replace the gate with one built from this
#                                    checkout: pause, wait for running jobs,
#                                    keep the old image as :previous, rebuild
#                                    the gate image only, start it with the
#                                    stored flags. The new gate is locked (the
#                                    PIN prompt is opened where there is one)
#                                    and its live budget is the boot flags
#                                    again; the last line printed restores it.
#                                    Asks first at a terminal, refuses without
#                                    one unless --yes
#   ci-runner seed                   fill the read-only cache from seed.list
#   ci-runner up     [flags]         start the gate — one for the machine; with
#                                    no flags, the ones `install` stored
#   ci-runner unlock                 give it its credential (after a reboot)
#                                    reads the clipboard; --stdin to pipe it;
#                                    --owner O for an organisation's own token
#   ci-runner sync                  push the registry into a running gate
#   ci-runner down                   stop the gate and its idle runners
#   ci-runner pause                  finish what is running, start nothing new
#   ci-runner resume                 start taking work again (no unlock needed)
#   ci-runner drain  [--timeout N]   pause, then wait until nothing here is busy
#   ci-runner budget [N --big-cap M] how much of the machine CI may use, live —
#                                    no argument reads it, --reset drops back to
#                                    the flags `up` was given
#   ci-runner on     <path|owner/repo>  point this repository's CI at this machine
#                                    (--json: the result, or the refusal and
#                                    every blocker, as JSON on stdout)
#   ci-runner off    <path|owner/repo>  point it back at GitHub
#   ci-runner mega   on|off <path|owner/repo>  route that repository's mega job
#                                    to the whole-machine class (sets or
#                                    deletes CI_RUNNER_LABEL_MEGA); `on` refuses
#                                    unless the running gate serves mega
#   ci-runner status <path>          where CI runs, the budget, is it locked
#   ci-runner status --json          the gate, the file it reports every tick
#                                    and each repository's switch, as JSON
#                                    (status.schema.json); no path, and the
#                                    switch is read at most once a minute
#   ci-runner logs   [-f]            the gate's log
#   ci-runner prune  <path>          delete offline runner registrations
#   ci-runner purge  <path>|--all    remove it, from this project or entirely
#   ci-runner doctor <path|owner/repo>  check the parts that fail silently,
#                                    and print the report `adopt` prints
#   ci-runner autoswitch <path>      flip the switch if the allowance is gone
#   ci-runner watch  <path> [flags]  run autoswitch on a timer (optional; needs
#                                    launchd, so macOS only)
#   ci-runner unwatch <path>         remove that timer
#
# <path> is a git checkout. The repository comes from its origin, so that is
# the only argument most commands need; `adopt`, `forget`, `on` and `off` also
# take `owner/repo`, so the repository need not be checked out here. `up`,
# `down`, `unlock`, `on` and `off` also take `--all`, which means every
# repository in the registry.
#
# The registry is a topic on the repository itself — `ci-local` — so the list
# of what this machine serves lives on GitHub and not in a file here: visible
# from the web, identical from a second machine, and nothing to restore when
# this one is rebuilt. `adopt` refuses a public repository outright.
#
# Flags:
#   --label L        up        runner label (default local-docker), for the
#                              big class; kept in machine/label, which `on`,
#                              `status` and `doctor` read too. `on` copies it into CI_RUNNER_LABEL
#                              and writes CI_RUNNER_LABEL_LIGHT as L-light, so
#                              the three cannot drift apart.
#   --budget N       up        machine-wide budget in cores, for both classes
#   --big-cap N      up        the most of it big runners may hold together
#                              together (default 8 of this machine's 14 — the
#                              rest is the gate, the daemon and whatever else
#                              is running).
#   --big-cpus N     up        CPU quota for a big runner (default 4). Not
#                              tuning: this is the number Playwright reads to
#                              size its worker pool, and without a quota a job
#                              runs seven Chromium contexts where the hosted
#                              runner runs two.
#   --big-memory X   up        memory cap for a big runner (default 4g)
#   --big-shares N   up        cpu-shares for a big runner (default 2048) —
#                              priority under contention, since a `--cpus`
#                              ceiling is not a reservation.
#   --little-cpus N  up        CPU quota for a little runner (default 4 — the
#                              same as big; it sizes workers, not priority)
#   --little-memory X up       memory cap for a little runner (default 2g)
#   --little-shares N up       cpu-shares for a little runner (default 1024)
#   --mega-cpus N    up        CPU quota for the mega class: a job that costs
#                              the WHOLE budget and runs alone (default: the
#                              machine's cores minus 2). 0 turns the class
#                              off: the label is then an ordinary big (the
#                              default on a mac).
#   --mega-memory X  up        memory cap for the mega class (default: the
#                              machine's memory minus 4 GiB)
#   --mega-drain-warn N up     say once, in the log, when a mega job has been
#                              waiting for the machine to empty for N seconds
#                              (default 1800); nothing is killed
#   --mega-max-busy N up       a mega runner busy longer than this is removed
#                              (default 7200; other runners: 2700)
#   --poll N     up            seconds between checks (default 20). Every
#                              repository is polled every tick — nothing is
#                              kept warm to shortcut it.
#   --defer N    up            yield to another machine on the same label:
#                              leave a queued job alone until it has waited N
#                              seconds (default 0 — take it at once). The
#                              machine that should win runs without it.
#   --host TAG   up            this machine's name inside every runner name
#                              (default: the host name, lower-cased, cut to
#                              8). Two machines on one label mint identical
#                              names otherwise, and a job's log then cannot
#                              say which one ran it.
#   Every up flag except --label is also what `install` stores, for a later
#   `up` with no flags; a flag on the `up` line wins for that start only.
#   --timeout N  drain         give up waiting after N seconds (default 1800)
#   --timeout N  unlock --wait give up waiting for Docker and the gate after N
#                              seconds (default 300)
#   --reserve N  autoswitch    switch here under N included minutes (default 30)
#   --every N    watch         seconds between autoswitch checks (default 900)
#   --dry-run    autoswitch    say what it would do, change nothing
#   --stdin      unlock        read the token from stdin instead of the clipboard
#   --wait       unlock        with --stdin: take the token, return 0 at once, and
#                              leave a background process to wait for Docker and
#                              the gate and then unlock; if it gives up, the
#                              token is dropped and a line in the unlock log
#                              (<state dir>/machine/unlock.log) says why
#   --json       on, status    JSON on stdout, nothing else on it
#   --yes        redeploy      do not ask first
#   -f           logs          follow
#
# --warm, --max, --cold and --cpus/--memory are gone: nothing is kept warm, the
# ceiling is the cores budget above rather than a container count, and a class
# is chosen by the workflow's `runs-on:` rather than by how the repository was
# adopted. Passing one of them is refused, naming its replacement.
#
# One gate serves every repository in the registry, so adding one is `adopt`
# and nothing else, and the budget is the machine's rather than one per
# repository. Two kinds of container, and the split is the point. The
# **gate** holds the credential and decides how many runners exist for which
# repository; it never runs anything from a repository itself.
# A **runner** is where a pull request's own code executes, and it holds one
# single-use credential good for one job, then exits. Stopping the gate in
# Docker Desktop stops everything.
#
# The gate's credential is never written to disk anywhere — it lives on a
# tmpfs inside the container, so a reboot leaves this machine holding nothing.
# The cost is one manual step after each reboot: `unlock`, which reads the
# token from the clipboard.
#
# Three repository variables, because they answer different questions and
# change at different rates. CI_RUNNER is the flag — `1` here, `0` or unset for
# GitHub — and is what gets flipped. CI_RUNNER_LABEL and CI_RUNNER_LABEL_LIGHT
# are the two destinations, written by `on` from this gate's own label, and
# changed about never; a job's `runs-on:` picks between them, and that choice
# — not `adopt` — is what decides which class it runs as.
#
# No tunnel, no port forwarding, nothing published: everything here dials
# GitHub outward. See the design docs, and README.md next to this file for
# the setup with URLs.
# END-USAGE
set -euo pipefail

# Kept for `install`, which says whether ~/.local/bin is on the PATH it was
# started from; the PATH below is the one every command here runs with.
CALLER_PATH=$PATH
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

_self=${BASH_SOURCE[0]}
while [ -L "$_self" ]; do
  _dir=$(cd "$(dirname "$_self")" && pwd)
  _self=$(readlink "$_self")
  case $_self in /*) ;; *) _self=$_dir/$_self ;; esac
done
SCRIPT_PATH=$(cd "$(dirname "$_self")" && pwd)/$(basename "$_self")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")

WATCH_PREFIX="${CI_RUNNER_LAUNCHD_PREFIX:-com.docker-ci-gate.watch}"
AGENTS_DIR="$HOME/Library/LaunchAgents"
RUNNER_IMAGE="${CI_RUNNER_IMAGE:-ci-runner:local}"
GATE_IMAGE="${CI_GATE_IMAGE:-ci-gate:local}"
# Mirrored in gate.sh, which mounts it :ro into every runner.
SEED_VOLUME=ci-runner-seed
STATE_ROOT="${CI_RUNNER_STATE_DIR:-$HOME/.local/state/ci-runner}"
# Where runners' work folders lived on the host until an earlier change, and nothing
# writes now: a runner's checkout is inside its own container and goes with
# it. Kept so `purge` can remove what an older gate left behind.
WORK_ROOT="${CI_RUNNER_WORK_ROOT:-$HOME/.ci-runner/work}"
VARIABLE="CI_RUNNER"
VARIABLE_LABEL="CI_RUNNER_LABEL"
VARIABLE_LABEL_LIGHT="CI_RUNNER_LABEL_LIGHT"
VARIABLE_LABEL_MEGA="CI_RUNNER_LABEL_MEGA"
TOPIC="${CI_RUNNER_TOPIC:-ci-local}"
DEFAULT_LABEL="local-docker"
DEFAULT_RESERVE=30
DEFAULT_EVERY=900
# Defaults mirrored from gate.sh's own class table — kept here only as the
# fallback this script shows before a gate has ever reported its actual
# environment back (`gate_env`, used by `status` and `doctor`).
DEFAULT_BUDGET=10; DEFAULT_BIG_CAP=8
DEFAULT_BIG_CPUS=4; DEFAULT_BIG_MEMORY=4g; DEFAULT_BIG_SHARES=2048; DEFAULT_BIG_COST=4
DEFAULT_LITTLE_CPUS=4; DEFAULT_LITTLE_MEMORY=2g; DEFAULT_LITTLE_SHARES=1024; DEFAULT_LITTLE_COST=2

RUNNER_VERSION_FALLBACK=2.336.0
GH_VERSION_FALLBACK=2.97.0

die() { printf '✗ %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }
ok() { printf '✓ %s\n' "$*"; }

usage() {
  sed -n '/^# BEGIN-USAGE$/,/^# END-USAGE$/p' "$SCRIPT_PATH" | sed '1d;$d' | sed 's/^# \{0,1\}//'
}

need_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is not on PATH."
  docker info >/dev/null 2>&1 || die "Docker is not running. Start Docker Desktop."
}
need_gh() {
  command -v gh >/dev/null 2>&1 || die "gh is not on PATH."
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run 'gh auth login'."
}

repo_of() {
  local path=$1 url
  [ -d "$path" ] || die "no such directory: $path"
  git -C "$path" rev-parse --git-dir >/dev/null 2>&1 || die "not a git checkout: $path"
  url=$(git -C "$path" remote get-url origin 2>/dev/null) || die "$path has no origin remote."
  url=${url%.git}
  case "$url" in
    git@*:*) printf '%s\n' "${url##*:}" ;;
    *github.com/*) printf '%s\n' "${url#*github.com/}" ;;
    *) die "origin is not a github.com remote: $url" ;;
  esac
}
slug_of() { printf '%s\n' "$1" | tr '/[:upper:]' '-[:lower:]'; }
GATE_NAME="ci-gate"
COLD_TOPIC="${CI_RUNNER_COLD_TOPIC:-ci-local-cold}"
# Gone with an earlier change: this topic gave a repository's runners the host's docker
# socket (`adopt --docker`, 2026-09-21 to 2026-11-03). The gate no longer
# reads it; adopt and forget still strip it so a leftover cannot look like it
# means something.
OLD_DOCKER_TOPIC="ci-local-docker"
state_dir_of() { local d="$STATE_ROOT/$1"; mkdir -p "$d"; printf '%s\n' "$d"; }

# The label has to be the same string in two places — the runner carries it,
# the repository variable names it — and a mismatch looks like nothing
# happening: the job queues, no runner claims it, and GitHub does not say which
# label it wanted. So it is remembered once, for the machine, rather than typed
# twice or kept per repository: there is one gate and it has one label, and a
# per-repository file that only `on` read could not agree with what `up` wrote.
label_of() {
  local override=${1:-} file="$STATE_ROOT/machine/label"
  if [ -n "$override" ]; then
    mkdir -p "$STATE_ROOT/machine"; printf '%s\n' "$override" > "$file"; printf '%s\n' "$override"
  elif [ -s "$file" ]; then cat "$file"
  else printf '%s\n' "$DEFAULT_LABEL"; fi
}

# The flags `up` takes, other than the label, are the machine's: what `install`
# stores in one file and a bare `up` reads back. KEY=value lines, read by
# parsing and never sourced, because the values end up as arguments to docker.
# The key is the flag's name upper-cased, so FLAG_<KEY> is the variable.
MACHINE_KEYS="BUDGET BIG_CAP BIG_CPUS BIG_MEMORY BIG_SHARES LITTLE_CPUS LITTLE_MEMORY LITTLE_SHARES MEGA_CPUS MEGA_MEMORY MEGA_DRAIN_WARN MEGA_MAX_BUSY POLL DEFER HOST"
machine_flags_file() { printf '%s\n' "$STATE_ROOT/machine/flags"; }

# The stored value of one key; empty when there is none or it is not plain.
stored_flag() {
  local file line found=""
  file=$(machine_flags_file); [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$1="*) found=${line#*=}; break ;; esac
  done < "$file"
  case "$found" in *[!A-Za-z0-9._:-]*) return 0 ;; esac
  printf '%s\n' "$found"
}

# Fill every machine flag the command line left empty from the file. Called by
# `up` alone: parse_flags is shared, and `budget --big-cap` or `drain` must not
# find a stored value where it asked for none.
apply_stored_flags() {
  local key var stored
  for key in $MACHINE_KEYS; do
    var="FLAG_$key"
    [ -z "${!var}" ] || continue
    stored=$(stored_flag "$key")
    [ -z "$stored" ] || printf -v "$var" '%s' "$stored"
  done
}

# What `install` was given over what is stored, the rest kept as it was.
store_machine_flags() {
  local key var value file tmp
  file=$(machine_flags_file); tmp="$file.new"
  mkdir -p "$STATE_ROOT/machine"
  : > "$tmp"
  for key in $MACHINE_KEYS; do
    var="FLAG_$key"; value=${!var}
    case "$value" in
      *[!A-Za-z0-9._:-]*) rm -f "$tmp"; die "a stored flag takes letters, digits and . _ : - only: $value" ;;
    esac
    [ -n "$value" ] || value=$(stored_flag "$key")
    [ -z "$value" ] || printf '%s=%s\n' "$key" "$value" >> "$tmp"
  done
  mv "$tmp" "$file"
}

parse_flags() {
  FLAG_LABEL=""; FLAG_FOLLOW=""; FLAG_RESERVE=""; FLAG_EVERY=""; FLAG_DRY=""
  FLAG_POLL=""; FLAG_STDIN=""; FLAG_JSON=""; FLAG_YES=""; FLAG_DEFER=""; FLAG_HOST=""; FLAG_TIMEOUT=""; FLAG_OWNER=""; FLAG_WAIT=""
  FLAG_BUDGET=""; FLAG_BIG_CAP=""; FLAG_BIG_CPUS=""; FLAG_BIG_MEMORY=""; FLAG_BIG_SHARES=""
  FLAG_LITTLE_CPUS=""; FLAG_LITTLE_MEMORY=""; FLAG_LITTLE_SHARES=""
  FLAG_MEGA_CPUS=""; FLAG_MEGA_MEMORY=""; FLAG_MEGA_DRAIN_WARN=""; FLAG_MEGA_MAX_BUSY=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --label) FLAG_LABEL=${2:?--label needs a value}; shift 2 ;;
      --budget) FLAG_BUDGET=${2:?--budget needs a value}; shift 2 ;;
      --big-cap) FLAG_BIG_CAP=${2:?--big-cap needs a value}; shift 2 ;;
      --big-cpus) FLAG_BIG_CPUS=${2:?--big-cpus needs a value}; shift 2 ;;
      --big-memory) FLAG_BIG_MEMORY=${2:?--big-memory needs a value}; shift 2 ;;
      --big-shares) FLAG_BIG_SHARES=${2:?--big-shares needs a value}; shift 2 ;;
      --little-cpus) FLAG_LITTLE_CPUS=${2:?--little-cpus needs a value}; shift 2 ;;
      --little-memory) FLAG_LITTLE_MEMORY=${2:?--little-memory needs a value}; shift 2 ;;
      --little-shares) FLAG_LITTLE_SHARES=${2:?--little-shares needs a value}; shift 2 ;;
      --mega-cpus) FLAG_MEGA_CPUS=${2:?--mega-cpus needs a value}; shift 2 ;;
      --mega-memory) FLAG_MEGA_MEMORY=${2:?--mega-memory needs a value}; shift 2 ;;
      --mega-drain-warn) FLAG_MEGA_DRAIN_WARN=${2:?--mega-drain-warn needs a value}; shift 2 ;;
      --mega-max-busy) FLAG_MEGA_MAX_BUSY=${2:?--mega-max-busy needs a value}; shift 2 ;;
      --poll) FLAG_POLL=${2:?--poll needs a value}; shift 2 ;;
      --defer) FLAG_DEFER=${2:?--defer needs a value}; shift 2 ;;
      --timeout) FLAG_TIMEOUT=${2:?--timeout needs a value}; shift 2 ;;
      --host) FLAG_HOST=${2:?--host needs a value}; shift 2 ;;
      --owner) FLAG_OWNER=${2:?--owner needs a value}; shift 2 ;;
      --reserve) FLAG_RESERVE=${2:?--reserve needs a value}; shift 2 ;;
      --every) FLAG_EVERY=${2:?--every needs a value}; shift 2 ;;
      --dry-run) FLAG_DRY=1; shift ;;
      --stdin) FLAG_STDIN=1; shift ;;
      --wait) FLAG_WAIT=1; shift ;;
      --json) FLAG_JSON=1; shift ;;
      --yes) FLAG_YES=1; shift ;;
      -f|--follow) FLAG_FOLLOW=1; shift ;;
      # Not tuning flags any more — a class is chosen by the workflow, the
      # ceiling is a cores budget, and nothing is warm to size a quota for.
      --warm) die "--warm is gone — nothing is kept warm; see --budget in 'ci-runner.sh up'." ;;
      --max) die "--max is gone — the ceiling is now --budget, in cores, not a container count." ;;
      --cpus) die "--cpus is gone — set --big-cpus/--little-cpus (both default 4)." ;;
      --memory) die "--memory is gone — set --big-memory/--little-memory." ;;
      --cold) die "--cold is gone — every repository is polled every tick now; a runner is never kept warm. See the README." ;;
      *) die "unknown flag: $1" ;;
    esac
  done
}

# ── images ───────────────────────────────────────────────────────────────

# The commit the gate image is built from, so a running gate can say which code
# it is: the short sha of this checkout, and `-dirty` when gate has a
# change that is not committed (the rest of the tree does not go into the gate).
# `unknown` where this is not a git checkout.
gate_commit() {
  local sha
  sha=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null) || { printf 'unknown\n'; return 0; }
  if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain -- gate 2>/dev/null)" ]; then
    printf '%s-dirty\n' "$sha"
  else
    printf '%s\n' "$sha"
  fi
}

build_gate_image() {
  docker build --build-arg "GATE_COMMIT=$(gate_commit)" --tag "$GATE_IMAGE" "$SCRIPT_DIR/gate"
}

cmd_build() {
  need_docker
  local runner_version gh_version
  runner_version=$(gh api /repos/actions/runner/releases/latest --jq .tag_name 2>/dev/null | tr -d v) || runner_version=""
  gh_version=$(gh api /repos/cli/cli/releases/latest --jq .tag_name 2>/dev/null | tr -d v) || gh_version=""
  : "${runner_version:=$RUNNER_VERSION_FALLBACK}"; : "${gh_version:=$GH_VERSION_FALLBACK}"
  note "runner $runner_version, gh $gh_version"
  # The uid is the host's. It had to be while the work folder was bind-mounted
  # from here (until an earlier change); it stays so the image does not change under the
  # per-repository volumes it already owns.
  docker build --build-arg "RUNNER_VERSION=$runner_version" --build-arg "GH_VERSION=$gh_version" \
    --build-arg "RUNNER_UID=$(id -u)" \
    --tag "$RUNNER_IMAGE" "$SCRIPT_DIR"
  build_gate_image
  ok "built $RUNNER_IMAGE and $GATE_IMAGE"
  cmd_seed
}

# Everything a machine needs once, without touching a gate: the images (built
# only when missing — `build` stays the one way to rebuild on purpose, since it
# pulls the latest runner and gh), the flags `up` uses when given none, and a
# `ci-runner` command that works from any directory. A wrapper and not a
# symlink: SCRIPT_DIR comes from where this file really is, and seed.list, the
# awk file and the build context are found through it. The wrapper is bash
# because the script is.
cmd_install() {
  parse_flags "$@"
  need_docker
  if docker image inspect "$RUNNER_IMAGE" >/dev/null 2>&1 \
      && docker image inspect "$GATE_IMAGE" >/dev/null 2>&1; then
    cmd_seed
  else
    cmd_build
  fi
  [ -z "$FLAG_LABEL" ] || label_of "$FLAG_LABEL" >/dev/null
  store_machine_flags
  ok "stored the machine flags in $(machine_flags_file)"
  write_wrapper
}

write_wrapper() {
  local dir="$HOME/.local/bin"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$SCRIPT_PATH" > "$dir/ci-runner.new"
  chmod 755 "$dir/ci-runner.new"
  mv -f "$dir/ci-runner.new" "$dir/ci-runner"
  ok "wrote $dir/ci-runner"
  case ":$CALLER_PATH:" in
    *":$dir:"*) ;;
    *) note "$dir is not on your PATH — add it to run: ci-runner on <owner/repo>" ;;
  esac
}

# The one place the shared, read-only cache is written. A container of
# the runner image with the seed volume and nothing else: no checkout, no
# job. Runners mount the result :ro; see seed.sh for why.
cmd_seed() {
  need_docker
  docker image inspect "$RUNNER_IMAGE" >/dev/null 2>&1 || die "no $RUNNER_IMAGE yet — run: ci-runner.sh build"
  docker run --rm --interactive --user root --entrypoint /usr/local/bin/seed.sh \
    --volume "$SEED_VOLUME:/seed" \
    "$RUNNER_IMAGE" < "$SCRIPT_DIR/seed.list" \
    && ok "seeded $SEED_VOLUME from seed.list" \
    || die "seeding failed — jobs still run, but download what the seed would have held"
}

ensure_images() {
  docker image inspect "$RUNNER_IMAGE" >/dev/null 2>&1 \
    && docker image inspect "$GATE_IMAGE" >/dev/null 2>&1 && return 0
  note "images are not built yet — building them now"
  cmd_build
}

# ── the gate ─────────────────────────────────────────────────────────────

up_gate() {
  local label gate
  label=$(label_of "$FLAG_LABEL")
  gate=$GATE_NAME
  # A directory, not a file: a single-file bind mount keeps the old inode after
  # an atomic replace, so the gate would go on reading the value it started
  # with. Nothing here writes into it; the owner does, and the gate reads it
  # every tick (admission on memory and load, gate.sh).
  mkdir -p "$HOME/.config/machine-limits"

  # Graceful, not `rm --force`: a gate already running here may hold runners
  # configured with a different label or a different budget, and its own
  # SIGTERM trap is the only thing that clears them. Killing it would leave a
  # pool nobody owns, carrying settings this command was called to change.
  docker stop "$gate" >/dev/null 2>&1 || true
  docker rm --force "$gate" >/dev/null 2>&1 || true

  # The two com.docker.compose.* labels are cosmetic and deliberate: Docker
  # Desktop groups containers by them, not by who created them, so the gate and
  # every runner it starts collapse into one "0-ci" row instead of
  # scattering through the list. Nothing here is compose-managed — `docker
  # compose ls` will list the project and be unable to act on it, since there
  # is no config file behind it.
  #
  # --restart unless-stopped is the whole supervisor, and it is also the off
  # switch the owner asked for: stopping this container in Docker Desktop stays
  # stopped, and its SIGTERM trap takes the idle runners with it.
  #
  # --tmpfs is where the credential goes. Nothing writes it to a layer, so a
  # `docker inspect`, a stopped container, and a powered-off machine all hold
  # nothing.
  # The mega class is sized by the gate from the machine it runs on; only a mac
  # is told otherwise, because its Docker VM is the machine's one shared budget.
  local mega_cpus=$FLAG_MEGA_CPUS
  [ -n "$mega_cpus" ] || [ "$(uname -s)" != Darwin ] || mega_cpus=0
  docker run --detach \
    --name "$gate" \
    --restart unless-stopped \
    --label "ci-runner.role=gate" \
    --label "com.docker.compose.project=0-ci" \
    --label "com.docker.compose.service=gate" \
    --volume /var/run/docker.sock:/var/run/docker.sock \
    --volume "$HOME/.config/machine-limits:/etc/machine-limits:ro" \
    --tmpfs /run/gate:rw,noexec,nosuid,mode=0700 \
    --env "RUNNER_LABEL=$label" \
    --env "RUNNER_IMAGE=$RUNNER_IMAGE" \
    --env "BUDGET=${FLAG_BUDGET:-$DEFAULT_BUDGET}" \
    --env "BIG_CAP=${FLAG_BIG_CAP:-$DEFAULT_BIG_CAP}" \
    --env "BIG_CPUS=${FLAG_BIG_CPUS:-$DEFAULT_BIG_CPUS}" \
    --env "BIG_MEMORY=${FLAG_BIG_MEMORY:-$DEFAULT_BIG_MEMORY}" \
    --env "BIG_SHARES=${FLAG_BIG_SHARES:-$DEFAULT_BIG_SHARES}" \
    --env "LITTLE_CPUS=${FLAG_LITTLE_CPUS:-$DEFAULT_LITTLE_CPUS}" \
    --env "LITTLE_MEMORY=${FLAG_LITTLE_MEMORY:-$DEFAULT_LITTLE_MEMORY}" \
    --env "LITTLE_SHARES=${FLAG_LITTLE_SHARES:-$DEFAULT_LITTLE_SHARES}" \
    ${mega_cpus:+--env "MEGA_CPUS=$mega_cpus"} \
    ${FLAG_MEGA_MEMORY:+--env "MEGA_MEMORY=$FLAG_MEGA_MEMORY"} \
    ${FLAG_MEGA_DRAIN_WARN:+--env "MEGA_DRAIN_WARN=$FLAG_MEGA_DRAIN_WARN"} \
    ${FLAG_MEGA_MAX_BUSY:+--env "MEGA_MAX_BUSY=$FLAG_MEGA_MAX_BUSY"} \
    --env "POLL=${FLAG_POLL:-20}" \
    --env "DEFER=${FLAG_DEFER:-0}" \
    --env "HOST_TAG=$(host_tag "$FLAG_HOST")" \
    "$GATE_IMAGE" >/dev/null
}

cmd_up() {
  parse_flags "$@"
  apply_stored_flags
  need_docker; need_gh
  ensure_images
  local list
  list=$(registry)
  [ -n "$list" ] || die "the registry is empty — adopt a repository first."
  up_gate || return 1
  printf '%s\n' "$list" | docker exec --interactive "$GATE_NAME" tee /run/gate/repos >/dev/null
  ok "gate up: $GATE_NAME"
  printf '%s\n' "$list" | sed 's/^/  /'
  note "label: $(label_of) — budget ${FLAG_BUDGET:-$DEFAULT_BUDGET} cores (big cap ${FLAG_BIG_CAP:-$DEFAULT_BIG_CAP}); big ${FLAG_BIG_CPUS:-$DEFAULT_BIG_CPUS}cpu/${FLAG_BIG_MEMORY:-$DEFAULT_BIG_MEMORY}/shares ${FLAG_BIG_SHARES:-$DEFAULT_BIG_SHARES}, little ${FLAG_LITTLE_CPUS:-$DEFAULT_LITTLE_CPUS}cpu/${FLAG_LITTLE_MEMORY:-$DEFAULT_LITTLE_MEMORY}/shares ${FLAG_LITTLE_SHARES:-$DEFAULT_LITTLE_SHARES}; poll ${FLAG_POLL:-20}s; defer ${FLAG_DEFER:-0}s; host $(host_tag "$FLAG_HOST")"
  note "mega: ${FLAG_MEGA_CPUS:-sized by the gate from the machine} cpu (0 = off, served as an ordinary big); drain warning ${FLAG_MEGA_DRAIN_WARN:-1800}s; max busy ${FLAG_MEGA_MAX_BUSY:-7200}s"
  note "it is locked until: ci-runner.sh unlock"
}

cmd_down() {
  need_docker
  # `stop` and not `rm`: the gate's own SIGTERM trap is what removes the idle
  # runners and spares a busy one. Killing it outright would leave the runners
  # orphaned and still registered.
  docker stop "$GATE_NAME" >/dev/null 2>&1 && ok "gate stopped (idle runners removed)" \
    || note "the gate was not running"
  docker rm "$GATE_NAME" >/dev/null 2>&1 || true
}

# pause / resume / drain — "finish what is running, take nothing new",
# without `down`. `down` does that too, but it takes the credential with it,
# and coming back is an unlock; a pause keeps the gate up and unlocked, so
# `resume` is free. `drain` is a pause that waits: it returns once no runner
# of this gate's is busy, which is the moment a `wsl --shutdown`, a reboot,
# or a `down` costs nobody a job.
cmd_pause() {
  need_docker
  docker inspect "$GATE_NAME" >/dev/null 2>&1 || die "no gate — nothing to pause"
  docker exec "$GATE_NAME" touch /run/gate/paused
  ok "paused — running jobs finish, nothing new starts; ci-runner.sh resume"
}

cmd_resume() {
  need_docker
  docker inspect "$GATE_NAME" >/dev/null 2>&1 || die "no gate — run: ci-runner.sh up"
  docker exec "$GATE_NAME" rm -f /run/gate/paused
  ok "resumed"
}

gate_paused() { docker exec "$1" test -e /run/gate/paused >/dev/null 2>&1 && printf 'paused\n' || printf ''; }

# How much of the machine CI may use, changed while the gate runs. This is the
# one setting worth turning often — the right number is found by watching the
# queue, not by reasoning — and it used to cost an unlock, because recreating
# the container to change an environment variable drops the credential. Now it
# is a file on the gate's tmpfs, read every tick. It dies with the container on
# purpose: the flags `up` was given stay the durable setting, and this is only
# ever the dial on top of them.
gate_budget_live() { docker exec "$GATE_NAME" cat /run/gate/budget 2>/dev/null || true; }

cmd_budget() {
  need_docker
  docker inspect "$GATE_NAME" >/dev/null 2>&1 || die "no gate — run: ci-runner.sh up"
  local live boot_b boot_c
  live=$(gate_budget_live)
  # `gate_env` greps the container's environment and succeeds even when it
  # finds nothing, so the fallback has to be on the value, not on the exit code.
  boot_b=$(gate_env BUDGET || true);  boot_b=${boot_b:-$DEFAULT_BUDGET}
  boot_c=$(gate_env BIG_CAP || true); boot_c=${boot_c:-$DEFAULT_BIG_CAP}
  if [ $# -eq 0 ]; then
    printf 'live   %s\n' "${live:-not set — the gate is using the flags it was started with}"
    printf 'boot   budget %s cores, big cap %s\n' "$boot_b" "$boot_c"
    return 0
  fi
  if [ "$1" = --reset ]; then
    docker exec "$GATE_NAME" rm -f /run/gate/budget
    ok "budget back to the flags the gate was started with — within one tick"
    return 0
  fi
  local budget=$1; shift
  parse_flags "$@"
  case "$budget" in ''|*[!0-9]*) die "budget takes a number of cores, e.g. ci-runner.sh budget 16 --big-cap 16" ;; esac
  [ "$budget" -ge 1 ] || die "a budget of $budget cores would serve nothing"
  # An omitted --big-cap keeps whatever cap is in force, so raising the budget
  # alone does not silently hand the whole of it to big jobs.
  local cap=${FLAG_BIG_CAP:-}
  if [ -z "$cap" ]; then
    cap=$(printf '%s' "$live" | awk '{print $2}')
    [ -n "$cap" ] || cap=$boot_c
  fi
  case "$cap" in ''|*[!0-9]*) die "--big-cap takes a number of cores" ;; esac
  [ "$cap" -ge 1 ] || die "a big cap of $cap would never start a big runner"
  [ "$cap" -le "$budget" ] || die "--big-cap ($cap) cannot exceed the budget ($budget)"
  printf '%s %s\n' "$budget" "$cap" | docker exec --interactive "$GATE_NAME" tee /run/gate/budget >/dev/null
  ok "budget $budget cores, big cap $cap — in force within one tick, no unlock"
  if [ "$cap" -eq "$budget" ]; then
    note "big cap equals the budget: big jobs may now fill it, and a one-minute lint can wait a whole e2e out"
  fi
  note "live override — a gate restart returns to budget $boot_b, big cap $boot_c"
}

cmd_drain() {
  parse_flags "$@"
  cmd_pause
  need_gh
  local n=0 limit=${FLAG_TIMEOUT:-1800} busy
  # Busy is GitHub's word, not the container's: a runner container that is
  # up but registered idle is not finishing anything and `drain` should not
  # wait for it — the gate's reap will take it in a few ticks.
  while :; do
    busy=$(busy_runners_here)
    [ -n "$busy" ] || { ok "drained — nothing running here"; return 0; }
    [ "$n" -lt "$limit" ] || { printf '✗ still busy after %ss:\n%s\n' "$limit" "$busy" >&2; return 1; }
    [ $((n % 60)) -eq 0 ] && note "waiting for: $(printf '%s' "$busy" | tr '\n' ' ')"
    sleep 15; n=$((n + 15))
  done
}

# Runner containers of this gate that GitHub currently reports busy, by
# asking each served repository once. `--timeout N` bounds the wait, in
# seconds (default 1800).
busy_runners_here() {
  local repo names here
  here=$(docker ps --filter 'label=ci-runner.gate' --format '{{.Names}}')
  [ -n "$here" ] || return 0
  while read -r repo _; do
    [ -n "$repo" ] || continue
    names=$(gh api "repos/$repo/actions/runners" --jq '.runners[] | select(.busy) | .name' 2>/dev/null) || continue
    printf '%s\n' "$here" | grep -xF -f <(printf '%s\n' "${names:-__none__}") || true
  done < <(registry)
}

# Replace the gate with one built from this checkout, without losing a job
#: pause, wait for what is running, keep the old image as :previous,
# build the gate image alone (the runner image is not rebuilt and the latest
# runner is not looked up), start it with the stored flags, and open the PIN
# prompt. The new gate is locked, as any new gate is, and its live budget is
# the boot flags again: both are said before anything is written, and the last
# line printed is the command that puts the live budget back.
# It reads the live override first because the stop destroys it.
cmd_redeploy() {
  parse_flags "$@"
  need_docker; need_gh
  [ -s "$(machine_flags_file)" ] \
    || die "no stored machine flags — redeploy would start the gate on defaults. Run first: ci-runner.sh install <up flags>"
  docker inspect "$GATE_NAME" >/dev/null 2>&1 || die "no gate to replace — run: ci-runner.sh up"
  [ -n "$(registry)" ] || die "the registry is empty — adopt a repository first."
  local live lb="" lc="" ans st was_paused
  live=$(gate_budget_live)
  read -r lb lc <<< "$live" || true
  case "$lb$lc" in ''|*[!0-9]*) lb=""; lc="" ;; esac
  [ -n "$lc" ] || lb=""

  printf '! redeploy replaces the gate with one built from this checkout (%s).\n' "$(gate_commit)"
  note "running jobs finish first; nothing new starts meanwhile."
  note "the new gate is LOCKED: its credential lived on the old one's tmpfs. It needs the PIN again."
  if [ -n "$lb" ]; then
    note "the live budget resets to the boot flags: it is now budget $lb cores, big cap $lc."
  else
    note "no live budget override is in force, so the boot flags lose nothing."
  fi
  if [ -z "$FLAG_YES" ]; then
    [ -t 0 ] || die "no terminal to ask on, so nothing was changed. Run again with --yes."
    printf 'Redeploy now? [y/N] ' > /dev/tty
    read -r ans < /dev/tty || ans=""
    case "$ans" in y|Y|yes) ;; *) die "not confirmed — nothing was changed." ;; esac
  fi

  # Read once confirmed and before the first write: drain pauses the gate
  # whatever it was, and a pause the owner set is theirs to lift, not ours.
  was_paused=$(gate_paused "$GATE_NAME")
  [ -z "$was_paused" ] || note "the gate is paused now, so the new one is paused again once it is up."
  cmd_drain || { [ -n "$was_paused" ] || cmd_resume || true; die "still busy, so the gate was left as it was and resumed."; }
  docker tag "$GATE_IMAGE" "${GATE_IMAGE%:*}:previous" || note "no $GATE_IMAGE to keep as :previous"
  build_gate_image || { [ -n "$was_paused" ] || cmd_resume || true; die "the gate image did not build, so the gate was left as it was and resumed."; }
  if ! cmd_up; then
    printf '✗ the new gate did not start, and the old one is already stopped.\n' >&2
    note "the previous image is kept. To go back:" >&2
    note "  docker tag ${GATE_IMAGE%:*}:previous $GATE_IMAGE" >&2
    note "  ci-runner.sh up" >&2
    return 1
  fi
  [ -z "$was_paused" ] || cmd_pause
  ok "redeployed: the gate runs $(gate_commit); the old image is ${GATE_IMAGE%:*}:previous"
  # The prompt is a Windows scheduled task (pin-vault windows/install-logon-task.ps1); there is
  # nothing to open it with anywhere else.
  st=${CI_RUNNER_SCHTASKS:-/mnt/c/Windows/System32/schtasks.exe}
  if [ -x "$st" ] && "$st" /Run /TN "pin-vault unlock" >/dev/null 2>&1 </dev/null; then
    note "the PIN prompt is open (scheduled task: pin-vault unlock)"
  else
    note "no way to open the PIN prompt from here: run the scheduled task pin-vault unlock, or ci-runner unlock with the token on the clipboard"
  fi
  [ -z "$lb" ] || note "to restore the live budget: ci-runner.sh budget $lb --big-cap $lc"
}

cmd_unlock() {
  parse_flags "$@"
  local token
  if [ -n "$FLAG_WAIT" ]; then
    # The token is read at once and the waiting is left to a background
    # process, so it has to come from stdin: the clipboard is not something to
    # hold for minutes. Refused before anything is read, so a caller whose
    # stdin is open and idle does not hang.
    [ -n "$FLAG_STDIN" ] || die "--wait needs --stdin: the token is read at once and the waiting is left to a background process."
    case "${FLAG_TIMEOUT:-300}" in ''|*[!0-9]*) die "--timeout needs a number of seconds." ;; esac
    token=$(cat)
    [ -n "$token" ] || die "nothing arrived on stdin."
    unlock_wait_start "$token"
    return 0
  fi
  need_docker; need_gh
  docker inspect "$GATE_NAME" >/dev/null 2>&1 || die "no gate — run: ci-runner.sh up"

  # The source is a flag and not a guess. Sniffing stdin looks friendlier and
  # is a trap: run from anything that is not an interactive terminal — a
  # script, an agent session, a launchd job — stdin is a pipe that is open and
  # idle rather than closed, so reading it blocks forever with no output and no
  # error. Clipboard by default, `--stdin` to pipe.
  if [ -n "$FLAG_STDIN" ]; then
    token=$(cat)
    [ -n "$token" ] || die "nothing arrived on stdin."
  else
    command -v pbpaste >/dev/null 2>&1 || die "no pbpaste — pipe the token in with --stdin."
    token=$(pbpaste)
    [ -n "$token" ] || die "the clipboard is empty. Copy the token first, or use --stdin."
    note "reading the token from the clipboard"
  fi
  unlock_send "$token"
}

# What happens to a token once it is in hand and the gate is there to take it.
unlock_send() {
  local token=$1 list check
  # The list goes in with the token, because a reboot loses both — they live on
  # the same tmpfs — and one command should restore the gate completely rather
  # than leaving it authenticated and serving nothing.
  list=$(registry)
  [ -n "$list" ] && printf '%s\n' "$list" | docker exec --interactive "$GATE_NAME" tee /run/gate/repos >/dev/null

  # Piped on stdin, never as an argument: an argument would show up in the
  # host's process list and in the shell history. Validated against the first
  # repository on the list — a token that authenticates but cannot administer
  # runners would otherwise be accepted and fail later, in a log nobody reads.
  # With --owner it is that owner's token, checked against that owner's first
  # repository; without, the main one, checked against the list's first —
  # which is the account's own, since `registry` lists those first.
  if [ -n "$FLAG_OWNER" ]; then
    check=$(printf '%s\n' "$list" | awk -v o="$FLAG_OWNER" \
      'tolower(substr($1, 1, index($1, "/") - 1)) == tolower(o) { print $1; exit }')
    [ -n "$check" ] || die "no repository of $FLAG_OWNER in the registry — adopt one first."
  else
    check=$(printf '%s' "$list" | head -1 | awk '{print $1}')
  fi
  printf '%s' "$token" | docker exec --interactive \
    --env "GITHUB_REPO=$check" --env "GATE_OWNER=$FLAG_OWNER" \
    "$GATE_NAME" /usr/local/bin/unlock.sh
}

# ── unlock --wait ────────────────────────────────────────────────────────
# After a boot Docker and the gate come up on their own time, and the PIN
# window (pin-vault) must not wait for them: it hands the token over and is
# done. The receiver that has to wait does it here, in a process of its own.
# The token reaches it over a pipe on its stdin and lives in a shell variable
# there: never an argument, an environment variable or a file, so nothing on
# the machine can read it from outside. Several waiters take turns on a lock,
# because two unlocks at once would write the gate's token files over each
# other.
UNLOCK_LOG="$STATE_ROOT/machine/unlock.log"
UNLOCK_LOCK="$STATE_ROOT/machine/unlock-wait.lock"

unlock_wait_start() {
  local args=(__unlock-wait) token=$1
  [ -z "$FLAG_OWNER" ] || args+=(--owner "$FLAG_OWNER")
  args+=(--timeout "${FLAG_TIMEOUT:-300}")
  # Its own session where there is `setsid`, so that the end of the call that
  # started it (a `wsl --exec` closes everything attached to it) does not take
  # it along. macOS has none: a subshell that ignores HUP is as far as that
  # goes, and ignored signals survive the exec. The first process takes the
  # token and leaves a child to wait, so this returns once the token is out of
  # the caller's session: measured on the PC, a waiter still being started when
  # `wsl --exec` ended was gone, token included, without a word. Nothing of it
  # stays on the caller's stdin, stdout or stderr, so a caller reading our
  # output gets EOF at once.
  if command -v setsid >/dev/null 2>&1; then
    printf '%s' "$token" | setsid "$BASH" "$SCRIPT_PATH" "${args[@]}" >/dev/null 2>&1
  else
    printf '%s' "$token" | ( trap '' HUP; exec "$BASH" "$SCRIPT_PATH" "${args[@]}" ) >/dev/null 2>&1
  fi
}

unlock_log() {
  mkdir -p "$STATE_ROOT/machine"
  printf '%s ci-runner unlock --wait: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$UNLOCK_LOG"
}

# mkdir is atomic on Linux and macOS alike, which flock is not. The holder
# writes its pid and the time it must be done by; a lock whose holder is gone
# or past that time is taken over, so one stuck waiter cannot hold the next
# one up for ever. The lock is renamed before it is judged: two waiters can
# find the same stale holder, and the second must not delete the fresh lock the
# first has made by then, so it puts back whatever is not what it found.
unlock_lock() { # <must be done by, epoch seconds>
  local pid="" until_=0 away=$UNLOCK_LOCK.stale.$UNLOCK_ME
  if mkdir "$UNLOCK_LOCK" 2>/dev/null; then
    printf '%s %s
' "$UNLOCK_ME" "$1" > "$UNLOCK_LOCK/holder"
    return 0
  fi
  read -r pid until_ < "$UNLOCK_LOCK/holder" 2>/dev/null || true
  if [ -n "$pid" ] && { ! kill -0 "$pid" 2>/dev/null || [ "$(date +%s)" -gt "${until_:-0}" ]; }; then
    mv "$UNLOCK_LOCK" "$away" 2>/dev/null || return 1
    if [ "$(cat "$away/holder" 2>/dev/null)" = "$pid $until_" ]; then rm -rf "$away"
    else mv "$away" "$UNLOCK_LOCK" 2>/dev/null; fi
  fi
  return 1
}

# Whoever took it over after this one overran keeps it.
unlock_unlock() {
  local pid=""
  read -r pid _ < "$UNLOCK_LOCK/holder" 2>/dev/null || true
  [ "$pid" != "$UNLOCK_ME" ] || rm -rf "$UNLOCK_LOCK"
}

gate_up() {
  docker info >/dev/null 2>&1 && docker inspect --format '{{.State.Running}}' "$GATE_NAME" 2>/dev/null | grep -q true
}

unlock_waiter() {
  parse_flags "$@"
  local token
  token=$(cat)
  [ -n "$token" ] || exit 1
  unlock_wait_for_gate </dev/null >/dev/null 2>&1 &
}

unlock_wait_for_gate() {
  local entry limit deadline out rc=0
  # This runs in a background subshell, where $$ is the process that has
  # already left, and macOS's bash has no BASHPID.
  UNLOCK_ME=$(exec sh -c 'echo $PPID')
  limit=${FLAG_TIMEOUT:-300}
  entry=gate
  [ -z "$FLAG_OWNER" ] || entry=gate-$(printf '%s' "$FLAG_OWNER" | tr '[:upper:]' '[:lower:]')
  deadline=$((SECONDS + limit))
  mkdir -p "$STATE_ROOT/machine"

  until gate_up; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      unlock_log "timed out after ${limit}s: Docker or the gate did not come up. The token was dropped; run: ${CI_RUNNER_UNLOCK_CMD:-pin-vault unlock} $entry"
      exit 1
    fi
    sleep 1
  done

  # Taken once the gate is up, so a slow boot does not spend the next waiter's
  # time, and only the holder may remove it.
  until unlock_lock $(($(date +%s) + limit + 60)); do
    if [ "$SECONDS" -ge "$deadline" ]; then
      unlock_log "gave up after ${limit}s: an earlier unlock did not finish. The token was dropped; run: ${CI_RUNNER_UNLOCK_CMD:-pin-vault unlock} $entry"
      exit 1
    fi
    sleep 1
  done
  trap unlock_unlock EXIT
  trap 'exit 1' HUP INT TERM

  # Once, and what it said is logged without the token, should it be in there.
  out=$( { need_gh; unlock_send "$token"; } 2>&1 ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    out=${out//"$token"/[token]}
    unlock_log "the unlock failed (exit $rc): $(printf '%s' "$out" | tail -n 1 | cut -c1-200). The token was dropped; run: ${CI_RUNNER_UNLOCK_CMD:-pin-vault unlock} $entry"
    exit 1
  fi
  unlock_log "unlocked $entry"
}

cmd_logs() {
  parse_flags "$@"
  if [ -n "$FLAG_FOLLOW" ]; then docker logs --follow --tail 100 "$GATE_NAME"
  else docker logs --tail 100 "$GATE_NAME"; fi
}

gate_state() {
  local st
  st=$(docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null | tr -d '\n')
  printf '%s\n' "${st:-absent}"
}
gate_locked() {
  docker exec "$1" test -s /run/gate/pat >/dev/null 2>&1 && printf 'unlocked\n' || printf 'LOCKED\n'
}
gate_expiry() { docker exec "$1" cat /run/gate/pat.expiry 2>/dev/null | tr -d '\n'; }
# The owners holding a token of their own, with its expiry: "acme-org (2026-12-01 …)".
gate_owner_tokens() {
  docker exec "$1" sh -c 'for f in /run/gate/pat.d/*; do
      case $f in *.expiry|*"*") continue ;; esac
      printf "%s (%s) " "${f##*/}" "$(cat "$f.expiry" 2>/dev/null)"
    done' 2>/dev/null | sed 's/ $//'
}

# What the *running* gate was actually started with, not what this invocation
# would use — `up` may have been run with different flags a week ago, and a
# stale default here would say so wrongly instead of just reading the
# container it is asking about.
# A runner name has 64 characters and the slug already spends up to ~30 of
# them, so the tag is short: lower-case letters, digits and dashes, eight at
# most. `--host` overrides; the default is the host name, which on a laptop is
# usually a person's name and on WSL the Windows machine's.
host_tag() {
  local tag=${1:-$(hostname -s 2>/dev/null || hostname)}
  printf '%s' "$tag" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | cut -c1-8 | sed 's/^-*//; s/-*$//'
}

gate_env() {
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$GATE_NAME" 2>/dev/null \
    | sed -n "s/^$1=//p"
}

# Whether the running gate serves the mega class: MEGA_CPUS in its
# environment says so (0 is the mac's "off"); a gate that sizes itself and was
# given none says so in the status file it writes, as a price for the class. An
# older gate has neither, and `mega on` for it would queue jobs nobody takes.
gate_mega_capable() {
  local v
  v=$(gate_env MEGA_CPUS 2>/dev/null || true)
  case "$v" in
    0) return 1 ;;
    ''|*[!0-9]*) ;;
    *) return 0 ;;
  esac
  docker exec "$GATE_NAME" cat /run/gate/status.json 2>/dev/null \
    | jq -e '.class_costs.mega != null' >/dev/null 2>&1
}

# Cores in use, machine-wide, read the same way gate.sh reads them: the
# `ci-runner.class` label on every runner container this gate owns, priced by
# the cost the gate itself is running with.
budget_summary() {
  [ "$(gate_state "$GATE_NAME")" = running ] || { printf 'gate not running\n'; return; }
  local budget big_cost little_cost used=0 class cost mega_capable=0
  gate_mega_capable && mega_capable=1
  budget=$(gate_env BUDGET); big_cost=$(gate_env BIG_COST); little_cost=$(gate_env LITTLE_COST)
  # A live override outranks the environment the gate was started with — show
  # what it is actually enforcing, not what it was told at boot.
  local live_budget
  live_budget=$(gate_budget_live | awk '{print $1}')
  case "$live_budget" in ''|*[!0-9]*) : ;; *) budget=$live_budget ;; esac
  while read -r class; do
    [ -n "$class" ] || continue
    # `now` is priced as big, and mega as the whole budget (as big when the
    # gate does not serve it) — the same table as the gate's class_cost.
    case "$class" in
      big|now) cost=${big_cost:-$DEFAULT_BIG_COST} ;;
      little) cost=${little_cost:-$DEFAULT_LITTLE_COST} ;;
      mega) if [ "$mega_capable" = 1 ]; then cost=${budget:-$DEFAULT_BUDGET}; else cost=${big_cost:-$DEFAULT_BIG_COST}; fi ;;
      *) cost=0 ;;
    esac
    used=$((used + cost))
  done < <(docker ps --filter 'label=ci-runner.gate' --format '{{.Label "ci-runner.class"}}')
  printf '%s/%s cores (big cost %s, little cost %s)\n' \
    "$used" "${budget:-$DEFAULT_BUDGET}" "${big_cost:-$DEFAULT_BIG_COST}" "${little_cost:-$DEFAULT_LITTLE_COST}"
}


# ── the registry ─────────────────────────────────────────────────────────

# Which repositories this machine serves is a list, and the list lives on
# GitHub as a repository topic rather than in a file here. Three reasons, in
# the order they matter: a file on this machine is one more thing to lose when
# the machine is rebuilt; the topic is visible and editable from the web, so
# adding a repository does not require this script; and the same question asked
# from a second machine gets the same answer without syncing anything. Same
# principle as 12 — the state is GitHub's.
#
# The topic marks *eligibility*, not where CI is running: that is the
# CI_RUNNER variable, per repository, and the two are deliberately separate.
# `owner/repo`, one per line — the exact bytes the gate reads. There used to
# be a middle field for warm/cold, then a trailing `docker`/`nodocker` for the
# socket; both are gone and gate.sh reads `read -r repo _`, which
# tolerates a file written before either went.
#
# The account's own repositories first, then each organisation it belongs to:
# `gh repo list` with no owner lists only the account's, so an organisation's
# repository with the topic was silently never served (acme-org/backend,
# 2026-10-06). An organisation's repositories need that owner's token in the
# gate — `unlock --owner` — and the gate logs a 404 for them until it has one.
registry() {
  local owner
  for owner in "" $(gh api user/orgs --jq '.[].login' 2>/dev/null); do
    gh repo list ${owner:+"$owner"} --topic "$TOPIC" --limit 100 \
       --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null
  done
}
registry_repos() { registry | awk '{print $1}'; }

# COLD_TOPIC is no longer read by anything here — a repository was never
# forced off it, so one adopted before this change may still carry it. Named
# rather than silently dropped: `sync` and `list` say so once, so it gets
# cleaned up by a person rather than left to look meaningful.
note_cold_leftovers() {
  local left
  left=$(gh repo list --topic "$COLD_TOPIC" --limit 100 --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null)
  [ -n "$left" ] || return 0
  note "$COLD_TOPIC is no longer read, but still set on: $(printf '%s' "$left" | tr '\n' ' ')"
  note "remove it with: gh repo edit <repo> --remove-topic $COLD_TOPIC"
}

# The gate is told the list; it never looks it up. See the header of gate.sh.
cmd_sync() {
  need_gh
  local list
  list=$(registry)
  [ -n "$list" ] || die "the registry is empty — adopt a repository first."
  if [ "$(gate_state "$GATE_NAME")" = running ]; then
    printf '%s\n' "$list" | docker exec --interactive "$GATE_NAME" tee /run/gate/repos >/dev/null \
      && ok "the gate is serving $(printf '%s' "$list" | grep -c .) repositories"
  else
    note "the gate is not running — the list will be pushed by 'up'."
  fi
  printf '%s\n' "$list" | sed 's/^/  /'
  note_cold_leftovers
}

# Every command that acts on a repository takes either a checkout path,
# owner/repo or --all, and this is the only place that difference exists.
targets() {
  local arg=${1:?a checkout path, owner/repo or --all}
  if [ "$arg" = "--all" ]; then
    registry
  else
    resolve_repo "$arg"
  fi
}

# adopt and forget also take `owner/repo`, because the repositories this
# machine should serve are not all checked out on it — and requiring a clone
# just to add a name to a list would be a rule that invents work.
resolve_repo() {
  local arg=$1
  if [ -d "$arg" ]; then repo_of "$arg"
  elif printf '%s' "$arg" | grep -q '^[^/ ]\+/[^/ ]\+$'; then printf '%s\n' "$arg"
  else die "not a checkout and not owner/repo: $arg"; fi
}

cmd_adopt() {
  local path=${1:?adopt needs a checkout path or owner/repo}; shift || true
  parse_flags "$@"
  need_gh
  local repo meta visibility archived
  repo=$(resolve_repo "$path")
  meta=$(gh repo view "$repo" --json visibility,isArchived) || die "cannot read $repo"
  visibility=$(printf '%s' "$meta" | jq -r .visibility)
  archived=$(printf '%s' "$meta" | jq -r .isArchived)

  # Refused, not warned about. A self-hosted runner on a public repository
  # executes code from anybody's fork on this machine — GitHub says so itself,
  # and no label or approval setting makes that a thing to opt into casually.
  # If it is ever genuinely wanted, it should be a deliberate act somewhere
  # other than a convenience command.
  [ "$visibility" = "PUBLIC" ] && die "$repo is public — a self-hosted runner there runs code from any fork. Refusing."
  [ "$archived" = "true" ] && die "$repo is archived — it runs nothing."

  gh repo edit "$repo" --add-topic "$TOPIC" >/dev/null
  gh repo edit "$repo" --remove-topic "$OLD_DOCKER_TOPIC" >/dev/null 2>&1 || true
  rm -f "$STATE_ROOT/cache/registry"
  ok "$repo is in the registry — nothing kept warm; a runner is raised when work is queued for it"
  cmd_sync >/dev/null 2>&1 || true
  note "it still runs on GitHub until: ci-runner.sh on <owner/repo>"
  # What the repository still needs, read from GitHub and written nowhere. Its
  # findings are advice: adopting succeeded, so they do not change the status.
  repo_report "$repo" "$(label_of)" || true
  return 0
}

cmd_forget() {
  local path=${1:?forget needs a checkout path or owner/repo}
  need_gh
  local repo; repo=$(resolve_repo "$path")
  gh repo edit "$repo" --remove-topic "$TOPIC" >/dev/null
  gh repo edit "$repo" --remove-topic "$COLD_TOPIC" >/dev/null 2>&1 || true
  gh repo edit "$repo" --remove-topic "$OLD_DOCKER_TOPIC" >/dev/null 2>&1 || true
  rm -f "$STATE_ROOT/cache/registry"
  cmd_sync >/dev/null 2>&1 || true
  ok "$repo removed from the registry"
  note "its gate and its switch are untouched — ci-runner.sh down/off if that is meant too"
}

cmd_list() {
  need_gh
  local repo flag count gate
  gate=$(gate_state "$GATE_NAME")
  [ "$gate" = running ] && gate="$gate, $(gate_locked "$GATE_NAME") — $(budget_summary)"
  printf 'gate  %s\n\n' "$gate"
  registry | while read -r repo; do
    [ -n "$repo" ] || continue
    flag=$(gh variable get "$VARIABLE" --repo "$repo" 2>/dev/null || printf '-')
    count=$(docker ps --filter "label=ci-runner.gate=$(slug_of "$repo")" --quiet 2>/dev/null | wc -l | tr -d ' ')
    printf '%-46s %s=%-3s runners=%s\n' "$repo" "$VARIABLE" "$flag" "$count"
  done
  note_cold_leftovers
}

# ── the switch ───────────────────────────────────────────────────────────

runners_json() { gh api "/repos/$1/actions/runners" 2>/dev/null || printf '{"runners":[]}'; }

# What the default branch's workflows do that this machine's runners cannot, one
# `path:line: what` per line (workflow-blockers.awk). Read from GitHub, not from
# a checkout: the switch applies to what is on the default branch, and a
# checkout may be behind it. Fails when a workflow cannot be read. The second
# argument is the list of workflow paths, for a caller that has fetched it.
workflow_blockers() {
  local repo=$1 paths=${2:-} path
  [ -n "$paths" ] || paths=$(workflow_paths "$repo") || return 1
  for path in $paths; do
    gh api "/repos/$repo/contents/$path" --jq .content 2>/dev/null | base64 -d | awk -f "$SCRIPT_DIR/workflow-blockers.awk" | sed "s|^|$path:|" || return 1
  done
}

# The workflow files of the default branch, one path per line; fails when the
# directory cannot be read.
workflow_paths() {
  gh api "/repos/$1/contents/.github/workflows" --jq '.[] | select(.name | test("[.]ya?ml$")) | .path' 2>/dev/null
}
# A file of the default branch. The contents API gives no body past its size
# limit, so a lockfile goes through repo_file_raw.
repo_file() {
  local content
  content=$(gh api "/repos/$1/contents/$2" --jq .content 2>/dev/null) || return 1
  [ -n "$content" ] || return 1
  printf '%s\n' "$content" | base64 -d
}
repo_file_raw() { gh api -H 'Accept: application/vnd.github.raw' "/repos/$1/contents/$2" 2>/dev/null; }

# Whether the gate holds a token of its own for an owner that is not the
# account. Existence only, `test -s`: the value is never read. The owner comes
# from a repository name and ends up in a `docker exec`, so its shape is checked.
report_owner_token() {
  local repo=$1 owner account lower
  owner=${repo%%/*}
  account=$(gh api user --jq .login 2>/dev/null) || account=""
  if [ -z "$account" ]; then
    printf '! cannot tell which account gh is, so cannot tell whether %s needs a token of its own\n' "$owner"
    return 0
  fi
  if [ "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$account" | tr '[:upper:]' '[:lower:]')" ]; then
    printf '✓ %s is the account gh is logged in as: the gate'\''s main token serves it\n' "$owner"
    return 0
  fi
  if ! printf '%s' "$owner" | grep -Eq '^[A-Za-z0-9-]+$'; then
    printf '✗ the owner %s has a name this tool will not look up a token for\n' "$owner"
    return 1
  fi
  if [ "$(gate_state "$GATE_NAME")" != running ]; then
    printf '! cannot tell whether the gate holds a token for %s: the gate is not running\n' "$owner"
    return 0
  fi
  # unlock.sh stores the file under the lower-cased owner, and gate.sh looks it up so.
  lower=$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')
  if docker exec "$GATE_NAME" test -s "/run/gate/pat.d/$lower" >/dev/null 2>&1; then
    printf '✓ the gate holds a token for %s\n' "$owner"
  else
    printf '! the gate holds no token for %s, so jobs in %s cannot be served — run: ci-runner.sh unlock --owner %s\n' "$owner" "$repo" "$owner"
  fi
}

# Whether the node or playwright version a workflow asks for is in seed.list.
# A version that is not still works, the job downloads it into its own
# container, so a gap is a warning. seed.list stays the trust list: this reads
# it and never edits it. $1 = tool, $2 = version, $3 = where it was asked for.
report_version() {
  local tool=$1 want=$2 where=$3 seeded s hit=0
  seeded=$(awk -v t="$tool" '$1 == t { printf "%s%s", sep, $2; sep = ", " }' "$SCRIPT_DIR/seed.list" 2>/dev/null)
  for s in $(printf '%s' "$seeded" | tr ',' ' '); do
    case "$s" in "$want"|"$want".*) hit=1 ;; esac
  done
  if [ $hit = 1 ]; then printf '✓ %s %s (%s) is in seed.list\n' "$tool" "$want" "$where"
  else printf '! %s %s (%s) is not in seed.list (seeded: %s) — every job downloads it. A person bumps seed.list, then: ci-runner.sh seed\n' \
      "$tool" "$want" "$where" "${seeded:-nothing}"; fi
}

# What a repository still needs before `on` will do anything useful, printed as
# lines: `!` for a warning, `✗` for an error, and the return status is non-zero
# on an error. Read from the default branch through `gh api`, never from a
# checkout, and nothing is written anywhere. A workflow that cannot be read is
# an error: unreadable is not clean. $1 = owner/repo, $2 = the machine's label.
repo_report() {
  local repo=$1 label=$2 errs=0 readable=1 paths="" path body res kind line job what
  local switched=0 bad=0 pinned=0 pw_used=0 node_refs="" blockers l key val ver file lock where
  printf '\nWorkflows of %s, default branch\n' "$repo"
  if ! paths=$(workflow_paths "$repo"); then
    readable=0; errs=$((errs + 1))
    printf '✗ cannot read the workflows of %s: nothing below is checked, which is not the same as clean\n' "$repo"
  fi
  for path in $paths; do
    if ! body=$(repo_file "$repo" "$path"); then
      printf '✗ cannot read %s\n' "$path"; errs=$((errs + 1)); continue
    fi
    res=$(printf '%s\n' "$body" | awk -f "$SCRIPT_DIR/workflow-switch.awk")
    while IFS=$'\t' read -r kind line job what; do
      case "$kind" in
        switch) switched=$((switched + 1)) ;;
        bad) bad=$((bad + 1)); errs=$((errs + 1)); printf '✗ %s:%s: %s: %s\n' "$path" "$line" "$job" "$what" ;;
        fixed|split) pinned=$((pinned + 1)); printf '! %s:%s: %s: %s\n' "$path" "$line" "$job" "$what" ;;
      esac
    done <<< "$res"
    # Here-strings, not a pipe into grep -q: it exits at the first match, and a
    # workflow past the pipe buffer would kill printf and fail the pipeline.
    ! grep -q 'playwright install' <<< "$body" || pw_used=1
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      key=$(printf '%s' "${l#*:}" | sed -E 's/^[ -]*(node-version(-file)?):.*/\1/')
      val=$(printf '%s' "${l#*:}" | sed -E "s/^[^:]*:[ ]*['\"]?([^'\" #]*).*/\1/")
      node_refs="$node_refs$path:${l%%:*} $key $val"$'\n'
    done < <(printf '%s\n' "$body" | grep -nE '^[ -]*node-version(-file)?:')
  done
  if [ $readable = 1 ]; then
    [ $switched -gt 0 ] && ok "$switched job(s) on the switch"
    if [ $((switched + bad)) -eq 0 ]; then
      printf '✗ no workflow reads vars.%s — the switch would do nothing\n' "$VARIABLE"; errs=$((errs + 1))
    fi

    printf '\nDocker\n'
    if blockers=$(workflow_blockers "$repo" "$paths"); then
      if [ -n "$blockers" ]; then
        printf '%s\n' "$blockers" | sed 's/^/✗ /'; errs=$((errs + 1))
      else ok "no job on the switch needs docker"; fi
    else
      printf '✗ cannot read the workflows to look for docker use\n'; errs=$((errs + 1))
    fi

    printf '\nVersions against seed.list\n'
    local seen_ref="" seen_ver=""
    while IFS=' ' read -r where key val; do
      [ -n "$where" ] || continue
      # Each distinct reference is read once, and each version reported once,
      # at the first place it is asked for.
      case "$seen_ref" in *"|$key $val|"*) continue ;; esac
      seen_ref="$seen_ref|$key $val|"
      if [ "$key" = node-version-file ]; then
        file=${val#./}
        grep -Eq '^[A-Za-z0-9_./-]+$' <<< "$file" || continue
        if ! ver=$(repo_file "$repo" "$file"); then
          printf '! %s names %s, which cannot be read on the default branch: its node version is not checked\n' "$where" "$file"
          continue
        fi
        val=$(head -n1 <<< "$ver" | tr -d ' \r')
      fi
      ver=${val#v}
      grep -Eq '^[0-9]+(\.[0-9]+){0,2}$' <<< "$ver" || continue
      case "$seen_ver" in *"|$ver|"*) continue ;; esac
      seen_ver="$seen_ver|$ver|"
      report_version node "$ver" "$where"
    done <<< "$node_refs"
    if [ $pw_used = 1 ]; then
      lock=$(repo_file_raw "$repo" pnpm-lock.yaml) || lock=""
      ver=$(grep -Eom1 'playwright-core@[0-9]+\.[0-9]+\.[0-9]+' <<< "$lock" | cut -d@ -f2 || true)
      if [ -n "$ver" ]; then report_version playwright "$ver" pnpm-lock.yaml
      else printf '! a workflow runs playwright install, but the playwright version could not be checked: no readable pnpm-lock.yaml with playwright-core in it\n'; fi
    fi
  fi

  printf '\nOwner token\n'
  report_owner_token "$repo" || errs=$((errs + 1))

  printf '\nLines to paste\n'
  note "runs-on for a job on this machine's big class:"
  printf '    runs-on: ${{ vars.%s == %s && (vars.%s || %s) || %s }}\n' "$VARIABLE" "'1'" "$VARIABLE_LABEL" "'$label'" "'ubuntu-latest'"
  note "runs-on for the mega job (the whole machine, alone; only on the one job that needs it):"
  printf '    runs-on: ${{ vars.%s == %s && (vars.%s || vars.%s || %s) || %s }}\n' "$VARIABLE" "'1'" "$VARIABLE_LABEL_MEGA" "$VARIABLE_LABEL" "'$label'" "'ubuntu-latest'"
  note "runs-on for a light job:"
  printf '    runs-on: ${{ vars.%s == %s && (vars.%s || %s) || %s }}\n' "$VARIABLE" "'1'" "$VARIABLE_LABEL_LIGHT" "'$label-light'" "'ubuntu-latest'"
  note "the last string is the project's own fallback on GitHub; keep it. Then switch it over:"
  note "ci-runner.sh on $repo"
  [ $errs -eq 0 ]
}

# What stands between a repository and the switch, collected once into
# ON_BLOCKERS (one `path:line: what` per line) and ON_WARNINGS (one message per
# line). cmd_on renders the same two variables as lines or, with --json, as one
# entry per repository, so the two cannot disagree about what was found.
on_collect() {
  local repo=$1 blockers
  ON_BLOCKERS=""; ON_WARNINGS=""; ON_NO_RUNNER=0
  if ! blockers=$(workflow_blockers "$repo"); then
    ON_WARNINGS="$repo: its workflows could not be read, so they were not checked."
  else
    ON_BLOCKERS=$blockers
  fi
}

on_entry() { # repo ok: the collected state as one compact JSON object
  jq --null-input --compact-output --arg repo "$1" --argjson ok "$2" \
    --arg b "$ON_BLOCKERS" --arg w "$ON_WARNINGS" \
    '{repo: $repo, ok: $ok,
      blockers: [$b | split("\n")[] | select(length > 0)],
      warnings: [$w | split("\n")[] | select(length > 0)]}'
}

cmd_on() {
  local target=${1:?on needs a checkout path, owner/repo or --all}
  shift
  parse_flags "$@"
  need_gh
  local repo repos label online refused=0 entries="" line out=1
  # With --json stdout carries the result and nothing else: gh's own output
  # goes to stderr with the rest of the prose.
  [ -z "$FLAG_JSON" ] || out=2
  # Assigned first: a failure inside `for x in $(...)` is swallowed, and a
  # misspelt name would then switch nothing and exit 0.
  repos=$(targets "$target")
  label=$(label_of)
  for repo in $repos; do
    on_collect "$repo"
    # Refused, not warned about: the switch moves every open pull request at
    # once, and each of them would go red on a job that never had a chance.
    if [ -n "$ON_BLOCKERS" ]; then
      refused=1
    else
      online=$(runners_json "$repo" | jq --arg l "$label" \
        '[.runners[]? | select(.status == "online") | select([.labels[].name] | index($l))] | length')
      if [ "${online:-0}" = 0 ]; then
        ON_NO_RUNNER=1
        ON_WARNINGS="${ON_WARNINGS:+$ON_WARNINGS$'\n'}$repo: no online runner carries the label $label."
      fi
      # Both destinations are written from the gate's own label rather than
      # typed, which is what keeps them from drifting: a label nothing carries
      # queues jobs forever and GitHub never says which label it was waiting
      # for. The light one is the same label with a fixed suffix — a job opts
      # into the little class by reading CI_RUNNER_LABEL_LIGHT instead.
      gh variable set "$VARIABLE_LABEL" --repo "$repo" --body "$label" >&"$out"
      gh variable set "$VARIABLE_LABEL_LIGHT" --repo "$repo" --body "${label}-light" >&"$out"
      gh variable set "$VARIABLE" --repo "$repo" --body 1 >&"$out"
      cache_put "$STATE_ROOT/cache/ci-runner-$(slug_of "$repo")" "1"
    fi
    if [ -n "$FLAG_JSON" ]; then
      entries="$entries$(on_entry "$repo" "$([ -n "$ON_BLOCKERS" ] && echo false || echo true)")"$'\n'
      continue
    fi
    while IFS= read -r line; do
      [ -z "$line" ] || printf '! %s\n' "$line" >&2
    done <<< "$ON_WARNINGS"
    if [ -n "$ON_BLOCKERS" ]; then
      printf '✗ %s stays on GitHub: its runners here have no docker.\n' "$repo" >&2
      printf '%s\n' "$ON_BLOCKERS" | sed 's/^/  /' >&2
      note "start it inside the job, or give that job a fixed runs-on." >&2
    else
      [ "$ON_NO_RUNNER" = 0 ] || note "setting the switch anyway; jobs will queue until one appears."
      ok "$repo now runs CI on this machine (runs-on: $label)"
    fi
  done
  if [ -n "$FLAG_JSON" ]; then
    if [ "$target" = "--all" ]; then
      printf '%s' "$entries" | jq --slurp '{schema: 1, ok: all(.[]; .ok), results: .}'
    else
      printf '%s' "$entries" | jq '{schema: 1} + .'
    fi
  fi
  [ "$refused" = 0 ]
}

cmd_off() {
  local target=${1:?off needs a checkout path, owner/repo or --all}
  need_gh
  local repo repos
  repos=$(targets "$target")
  for repo in $repos; do
    # Set to 0 rather than deleted. Both mean the same to the workflow, and a
    # variable that is present and reads `0` says "this repository knows about
    # the switch and it is off" — an absent one is indistinguishable from a
    # repository nobody has set up.
    gh variable set "$VARIABLE" --repo "$repo" --body 0
    cache_put "$STATE_ROOT/cache/ci-runner-$(slug_of "$repo")" "0"
    ok "$repo is back on GitHub-hosted runners"
  done
}


# `mega on|off`: the repository variable CI_RUNNER_LABEL_MEGA and nothing else.
# A workflow's mega job reads it (`vars.CI_RUNNER_LABEL_MEGA || vars.CI_RUNNER_LABEL`),
# so deleting it sends the job back to the ordinary big label — a run already
# queued keeps the label it was queued with. `on` refuses unless the running
# gate serves the class: a job labelled for a runner nobody starts queues forever.
cmd_mega() {
  local mode=${1:-} target=${2:-} repo label
  case "$mode" in on|off) ;; *) die "usage: ci-runner.sh mega on|off <path|owner/repo>" ;; esac
  [ -n "$target" ] || die "mega $mode needs a checkout path or owner/repo"
  need_gh
  repo=$(resolve_repo "$target"); label=$(label_of)
  if [ "$mode" = on ]; then
    gate_mega_capable || die "the running gate does not serve mega (no MEGA_CPUS, or --mega-cpus 0) — redeploy it first: ci-runner.sh redeploy. $VARIABLE_LABEL_MEGA not set."
    gh variable set "$VARIABLE_LABEL_MEGA" --repo "$repo" --body "${label}-mega"
    cache_put "$STATE_ROOT/cache/ci-runner-mega-$(slug_of "$repo")" "${label}-mega"
    ok "$repo: mega jobs run alone on this machine (runs-on: ${label}-mega)"
  else
    gh variable delete "$VARIABLE_LABEL_MEGA" --repo "$repo"
    cache_put "$STATE_ROOT/cache/ci-runner-mega-$(slug_of "$repo")" ""
    ok "$repo: mega jobs run as an ordinary big again (a run queued before this keeps its mega label)"
  fi
}

minutes_remaining() {
  local owner=${1%%/*} json included used
  json=$(gh api "/users/$owner/settings/billing/actions" 2>/dev/null) || return 1
  included=$(printf '%s' "$json" | jq -r '.included_minutes // empty')
  used=$(printf '%s' "$json" | jq -r '.total_minutes_used // empty')
  [ -n "$included" ] && [ -n "$used" ] || return 1
  awk -v i="$included" -v u="$used" 'BEGIN { r = i - u; print (r > 0 ? r : 0) }'
}

# 15 minutes is how long the panel's answers are kept: it asks often, and every
# answer is an API call (the variable per repository, and the registry). Mutators
# already update/invalidate caches synchronously.
CI_RUNNER_CACHE_TTL=${CI_RUNNER_CACHE_TTL:-900}
cache_fresh() { # file: written less than CI_RUNNER_CACHE_TTL seconds ago
  local mtime
  [ -f "$1" ] || return 1
  mtime=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)
  [ $(( $(date +%s) - mtime )) -lt "$CI_RUNNER_CACHE_TTL" ]
}
# A temp file per process, because two polls can overlap; gone if it fails.
cache_put() { # file value
  mkdir -p "$(dirname "$1")"
  if printf '%s\n' "$2" > "$1.new.$$" && mv -f "$1.new.$$" "$1"; then :; else rm -f "$1.new.$$"; fi
}

# The CI_RUNNER variable of a repository, kept for a minute. Empty when it is
# unset or the call failed — the failure is kept for the minute too.
ci_runner_cached() {
  local file="$STATE_ROOT/cache/ci-runner-$(slug_of "$1")" v
  if cache_fresh "$file"; then cat "$file"; return 0; fi
  v=$(gh variable get "$VARIABLE" --repo "$1" 2>/dev/null || true)
  cache_put "$file" "$v"
  printf '%s\n' "$v"
}

# Same, for the mega switch: the label the variable holds, empty when unset.
mega_cached() {
  local file="$STATE_ROOT/cache/ci-runner-mega-$(slug_of "$1")" v
  if cache_fresh "$file"; then cat "$file"; return 0; fi
  v=$(gh variable get "$VARIABLE_LABEL_MEGA" --repo "$1" 2>/dev/null || true)
  cache_put "$file" "$v"
  printf '%s\n' "$v"
}

# The registry, kept for a minute. An empty answer is never kept: it is what a
# logged-out gh gives, and it must not hide a repository for the next minute.
registry_cached() {
  local file="$STATE_ROOT/cache/registry" list
  if cache_fresh "$file"; then cat "$file"; return 0; fi
  list=$(registry_repos 2>/dev/null || true)
  [ -z "$list" ] || { cache_put "$file" "$list"; printf '%s\n' "$list"; }
  return 0
}

# Where the machine stands as one JSON document (status.schema.json), for the
# panel. No path: it is about the gate and the registry, not one checkout. The
# gate's own file is passed through as it is; no token is read, only whether one
# exists and the expiry files beside it. It never needs gh to answer: logged out,
# it is still valid JSON, with no repositories or a null switch.
cmd_status_json() {
  local state locked=null paused=null commit="" expiry="" owners="" file=null repos r
  state=$(gate_state "$GATE_NAME")
  if [ "$state" = running ]; then
    if [ "$(gate_locked "$GATE_NAME")" = LOCKED ]; then locked=true; else locked=false; fi
    if [ -n "$(gate_paused "$GATE_NAME")" ]; then paused=true; else paused=false; fi
    commit=$(gate_env GATE_COMMIT || true)
    [ "$locked" = true ] || expiry=$(gate_expiry "$GATE_NAME")
    owners=$(gate_owner_tokens "$GATE_NAME")
    file=$(docker exec "$GATE_NAME" cat /run/gate/status.json 2>/dev/null | jq --compact-output . 2>/dev/null) || file=null
    [ -n "$file" ] || file=null
  fi
  repos=$(for r in $(registry_cached); do printf '%s\t%s\t%s\n' "$r" "$(ci_runner_cached "$r")" "$(mega_cached "$r")"; done)
  jq --null-input \
    --arg state "$state" --argjson locked "$locked" --argjson paused "$paused" \
    --arg commit "$commit" --arg expiry "$expiry" --arg owners "$owners" \
    --argjson status "$file" --arg repos "$repos" '
    def none($x): if $x == "" then null else $x end;
    { schema: 1,
      gate: { state: $state, locked: $locked, paused: $paused,
              commit: none($commit), token_expires: none($expiry),
              owner_tokens: [$owners | scan("([^ ()]+) [(]([^)]*)[)]")
                             | { owner: .[0], expires: none(.[1]) }] },
      status: $status,
      repositories: [$repos | split("\n")[] | select(length > 0) | split("\t")
                     | { repo: .[0],
                         ci_runner: (.[1] // "" | if . == "" then null
                                     elif test("^[0-9]+$") then tonumber else . end),
                         mega: (.[2] // "" | if . == "" then null else . end) }] }'
}

cmd_status() {
  if [ "${1:-}" = --json ]; then shift; cmd_status_json "$@"; return; fi
  local path=${1:?status needs a checkout path}
  [ "$path" = "--all" ] && die "status is per project — the fleet view is: ci-runner.sh list"
  need_gh
  local repo slug label value gate remaining destination defer
  repo=$(repo_of "$path"); slug=$(slug_of "$repo"); label=$(label_of); gate=$GATE_NAME
  value=$(gh variable get "$VARIABLE" --repo "$repo" 2>/dev/null || true)

  printf 'repository   %s\n' "$repo"
  destination=$(gh variable get "$VARIABLE_LABEL" --repo "$repo" 2>/dev/null || true)
  case "$value" in
    1) printf 'runs-on      %s — %s (%s=1)\n' "${destination:-local-docker}" \
         "$([ "${destination:-local-docker}" = "$label" ] && printf 'this machine' || printf 'NOT this gate — its label is '"$label")" "$VARIABLE" ;;
    0) printf 'runs-on      ubuntu-latest — GitHub-hosted (%s=0)\n' "$VARIABLE" ;;
    "") printf 'runs-on      ubuntu-latest — GitHub-hosted (%s is not set)\n' "$VARIABLE" ;;
    *) printf 'runs-on      ubuntu-latest — %s is %s, which is neither 0 nor 1\n' "$VARIABLE" "$value" ;;
  esac
  printf 'label        %s (light: %s-light, priority: %s-now, mega: %s-mega)\n' "$label" "$label" "$label" "$label"
  local mega_value
  mega_value=$(gh variable get "$VARIABLE_LABEL_MEGA" --repo "$repo" 2>/dev/null || true)
  if [ -n "$mega_value" ]; then
    printf 'mega         %s — ON for %s (%s): a queued mega job drains the machine and runs alone\n' "$mega_value" "$repo" "$VARIABLE_LABEL_MEGA"
  else
    printf 'mega         %s — OFF — the job runs as an ordinary big (%s is not set)\n' "$label-mega" "$VARIABLE_LABEL_MEGA"
  fi
  # While the gate is holding the line for a mega job of this repository, say so;
  # read from the file it writes every tick, whatever state docker reports.
  docker exec "$gate" cat /run/gate/status.json 2>/dev/null | jq -r --arg r "$repo" '
    select(.draining != null and .draining.repo == $r)
    | "draining     \(.waiting // "")\(if .draining.overdue then " — OVERDUE, past MEGA_DRAIN_WARN" else "" end)"' 2>/dev/null || true
  # Which of two machines on one label this one is: the one that takes a job
  # at once, or the one that yields for a while. Visible here because a job
  # that waits thirty seconds looks like a broken gate to anyone who forgot.
  defer=$(gate_env DEFER 2>/dev/null || true)
  case "${defer:-0}" in
    0|"") printf 'defer        0s — takes a queued job at once\n' ;;
    *) printf 'defer        %ss — yields to another machine on this label for that long\n' "$defer" ;;
  esac
  host=$(gate_env HOST_TAG 2>/dev/null || true)
  [ -n "$host" ] && printf 'host         %s — inside every runner name this machine mints\n' "$host"
  printf 'gate         %s' "$(gate_state "$gate")"
  if [ "$(gate_state "$gate")" = running ]; then
    printf ', %s' "$(gate_locked "$gate")"
    [ -n "$(gate_paused "$gate")" ] && printf ', PAUSED — ci-runner.sh resume'
    [ -n "$(gate_expiry "$gate")" ] && printf ', token expires %s' "$(gate_expiry "$gate")"
    [ -n "$(gate_owner_tokens "$gate")" ] && printf '; own tokens: %s' "$(gate_owner_tokens "$gate")"
  fi
  printf '\n'
  printf 'budget       %s\n' "$(budget_summary)"
  local runner_lines
  runner_lines=$(docker ps --filter "label=ci-runner.gate=$slug" \
    --format '{{.Names}} ({{.Label "ci-runner.class"}})' 2>/dev/null)
  printf 'runners here %s\n' "${runner_lines:-0}"
  if remaining=$(minutes_remaining "$repo"); then
    printf 'allowance    %s included minutes left\n' "$remaining"
  else
    printf 'allowance    unreadable — gh auth refresh -h github.com -s user\n'
  fi
  printf 'registered   '
  runners_json "$repo" | jq -r \
    'if (.runners | length) == 0 then "none"
     else (.runners[] | "\(.name) [\(.status)\(if .busy then ", busy" else ", idle" end)]") end'

  if ! grep -rq "vars\.$VARIABLE" "$path/.github/workflows" 2>/dev/null; then
    printf '! no workflow in %s reads vars.%s — the switch does nothing there.\n' \
      "$path/.github/workflows" "$VARIABLE" >&2
  fi
}

cmd_prune() {
  local path=${1:?prune needs a checkout path}
  need_gh
  local repo ids id; repo=$(repo_of "$path")
  ids=$(runners_json "$repo" | jq -r '.runners[]? | select(.status == "offline") | .id')
  [ -n "$ids" ] || { note "nothing to prune."; return 0; }
  for id in $ids; do gh api --method DELETE "/repos/$repo/actions/runners/$id" >/dev/null && note "deleted runner $id"; done
}

# ── autoswitch (optional, and the only thing still using launchd) ─────────

# Said first, before anything is read or made: on WSL and plain Linux there is
# no launchd, and the plist this used to write there was a file nothing loaded.
need_launchd() {
  command -v launchctl >/dev/null 2>&1 \
    || die "$1 needs launchd, which only macOS has; nothing was written. Run 'ci-runner.sh autoswitch <path>' from your own scheduler instead."
}

blocked_runs() {
  local repo=$1 since
  since=$(date -u -v-2d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || since=$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)
  gh api "/repos/$repo/actions/runs?per_page=30" 2>/dev/null \
    | jq --arg since "$since" '[.workflow_runs[]? | select(.created_at > $since) | select(.conclusion == "startup_failure")] | length' 2>/dev/null \
    || printf '0\n'
}

log_switch() {
  local slug=$1; shift
  local line; line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  printf '%s\n' "$line"; printf '%s\n' "$line" >> "$(state_dir_of "$slug")/autoswitch.log"
}

cmd_autoswitch() {
  local path=${1:?autoswitch needs a checkout path}; shift || true
  parse_flags "$@"; need_gh
  local repo slug label reserve current remaining blocked marker want blockers
  repo=$(repo_of "$path"); slug=$(slug_of "$repo"); label=$(label_of)
  marker="$(state_dir_of "$slug")/auto-on"; reserve=${FLAG_RESERVE:-$DEFAULT_RESERVE}
  current=$(gh variable get "$VARIABLE" --repo "$repo" 2>/dev/null || true)

  if remaining=$(minutes_remaining "$repo"); then
    want=$(awk -v r="$remaining" -v k="$reserve" 'BEGIN { print (r <= k ? 1 : 0) }')
    log_switch "$slug" "balance: ${remaining} included minutes left, reserve ${reserve}"
  else
    remaining=""; blocked=$(blocked_runs "$repo")
    want=$([ "${blocked:-0}" -gt 0 ] && printf 1 || printf 0)
    log_switch "$slug" "balance unreadable (gh auth refresh -h github.com -s user); ${blocked:-0} refused run(s) in 2 days"
  fi

  # Switching on is safe to repeat and safe to be wrong about. Switching off is
  # how a deliberate choice gets undone by a timer, so it happens only when
  # this command was what turned it on, and only on a balance it could read.
  if [ "$want" = 1 ] && [ "$current" != 1 ]; then
    if blockers=$(workflow_blockers "$repo") && [ -n "$blockers" ]; then
      log_switch "$slug" "stays on GitHub, its workflows need docker: ${blockers%%$'
'*}"
      return 0
    fi
    [ -n "$FLAG_DRY" ] && { log_switch "$slug" "would switch to $label (dry run)"; return 0; }
    [ "$(gate_state "$GATE_NAME")" = running ] || log_switch "$slug" "warning: the gate is not running — jobs will queue"
    gh variable set "$VARIABLE" --repo "$repo" --body 1; : > "$marker"
    cache_put "$STATE_ROOT/cache/ci-runner-$slug" "1"
    log_switch "$slug" "switched $repo to this machine (runs-on: $label)"
  elif [ "$want" = 0 ] && [ "$current" = 1 ] && [ -f "$marker" ] && [ -n "$remaining" ]; then
    [ -n "$FLAG_DRY" ] && { log_switch "$slug" "would switch back to GitHub (dry run)"; return 0; }
    gh variable set "$VARIABLE" --repo "$repo" --body 0 >/dev/null; rm -f "$marker"
    cache_put "$STATE_ROOT/cache/ci-runner-$slug" "0"
    log_switch "$slug" "allowance is back — $repo returned to GitHub-hosted runners"
  else
    log_switch "$slug" "no change ($VARIABLE=${current:-unset})"
  fi
}

cmd_watch() {
  need_launchd watch
  local path=${1:?watch needs a checkout path}; shift || true
  parse_flags "$@"; need_gh
  path=$(cd "$path" && pwd)
  local repo slug plist state every reserve
  repo=$(repo_of "$path"); slug=$(slug_of "$repo"); state=$(state_dir_of "$slug")
  every=${FLAG_EVERY:-$DEFAULT_EVERY}; reserve=${FLAG_RESERVE:-$DEFAULT_RESERVE}
  plist="$AGENTS_DIR/${WATCH_PREFIX}.${slug}.plist"; mkdir -p "$AGENTS_DIR"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${WATCH_PREFIX}.${slug}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${SCRIPT_PATH}</string><string>autoswitch</string><string>${path}</string>
    <string>--reserve</string><string>${reserve}</string>
  </array>
  <key>StartInterval</key><integer>${every}</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${state}/watch.log</string>
  <key>StandardErrorPath</key><string>${state}/watch.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>${HOME}</string>
  </dict>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$UID/${WATCH_PREFIX}.${slug}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$UID" "$plist"
  ok "watching $repo every ${every}s, reserve ${reserve} minutes"
  note "log: $state/watch.log"
}

cmd_unwatch() {
  need_launchd unwatch
  local path=${1:?unwatch needs a checkout path}
  local repo slug; repo=$(repo_of "$path"); slug=$(slug_of "$repo")
  launchctl bootout "gui/$UID/${WATCH_PREFIX}.${slug}" >/dev/null 2>&1 || true
  rm -f "$AGENTS_DIR/${WATCH_PREFIX}.${slug}.plist"
  ok "stopped watching ${slug}"
}

# ── removing it ──────────────────────────────────────────────────────────

purge_project() {
  local path=$1 repo slug dir
  repo=$(repo_of "$path"); slug=$(slug_of "$repo")
  docker ps --all --filter "label=ci-runner.gate=$slug" --format '{{.Names}}' \
    | while read -r n; do [ -n "$n" ] && docker rm --force "$n" >/dev/null 2>&1; done
  launchctl bootout "gui/$UID/${WATCH_PREFIX}.${slug}" >/dev/null 2>&1 || true
  rm -f "$AGENTS_DIR/${WATCH_PREFIX}.${slug}.plist"
  if gh variable get "$VARIABLE" --repo "$repo" >/dev/null 2>&1; then
    gh variable delete "$VARIABLE" --repo "$repo" >/dev/null 2>&1 || true
    gh variable delete "$VARIABLE_LABEL" --repo "$repo" >/dev/null 2>&1 || true
    gh variable delete "$VARIABLE_LABEL_MEGA" --repo "$repo" >/dev/null 2>&1 || true
    rm -f "$STATE_ROOT/cache/ci-runner-$slug" "$STATE_ROOT/cache/ci-runner-mega-$slug"
    note "$repo is back on GitHub-hosted runners"
  fi
  cmd_prune "$path" >/dev/null 2>&1 || true
  docker volume rm "ci-runner-git-$slug" "ci-runner-npm-$slug" "ci-runner-cache-$slug" "ci-runner-pnpm-$slug" >/dev/null 2>&1 || true
  for dir in "$WORK_ROOT/$slug" "$STATE_ROOT/$slug"; do
    case "$dir" in "$HOME"/*) [ -d "$dir" ] && remove_tree "$dir" ;; esac
  done
  ok "purged $repo"
}

# rm -rf that says when it could not finish. A work folder left by a gate
# older than an earlier change has root-owned directories in it — docker made them as the
# source of a bind mount — and the host user cannot remove those. That needs
# the owner's sudo, which this tool does not reach for.
remove_tree() {
  rm -rf "$1" 2>/dev/null
  [ -e "$1" ] || return 0
  note "could not remove all of $1 — parts are owned by root (made by docker for an old gate's bind mount)."
  note "remove it yourself: sudo rm -rf $1"
}

cmd_purge() {
  local arg=${1:?purge needs a checkout path or --all}
  need_gh
  [ "$arg" != "--all" ] && { purge_project "$arg"; return 0; }
  local name
  docker rm --force "$GATE_NAME" >/dev/null 2>&1 || true
  docker ps --all --format '{{.Names}}' | grep '^ci-runner-' \
    | while read -r n; do docker rm --force "$n" >/dev/null 2>&1; done
  # The last three are the shared read-write volumes an earlier change retired; a machine
  # that never redeployed since may still have them.
  docker volume ls --quiet | grep -E '^ci-runner-(npm|cache|pnpm|git)-' | xargs -r docker volume rm >/dev/null 2>&1 || true
  docker volume rm "$SEED_VOLUME" ci-runner-toolcache ci-runner-npm ci-runner-cache >/dev/null 2>&1 || true
  docker image rm "$RUNNER_IMAGE" "$GATE_IMAGE" >/dev/null 2>&1 || true
  for name in "$AGENTS_DIR/${WATCH_PREFIX}".*.plist; do
    [ -e "$name" ] || continue
    launchctl bootout "gui/$UID/$(basename "$name" .plist)" >/dev/null 2>&1 || true
    rm -f "$name"
  done
  case "$WORK_ROOT" in "$HOME"/*) [ -e "$WORK_ROOT" ] && remove_tree "$WORK_ROOT" ;; esac
  case "$STATE_ROOT" in "$HOME"/*) rm -rf "$STATE_ROOT" ;; esac
  ok "nothing of this is left on the machine except ci-runner.sh itself"
  note "the repository variable, if any, is per project — clear it with: ci-runner.sh off <path>"
}

cmd_doctor() {
  local path=${1:?doctor needs a checkout path or owner/repo}
  local rc=0 repo slug
  docker info >/dev/null 2>&1 && ok "docker is running" || { printf '✗ docker is not running\n'; rc=1; }
  gh auth status >/dev/null 2>&1 && ok "gh is authenticated" || { printf '✗ gh is not authenticated\n'; rc=1; }
  docker image inspect "$RUNNER_IMAGE" >/dev/null 2>&1 && docker image inspect "$GATE_IMAGE" >/dev/null 2>&1 \
    && ok "both images are built" || printf '! images missing — run: ci-runner.sh build\n'
  docker run --rm --network none --entrypoint sh --volume "$SEED_VOLUME:/seed:ro" "$RUNNER_IMAGE" \
      -c 'ls /seed/toolcache/node | grep -q . && ls /seed/ms-playwright | grep -q .' >/dev/null 2>&1 \
    && ok "the seed holds node and browsers" \
    || printf '! the seed is empty — jobs download their toolchain every time. Fix: ci-runner.sh seed\n'
  repo=$(resolve_repo "$path") && ok "checking $repo" || return 1
  slug=$(slug_of "$repo")
  case "$(gate_state "$GATE_NAME")" in
    running) ok "the gate is running ($(gate_locked "$GATE_NAME")) — budget $(budget_summary)" ;;
    absent) printf '! no gate on this machine — run: ci-runner.sh up\n' ;;
    *) printf '! the gate exists but is %s\n' "$(gate_state "$GATE_NAME")" ;;
  esac
  # -x: a registry line is the bare owner/repo since an earlier change; "^$repo " matched
  # the second column that is gone.
  registry | grep -qx "$repo" && ok "$repo is in the registry" \
    || { printf '✗ %s is not in the registry — run: ci-runner.sh adopt %s\n' "$repo" "$repo"; rc=1; }
  # The destination is a second variable, so it can drift from the gate's
  # label — and a job asking for a label nothing carries queues forever
  # without saying which label it wanted. Unset is fine: the workflow's own
  # default covers it, and `on` writes it anyway.
  local want have
  want=$(label_of)
  have=$(gh variable get "$VARIABLE_LABEL" --repo "$repo" 2>/dev/null || true)
  if [ -z "$have" ]; then
    printf '! %s is not set — the workflow default applies. `on` will set it.\n' "$VARIABLE_LABEL"
  elif [ "$have" = "$want" ]; then
    ok "$VARIABLE_LABEL is $have, which is what this gate hands out"
  else
    printf '✗ %s is %s but this gate hands out %s — jobs would queue unclaimed\n' "$VARIABLE_LABEL" "$have" "$want"; rc=1
  fi
  # Same check, for the little class. A job opts in by reading this variable
  # instead of CI_RUNNER_LABEL; a workflow that never mentions it just never
  # asks for the little class, which is fine and not a failure here.
  local want_light have_light
  want_light="${want}-light"
  have_light=$(gh variable get "$VARIABLE_LABEL_LIGHT" --repo "$repo" 2>/dev/null || true)
  if [ -z "$have_light" ]; then
    printf '! %s is not set — a job asking for the light class falls back to its own default. `on` will set it.\n' "$VARIABLE_LABEL_LIGHT"
  elif [ "$have_light" = "$want_light" ]; then
    ok "$VARIABLE_LABEL_LIGHT is $have_light, which is what this gate hands out"
  else
    printf '✗ %s is %s but this gate hands out %s — jobs would queue unclaimed\n' "$VARIABLE_LABEL_LIGHT" "$have_light" "$want_light"; rc=1
  fi
  # A set mega variable is a promise that the gate will drain for the job. An
  # older gate, or one started with --mega-cpus 0, would leave it queued forever.
  local have_mega
  have_mega=$(gh variable get "$VARIABLE_LABEL_MEGA" --repo "$repo" 2>/dev/null || true)
  if [ -z "$have_mega" ]; then
    ok "$VARIABLE_LABEL_MEGA is not set — a mega job runs as an ordinary big"
  elif [ "$(gate_state "$GATE_NAME")" != running ]; then
    printf '! %s is %s but the gate is not running — a mega job would queue\n' "$VARIABLE_LABEL_MEGA" "$have_mega"
  elif gate_mega_capable; then
    ok "$VARIABLE_LABEL_MEGA is $have_mega, and the gate serves mega"
  else
    printf '! %s is %s but the gate does not serve mega — a mega job would queue unclaimed. Redeploy the gate, or: ci-runner.sh mega off %s\n' "$VARIABLE_LABEL_MEGA" "$have_mega" "$repo"
  fi
  minutes_remaining "$repo" >/dev/null 2>&1 && ok "the token can read the minute balance" \
    || printf '! cannot read the minute balance — autoswitch falls back to detecting a refused run. Fix: gh auth refresh -h github.com -s user\n'
  case "$(uname -m)" in
    arm64|aarch64) ok "arm64 host — native, and a different architecture from GitHub's x64 runners" ;;
    *) ok "$(uname -m) host" ;;
  esac
  repo_report "$repo" "$want" || rc=1
  return $rc
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  build)   shift; cmd_build "$@" ;;
  redeploy) shift; cmd_redeploy "$@" ;;
  seed)    shift; cmd_seed "$@" ;;
  up)      shift; cmd_up "$@" ;;
  down)    shift; cmd_down "$@" ;;
  pause)   shift; cmd_pause "$@" ;;
  resume)  shift; cmd_resume "$@" ;;
  drain)   shift; cmd_drain "$@" ;;
  budget)  shift; cmd_budget "$@" ;;
  unlock)  shift; cmd_unlock "$@" ;;
  __unlock-wait) shift; unlock_waiter "$@" ;;
  on)      shift; cmd_on "$@" ;;
  off)     shift; cmd_off "$@" ;;
  mega)    shift; cmd_mega "$@" ;;
  status)  shift; cmd_status "$@" ;;
  logs)    shift; cmd_logs "$@" ;;
  prune)   shift; cmd_prune "$@" ;;
  purge)   shift; cmd_purge "$@" ;;
  doctor)  shift; cmd_doctor "$@" ;;
  adopt)   shift; cmd_adopt "$@" ;;
  forget)  shift; cmd_forget "$@" ;;
  list)    shift; cmd_list "$@" ;;
  sync)    shift; cmd_sync "$@" ;;
  autoswitch) shift; cmd_autoswitch "$@" ;;
  watch)   shift; cmd_watch "$@" ;;
  unwatch) shift; cmd_unwatch "$@" ;;
  ""|-h|--help|help) usage ;;
  *) usage >&2; exit 64 ;;
esac
