#!/usr/bin/env bash
#
# One gate for the whole machine. It serves every repository on its list,
# polls it for queued work every tick, raises a runner only when GitHub has a
# job waiting for one of this machine's two labels, and holds every
# repository's runners under one machine-wide budget — cores, not containers.
#
# Nothing here is kept warm. A warm runner earns back ~10s of registration
# time and costs a slot of the budget for as long as it sits idle; measured
# 2026-09-16, three warm repositories at the old MAX=3 was the whole ceiling
# spent on listeners with nothing queued. Cold and polled every tick is the
# only shape that leaves the budget for the runners actually doing work.
#
# Two classes, not one quota. `--cpus` is a ceiling, not a reservation — a
# runner with `--cpus 4` beside three other busy slots measured out to about
# one core, on the owner's 14-core machine with three agent dev containers
# also running — and its only reliable job is telling Playwright/vitest how
# many workers to spawn, which is why `cpus` is the same for both classes
# below. Priority under contention is `--cpu-shares`, not the quota, so a
# class is a cpu/memory/shares/cost tuple rather than one number:
#
#   class    label            cpus   memory   cpu-shares   cost
#   big      $LABEL           4      4g       2048         4
#   little   $LABEL-light     4      2g       1024         2
#
# Most jobs are cheap — lint, typecheck, unit, a couple of cores for a few
# minutes — and get the little class if a workflow opts in; the expensive one
# is e2e, now once per pull request since a project gates it on
# ready-for-review, and stays on big by default. `cost` is what the budget
# counts: expected cores under contention, not the `--cpus` ceiling, because
# the ceiling already summed to 44 on 14 cores under the old per-repository
# quota and BUDGET is what stops that happening again.
#
# THE LIST IS NOT DISCOVERED HERE. `ci-runner.sh` writes it into /run/gate,
# beside the credential and on the same tmpfs, because the host already holds a
# `gh` that can read the registry and this container should not need a token
# permission — nor an API call every tick — to learn what it already can be
# told. `adopt` pushes an updated list into a running gate, so a repository
# joins without a restart. A reboot loses both files together, and `unlock`
# restores both, which keeps "the machine at rest holds nothing" true.
#
# Nothing here listens. The gate polls GitHub and GitHub is never told where
# this machine is; the runners it starts dial out the same way. That is why
# none of this needs a tunnel, a static address, or an open port.
#
# set -e is deliberately absent: this is a supervisor, and a failed API call is
# an ordinary event that must not end the process.
set -uo pipefail

IMAGE=${RUNNER_IMAGE:-ci-runner:local}
LABEL=${RUNNER_LABEL:-local-docker}

# One row per class, threaded through a case statement rather than a key into
# an associative array — this file is read next to ci-runner.sh, which runs
# on the mac's bash 3.2 and has neither, and a table that only one of the two
# scripts could express would be a table in name only.
BIG_CPUS=${BIG_CPUS:-4};       BIG_MEMORY=${BIG_MEMORY:-4g};       BIG_SHARES=${BIG_SHARES:-2048};       BIG_COST=${BIG_COST:-4}
LITTLE_CPUS=${LITTLE_CPUS:-4}; LITTLE_MEMORY=${LITTLE_MEMORY:-2g}; LITTLE_SHARES=${LITTLE_SHARES:-1024}; LITTLE_COST=${LITTLE_COST:-2}
# `now` is `big` in everything that costs — same cores, same memory, same price
# against the budget and the same cap. It differs in one thing only: where it
# sits in the queue. A priority class that was also cheaper, or exempt from the
# cap, would be a way to get more machine by editing a workflow rather than a
# way to be served first.
# `mega` is the job that costs the WHOLE budget: a mutation-testing run
# that wants every core the machine can spare. It is a switch, not a tier with
# arithmetic of its own — its cost is whatever BUDGET is right now, read live
# and never stored, so a busy mega runner leaves `used == BUDGET` and nothing
# else fits, and a queued mega job fits only on an empty machine. Sized from
# the machine in the discovery block below. MEGA_CPUS=0 turns the capability
# off (the mac), and the label is then still served — as an ordinary big, with
# the big cost, cpus, memory and cap — so a workflow that names it never waits
# for a runner nobody will start.
MEGA_SHARES=${MEGA_SHARES:-4096}
# How long a mega job may wait for the machine to drain before the gate says
# so, once. Nothing is killed: a long drain is a person's decision.
MEGA_DRAIN_WARN=${MEGA_DRAIN_WARN:-1800}
# A mutation job is long on purpose and was swept at the ordinary 2700s.
MEGA_MAX_BUSY=${MEGA_MAX_BUSY:-7200}
CLASSES="now big little mega"

mega_on() { [ "${MEGA_CPUS:-0}" -ge 1 ] 2>/dev/null; }
class_label()  { case "$1" in now) printf '%s-now\n' "$LABEL" ;;     big) printf '%s\n' "$LABEL" ;;        little) printf '%s-light\n' "$LABEL" ;; mega) printf '%s-mega\n' "$LABEL" ;; esac; }
class_cpus()   { case "$1" in now|big) printf '%s\n' "$BIG_CPUS" ;;   little) printf '%s\n' "$LITTLE_CPUS" ;;   mega) if mega_on; then printf '%s\n' "$MEGA_CPUS"; else printf '%s\n' "$BIG_CPUS"; fi ;; esac; }
class_memory() { case "$1" in now|big) printf '%s\n' "$BIG_MEMORY" ;; little) printf '%s\n' "$LITTLE_MEMORY" ;; mega) if mega_on; then printf '%s\n' "$MEGA_MEMORY"; else printf '%s\n' "$BIG_MEMORY"; fi ;; esac; }
class_shares() { case "$1" in now|big) printf '%s\n' "$BIG_SHARES" ;; little) printf '%s\n' "$LITTLE_SHARES" ;; mega) if mega_on; then printf '%s\n' "$MEGA_SHARES"; else printf '%s\n' "$BIG_SHARES"; fi ;; esac; }
class_cost()   { case "$1" in now|big) printf '%s\n' "$BIG_COST" ;;   little) printf '%s\n' "$LITTLE_COST" ;;   mega) if mega_on; then printf '%s\n' "$BUDGET"; else printf '%s\n' "$BIG_COST"; fi ;; esac; }

# Units are cores, same as `cost` above. 8 of 14 leaves the rest for the gate,
# the daemon and whatever the owner's dev containers are doing at the time —
# the measurement that set this: three 4-cpu runners plus three agent dev
# containers put load average at 18.9 on 14, and a 2.3-minute suite took 9.7.
BUDGET=${BUDGET:-10}
# Big runners alone may not fill the budget: with BUDGET 8 and nothing held
# back, two e2e jobs sat on every core for 13 minutes while a one-minute
# lint job for another repository queued behind them (2026-09-21 17:10 to
# 17:40). Two bigs still fit; the two cores above them are the little class's
# to take, so a cheap job never waits a whole e2e out.
BIG_CAP=${BIG_CAP:-8}
# Both of the above, overridable while the gate runs. How much of the machine
# CI may use is the one setting worth changing often — it is tuning, answered
# by watching the queue — and until this file existed, changing it meant
# recreating the container, which drops the credential and costs an unlock.
# The same tmpfs as the token and the pause flag, and for the same reason: a
# gate that comes back comes back with the numbers `up` was given, so the
# flags stay the durable setting and this is only ever a live override.
BUDGET_FILE=${BUDGET_FILE:-/run/gate/budget}
BUDGET_BOOT=$BUDGET
BIG_CAP_BOOT=$BIG_CAP

# Read every tick. Anything unparsable is ignored rather than obeyed: a
# half-written file must not hand the machine an unbounded budget, and a
# removed one falls back to what the gate started with.
read_budget() {
  local b c
  if [ -s "$BUDGET_FILE" ]; then
    read -r b c < "$BUDGET_FILE" || return 0
  else
    b=$BUDGET_BOOT; c=$BIG_CAP_BOOT
  fi
  case "$b" in ''|*[!0-9]*) return 0 ;; esac
  case "$c" in ''|*[!0-9]*) return 0 ;; esac
  [ "$b" -ge 1 ] && [ "$c" -ge 1 ] && [ "$c" -le "$b" ] || return 0
  if [ "$b" != "$BUDGET" ] || [ "$c" != "$BIG_CAP" ]; then
    log "budget now ${b} cores, big cap ${c} (was ${BUDGET}/${BIG_CAP})"
    BUDGET=$b; BIG_CAP=$c
  fi
}
# Admission on what the machine has, not only on what the gate counts. The
# budget above sees the gate's own containers and nothing else; on 2026-11-04
# four runners ran beside dev-container slots on a 20 GB WSL, one slot held
# 12.1 GB, Windows fell to 0.6 GB free and Ubuntu stopped answering. A ledger
# of what each slot may use cannot fix that, because a slot's use is unknown
# when it is acquired and it idles at 15-80 MiB. A number read off the machine
# can. So Pass 2 reads MemAvailable and the one-minute load, and a job that
# would start below the floor or above the ceiling is stepped over like any
# job that does not fit. This makes jobs queue; it does not make room.
#
# The two limits are one value each in a directory, mounted read-only and read
# every tick, so a change takes effect without a restart. A directory, because
# a single-file bind mount keeps the old inode after an atomic replace. The
# dev-container engine reads the same directory on its own; neither tool
# depends on the other.
MEMINFO_FILE=${MEMINFO_FILE:-/proc/meminfo}
LOADAVG_FILE=${LOADAVG_FILE:-/proc/loadavg}
LIMITS_DIR=${LIMITS_DIR:-/etc/machine-limits}
FLOOR_DEFAULT=2048
floor_bad_said=""; ceiling_bad_said=""; meminfo_said=0; loadavg_said=0
adm_said=""    # the reasons already reported for the wait in progress

# Docker size to MiB: 4g, 2g, 512m. Anything else counts as 0, which only ever
# makes the gate more willing to start, never less.
mem_to_mb() {
  case "$1" in
    *[gG]) echo $(( ${1%?} * 1024 )) ;;
    *[mM]) echo $(( ${1%?} )) ;;
    *[kK]) echo $(( ${1%?} / 1024 )) ;;
    ""|*[!0-9]*) echo 0 ;;
    *) echo $(( $1 / 1048576 )) ;;
  esac 2>/dev/null || echo 0
}

# What the mega class is sized from, once at boot: all cores but two and
# all memory but 4 GiB. Either may be given instead; MEGA_CPUS=0 is "no mega
# capability" and leaves the label served as an ordinary big.
CPU_COUNT=${CPU_COUNT:-$(nproc)}
if [ -z "${MEGA_CPUS:-}" ]; then
  MEGA_CPUS=$((CPU_COUNT - 2)); [ "$MEGA_CPUS" -ge 1 ] || MEGA_CPUS=1
fi
if [ -z "${MEGA_MEMORY:-}" ]; then
  mega_total=$(awk '/^MemTotal:/ { print int($2 / 1024); exit }' "$MEMINFO_FILE" 2>/dev/null)
  case "$mega_total" in ""|*[!0-9]*) mega_total=0 ;; esac
  mega_mb=$((mega_total - 4096))
  [ "$mega_mb" -ge "$(mem_to_mb "$BIG_MEMORY")" ] || mega_mb=$(mem_to_mb "$BIG_MEMORY")
  MEGA_MEMORY=${mega_mb}m
fi

# Read one integer limit into LIMIT_VALUE. Absent means the default, silently;
# a value that is not an integer means the default and is said once until it
# changes. $3 names the variable remembering the last bad value.
read_limit() {
  local file=$LIMITS_DIR/$1 v=""
  LIMIT_VALUE=$2
  [ -r "$file" ] || { printf -v "$3" ""; return 0; }
  read -r v < "$file" || true
  case "$v" in
    ""|*[!0-9]*)
      if [ "${!3}" != "bad:$v" ]; then
        log "$1: '$v' is not an integer — using the default $2"
        printf -v "$3" "%s" "bad:$v"
      fi ;;
    *) LIMIT_VALUE=$v; printf -v "$3" "" ;;
  esac
}

# There used to be SLOTS here, a cap on work-folder slots: each runner's
# checkout lived at $WORK_ROOT/<repo>/<slot> on the host and outlived it, so
# the next runner of that slot fetched instead of cloning. It saved no
# transfer — a fetch into a shallow clone brings a whole snapshot — and
# nothing bounded it: a project's slot 1 reached 5.5 GB, 277 packs, root-owned
# parents the host user could not remove. The work folder is now the
# runner's own `_work`, inside its container, and goes with it.
POLL_DEFAULT=20
POLL=${POLL:-$POLL_DEFAULT}
if [ -z "${POLL_IDLE+x}" ]; then
  if [ "$POLL" = "$POLL_DEFAULT" ]; then
    POLL_IDLE=30
  else
    POLL_IDLE=$POLL
  fi
fi
COLD_QUIET=${COLD_QUIET:-3}      # quiet ticks, nothing queued, before an idle runner is reaped
# How long one of OUR runners may stay busy before the gate stops believing
# it. Measured a project on the Windows host: the
# job's own work finished in 127 seconds, every check green, and the runner
# then sat in `Post Run actions/checkout@v7` — the step that unsets the git
# credential config — for 27 minutes, until a person cancelled the run. The
# workflow's own `timeout-minutes: 25` did NOT cut it: that limit is enforced
# by the runner process, and this is the runner process being stuck.
#
# What it costs while it lasts is not the machine, it is the pull request:
# branch protection sees a required check `in_progress` and will not let the
# change merge, so a green run blocks its own PR until somebody notices and
# cancels by hand.
#
# Removing the container is a blunt but honest answer: GitHub marks the job
# failed once its runner disappears, which is a state a person can see and
# `gh run rerun` can fix, unlike a hang. Set well above any real job here —
# the longest measured is a 13-minute e2e suite — so this can only fire on
# something that is not working.
MAX_BUSY=${MAX_BUSY:-2700}
# Two machines, one label, no shared state: the one that should yield runs
# with DEFER and leaves a queued job alone until it has waited this many
# seconds. The other machine, if it is on, registers in ~10s and the job is
# `in_progress` before this one looks again; if it is off, or at its budget,
# the job ages past DEFER and is taken here. What is bought is a second
# machine that helps whenever it happens to be on, with no variable to flip
# and nothing to undo when it goes away — and a crash of the helper leaves no
# queue pointing at a corpse, because nothing was ever pointed anywhere.
DEFER=${DEFER:-0}
# The machine's tag inside every runner name (ci-runner.sh `--host`). Two
# gates on one label mint names from the same slug, slot and clock, and a
# job's "Runner name" line then says nothing about where it ran.
HOST_TAG=${HOST_TAG:-}
TOKEN_FILE=${TOKEN_FILE:-/run/gate/pat}
# One token per owner, beside the main one. A fine-grained token has a single
# resource owner, so a gate serving the account's repositories and an
# organisation's needs a token for each; `ci-runner.sh unlock --owner O` puts
# O's here. An owner with no file of its own falls back to $TOKEN_FILE, which
# is how a machine serving one owner has always worked.
TOKEN_DIR=${TOKEN_DIR:-/run/gate/pat.d}
REPOS_FILE=${REPOS_FILE:-/run/gate/repos}
# `ci-runner.sh pause` touches this; `resume` removes it. While it exists the
# gate raises nothing and reaps as usual, so what is running finishes and
# nothing new starts — without stopping the gate, which would drop the
# credential and cost an unlock to come back. On the same tmpfs as the token
# so a reboot clears both: a machine that comes back comes back serving.
PAUSE_FILE=${PAUSE_FILE:-/run/gate/paused}
# What the gate reports about itself, rewritten every tick whether it is locked
# or not: `ci-runner.sh status --json` reads it with `docker exec` and status consumers
# shows it, so nothing has to scrape this log. On the same tmpfs, mode 0700,
# for the same reason as the token; it holds no token and nothing read from a
# token file reaches it (status.schema.json describes it).
STATUS_FILE=${STATUS_FILE:-/run/gate/status.json}
# Which commit this image was built from (`ci-runner.sh build`/`redeploy`).
GATE_COMMIT=${GATE_COMMIT:-unknown}

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*"; }
slug_of() { printf '%s' "$1" | tr '/[:upper:]' '-[:lower:]'; }

# The token for an API path: its owner's, when `/repos/<owner>/` names one
# that has a file in $TOKEN_DIR, else the main one. Owners are compared
# lowercased, as GitHub does.
token_for() {
  local owner
  owner=$(printf '%s' "$1" | sed -n 's|^/repos/\([^/]*\)/.*|\1|p' | tr '[:upper:]' '[:lower:]')
  if [ -n "$owner" ] && [ -s "$TOKEN_DIR/$owner" ]; then cat "$TOKEN_DIR/$owner"
  else cat "$TOKEN_FILE" 2>/dev/null; fi
}

# Rate-limit state per token scope (same scope as etag_cache), and
# per-(owner, url) ETag/body caches. Token rotation for an owner (or the
# default token) clears only that owner's cached entries and rate-limit state.
declare -A rl_remaining
declare -A rl_limit
declare -A rl_reset
declare -A rl_throttled
declare -A rl_hit_limit
declare -A rl_pause_until
LAST_API_CODE=""
API_BODY=""
API_ETAG=""
declare -A etag_cache
declare -A body_cache
declare -A token_fp

token_scope_for() {
  local owner
  owner=$(printf '%s' "$1" | sed -n 's|^/repos/\([^/]*\)/.*|\1|p' | tr '[:upper:]' '[:lower:]')
  if [ -n "$owner" ] && [ -s "$TOKEN_DIR/$owner" ]; then
    printf '%s\n' "$owner"
  else
    printf '_default\n'
  fi
}

clear_scope_rate_limit() {
  local scope=$1
  unset "rl_remaining[$scope]" "rl_limit[$scope]" "rl_reset[$scope]" \
        "rl_hit_limit[$scope]" "rl_throttled[$scope]" "rl_pause_until[$scope]"
}

expire_scope_rate_limit() {
  local scope=$1 now=$2
  local until=${rl_pause_until[$scope]:-0}
  [ "$until" -gt 0 ] && [ "$until" -le "$now" ] || return 0
  clear_scope_rate_limit "$scope"
}

clear_owner_cache() {
  local scope=$1 k
  for k in "${!etag_cache[@]}"; do
    case "$k" in "$scope:"*) unset "etag_cache[$k]" ;; esac
  done
  for k in "${!body_cache[@]}"; do
    case "$k" in "$scope:"*) unset "body_cache[$k]" ;; esac
  done
  clear_scope_rate_limit "$scope"
}

scope_at_limit() {
  local scope=$1
  [ "${rl_hit_limit[$scope]:-0}" = 1 ] && return 0
  local rem=${rl_remaining[$scope]:-}
  [ -n "$rem" ] && [ "$rem" -lt 50 ]
}

update_rate_limit_from_headers() {
  local scope=$1 hdr=$2 code=${3:-} rl_rem rl_lim rl_rst
  rl_rem=$(sed -n 's/^[Xx]-[Rr]ate[Ll]imit-[Rr]emaining: *//p' "$hdr" | tail -1 | tr -d '\r')
  rl_lim=$(sed -n 's/^[Xx]-[Rr]ate[Ll]imit-[Ll]imit: *//p' "$hdr" | tail -1 | tr -d '\r')
  rl_rst=$(sed -n 's/^[Xx]-[Rr]ate[Ll]imit-[Rr]eset: *//p' "$hdr" | tail -1 | tr -d '\r')
  case "$rl_rem" in ''|*[!0-9]*) ;; *) rl_remaining[$scope]=$rl_rem ;; esac
  case "$rl_lim" in ''|*[!0-9]*) ;; *) rl_limit[$scope]=$rl_lim ;; esac
  case "$rl_rst" in ''|*[!0-9]*) ;; *) rl_reset[$scope]=$rl_rst ;; esac
  if { [ "$code" = "403" ] || [ "$code" = "429" ]; } && [ "${rl_remaining[$scope]:-}" = "0" ]; then
    rl_hit_limit[$scope]=1
  fi
}

api_request() {
  local method=$1 path=$2 body=${3:-} inm=${4:-}
  local token scope hdr out_f out code rc=0
  token=$(token_for "$path") || return 1
  [ -n "$token" ] || return 1
  scope=$(token_scope_for "$path")
  hdr="/tmp/gate-hdr.$$"
  out_f="/tmp/gate-body.$$"
  : > "$hdr"; : > "$out_f"
  out=$(curl -sS --location \
    --dump-header "$hdr" \
    --output "$out_f" \
    --write-out '%{http_code}' \
    --request "$method" \
    --header "Authorization: Bearer $token" \
    --header "Accept: application/vnd.github+json" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    ${inm:+--header "If-None-Match: $inm"} \
    ${body:+--data "$body"} \
    "https://api.github.com$path") || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$hdr" "$out_f"
    LAST_API_CODE="000"
    API_BODY=""
    return 1
  fi
  if [ -s "$hdr" ]; then
    code=$out
    API_BODY=$(cat "$out_f")
    update_rate_limit_from_headers "$scope" "$hdr" "$code"
    API_ETAG=$(sed -n 's/^[Ee][Tt][Aa][Gg]: *//p' "$hdr" | tail -1 | tr -d '\r')
  else
    # Legacy test curl stub that ignores --dump-header/--output/--write-out
    code=200
    API_BODY=$out
    API_ETAG=""
  fi
  rm -f "$hdr" "$out_f"
  LAST_API_CODE=$code
  case "$code" in
    2??|304) return 0 ;;
    *) return 1 ;;
  esac
}

api() {
  api_request "$@" || return 1
  printf '%s\n' "$API_BODY"
}

api_get_cached() {
  local path=$1
  local token scope fp ckey inm=""
  token=$(token_for "$path") || return 1
  [ -n "$token" ] || return 1
  scope=$(token_scope_for "$path")
  fp=$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)
  if [ "${token_fp[$scope]:-}" != "$fp" ]; then
    clear_owner_cache "$scope"
    token_fp[$scope]=$fp
  fi
  ckey="${scope}:${path}"
  inm=${etag_cache[$ckey]:-}
  API_ETAG=""
  if ! api_request GET "$path" "" "$inm"; then
    return 1
  fi
  if [ "$LAST_API_CODE" = "304" ]; then
    if [ -n "${body_cache[$ckey]+set}" ]; then
      API_BODY=${body_cache[$ckey]}
      return 0
    fi
    return 1
  fi
  body_cache[$ckey]=$API_BODY
  if [ -n "$API_ETAG" ]; then
    etag_cache[$ckey]=$API_ETAG
  else
    unset "etag_cache[$ckey]"
  fi
  return 0
}

# Called only when a call has already failed, to say which of two very
# different things happened. GitHub answers 404 rather than 403 for a
# repository a token cannot see, so "not on the token" and "does not exist"
# look identical from here — and both look nothing like "expired", which is
# what the single message used to claim for all of them.
api_code() {
  local token; token=$(token_for "$1") || { printf '000\n'; return; }
  curl --silent --output /dev/null --dump-header /tmp/h.$$ --write-out '%{http_code}' \
    --header "Authorization: Bearer $token" \
    --header "Accept: application/vnd.github+json" \
    "https://api.github.com$1"
  # GitHub names the permission it wanted in a header. Quoting it beats
  # guessing: "403" sends somebody to the rate-limit docs, `actions=read` sends
  # them to the one checkbox that fixes it.
  NEEDS=$(sed -n 's/^[Xx]-[Aa]ccepted-[Gg]ithub-[Pp]ermissions: *//p' /tmp/h.$$ | tr -d '\r')
  rm -f /tmp/h.$$
}

explain_failure() {
  local repo=$1 path=$2 code=${LAST_API_CODE:-} scope
  scope=$(token_scope_for "$path")
  NEEDS=""
  if [ -z "$code" ] || [ "$code" = "200" ] || [ "$code" = "304" ] || { [ "$code" = "403" ] && [ "${rl_remaining[$scope]:-}" != "0" ]; }; then
    code=$(api_code "$path")
  fi
  case "$code" in
    404) log "$repo: 404 — not on the token, or the token lacks Administration on it. Add it at github.com/settings/personal-access-tokens, then: ci-runner.sh unlock — or, for an organisation's repository, give that owner a token of its own: ci-runner.sh unlock --owner ${repo%%/*}" ;;
    401) log "$repo: 401 — the token is expired or revoked. Make a new one and unlock." ;;
    403) log "$repo: 403 — the token lacks a permission${NEEDS:+ (GitHub wants: $NEEDS)}, or the hourly rate limit is spent." ;;
    429) log "$repo: 429 — GitHub API rate limit exceeded." ;;
    000) log "$repo: no answer from api.github.com — network." ;;
    *)   log "$repo: API call failed (HTTP $code)." ;;
  esac
}

# Every container this gate owns, across every repository — the machine-wide
# budget is counted here and nowhere else.
all_ours() { docker ps --filter 'label=ci-runner.gate' --format '{{.Names}}'; }
ours() { docker ps --filter "label=ci-runner.gate=$1" --format '{{.Names}}'; }
ours_class() { docker ps --filter "label=ci-runner.gate=$1" --filter "label=ci-runner.class=$2" --format '{{.Names}}'; }
count() { grep -c . || true; }

# Cores, not containers. `ci-runner.class` is a container label rather than
# something counted from a side file, so a gate restart re-derives `used`
# from what docker already knows instead of trusting a number that survived
# the restart by accident.
# With a class as $1, only that class's runners are summed (the big cap). Asking
# for `big` counts `now` too: they are the same weight on the machine, and the
# cap exists to stop heavyweights filling the budget, not to describe labels.
# Counting them apart would let one `now` runner sit outside the ceiling it was
# meant to be inside. A mega runner counts for the whole BUDGET (class_cost) and
# sits outside the big cap: it can only ever run alone.
budget_used() {
  local only=${1:-} c total=0
  while read -r c; do
    [ -n "$c" ] || continue
    if [ -n "$only" ]; then
      case "$only:$c" in
        big:big|big:now) ;;
        big:mega) ! mega_on || continue ;;   # a mega with the capability off is an ordinary big
        *) [ "$c" = "$only" ] || continue ;;
      esac
    fi
    total=$((total + $(class_cost "$c")))
  done < <(docker ps --filter 'label=ci-runner.gate' --format '{{.Label "ci-runner.class"}}')
  printf '%s\n' "$total"
}

start_runner() {
  local repo=$1 class=$2
  local slug name jit label cpus memory shares
  slug=$(slug_of "$repo")
  # Unique without a slot: the epoch, plus four hex digits for two runners of
  # one repository started in the same second. GitHub caps a runner name at
  # 64 characters; the longest served slug leaves room.
  name="ci-runner-${slug}-${HOST_TAG:+$HOST_TAG-}$(date +%s)-$(printf '%04x' $((RANDOM % 65536)))"
  label=$(class_label "$class"); cpus=$(class_cpus "$class")
  memory=$(class_memory "$class"); shares=$(class_shares "$class")

  # The runner is named after the container on purpose: it is the only join
  # between what GitHub reports as busy and what is running here, and the
  # shutdown path needs exactly that join to avoid killing a live job.
  # work_folder `_work` is the runner's default, /opt/runner/_work, owned by
  # `runner` and inside the container.
  jit=$(api POST "/repos/$repo/actions/runners/generate-jitconfig" \
        "$(jq --null-input --arg n "$name" --arg l "$label" \
             '{name: $n, runner_group_id: 1, labels: [$l], work_folder: "_work"}')" \
        | jq --raw-output '.encoded_jit_config // empty')
  [ -n "$jit" ] || { log "$repo: could not mint a credential — is the token valid for it?"; return 1; }

  # No docker socket, for any repository. From 2026-09-21 to 2026-11-03 a
  # repository carrying the topic ci-local-docker got the host's socket here,
  # for a linter image and a throwaway postgres; a container with that socket
  # is the host, and once the caches were split it was the one mount
  # left that made every other boundary optional. The two repositories that
  # had it no longer need it (a project : postgres by initdb, actionlint
  # as a pinned binary), so the option is gone rather than off.

  # CI_CPUS below is how many cores this container may actually use. `--cpus`
  # is a cgroup quota, but `nproc` and `os.cpus()` read /proc, which shows the
  # *host's* count — so a test runner that sizes its worker pool from the core
  # count starts sixteen workers inside a four-core quota. Measured here
  # 2026-09-25: an e2e container pinned at a steady 400%, its whole quota,
  # running a fleet of Playwright Chromiums at ~3.9 GB resident against a 4 GB
  # limit, while the machine as a whole sat at a third of its capacity. The
  # cores were going into context switching rather than into tests. Nothing in
  # Node reads a limit from the cgroup, so the number is handed over explicitly
  # and the workflow has to use it: `workers: Number(process.env.CI_CPUS) ||
  # undefined` in a Playwright config, the same for vitest's maxThreads.
  #
  # No --volume for the work folder. It was a host path mounted at its
  # own absolute path, kept across jobs; now the checkout, _actions, _temp and
  # whatever a job writes beside them live in the container's writable layer
  # and go with --rm. The only things that outlive a job are the volumes below.
  #
  # The caches are split by who may write them, .
  #   - ci-runner-seed is the toolchain every job executes (node, Playwright's
  #     browsers). Only `ci-runner.sh seed` writes it; here it is :ro, and
  #     the job has no root to remount it with. entrypoint.sh
  #     links it into a tool cache that lives and dies with the container.
  #   - ci-runner-git, ci-runner-npm, ci-runner-cache, ci-runner-pnpm are per
  #     repository: warm across that repository's jobs, never seen by another's,
  #     and emptied by the runner's entrypoint once any passes its cap (cache-cap.sh).
  #     The git volume is pre-populated into the runner workspace before the job
  #     and synced back on completion, so checkouts fetch rather than clone.
  # --init, because runuser is otherwise PID 1 and reaps nothing: about 450
  # zombies by the middle of a the repository job, which no GitHub runner has.
  docker run --detach --rm --init \
    --name "$name" \
    --cpus "$cpus" \
    --memory "$memory" \
    --cpu-shares "$shares" \
    --label "ci-runner.gate=$slug" \
    --label "ci-runner.class=$class" \
    --label "com.docker.compose.project=0-ci" \
    --label "com.docker.compose.service=runner-$slug" \
    --env "JITCONFIG=$jit" \
    --env "CI_CPUS=$cpus" \
    --env "CI_REPO=$repo" \
    --volume ci-runner-seed:/opt/seed:ro \
    --volume "ci-runner-git-$slug:/var/cache/ci-runner/git" \
    --volume "ci-runner-npm-$slug:/home/runner/.npm" \
    --volume "ci-runner-cache-$slug:/home/runner/.cache" \
    --volume "ci-runner-pnpm-$slug:/home/runner/.local/share/pnpm" \
    --add-host host.docker.internal:host-gateway \
    "$IMAGE" >/dev/null \
    && log "$repo: started $name ($class)" \
    || log "$repo: docker run failed for $name"
}

# Stopping the gate should leave nothing behind — except a runner in the middle
# of somebody's job, which is killed by nobody.
shutdown() {
  log "stopping — removing idle runners, leaving busy ones to finish"
  local repo busy name all_busy=""
  while read -r repo _; do
    [ -n "$repo" ] || continue
    busy=$(api GET "/repos/$repo/actions/runners" \
           | jq --raw-output '[.runners[]? | select(.busy == true) | .name] | join("\n")' 2>/dev/null)
    all_busy="$all_busy$busy"$'\n'
  done < <(cat "$REPOS_FILE" 2>/dev/null)
  for name in $(all_ours); do
    if printf '%s\n' "$all_busy" | grep -qx "$name"; then
      log "leaving $name — it is running a job"
    else
      docker rm --force "$name" >/dev/null 2>&1 && log "removed $name"
    fi
  done
  exit 0
}
trap shutdown TERM INT

log "gate up: commit=${GATE_COMMIT} label=$LABEL budget=${BUDGET}cores bigcap=${BIG_CAP} big=${BIG_CPUS}cpu/${BIG_MEMORY}/shares=${BIG_SHARES}/cost=${BIG_COST} little=${LITTLE_CPUS}cpu/${LITTLE_MEMORY}/shares=${LITTLE_SHARES}/cost=${LITTLE_COST} poll=${POLL}s defer=${DEFER}s maxbusy=${MAX_BUSY}s $(if mega_on; then printf 'mega=%scpu/%s/shares=%s/cost=budget drainwarn=%ss megamaxbusy=%ss' "$MEGA_CPUS" "$MEGA_MEMORY" "$MEGA_SHARES" "$MEGA_DRAIN_WARN" "$MEGA_MAX_BUSY"; else printf 'mega=off (served as an ordinary big)'; fi)"

# The memory and load Pass 2 admits on, read into avail_mb, load_now, floor_mb
# and ceiling. A function so the status file can read the same numbers on a tick
# that never reaches Pass 2 (locked), with the same wording when one is unreadable.
read_machine() {
  read_limit memory-floor-mb "$FLOOR_DEFAULT" floor_bad_said; floor_mb=$LIMIT_VALUE
  read_limit load-ceiling "$(nproc)" ceiling_bad_said; ceiling=$LIMIT_VALUE
  avail_mb=$(awk '/^MemAvailable:/ { print int($2 / 1024); exit }' "$MEMINFO_FILE" 2>/dev/null)
  case "$avail_mb" in
    ""|*[!0-9]*) avail_mb=""
      [ "$meminfo_said" = 1 ] || log "cannot read MemAvailable from $MEMINFO_FILE — admitting without a memory check"
      meminfo_said=1 ;;
    *) meminfo_said=0 ;;
  esac
  load_now=""
  read -r load_now _ < "$LOADAVG_FILE" 2>/dev/null || true
  case "$load_now" in
    ""|*[!0-9.]*|*.*.*|.) load_now=""
      [ "$loadavg_said" = 1 ] || log "cannot read the load from $LOADAVG_FILE — admitting without a load check"
      loadavg_said=1 ;;
    *) loadavg_said=0 ;;
  esac
}

declare -A quiet
declare -A failed
declare -A busy_of
# name -> epoch when this gate FIRST saw that runner busy. Kept across ticks,
# cleared the moment it goes idle, and lost on a gate restart — which just
# restarts the clock rather than condemning a container the gate has no
# history for.
declare -A busy_since
declare -A runners_of
declare -A queued_flag
# Which repositories this tick actually managed to read. Empty queued_flag means
# "nothing waiting" only for a repository in here; for one that is absent it
# means the gate never got to look.
declare -A queue_read
declare -A idle_snap
declare -A foreign_said
# "run id:attempt" -> the classes that run has queued, as "class timestamp"
# lines, and when that was asked. Outlives a tick on purpose, but not forever:
# see RUN_RECHECK below.
declare -A run_classes
declare -A run_asked
declare -A run_nonlocal
# How long an answer about a queued run is trusted. "Cannot change while the
# run is queued" turned out false for a re-run: GitHub puts the run back on
# the queue a second before it creates the new attempt's jobs, and a gate that
# asked in that second cached "nothing for us" and never asked again —
# owner/repo sat queued for an hour, 2026-10-07. Keyed
# by attempt as well, so a re-run is a new question. One call per queued run
# per five minutes is still far from the rate limit that made this a cache.
# Stale (>1h) runs with no local jobs (0-job ghosts or non-local workflows)
# back off to RUN_RECHECK_STALE.
RUN_RECHECK=${RUN_RECHECK:-300}
RUN_RECHECK_STALE=${RUN_RECHECK_STALE:-3600}
ticks=0
locked_said=0
listed=""

# The numbers Pass 2 last admitted on, kept for write_status, which runs at the
# top of a tick and so reports the pass before it. ST_SEEN is 0 until Pass 2
# has run once; until then (the first tick, or every tick while locked) they are
# read directly with the same helpers. Pass 2 itself is not changed by this.
ST_SEEN=0
ST_AVAIL=""; ST_FLOOR=""; ST_LOAD=""; ST_CEILING=""; ST_USED=0; ST_BIG_USED=0
ST_WAITING=""; ST_WAIT_NOW=""
ST_NON_LOCAL_QUEUED=0
# The mega hold in progress, if there is one (repo, run/job, when it began, how
# long, whether past MEGA_DRAIN_WARN). Empty repo means nothing is draining.
ST_DRAIN_REPO=""; ST_DRAIN_REF=""; ST_DRAIN_SINCE=""; ST_DRAIN_SECS=0; ST_DRAIN_OVER=false
QUEUE=""   # the last pass's, until the first tick makes one

# One JSON object, written to a temp file beside STATUS_FILE and renamed over it:
# a reader sees the old file or the new one, never half of one. Called as
# `write_status || true` — failing to report must never end the loop. Nothing
# here reads a token file; `locked` is whether $TOKEN_FILE has content, and the
# values are counts, numbers and repository names.
write_status() {
  local locked=true paused=false busy_n=0 s n tmp="$STATUS_FILE.$$" s_used s_big rl_reset_at=""
  local rl_rem="" rl_lim="" rl_rst="" rl_throt=false best_rem="" best_throt=0 s_rem s_throt
  [ -s "$TOKEN_FILE" ] && locked=false
  [ -e "$PAUSE_FILE" ] && paused=true
  for s in "${!rl_remaining[@]}" "${!rl_throttled[@]}"; do
    s_rem=${rl_remaining[$s]:-}
    s_throt=0; [ "${rl_throttled[$s]:-false}" = "true" ] && s_throt=1
    if [ -z "$best_rem" ] && [ -z "$rl_rem" ] && [ "$best_throt" = 0 ]; then
      rl_rem=$s_rem; rl_lim=${rl_limit[$s]:-}; rl_rst=${rl_reset[$s]:-}
      rl_throt=${rl_throttled[$s]:-false}
      best_rem=$s_rem; best_throt=$s_throt
    elif [ "$s_throt" -gt "$best_throt" ] \
      || { [ "$s_throt" -eq "$best_throt" ] && [ -n "$s_rem" ] && { [ -z "$best_rem" ] || [ "$s_rem" -lt "$best_rem" ]; }; }; then
      rl_rem=$s_rem; rl_lim=${rl_limit[$s]:-}; rl_rst=${rl_reset[$s]:-}
      rl_throt=${rl_throttled[$s]:-false}
      best_rem=$s_rem; best_throt=$s_throt
    fi
  done
  if [ -n "$rl_rst" ]; then
    rl_reset_at=$(date -u -d "@$rl_rst" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
  fi
  # Pass 2's numbers are only true while it is running. A gate that locked after
  # having run would otherwise report memory and load from whenever it last
  # passed, under a fresh ts; locking drops back to reading them directly.
  [ "$locked" = false ] || ST_SEEN=0
  if [ "$ST_SEEN" = 1 ]; then
    s_used=$ST_USED; s_big=$ST_BIG_USED
  else
    read_machine
    ST_AVAIL=$avail_mb; ST_FLOOR=$floor_mb; ST_LOAD=$load_now; ST_CEILING=$ceiling
    s_used=$(budget_used); s_big=$(budget_used big)
  fi
  for s in "${!busy_of[@]}"; do
    [ -n "${busy_of[$s]}" ] || continue
    n=$(printf '%s\n' "${busy_of[$s]}" | count)
    busy_n=$((busy_n + n))
  done
  jq --null-input \
    --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson locked "$locked" --argjson paused "$paused" \
    --arg repos "$(cat "$REPOS_FILE" 2>/dev/null)" --arg queue "$QUEUE" \
    --arg busy "$busy_n" --arg used "$s_used" --arg big_used "$s_big" \
    --arg budget "$BUDGET" --arg big_cap "$BIG_CAP" \
    --arg big_cost "$BIG_COST" --arg little_cost "$LITTLE_COST" \
    --arg mega_cost "$(class_cost mega)" \
    --arg d_repo "$ST_DRAIN_REPO" --arg d_ref "$ST_DRAIN_REF" --arg d_since "$ST_DRAIN_SINCE" \
    --arg d_secs "$ST_DRAIN_SECS" --argjson d_over "$ST_DRAIN_OVER" \
    --arg avail "$ST_AVAIL" --arg floor "$ST_FLOOR" \
    --arg load "$ST_LOAD" --arg ceiling "$ST_CEILING" \
    --arg waiting "$ST_WAITING" --arg commit "$GATE_COMMIT" \
    --arg non_local "$ST_NON_LOCAL_QUEUED" \
    --arg rl_rem "$rl_rem" --arg rl_lim "$rl_lim" \
    --arg rl_reset_at "$rl_reset_at" --argjson rl_throttled "$rl_throt" '
    def n($x): try ($x | tonumber) catch null;
    def s($x): if ($x // "") == "" then null else $x end;
    { schema: 1, ts: $ts, locked: $locked, paused: $paused,
      repos: [$repos | split("\n")[] | split(" ")[0] | select(length > 0)],
      queue: [$queue | split("\n")[] | select(length > 0) | split("\u001f")
              | { repo: .[3], class: .[2], since: .[1],
                  run_id: n(.[5]), name: s(.[7]), branch: s(.[6]) }],
      non_local_queued: (n($non_local) // 0),
      rate_limit: {
        remaining: n($rl_rem),
        limit: n($rl_lim),
        reset_at: s($rl_reset_at),
        throttled: $rl_throttled
      },
      busy: n($busy), used: n($used), budget: n($budget),
      big_used: n($big_used), big_cap: n($big_cap),
      class_costs: { big: n($big_cost), little: n($little_cost), mega: n($mega_cost) },
      draining: (if $d_repo == "" then null
                 else { repo: $d_repo, ref: $d_ref, since: $d_since,
                        seconds: n($d_secs), overdue: $d_over } end),
      memory_available_mb: n($avail), memory_floor_mb: n($floor),
      load: n($load), load_ceiling: n($ceiling),
      waiting: (if $waiting == "" then null else $waiting end),
      commit: $commit }' > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$STATUS_FILE" || { rm -f "$tmp"; return 1; }
}

# A queued mega job the machine has to drain for: nothing behind it
# starts until it does. Said once per hold, with the time counted from the
# gate's first refusal — the job's own age would include time the machine spent
# on work this gate was right to run first. Sets the ST_DRAIN_* the status file
# reports and the waiting text; past MEGA_DRAIN_WARN it says so once and still
# forces nothing. [$]4 is a memory or load reason, when that is what held it.
drain_key=""; drain_epoch=0; drain_said=0; drain_over_said=0
mega_hold() { # repo ref used reason
  local repo=$1 ref=$2 u=$3 reason=${4:-} now secs text
  now=$(date +%s)
  if [ "$drain_key" != "$repo $ref" ]; then
    drain_key="$repo $ref"; drain_epoch=$now; drain_said=0; drain_over_said=0
  fi
  secs=$((now - drain_epoch))
  text="draining for mega job $repo $ref: $u/$BUDGET cores still in use, ${secs}s${reason:+ (held by $reason)}"
  [ "$drain_said" = 1 ] || { log "$text"; drain_said=1; }
  ST_WAIT_NOW=$text
  ST_DRAIN_REPO=$repo; ST_DRAIN_REF=$ref; ST_DRAIN_SECS=$secs; ST_DRAIN_OVER=false
  ST_DRAIN_SINCE=$(date -u -d "@$drain_epoch" '+%Y-%m-%dT%H:%M:%SZ')
  if [ "$secs" -ge "$MEGA_DRAIN_WARN" ]; then
    ST_DRAIN_OVER=true
    [ "$drain_over_said" = 1 ] || { log "mega job $repo $ref has waited ${secs}s, over MEGA_DRAIN_WARN=${MEGA_DRAIN_WARN}s — not forcing anything"; drain_over_said=1; }
  fi
}

# "Already has an idle runner" means idle *before this tick started scheduling
# anything* — a fresh docker-ps read after this tick has itself started a
# runner would see that runner too, and a second queued job for the same
# repository and class would then wrongly wait for a runner that already
# belongs to the first. Caching the answer the first time each (repo, class)
# pair is asked, this tick, is what keeps the snapshot honest without a
# second, explicit "state at tick start" pass.
#
# Sets IDLE rather than printing: called as `$(...)` it would run in a subshell
# and the cache write would never reach this process — which is how the cache
# was dead from the day it was written, and how a decrement of it under
# `set -u` took the gate down in a restart loop (2026-09-21, locked after every
# restart because the tmpfs does not survive one).
idle_snapshot() {
  local slug=$1 class=$2
  local key="$slug:$class" mine
  if [ -z "${idle_snap[$key]+x}" ]; then
    mine=$(ours_class "$slug" "$class")
    if [ -n "$mine" ] && [ -n "${busy_of[$slug]:-}" ]; then
      idle_snap[$key]=$(printf '%s\n' "$mine" | grep -vxF -f <(printf '%s\n' "${busy_of[$slug]}") | count)
    elif [ -n "$mine" ]; then
      idle_snap[$key]=$(printf '%s\n' "$mine" | count)
    else
      idle_snap[$key]=0
    fi
  fi
  IDLE=${idle_snap[$key]}
}

# The reap pass runs after scheduling and wants the real, current answer —
# including anything this tick just started — so it does not read the cache.
idle_names_now() {
  local slug=$1 class=$2 mine
  mine=$(ours_class "$slug" "$class")
  [ -n "$mine" ] || return 0
  # "I could not ask" is not "nobody is busy". The names come from docker, which
  # always answers; who is busy comes from GitHub, which sometimes does not. On a
  # tick where this repository failed to read, the busy map is never set, and
  # calling every container idle let the reaper below force-remove runners in the
  # middle of somebody's job — which GitHub reports as "the self-hosted runner
  # lost communication with the server". Three jobs died that way on 2026-09-24
  # during one seven-minute network outage. Set-but-empty still means nobody is
  # busy; unset means we do not know, and not knowing claims nothing.
  [ -n "${busy_of[$slug]+set}" ] || return 0
  if [ -n "${busy_of[$slug]}" ]; then
    printf '%s\n' "$mine" | grep -vxF -f <(printf '%s\n' "${busy_of[$slug]}")
  else
    printf '%s\n' "$mine"
  fi
}

# Our own containers that have been busy longer than MAX_BUSY, removed. See
# MAX_BUSY's comment for the measurement behind it. Only OUR containers: a
# runner from the other machine on the same label is not ours to kill, and
# `all_ours` is what tells them apart.
sweep_stuck_runners() {
  local busy_now="$1" now name age limit limit_name mega_names
  now=$(date +%s)

  # Forget anything that is no longer busy, so a name that comes back later
  # starts a fresh clock rather than inheriting the last job's.
  for name in "${!busy_since[@]}"; do
    printf '%s\n' "$busy_now" | grep -qxF "$name" || unset "busy_since[$name]"
  done

  mega_names=$(docker ps --filter 'label=ci-runner.gate' --filter 'label=ci-runner.class=mega' --format '{{.Names}}')
  for name in $(all_ours); do
    printf '%s\n' "$busy_now" | grep -qxF "$name" || continue
    if [ -z "${busy_since[$name]:-}" ]; then
      busy_since[$name]=$now
      continue
    fi
    age=$(( now - busy_since[$name] ))
    limit=$MAX_BUSY; limit_name=MAX_BUSY
    if printf '%s\n' "$mega_names" | grep -qxF "$name"; then limit=$MEGA_MAX_BUSY; limit_name=MEGA_MAX_BUSY; fi
    [ "$age" -ge "$limit" ] || continue
    log "removing $name — busy ${age}s, past ${limit_name}=${limit}s. Its job is wedged (2026-09-22: a finished job stuck in Post Run actions/checkout for 27 minutes, blocking its pull request). GitHub will mark the job failed; re-run it."
    docker rm --force "$name" >/dev/null 2>&1 || log "  could not remove $name"
    unset "busy_since[$name]"
  done
}

# An online, idle runner of this class that is not one of our containers: the
# other machine on this label has already answered, and is inside the ~10s
# between registering and taking the job. Read from the runner list this tick
# already fetched, so it costs nothing. It closes most of the window DEFER
# leaves open when the other machine was slow rather than absent; the ~10s
# before a registration shows up at all is the part neither closes.
foreign_idle() {
  local slug=$1 class=$2 mine
  mine=$(ours_class "$slug" "$class")
  printf '%s' "${runners_of[$slug]:-}" | jq --raw-output --arg l "$(class_label "$class")" '
    .runners[]? | select(.status == "online" and .busy == false) |
    select([.labels[]?.name] | index($l)) | .name' 2>/dev/null \
    | grep -vxF -f <(printf '%s\n' "${mine:-__none__}") | count
}

while true; do
  write_status 2>/dev/null || true
  if [ ! -s "$TOKEN_FILE" ]; then
    [ "$locked_said" = 0 ] && log "locked — no credential. Unlock with: ci-runner.sh unlock"
    locked_said=1; sleep "$POLL"; continue
  fi
  locked_said=0

  if [ ! -s "$REPOS_FILE" ]; then
    log "no repositories on the list — ci-runner.sh sync"
    sleep "$POLL"; continue
  fi

  # Say what is being served, but only when it changes: a supervisor that
  # repeats itself every twenty seconds is a log nobody reads.
  now_listed=$(tr '\n' ' ' < "$REPOS_FILE")
  [ "$now_listed" != "$listed" ] && { log "serving: $now_listed"; listed=$now_listed; }

  ticks=$((ticks + 1))
  read_budget
  QUEUE=""
  busy_of=(); runners_of=(); queued_flag=(); idle_snap=(); foreign_said=()
  seen_runs=""
  queue_read=()
  rl_hit_limit=()
  non_local_count=0
  now_epoch=$(date +%s)
  broke_early=0

  # Pass 1 — every repository, every tick: what is queued for one of our
  # labels, and (when active or on a 10-min prune sweep) who is busy.
  while read -r repo _; do
    [ -n "$repo" ] || continue
    slug=$(slug_of "$repo")
    scope=$(token_scope_for "/repos/$repo/")
    expire_scope_rate_limit "$scope" "$now_epoch"
    if [ "${rl_pause_until[$scope]:-0}" -gt "$now_epoch" ] || scope_at_limit "$scope"; then
      broke_early=1
      continue
    fi

    if ! api_get_cached "/repos/$repo/actions/runs?status=queued&per_page=10"; then
      # Silence here would be the worst kind: a repository that simply never
      # wakes, with nothing in the log to say why.
      if [ "${failed[$slug:runs]:-}" != 1 ]; then
        explain_failure "$repo" "/repos/$repo/actions/runs?status=queued&per_page=1"
        log "$repo: needs Actions: Read-only on the token, on top of Administration."
        failed[$slug:runs]=1
      fi
      if scope_at_limit "$scope"; then
        broke_early=1
      fi
      continue
    fi
    queued_json=$API_BODY
    [ -n "$queued_json" ] || continue
    [ "${failed[$slug:runs]:-}" = 1 ] && { log "$repo: queue readable again"; failed[$slug:runs]=0; }
    # This tick actually saw this repository's queue. The reaper needs to tell
    # that from a tick that never got an answer, because "nothing is queued" and
    # "I could not look" are the same empty map otherwise.
    queue_read[$slug]=1

    repo_rl_stop=0
    while IFS=$'\x1f' read -r run_key run_attempt_ts run_branch run_name; do
      [ -n "$run_key" ] || continue
      run_id=${run_key%%:*}
      seen_runs="$seen_runs $run_key"
      recheck=$RUN_RECHECK
      if [ -n "${run_classes[$run_key]+set}" ] && [ -z "${run_classes[$run_key]}" ] && [ -n "$run_attempt_ts" ]; then
        attempt_epoch=$(date -u -d "$run_attempt_ts" +%s 2>/dev/null || echo 0)
        if [ "$attempt_epoch" -gt 0 ] && [ $(( now_epoch - attempt_epoch )) -ge 3600 ]; then
          recheck=$RUN_RECHECK_STALE
        fi
      fi
      if [ -z "${run_classes[$run_key]+set}" ] \
         || [ $(( now_epoch - ${run_asked[$run_key]:-0} )) -ge "$recheck" ]; then
        if ! api_request GET "/repos/$repo/actions/runs/$run_id/jobs"; then
          if scope_at_limit "$scope"; then
            broke_early=1; repo_rl_stop=1; break
          fi
          continue
        fi
        jobs_json=$API_BODY
        [ -n "$jobs_json" ] || continue
        run_asked[$run_key]=$now_epoch
        run_classes[$run_key]=$(printf '%s' "$jobs_json" | jq --raw-output \
          --arg now "$(class_label now)" --arg run "$run_id" \
          --arg mega "$(class_label mega)" \
          --arg big "$(class_label big)" --arg little "$(class_label little)" '
          .jobs[]? | select(.status == "queued") |
          ([.labels[]?]) as $l |
          if ($l | index($mega)) then "mega \(.created_at) \($run)/\(.id)"
          elif ($l | index($now)) then "now \(.started_at // .created_at)"
          elif ($l | index($little)) then "little \(.started_at // .created_at)"
          elif ($l | index($big)) then "big \(.started_at // .created_at)"
          else empty end' 2>/dev/null)
        if [ -z "${run_classes[$run_key]}" ]; then
          has_q=$(printf '%s' "$jobs_json" | jq '[.jobs[]? | select(.status == "queued")] | length' 2>/dev/null || echo 0)
          if [ "${has_q:-0}" -gt 0 ]; then run_nonlocal[$run_key]=1; else run_nonlocal[$run_key]=0; fi
        else
          run_nonlocal[$run_key]=0
        fi
      fi
      [ "${run_nonlocal[$run_key]:-0}" = 1 ] && non_local_count=$((non_local_count + 1))
      while read -r class ts ref; do
        [ -n "$class" ] || continue
        case "$class" in now) prio=0 ;; *) prio=1 ;; esac
        QUEUE="$QUEUE$prio"$'\x1f'"$ts"$'\x1f'"$class"$'\x1f'"$repo"$'\x1f'"${ref:-}"$'\x1f'"$run_id"$'\x1f'"$run_branch"$'\x1f'"$run_name"$'\n'
        queued_flag[$slug:$class]=1
      done < <(printf '%s\n' "${run_classes[$run_key]}")
    done < <(printf '%s' "$queued_json" | jq --raw-output '.workflow_runs[]? | "\(.id):\(.run_attempt // 1)\u001f\(.run_started_at // (if (.run_attempt // 1) == 1 then .created_at else "" end) // "")\u001f\(.head_branch // "")\u001f\(.name // "")"' 2>/dev/null)

    [ "$repo_rl_stop" = 1 ] && continue
    if scope_at_limit "$scope"; then
      broke_early=1
      continue
    fi

    # Skip /actions/runners on idle repos between 10-min offline prune sweeps.
    repo_has_q=0
    for c in $CLASSES; do [ -z "${queued_flag[$slug:$c]:-}" ] || { repo_has_q=1; break; }; done
    repo_has_c=0
    [ -z "$(ours "$slug")" ] || repo_has_c=1
    prune_due=0
    [ $((ticks % 30)) -eq 0 ] && [ "${rl_throttled[$scope]:-false}" != "true" ] && prune_due=1
    if [ "$repo_has_c" = 0 ] && [ "$repo_has_q" = 0 ] && [ "$prune_due" = 0 ]; then
      runners_of[$slug]=""
      busy_of[$slug]=""
      continue
    fi

    if ! api_get_cached "/repos/$repo/actions/runners"; then
      # Said once per repository, not once per tick: a supervisor that repeats
      # the same failure every twenty seconds buries the moment it started.
      if [ "${failed[$slug]:-}" != 1 ]; then
        explain_failure "$repo" "/repos/$repo/actions/runners"
        failed[$slug]=1
      fi
      if scope_at_limit "$scope"; then
        broke_early=1
      fi
      continue
    fi
    runners=$API_BODY
    [ -n "$runners" ] || continue
    [ "${failed[$slug]:-}" = 1 ] && { log "$repo: recovered"; failed[$slug]=0; }
    runners_of[$slug]=$runners
    busy_of[$slug]=$(printf '%s' "$runners" | jq --raw-output '[.runners[]? | select(.busy == true) | .name] | join("\n")')
  done < <(cat "$REPOS_FILE")
  ST_NON_LOCAL_QUEUED=$non_local_count

  # A run that has left the queue is never asked about again, so its entry
  # leaves with it: the cache is the size of the queue, not of the day.
  if [ "$broke_early" = 0 ]; then
    for run_key in "${!run_classes[@]}"; do
      case " $seen_runs " in
        *" $run_key "*) ;;
        *) unset "run_classes[$run_key]" "run_asked[$run_key]" "run_nonlocal[$run_key]" ;;
      esac
    done
  fi

  # Between the passes: every runner GitHub still calls busy, across every
  # repository, checked against how long this gate has seen it that way.
  sweep_stuck_runners "$(for slug in "${!busy_of[@]}"; do printf '%s\n' "${busy_of[$slug]}"; done)"

  # Pass 2 — one FIFO across every repository, oldest job first. A job either
  # finds a runner already idle for it, or spends from the shared budget, or
  # — the budget spent — waits, and so does everything behind it: FIFO means
  # nothing later gets ahead of it just because it was cheaper.
  used=$(budget_used)
  big_used=$(budget_used big)
  budget_said=0
  # The limits and the observed numbers, once per pass. A number that cannot be
  # read leaves its check out, said once: a tool that cannot read a number must
  # not stop CI.
  read_machine
  ST_AVAIL=$avail_mb; ST_FLOOR=$floor_mb; ST_LOAD=$load_now; ST_CEILING=$ceiling
  ST_WAIT_NOW=""
  adm_now=""; hold_active=0
  # Paused: skip the pass, not the tick. Pass 1 still ran, so the reap below
  # still knows what is busy, and a runner mid-job is left exactly as it is.
  if [ -e "$PAUSE_FILE" ]; then
    [ "${paused_said:-0}" = 1 ] || log "paused — finishing what is running, starting nothing. Resume with: ci-runner.sh resume"
    paused_said=1
    QUEUE=""
  else
    [ "${paused_said:-0}" = 0 ] || log "resumed"
    paused_said=0
  fi
  while IFS=$'\x1f' read -r prio ts class repo ref _run_id _branch _name; do
    [ -n "$repo" ] || continue
    slug=$(slug_of "$repo")
    # An idle runner answers for exactly one queued job. Two jobs of the same
    # class behind one idle runner would otherwise both be skipped, and the
    # second one waits a whole job's length for a runner the budget could
    # have paid for now.
    idle_snapshot "$slug" "$class"
    if [ "$IDLE" -gt 0 ]; then
      idle_snap["$slug:$class"]=$((IDLE - 1))
      continue
    fi
    # The other machine on this label gets first refusal — see DEFER. A job
    # younger than that is left alone; one already answered by a foreign
    # runner is left alone this tick, whatever its age.
    if [ "$DEFER" -gt 0 ]; then
      age=$(jq --null-input --arg t "$ts" 'now - ($t | fromdateiso8601) | floor' 2>/dev/null) || age=$DEFER
      [ "${age:-$DEFER}" -ge "$DEFER" ] || continue
    fi
    if [ "$(foreign_idle "$slug" "$class")" -gt 0 ]; then
      [ -n "${foreign_said[$slug:$class]:-}" ] || log "$repo: $class already answered by another machine on this label — leaving it"
      foreign_said[$slug:$class]=1
      continue
    fi
    cost=$(class_cost "$class")
    mega_job=0; [ "$class" = mega ] && mega_on && mega_job=1
    # A job that does not fit is stepped over, not stopped at: a little job
    # behind a big one that cannot start yet is exactly what the two classes
    # exist for. Order still holds within what fits — the queue is sorted.
    fits=1
    [ $((used + cost)) -le "$BUDGET" ] || fits=0
    # `now` counts against BIG_CAP like any other heavyweight. Exempting it
    # would make the priority label a way to exceed the machine's ceiling
    # rather than a way to be served first — and a label anyone can add to a
    # workflow must not be able to do that.
    # A mega job is outside the cap: it costs the whole budget, so it fits on
    # an empty machine only. With the capability off it is an ordinary big.
    case "$class" in
      big|now) [ $((big_used + cost)) -le "$BIG_CAP" ] || fits=0 ;;
      mega) [ "$mega_job" = 1 ] || [ $((big_used + cost)) -le "$BIG_CAP" ] || fits=0 ;;
    esac
    # Observed, not counted: the first of these that fails is the reason the
    # job waits. Only asked of a job the budget would have let in, so the
    # budget line stays the answer when it is the budget that said no.
    adm_reason=""
    if [ "$fits" = 1 ] && [ -n "$avail_mb" ] && [ "$avail_mb" -lt "$floor_mb" ]; then
      fits=0; adm_reason=memory
      adm_msg="memory: ${avail_mb} MiB available, floor ${floor_mb} MiB, $class for $repo waits"
    elif [ "$fits" = 1 ] && [ -n "$load_now" ] && awk -v l="$load_now" -v c="$ceiling" 'BEGIN { exit !(l > c) }'; then
      fits=0; adm_reason=load
      adm_msg="load: ${load_now} over ceiling ${ceiling}, $class for $repo waits"
    fi
    # Head of the line: a mega job that does not fit holds everything behind it,
    # unlike every other class, which is stepped over. Otherwise a stream of
    # little jobs would keep the machine from ever emptying.
    if [ "$mega_job" = 1 ] && [ "$fits" = 0 ]; then
      mega_hold "$repo" "$ref" "$used" "$adm_reason"
      hold_active=1
      break
    fi
    if [ "$fits" = 1 ]; then
      if start_runner "$repo" "$class"; then
        # What the runner may take is gone from what is available, within this
        # pass: the machine's own number only catches up a tick later.
        [ -z "$avail_mb" ] || avail_mb=$((avail_mb - $(mem_to_mb "$(class_memory "$class")")))
        used=$((used + cost))
        case "$class" in big|now) big_used=$((big_used + cost)) ;; mega) [ "$mega_job" = 1 ] || big_used=$((big_used + cost)) ;; esac
      fi
    elif [ -n "$adm_reason" ]; then
      # Once per wait, not per pass: the reason is remembered across ticks and
      # forgotten on a pass where nothing waited for it.
      [ -n "$ST_WAIT_NOW" ] || ST_WAIT_NOW=$adm_msg
      case " $adm_now " in *" $adm_reason "*) ;; *) adm_now="$adm_now $adm_reason" ;; esac
      case " $adm_said " in *" $adm_reason "*) ;; *) log "$adm_msg"; adm_said="$adm_said $adm_reason" ;; esac
    else
      [ -n "$ST_WAIT_NOW" ] || ST_WAIT_NOW="budget: $used/$BUDGET used (big $big_used/$BIG_CAP), $class for $repo waits"
      if [ "$budget_said" != 1 ]; then
        log "budget: $used/$BUDGET used (big $big_used/$BIG_CAP), $class for $repo waits"
        budget_said=1
      fi
    fi
  done < <(printf '%s' "$QUEUE" | sort)
  adm_said=$adm_now
  [ "$hold_active" = 1 ] || { drain_key=""; ST_DRAIN_REPO=""; ST_DRAIN_REF=""; ST_DRAIN_SINCE=""; ST_DRAIN_SECS=0; ST_DRAIN_OVER=false; }
  ST_USED=$used; ST_BIG_USED=$big_used; ST_WAITING=$ST_WAIT_NOW; ST_SEEN=1

  # Pass 3 — reap. A runner whose class has nothing queued for its repository,
  # this tick, and is not claimed by a job GitHub calls busy, gets several
  # quiet ticks of grace — a gap between "queued" clearing and the job
  # actually starting should not kill a runner about to be used — before it
  # goes.
  while read -r repo _; do
    [ -n "$repo" ] || continue
    slug=$(slug_of "$repo")
    for class in $CLASSES; do
      key="$slug:$class"
      mine=$(ours_class "$slug" "$class" | count)
      if [ "$mine" -eq 0 ]; then quiet[$key]=0; continue; fi
      idle=$(idle_names_now "$slug" "$class" | count)
      # A tick that could not read this repository is not a quiet tick: it is no
      # tick at all. Counting it as quiet is what let an outage spend the grace
      # period and then reap.
      if [ -z "${queue_read[$slug]:-}" ]; then continue; fi
      if [ -z "${queued_flag[$key]:-}" ] && [ "$idle" -gt 0 ]; then
        quiet[$key]=$(( ${quiet[$key]:-0} + 1 ))
        if [ "${quiet[$key]}" -ge "$COLD_QUIET" ]; then
          name=$(idle_names_now "$slug" "$class" | head -1)
          if [ -n "$name" ] && docker rm --force "$name" >/dev/null 2>&1; then
            log "$repo: reaped idle $name ($class, nothing queued)"
          fi
          quiet[$key]=0
        fi
      else
        quiet[$key]=0
      fi
    done
  done < <(cat "$REPOS_FILE")

  # Until a job could start sibling containers over the socket, and the
  # docker shim named them `<name>__<runner id>`; a workflow written for a
  # hosted VM never removed them, so every e2e job left a `ci-postgres__…`
  # behind (nine, four days old, 2026-09-21; hundreds of their anonymous
  # volumes, ~24 GB, 2026-11-02). No job can make one now. This sweep stays
  # for whatever is still there from before: a `__<id>` with no runner
  # container of that id is a corpse. It never removes a named volume.
  alive=$(docker ps --quiet --no-trunc --filter 'label=ci-runner.gate' | cut -c1-12)
  for name in $(docker ps --all --format '{{.Names}}' | grep '__' || true); do
    id=${name##*__}
    printf '%s\n' "$alive" | grep -qx "$id" && continue
    docker rm --force --volumes "$name" >/dev/null 2>&1 && log "removed orphaned sibling $name (its runner is gone)"
  done

  # Adaptive poll & rate-limit circuit breaker (per token scope).
  now_s=$(date +%s)
  declare -A active_scopes=()
  while read -r repo _; do
    [ -n "$repo" ] || continue
    active_scopes[$(token_scope_for "/repos/$repo/")]=1
  done < <(cat "$REPOS_FILE")

  any_throttled=0
  all_paused=1
  min_wait=""
  p3=$(awk -v p="$POLL" 'BEGIN { v = p * 3; print (v > 60 ? int(v) : 60) }')
  for scope in "${!active_scopes[@]}"; do
    rem=${rl_remaining[$scope]:-}
    rst=${rl_reset[$scope]:-}
    hit=${rl_hit_limit[$scope]:-0}
    if [ "$hit" = 1 ] || { [ -n "$rem" ] && [ "$rem" -lt 50 ]; }; then
      rl_throttled[$scope]=true
      any_throttled=1
      if [ "${rl_pause_until[$scope]:-0}" -eq 0 ]; then
        cap_s=$((now_s + 300))
        if [ -n "$rst" ] && [ "$rst" -gt "$now_s" ] 2>/dev/null; then
          target_s=$((rst + 5))
          [ "$target_s" -le "$cap_s" ] || target_s=$cap_s
          pause_s=$((target_s - now_s))
        else
          pause_s=300
        fi
        [ "$pause_s" -ge 1 ] || pause_s=1
        rl_pause_until[$scope]=$((now_s + pause_s))
        log "rate-limit circuit breaker ($scope): remaining=${rem:-0}, pausing API calls for ${pause_s}s"
      fi
      rl_hit_limit[$scope]=0
    elif [ -n "$rem" ] && [ "$rem" -lt 150 ]; then
      rl_throttled[$scope]=true
      any_throttled=1
      if [ "${rl_pause_until[$scope]:-0}" -eq 0 ]; then
        rl_pause_until[$scope]=$((now_s + 120))
      fi
    elif [ -n "$rem" ] && [ "$rem" -lt 500 ]; then
      rl_throttled[$scope]=true
      any_throttled=1
      if [ "${rl_pause_until[$scope]:-0}" -eq 0 ]; then
        rl_pause_until[$scope]=$((now_s + p3))
      fi
    else
      rl_throttled[$scope]=false
      rl_pause_until[$scope]=0
    fi

    if [ "${rl_pause_until[$scope]:-0}" -gt "$now_s" ]; then
      wait_s=$(( rl_pause_until[$scope] - now_s ))
      if [ -z "$min_wait" ] || [ "$wait_s" -lt "$min_wait" ]; then
        min_wait=$wait_s
      fi
    else
      all_paused=0
    fi
  done

  if [ "$all_paused" = 1 ] && [ -n "$min_wait" ]; then
    sleep_s=$min_wait
  elif [ -z "$(all_ours)" ] && [ -z "$QUEUE" ]; then
    sleep_s=$POLL_IDLE
  else
    sleep_s=$POLL
  fi

  if [ "$any_throttled" = 1 ]; then
    write_status 2>/dev/null || true
  fi

  # Every runner here is single-use, so an offline registration is a finished
  # one. Left alone the list grows until it is unreadable, which is the only
  # thing that makes an intruder's runner hard to spot. Reuses the runners
  # list already fetched in pass 1 rather than asking GitHub again.
  if [ $((ticks % 30)) = 0 ]; then
    while read -r repo _; do
      [ -n "$repo" ] || continue
      scope=$(token_scope_for "/repos/$repo/")
      [ "${rl_throttled[$scope]:-false}" != "true" ] || continue
      slug=$(slug_of "$repo")
      runners=${runners_of[$slug]:-}
      [ -n "$runners" ] || continue
      for id in $(printf '%s' "$runners" | jq --raw-output '.runners[]? | select(.status == "offline") | .id'); do
        api DELETE "/repos/$repo/actions/runners/$id" >/dev/null 2>&1 && log "$repo: pruned offline runner $id"
      done
    done < <(cat "$REPOS_FILE")
  fi

  sleep "$sleep_s"
done
