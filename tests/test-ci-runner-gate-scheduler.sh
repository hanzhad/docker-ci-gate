#!/usr/bin/env bash
# Consolidated gate admission, mega-class scheduler, status.json, and volume
# flock tests for ci-runner (upstream issue).
# Consolidates:
#   - test-ci-runner-gate.sh
#   - test-ci-runner-mega.sh
#   - test-ci-runner-volume-locks.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
. "$here/tests/lib-parallel.sh"

# ==============================================================================
# Section 1: Gate admission (memory/load), status.json, and volume-only runners
# ==============================================================================
section_1() (
  GATE="$here/gate/gate.sh"
  ROOT=$(mktemp -d)
  GPID=""
  cleanup() { stop_gate; rm -rf "$ROOT"; }
  trap cleanup EXIT
  fail=0
  POLLS=0.2

  check() {
    local label=$1; shift
    if "$@"; then printf 'ok    %s\n' "$label"
    else
      printf 'FAIL  %s\n' "$label"
      [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | tail -4 | sed 's/^/        | /'
      fail=1
    fi
  }

  docker() {
    printf 'docker %s\n' "$*" >> "$CALLS"
    case "${1:-}" in
      ps)
        shift
        local filters=() fmt="" name slug slot class ok f
        while [ $# -gt 0 ]; do
          case $1 in
            --filter) filters+=("$2"); shift 2 ;;
            --format) fmt=$2; shift 2 ;;
            --all|--quiet|--no-trunc) shift ;;
            *) printf 'UNEXPECTED docker ps %s\n' "$1" >> "$CALLS"; return 1 ;;
          esac
        done
        while IFS='|' read -r name slug slot class; do
          [ -n "$name" ] || continue
          ok=1
          for f in "${filters[@]+"${filters[@]}"}"; do
            case $f in
              label=ci-runner.gate) ;;
              label=ci-runner.gate=*) [ "${f#label=ci-runner.gate=}" = "$slug" ] || ok=0 ;;
              label=ci-runner.class=*) [ "${f#label=ci-runner.class=}" = "$class" ] || ok=0 ;;
              *) printf 'UNEXPECTED docker ps filter %s\n' "$f" >> "$CALLS"; return 1 ;;
            esac
          done
          [ $ok = 1 ] || continue
          case "$fmt" in
            '{{.Names}}'|'') printf '%s\n' "$name" ;;
            '{{.Label "ci-runner.slot"}}') printf '%s\n' "$slot" ;;
            '{{.Label "ci-runner.class"}}') printf '%s\n' "$class" ;;
            *) printf 'UNEXPECTED docker ps format %s\n' "$fmt" >> "$CALLS"; return 1 ;;
          esac
        done < "$STATE/running"
        ;;
      run)
        shift
        local rname="" rslug="" rslot="" rclass=""
        while [ $# -gt 0 ]; do
          case $1 in
            --detach|--rm|--init) shift ;;
            --name) rname=$2; shift 2 ;;
            --label)
              case $2 in
                ci-runner.gate=*) rslug=${2#*=} ;;
                ci-runner.slot=*) rslot=${2#*=} ;;
                ci-runner.class=*) rclass=${2#*=} ;;
              esac
              shift 2 ;;
            --*) shift 2 ;;
            *) shift ;;
          esac
        done
        printf '%s|%s|%s|%s\n' "$rname" "$rslug" "$rslot" "$rclass" >> "$STATE/running"
        printf 'container-id\n'
        ;;
      rm)
        local last="${*: -1}"
        grep -v "^$last|" "$STATE/running" > "$STATE/running.tmp"; mv "$STATE/running.tmp" "$STATE/running"
        ;;
      *) printf 'UNEXPECTED docker %s\n' "$*" >> "$CALLS"; return 1 ;;
    esac
  }
  curl() {
    local url="" method=GET path repo slug id
    while [ $# -gt 0 ]; do
      case $1 in
        --request) method=$2; shift 2 ;;
        --header|--data|--dump-header|--output|--write-out) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
      esac
    done
    printf 'curl %s %s\n' "$method" "$url" >> "$CALLS"
    path=${url#https://api.github.com}
    case "$method $path" in
      "POST /repos/"*"/actions/runners/generate-jitconfig") printf '{"encoded_jit_config":"jit"}\n' ;;
      "GET /repos/"*"/actions/runners") printf '{"runners":[]}\n' ;;
      "GET /repos/"*"/actions/runs?status=queued"*)
        repo=${path#/repos/}; repo=${repo%%/actions/*}; slug=$(printf '%s' "$repo" | tr '/' '-')
        if [ -s "$STATE/runs-$slug.json" ]; then cat "$STATE/runs-$slug.json"; else printf '{"workflow_runs":[]}\n'; fi ;;
      "GET /repos/"*"/actions/runs/"*"/jobs")
        id=${path%/jobs}; id=${id##*/}
        cat "$STATE/jobs-$id.json" ;;
      *) printf 'UNEXPECTED curl %s %s\n' "$method" "$path" >> "$CALLS"; return 22 ;;
    esac
  }
  export -f docker curl

  put() { printf '%s\n' "$2" > "$1.tmp" && mv "$1.tmp" "$1"; }
  set_mem() {
    put "$STATE/meminfo" "$(printf 'MemTotal:       20971520 kB\nMemFree:          102400 kB\nMemAvailable:   %d kB\nBuffers: 1 kB' $(($1 * 1024)))"
  }
  set_load() { put "$STATE/loadavg" "$1 0.50 0.40 1/300 1234"; }
  set_floor() { put "$STATE/limits/memory-floor-mb" "$1"; }
  set_ceiling() { put "$STATE/limits/load-ceiling" "$1"; }
  job_n=0
  queue() {
    local repo=$1 class label runs="" slug; shift
    slug=$(printf '%s' "$repo" | tr '/' '-')
    for class in "$@"; do
      job_n=$((job_n + 1))
      case $class in now) label=local-docker-now ;; little) label=local-docker-light ;; *) label=local-docker ;; esac
      printf '{"jobs":[{"status":"queued","labels":["%s"],"created_at":"2026-11-05T00:%02d:00Z"}]}\n' "$label" "$job_n" > "$STATE/jobs-$job_n.json"
      runs="$runs${runs:+,}{\"id\":$job_n,\"run_attempt\":1}"
    done
    printf '{"workflow_runs":[%s]}\n' "$runs" > "$STATE/runs-$slug.json"
  }
  setup() {
    STATE=$(mktemp -d -p "$ROOT"); CALLS="$STATE/calls"; : > "$CALLS"; : > "$STATE/running"
    mkdir -p "$STATE/limits" "$STATE/work" "$STATE/pat.d"
    printf 'o/r\n' > "$STATE/repos"; printf 'token\n' > "$STATE/pat"
    set_mem 8192; set_load 0.00
    LIMITS="$STATE/limits"; EXTRA=(); POLL_USED=$POLLS; OUT=""
    export STATE CALLS
  }
  start_gate() {
    env WORK_ROOT="$STATE/work" TOKEN_FILE="$STATE/pat" TOKEN_DIR="$STATE/pat.d" \
      REPOS_FILE="$STATE/repos" PAUSE_FILE="$STATE/paused" BUDGET_FILE="$STATE/budget" \
      MEMINFO_FILE="$STATE/meminfo" LOADAVG_FILE="$STATE/loadavg" LIMITS_DIR="$LIMITS" \
      STATUS_FILE="$STATE/status.json" POLL="$POLL_USED" "${EXTRA[@]+"${EXTRA[@]}"}" \
      timeout -s KILL 40 bash "$GATE" > "$STATE/out" 2>&1 &
    GPID=$!
  }
  stop_gate() {
    local g
    [ -n "$GPID" ] || return 0
    g=$(pgrep -P "$GPID" | head -1)
    if [ -n "$g" ]; then pkill -KILL -P "$g" 2>/dev/null; kill -KILL "$g" 2>/dev/null; fi
    kill -KILL "$GPID" 2>/dev/null
    { wait "$GPID"; } 2>/dev/null
    GPID=""
    [ -f "$STATE/out" ] && OUT=$(cat "$STATE/out")
  }
  passes() { grep -c '^docker ps --all' "$CALLS" || true; }
  wait_passes() {
    local i
    for i in $(seq 1 200); do [ "$(passes)" -ge "$1" ] && return 0; sleep 0.05; done
    return 1
  }
  runs() { grep -c '^docker run ' "$CALLS" || true; }
  wait_runs() {
    local i
    for i in $(seq 1 200); do [ "$(runs)" -ge "$1" ] && return 0; sleep 0.05; done
    return 1
  }
  runs_are() { [ "$(runs)" -eq "$1" ]; }
  logged() { printf '%s\n' "$OUT" | grep -Eqi -- "$1"; }
  not_logged() { ! logged "$1"; }
  wait_lines() { printf '%s\n' "$OUT" | grep -i -- "$1" | grep -ci waits || true; }
  wait_lines_are() { [ "$(wait_lines "$1")" -eq "$2" ]; }
  wait_line_has() {
    local kind=$1 line; shift
    line=$(printf '%s\n' "$OUT" | grep -i -- "$kind" | grep -i waits | head -1)
    [ -n "$line" ] || return 1
    while [ $# -gt 0 ]; do printf '%s\n' "$line" | grep -Eq -- "$1" || return 1; shift; done
  }
  notice_lines() { printf '%s\n' "$OUT" | grep -i -- "$1" | grep -vci waits || true; }
  notice_once() { [ "$(notice_lines "$1")" -eq 1 ]; }
  no_unexpected() { ! grep -q '^UNEXPECTED' "$CALLS"; }
  num() { printf '(^|[^0-9.])%s([^0-9]|$)' "$1"; }
  eq() { [ "$1" -eq "$2" ]; }
  alive() { wait_passes "$1"; }

  echo '== below the floor a queued job waits, once'
  setup; set_floor 2048; set_mem 1000; queue o/r big
  start_gate; check "memory: four passes made" alive 4; stop_gate
  check "memory below floor: no docker run" runs_are 0
  check "memory below floor: one waiting line, not one per tick" wait_lines_are memory 1
  check "memory below floor: the line gives memory 1000, floor 2048 and the job" \
    wait_line_has memory "$(num 1000)" "$(num 2048)" 'o/r'
  check "memory below floor: no stub call was unexpected" no_unexpected

  echo '== above the floor the same job starts on the next tick'
  setup; set_floor 2048; set_mem 1000; queue o/r big
  start_gate; wait_passes 2; R0=$(runs); set_mem 8192; P=$(passes); wait_passes $((P + 2)); stop_gate
  check "memory raised: nothing had started while below" eq "$R0" 0
  check "memory raised: the job started within a tick or two" runs_are 1
  check "a runner starts under --init, so orphans are reaped" grep -q "^docker run .*--init" "$CALLS"
  check "memory raised: the wait left no repeat of the waiting line" wait_lines_are memory 1

  echo '== changing memory-floor-mb takes effect within a tick, both ways'
  setup; set_floor 4096; set_mem 3000; queue o/r big
  start_gate; wait_passes 2; R0=$(runs); set_floor 2048; P=$(passes); wait_passes $((P + 2)); stop_gate
  check "floor lowered: waited at 3000 MiB with floor 4096" eq "$R0" 0
  check "floor lowered to 2048: started with no restart" runs_are 1
  setup; printf 'o/r\no/r2\n' > "$STATE/repos"; set_floor 2048; set_mem 3000; queue o/r big
  start_gate; wait_runs 1; set_floor 4096; queue o/r2 big; P=$(passes); wait_passes $((P + 2)); stop_gate
  check "floor raised to 4096: the second repository's job did not start" runs_are 1
  check "floor raised to 4096: the second job waits on memory" wait_lines_are memory 1

  echo '== missing directory, missing file: the default 2048'
  setup; set_mem 1000; queue o/r big; LIMITS="$STATE/no-such-dir"
  start_gate; check "missing dir: three passes made" alive 3; stop_gate
  check "missing dir: 1000 MiB is below the default 2048, no docker run" runs_are 0
  check "missing dir: the wait names memory and 2048" wait_line_has memory "$(num 1000)" "$(num 2048)"
  setup; set_mem 1000; queue o/r big
  start_gate; check "missing file: three passes made" alive 3; stop_gate
  check "missing file: 1000 MiB is below the default 2048, no docker run" runs_are 0
  check "missing file: the wait names memory and 2048" wait_line_has memory "$(num 1000)" "$(num 2048)"
  setup; set_mem 2047; queue o/r big
  start_gate; check "default boundary: three passes made" alive 3; stop_gate
  check "default boundary: 2047 MiB waits" runs_are 0
  setup; set_mem 2048; queue o/r big
  start_gate; wait_runs 1; stop_gate
  check "default boundary: 2048 MiB starts (at the floor is enough)" runs_are 1

  echo '== a value that is not an integer means the default, said once'
  setup; set_floor lots; set_mem 1000; queue o/r big
  start_gate; check "bad floor: four passes made" alive 4; stop_gate
  check "bad floor: the default 2048 applies, no docker run" runs_are 0
  check "bad floor: said once in the log" notice_once memory-floor-mb
  setup; set_ceiling many; set_load 1000.00; queue o/r big
  start_gate; check "bad ceiling: four passes made" alive 4; stop_gate
  check "bad ceiling: the default (cores) applies, no docker run" runs_are 0
  check "bad ceiling: said once in the log" notice_once load-ceiling

  echo '== the floor applies to every class, now included'
  setup; set_mem 1000; queue o/r little
  start_gate; check "little: three passes made" alive 3; stop_gate
  check "little below floor: no docker run" runs_are 0
  check "little below floor: the wait names memory" wait_lines_are memory 1
  setup; set_mem 1000; queue o/r now
  start_gate; check "now: three passes made" alive 3; stop_gate
  check "now below floor: no docker run" runs_are 0
  check "now below floor: the wait names memory" wait_lines_are memory 1

  echo '== within one pass each started runner uses up its --memory ceiling'
  setup; set_floor 2048; set_mem 7168; queue o/r little little little little; POLL_USED=30
  start_gate; wait_passes 1; stop_gate
  check "7 GiB, four little (2g): 7, 5, 3 start, then 1 < 2 waits: three runs" runs_are 3
  check "7 GiB, four little: the fourth waits on memory" wait_lines_are memory 1
  setup; set_floor 2048; set_mem 5000; queue o/r big big; POLL_USED=30
  start_gate; wait_passes 1; stop_gate
  check "5000 MiB, two big (4g): 5000-4096 < 2048, one run" runs_are 1
  check "5000 MiB, two big: the second waits on memory" wait_lines_are memory 1
  setup; set_floor 2048; set_mem 7168; queue o/r big big; POLL_USED=30
  start_gate; wait_passes 1; stop_gate
  check "7 GiB, two big: 7-4 still at the floor, both start (green today)" runs_are 2

  echo '== load over the ceiling waits, once; under it the job starts'
  setup; set_ceiling 7; set_load 12.50; queue o/r big
  start_gate; check "load: four passes made" alive 4; stop_gate
  check "load over ceiling: no docker run" runs_are 0
  check "load over ceiling: one waiting line" wait_lines_are load 1
  check "load over ceiling: the line gives load 12.5, ceiling 7 and the job" \
    wait_line_has load '12\.5' "$(num 7)" 'o/r'
  check "load over ceiling: memory is fine, no memory wait" wait_lines_are memory 0
  setup; set_ceiling 7; set_load 12.50; queue o/r big
  start_gate; wait_passes 2; R0=$(runs); set_load 1.00; P=$(passes); wait_passes $((P + 2)); stop_gate
  check "load dropped: nothing had started while over" eq "$R0" 0
  check "load dropped: the job started within a tick or two" runs_are 1
  check "load dropped: the wait left no repeat of the waiting line" wait_lines_are load 1
  setup; set_ceiling 2; set_load 3.00; queue o/r big
  start_gate; wait_passes 2; R0=$(runs); set_ceiling 4; P=$(passes); wait_passes $((P + 2)); stop_gate
  check "ceiling raised: waited at load 3 with ceiling 2" eq "$R0" 0
  check "ceiling raised to 4: started with no restart" runs_are 1
  setup; set_load "$(($(nproc) + 1)).00"; queue o/r big
  start_gate; check "default ceiling: three passes made" alive 3; stop_gate
  check "default ceiling is the cores the gate sees: load above nproc waits" runs_are 0
  check "default ceiling: the wait names load" wait_lines_are load 1

  echo '== an idle runner takes its job with no check (green today)'
  setup; set_mem 1000; set_load 1000.00; queue o/r big; printf 'ci-runner-o-r-1-100|o-r|1|big\n' > "$STATE/running"
  start_gate; check "idle runner: three passes made" alive 3; stop_gate
  check "idle runner: no second runner raised" runs_are 0
  check "idle runner: nothing waits on it" not_logged waits

  echo '== budget and big cap behave as before (green today)'
  setup; set_mem 8192; queue o/r big big; EXTRA=(BUDGET=4 BIG_CAP=4)
  start_gate; check "budget: two passes made" alive 2; stop_gate
  check "budget 4: one big runs, the second waits" runs_are 1
  check "budget 4: the budget line is logged" logged 'budget:.*waits'
  setup; set_mem 8192; queue o/r big big; EXTRA=(BUDGET=10 BIG_CAP=4)
  start_gate; check "big cap: two passes made" alive 2; stop_gate
  check "big cap 4 of 10: one big runs, the second waits" runs_are 1
  check "big cap 4 of 10: the budget line is logged" logged 'budget:.*waits'

  echo '== a paused gate starts nothing (green today)'
  setup; set_mem 8192; queue o/r big; : > "$STATE/paused"
  start_gate; check "paused: three passes made" alive 3; stop_gate
  check "paused: no docker run" runs_are 0

  STATUS_KEYS='schema ts locked paused repos queue busy used budget big_used big_cap class_costs memory_available_mb memory_floor_mb load load_ceiling waiting commit'
  SF() { printf '%s' "$STATE/status.json"; }
  sj() { jq -e "$1" "$(SF)" >/dev/null 2>&1; }
  wait_status() {
    local i
    for i in $(seq 1 100); do jq -e . "$(SF)" >/dev/null 2>&1 && return 0; sleep 0.05; done
    return 1
  }
  ts_of() { jq -r '.ts // empty' "$(SF)" 2>/dev/null; }
  wait_ts_change() {
    local i t
    for i in $(seq 1 100); do t=$(ts_of); [ -n "$t" ] && [ "$t" != "$1" ] && return 0; sleep 0.1; done
    return 1
  }
  has_every_key() {
    local k
    for k in $STATUS_KEYS; do jq -e --arg k "$k" 'has($k)' "$(SF)" >/dev/null 2>&1 || { echo "missing $k"; return 1; }; done
  }
  no_secret() { [ -f "$(SF)" ] && ! grep -q 'planted-token-value' "$(SF)"; }
  inodes_seen() {
    local i seen="" count
    for i in $(seq 1 40); do
      seen="$seen $(stat -c %i "$(SF)" 2>/dev/null)"
      count=$(printf '%s\n' $seen | sort -u | grep -c .)
      if [ "$count" -ge 2 ]; then
        printf '%s\n' "$count"
        return 0
      fi
      sleep 0.05
    done
    printf '%s\n' $seen | sort -u | grep -c .
  }
  always_parses() {
    local i
    for i in $(seq 1 50); do jq -e . "$(SF)" >/dev/null 2>&1 || return 1; sleep 0.03; done
  }

  echo '== a waiting gate writes status.json: every field, no secret'
  setup; set_floor 2048; set_mem 1000; set_ceiling 7; set_load 0.50; queue o/r big
  printf 'planted-token-value\n' > "$STATE/pat"; printf 'planted-token-value\n' > "$STATE/pat.d/acme"
  EXTRA=(GATE_COMMIT=abc1234 BUDGET=12 BIG_CAP=6)
  start_gate; wait_passes 3; wait_status; stop_gate
  check "status: the file exists and is valid JSON" sj .
  check "status: schema is 1" sj '.schema == 1'
  check "status: every documented field is present" has_every_key
  check "status: unlocked, not paused" sj '.locked == false and .paused == false'
  check "status: repos names the served repository" sj '(.repos | tostring | contains("o/r"))'
  check "status: the queue holds the waiting big job with repo, class and since" \
    sj '.queue | any(.[]; .class == "big" and .repo == "o/r" and (.since != null))'
  check "status: budget 12 and big cap 6 as the gate runs them" sj '.budget == 12 and .big_cap == 6'
  check "status: nothing running, so used and big_used are 0" sj '.used == 0 and .big_used == 0'
  check "status: class_costs gives a number for big and for little" \
    sj '(.class_costs.big | type) == "number" and (.class_costs.little | type) == "number"'
  check "status: memory available 1000 against the floor 2048" sj '.memory_available_mb == 1000 and .memory_floor_mb == 2048'
  check "status: load 0.5 against the ceiling 7" sj '.load == 0.5 and .load_ceiling == 7'
  check "status: waiting is the memory reason while the job waits" sj '(.waiting | type) == "string" and (.waiting | test("memory"; "i"))'
  check "status: busy is present" sj 'has("busy")'
  check "status: GATE_COMMIT is in the file" sj '.commit == "abc1234"'
  check "status: GATE_COMMIT is in the gate up line of the log" logged 'gate up:.*abc1234'
  check "status: a token value planted in pat and pat.d is not in the file" no_secret

  echo '== an idle gate: empty queue, nothing waiting'
  setup; set_mem 8192
  start_gate; wait_passes 3; wait_status; stop_gate
  check "idle: the queue is empty" sj '(.queue | length) == 0'
  check "idle: waiting is null" sj '.waiting == null'
  check "idle: used is 0" sj '.used == 0'

  echo '== a running runner is counted in used and big_used'
  setup; set_mem 8192; queue o/r big
  start_gate; wait_runs 1; P=$(passes); wait_passes $((P + 3)); wait_status; stop_gate
  check "running: a big runner costs 4 cores in used and big_used" sj '.used == 4 and .big_used == 4'

  echo '== a paused gate says so'
  setup; set_mem 8192; : > "$STATE/paused"
  start_gate; wait_passes 3; wait_status; stop_gate
  check "paused: paused is true" sj '.paused == true'

  echo '== a locked gate still refreshes status.json'
  setup; : > "$STATE/pat"
  start_gate; wait_status; T0=$(ts_of)
  check "locked: the file exists" sj .
  check "locked: locked is true, schema 1" sj '.locked == true and .schema == 1'
  check "locked: ts is present" test -n "$T0"
  check "locked: ts changes between two locked ticks" wait_ts_change "$T0"
  stop_gate

  echo '== a gate locked after it ran reports the machine as it is now'
  setup; set_mem 8192; set_load 0.50
  start_gate; wait_passes 3; wait_status
  check "relock: while unlocked the file has the memory read by the pass" sj '.memory_available_mb == 8192'
  : > "$STATE/pat"; set_mem 1234; set_load 1.25
  wait_mem_in_status() { local i; for i in $(seq 1 100); do sj '.memory_available_mb == 1234 and .load == 1.25' && return 0; sleep 0.1; done; return 1; }
  check "relock: once locked, memory and load are the new reading, not the last pass's" wait_mem_in_status
  check "relock: and the file says locked" sj '.locked == true'
  stop_gate

  echo '== the file is replaced atomically, never rewritten in place'
  setup; set_mem 8192
  start_gate; wait_status
  check "atomic: every read of a file the gate is rewriting parses" always_parses
  check "atomic: a replace each tick gives more than one distinct file (rename, not truncate)" \
    test "$(inodes_seen)" -ge 2
  stop_gate

  run_lines() { grep '^docker run ' "$CALLS"; }
  no_host_mount() { ! run_lines | grep -Eq -- '--volume /'; }
  no_slot_label() { ! run_lines | grep -q 'ci-runner\.slot'; }
  has_ci_repo() { run_lines | grep -q -- '--env CI_REPO=o/r'; }
  mounts_git() { run_lines | grep -q -- '--volume ci-runner-git-o-r:/var/cache/ci-runner/git'; }
  mounts_npm() { run_lines | grep -q -- '--volume ci-runner-npm-o-r:/home/runner/\.npm'; }
  mounts_cache() { run_lines | grep -q -- '--volume ci-runner-cache-o-r:/home/runner/\.cache'; }
  mounts_pnpm() { run_lines | grep -q -- '--volume ci-runner-pnpm-o-r:/home/runner/\.local/share/pnpm'; }
  has_compose_project_0_ci() { run_lines | grep -q -- '--label com.docker.compose.project=0-ci'; }
  no_legacy_compose_project() { ! run_lines | grep -q -- 'com.docker.compose.project=ci-runner'; }
  has_runner_container_name() { run_lines | grep -Eq -- '--name ci-runner-o-r-[0-9]+-[0-9]+'; }
  has_compose_service_runner() { run_lines | grep -q -- '--label com.docker.compose.service=runner-o-r'; }
  names_differ() {
    local n
    n=$(run_lines | sed -n 's/.*--name \([^ ]*\).*/\1/p')
    [ "$(printf '%s\n' "$n" | grep -c .)" -ge 2 ] && [ "$(printf '%s\n' "$n" | sort -u | grep -c .)" -eq "$(printf '%s\n' "$n" | grep -c .)" ]
  }

  echo '== no work root: the gate starts without one and starts a runner'
  setup; set_mem 8192; queue o/r big
  EXTRA=(WORK_ROOT=)
  start_gate; wait_runs 1; stop_gate
  check "work: the gate starts a runner with WORK_ROOT empty" runs_are 1
  check "work: the runner mounts no host path" no_host_mount
  check "work: the runner carries no ci-runner.slot label" no_slot_label
  check "work: the runner passes CI_REPO" has_ci_repo
  check "work: the runner mounts git volume" mounts_git
  check "work: the runner mounts npm volume" mounts_npm
  check "work: the runner mounts cache volume" mounts_cache
  check "work: the runner mounts pnpm volume" mounts_pnpm
  check "work: the runner carries com.docker.compose.project=0-ci" has_compose_project_0_ci
  check "work: the runner does not carry legacy com.docker.compose.project=ci-runner" no_legacy_compose_project
  check "work: the runner keeps the ci-runner-* container name" has_runner_container_name
  check "work: the runner keeps com.docker.compose.service=runner-o-r" has_compose_service_runner

  echo '== two runners of one repository in one pass get different names'
  setup; set_mem 8192; queue o/r big little
  start_gate; wait_runs 2; stop_gate
  check "names: two runners started" runs_are 2
  check "names: their names differ" names_differ

  exit "$fail"
)

# ==============================================================================
# Section 2: Mega class exclusivity, draining, reaping, and cache refresh
# ==============================================================================
section_2() (
  GATE="$here/gate/gate.sh"
  ROOT=$(mktemp -d)
  GPID=""
  cleanup() { stop_gate; rm -rf "$ROOT"; }
  trap cleanup EXIT
  fail=0
  POLLS=0.2

  check() {
    local label=$1; shift
    if "$@"; then printf 'ok    %s\n' "$label"
    else
      printf 'FAIL  %s\n' "$label"
      [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | tail -4 | sed 's/^/        | /'
      fail=1
    fi
  }

  docker() {
    printf 'docker %s\n' "$*" >> "$CALLS"
    case "${1:-}" in
      ps)
        shift
        local filters=() fmt="" name slug slot class ok f
        while [ $# -gt 0 ]; do
          case $1 in
            --filter) filters+=("$2"); shift 2 ;;
            --format) fmt=$2; shift 2 ;;
            --all|--quiet|--no-trunc) shift ;;
            *) printf 'UNEXPECTED docker ps %s\n' "$1" >> "$CALLS"; return 1 ;;
          esac
        done
        while IFS='|' read -r name slug slot class; do
          [ -n "$name" ] || continue
          ok=1
          for f in "${filters[@]+"${filters[@]}"}"; do
            case $f in
              label=ci-runner.gate) ;;
              label=ci-runner.gate=*) [ "${f#label=ci-runner.gate=}" = "$slug" ] || ok=0 ;;
              label=ci-runner.class=*) [ "${f#label=ci-runner.class=}" = "$class" ] || ok=0 ;;
              *) printf 'UNEXPECTED docker ps filter %s\n' "$f" >> "$CALLS"; return 1 ;;
            esac
          done
          [ $ok = 1 ] || continue
          case "$fmt" in
            '{{.Names}}'|'') printf '%s\n' "$name" ;;
            '{{.Label "ci-runner.slot"}}') printf '%s\n' "$slot" ;;
            '{{.Label "ci-runner.class"}}') printf '%s\n' "$class" ;;
            *) printf 'UNEXPECTED docker ps format %s\n' "$fmt" >> "$CALLS"; return 1 ;;
          esac
        done < "$STATE/running"
        ;;
      run)
        shift
        local rname="" rslug="" rslot="" rclass=""
        while [ $# -gt 0 ]; do
          case $1 in
            --detach|--rm|--init) shift ;;
            --name) rname=$2; shift 2 ;;
            --label)
              case $2 in
                ci-runner.gate=*) rslug=${2#*=} ;;
                ci-runner.slot=*) rslot=${2#*=} ;;
                ci-runner.class=*) rclass=${2#*=} ;;
              esac
              shift 2 ;;
            --*) shift 2 ;;
            *) shift ;;
          esac
        done
        printf '%s|%s|%s|%s\n' "$rname" "$rslug" "$rslot" "$rclass" >> "$STATE/running"
        printf 'container-id\n'
        ;;
      rm)
        local last="${*: -1}"
        grep -v "^$last|" "$STATE/running" > "$STATE/running.tmp"; mv "$STATE/running.tmp" "$STATE/running"
        ;;
      *) printf 'UNEXPECTED docker %s\n' "$*" >> "$CALLS"; return 1 ;;
    esac
  }
  curl() {
    local url="" method=GET path repo slug id
    while [ $# -gt 0 ]; do
      case $1 in
        --request) method=$2; shift 2 ;;
        --data) printf 'curl-data %s\n' "$2" >> "$CALLS"; shift 2 ;;
        --header|--dump-header|--output|--write-out) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
      esac
    done
    printf 'curl %s %s\n' "$method" "$url" >> "$CALLS"
    path=${url#https://api.github.com}
    case "$method $path" in
      "POST /repos/"*"/actions/runners/generate-jitconfig") printf '{"encoded_jit_config":"jit"}\n' ;;
      "GET /repos/"*"/actions/runners") runners_json ;;
      "GET /repos/"*"/actions/runs?status=queued"*)
        repo=${path#/repos/}; repo=${repo%%/actions/*}; slug=$(printf '%s' "$repo" | tr '/' '-')
        if [ -s "$STATE/runs-$slug.json" ]; then cat "$STATE/runs-$slug.json"; else printf '{"workflow_runs":[]}\n'; fi ;;
      "GET /repos/"*"/actions/runs/"*"/jobs")
        id=${path%/jobs}; id=${id##*/}
        cat "$STATE/jobs-$id.json" ;;
      *) printf 'UNEXPECTED curl %s %s\n' "$method" "$path" >> "$CALLS"; return 22 ;;
    esac
  }
  runners_json() {
    local sep="" id
    printf '{"runners":['
    while read -r id; do
      [ -n "$id" ] || continue
      printf '%s{"name":"%s","status":"online","busy":true}' "$sep" "$id"; sep=,
    done < "$STATE/busy"
    printf ']}\n'
  }
  export -f docker curl runners_json

  put() { printf '%s\n' "$2" > "$1.tmp" && mv "$1.tmp" "$1"; }
  set_mem() {
    put "$STATE/meminfo" "$(printf 'MemTotal:       20971520 kB\nMemFree:          102400 kB\nMemAvailable:   %d kB\nBuffers: 1 kB' $(($1 * 1024)))"
  }
  set_load() { put "$STATE/loadavg" "$1 0.50 0.40 1/300 1234"; }
  job_n=0
  queue() {
    local repo=$1 class label runs="" slug; shift
    slug=$(printf '%s' "$repo" | tr '/' '-')
    for class in "$@"; do
      job_n=$((job_n + 1))
      case $class in now) label=local-docker-now ;; little) label=local-docker-light ;; mega) label=local-docker-mega ;; *) label=local-docker ;; esac
      printf '{"jobs":[{"id":%d,"status":"queued","labels":["%s"],"created_at":"2026-11-05T00:%02d:00Z"}]}\n' "$((job_n + 100))" "$label" "$job_n" > "$STATE/jobs-$job_n.json"
      runs="$runs${runs:+,}{\"id\":$job_n,\"run_attempt\":1}"
    done
    printf '{"workflow_runs":[%s]}\n' "$runs" > "$STATE/runs-$slug.json"
  }
  setup() {
    STATE=$(mktemp -d -p "$ROOT"); CALLS="$STATE/calls"; : > "$CALLS"; : > "$STATE/running"
    : > "$STATE/busy"; mkdir -p "$STATE/limits" "$STATE/work" "$STATE/pat.d"
    printf 'o/r\n' > "$STATE/repos"; printf 'token\n' > "$STATE/pat"
    set_mem 8192; set_load 0.00
    LIMITS="$STATE/limits"; EXTRA=(); POLL_USED=$POLLS; OUT=""
    export STATE CALLS
  }
  start_gate() {
    env WORK_ROOT="$STATE/work" TOKEN_FILE="$STATE/pat" TOKEN_DIR="$STATE/pat.d" \
      REPOS_FILE="$STATE/repos" PAUSE_FILE="$STATE/paused" BUDGET_FILE="$STATE/budget" \
      MEMINFO_FILE="$STATE/meminfo" LOADAVG_FILE="$STATE/loadavg" LIMITS_DIR="$LIMITS" \
      STATUS_FILE="$STATE/status.json" POLL="$POLL_USED" "${EXTRA[@]+"${EXTRA[@]}"}" \
      timeout -s KILL 40 bash "$GATE" > "$STATE/out" 2>&1 &
    GPID=$!
  }
  stop_gate() {
    local g
    [ -n "$GPID" ] || return 0
    g=$(pgrep -P "$GPID" | head -1)
    if [ -n "$g" ]; then pkill -KILL -P "$g" 2>/dev/null; kill -KILL "$g" 2>/dev/null; fi
    kill -KILL "$GPID" 2>/dev/null
    { wait "$GPID"; } 2>/dev/null
    GPID=""
    [ -f "$STATE/out" ] && OUT=$(cat "$STATE/out")
  }
  passes() { grep -c '^docker ps --all' "$CALLS" || true; }
  wait_passes() {
    local i
    for i in $(seq 1 200); do [ "$(passes)" -ge "$1" ] && return 0; sleep 0.05; done
    return 1
  }
  runs() { grep -c '^docker run ' "$CALLS" || true; }
  wait_runs() {
    local i
    for i in $(seq 1 200); do [ "$(runs)" -ge "$1" ] && return 0; sleep 0.05; done
    return 1
  }
  runs_are() { [ "$(runs)" -eq "$1" ]; }
  logged() { printf '%s\n' "$OUT" | grep -Eqi -- "$1"; }
  not_logged() { ! logged "$1"; }
  notice_lines() { printf '%s\n' "$OUT" | grep -i -- "$1" | grep -vci waits || true; }
  notice_once() { [ "$(notice_lines "$1")" -eq 1 ]; }
  no_unexpected() { ! grep -q '^UNEXPECTED' "$CALLS"; }
  eq() { [ "$1" -eq "$2" ]; }
  alive() { wait_passes "$1"; }

  preload() {
    printf '%s|o-r||%s\n' "$1" "$2" >> "$STATE/running"
    [ "${3:-}" = busy ] && printf '%s\n' "$1" >> "$STATE/busy"
    return 0
  }
  unload() {
    grep -v "^$1|" "$STATE/running" > "$STATE/running.tmp"; mv "$STATE/running.tmp" "$STATE/running"
  }
  msetup() { setup; set_mem 20000; EXTRA=(CPU_COUNT=16); }
  sj() { jq -e "$1" "$STATE/status.json" >/dev/null 2>&1; }
  wait_sj() { local i; for i in $(seq 1 100); do sj "$1" && return 0; sleep 0.1; done; return 1; }
  run_lines() { grep '^docker run ' "$CALLS"; }
  run_has() { run_lines | grep -q -- "$1"; }
  rm_called() { grep -q '^docker rm ' "$CALLS"; }
  rm_called_for() { grep -q "^docker rm .*$1" "$CALLS"; }
  no_rm() { ! rm_called; }
  BIGC=ci-runner-o-r-1-100
  MEGAC=ci-runner-o-r-2-200

  echo '== 1. a queued mega job holds the line: nothing new starts while a big runs'
  msetup; preload $BIGC big busy; queue o/r mega little
  start_gate; check "hold: four passes made" alive 4; stop_gate
  check "hold: no runner started (the little behind the mega job does not jump)" runs_are 0
  check "hold: the log says it is draining for the mega job" logged 'draining for mega job o/r'
  check "hold: the draining line is logged once per hold, not per tick" notice_once 'draining for mega job'
  check "hold: the line has the run/job and the cores in use" logged 'draining for mega job o/r [0-9]+/[0-9]+: 4/10 cores still in use, [0-9]+s'
  check "hold: no stub call was unexpected" no_unexpected

  echo '== 2. the mega job starts only when nothing else runs, and takes the machine'
  msetup; preload $BIGC big busy; queue o/r mega little
  start_gate; wait_passes 3; R0=$(runs); unload $BIGC; P=$(passes); wait_runs 1; wait_passes $((P + 3)); stop_gate
  check "start: nothing started while the big ran" eq "$R0" 0
  check "start: exactly one runner started once the big was gone" runs_are 1
  check "start: it is class mega" run_has 'ci-runner.class=mega'
  check "start: --cpus is the CPU count minus 2 (16 -> 14)" run_has -- '--cpus 14'
  check "start: --memory is MemTotal minus 4096 MiB (20 GiB -> 16384m)" run_has -- '--memory 16384m'
  check "start: the little behind it did not start" eq "$(run_lines | grep -c 'ci-runner.class=little')" 0

  echo '== 3. while a mega runs nothing else fits'
  msetup; preload $MEGAC mega busy; queue o/r now big little
  start_gate; check "exclusive: four passes made" alive 4; stop_gate
  check "exclusive: now, big and little all wait: no runner started" runs_are 0

  echo '== 4. a live budget raise does not break exclusivity'
  msetup; preload $MEGAC mega busy; queue o/r now big little
  start_gate; wait_passes 2; put "$STATE/budget" "20 8"; P=$(passes); wait_passes $((P + 3)); stop_gate
  check "budget raised to 20 under a running mega: still no runner started" runs_are 0

  echo '== 5. a failed mega job releases the line'
  msetup; preload $MEGAC mega busy; queue o/r little
  start_gate; wait_passes 2; R0=$(runs); unload $MEGAC; P=$(passes); wait_passes $((P + 2)); stop_gate
  check "release: nothing started while the mega ran" eq "$R0" 0
  check "release: the little starts within two passes of the mega's exit" runs_are 1

  echo '== 6. the line is released after a gate restart too (the label is the marker)'
  msetup; preload $MEGAC mega busy; queue o/r little
  start_gate; wait_passes 3; stop_gate
  check "restart: a mega found at boot still holds the machine" runs_are 0
  unload $MEGAC; start_gate; wait_runs 1; stop_gate
  check "restart: once it is gone a fresh gate starts the little" runs_are 1

  echo '== 7. an idle mega runner with no mega job queued is reaped'
  msetup; preload $MEGAC mega; queue o/r little
  start_gate; wait_runs 1; stop_gate
  check "reap: the idle mega runner was removed" rm_called_for "$MEGAC"
  check "reap: afterwards the little starts" runs_are 1

  echo '== 8. mega ignores BIG_CAP'
  msetup; EXTRA=(CPU_COUNT=16 BUDGET=10 BIG_CAP=8); queue o/r mega
  start_gate; wait_runs 1; stop_gate
  check "no cap: BUDGET=10 BIG_CAP=8 on an empty machine still starts the mega job" runs_are 1
  check "no cap: and it is class mega" run_has 'ci-runner.class=mega'

  echo '== 9. a long drain is reported, never forced'
  msetup; EXTRA=(CPU_COUNT=16 MEGA_DRAIN_WARN=1); preload $BIGC big busy; queue o/r mega
  start_gate; wait_passes 16; stop_gate
  check "overdue: one line says it is over MEGA_DRAIN_WARN" notice_once 'over MEGA_DRAIN_WARN'
  check "overdue: the line gives the wait in seconds" logged 'mega job .* has waited [0-9]+s, over MEGA_DRAIN_WARN'
  check "overdue: nothing was removed" no_rm
  check "overdue: nothing started" runs_are 0

  echo '== 10. switch off: the designated job is an ordinary big (green today)'
  msetup; queue o/r big big
  start_gate; wait_runs 2; stop_gate
  check "off: both run in parallel" runs_are 2
  check "off: each is --cpus 4" eq "$(run_lines | grep -c -- '--cpus 4 ')" 2
  check "off: each is --memory 4g" eq "$(run_lines | grep -c -- '--memory 4g')" 2
  check "off: no mega runner" eq "$(run_lines | grep -c 'ci-runner.class=mega')" 0
  check "off: no draining line" not_logged draining

  echo '== 11. status.json says what the hold is waiting for'
  msetup; preload $BIGC big busy; queue o/r mega
  start_gate; wait_passes 2; wait_sj '.draining.seconds > 0'; wait_passes $(( $(passes) + 1 ))
  check "status: draining.repo is o/r" sj '.draining.repo == "o/r"'
  check "status: draining has a ref and a since" sj '(.draining.ref | type) == "string" and (.draining.since != null)'
  check "status: draining.seconds counts up" sj '.draining.seconds > 0'
  check "status: not overdue" sj '.draining.overdue == false'
  check "status: waiting starts with draining for mega job" sj '(.waiting | type) == "string" and (.waiting | startswith("draining for mega job"))'
  stop_gate
  msetup; start_gate; wait_passes 3; sleep 0.3; stop_gate
  check "status: with no mega job queued draining is null (key present)" sj 'has("draining") and .draining == null'

  echo '== 15. a mega runner is not swept at MAX_BUSY, only at MEGA_MAX_BUSY'
  msetup; EXTRA=(CPU_COUNT=16 MAX_BUSY=1 MEGA_MAX_BUSY=100); preload $MEGAC mega busy
  start_gate; wait_passes 16; stop_gate
  check "mega busy past MAX_BUSY, under MEGA_MAX_BUSY: not removed" no_rm

  echo '== 16. past MEGA_MAX_BUSY a mega runner is swept; a big still is at MAX_BUSY'
  msetup; EXTRA=(CPU_COUNT=16 MAX_BUSY=100 MEGA_MAX_BUSY=1); preload $MEGAC mega busy
  start_gate; wait_passes 16; stop_gate
  check "mega busy past MEGA_MAX_BUSY: removed" rm_called_for "$MEGAC"
  msetup; EXTRA=(CPU_COUNT=16 MAX_BUSY=1 MEGA_MAX_BUSY=100); preload $BIGC big busy
  start_gate; wait_passes 16; stop_gate
  check "big busy past MAX_BUSY: still removed as today (green today)" rm_called_for "$BIGC"

  echo '== 17. mega on/off and on/off refresh the status --json cache within 60s'
  (
    fail=0; OUT=""; JSON=""; RC=0
    CR="$here/ci-runner.sh"
    unset -f curl runners_json 2>/dev/null || true
    docker() {
      local a="$*" x interactive=0
      for x in "$@"; do case $x in --interactive|-i) interactive=1 ;; esac; done
      printf 'docker %s\n' "$a" >> "$CALLS"
      [ $interactive = 1 ] && cat > /dev/null
      case "${1:-}" in
        image) [ -e "$IMAGES_OK" ] ;;
        inspect)
          [ "$GATE_STATE" = absent ] && return 1
          case "$a" in
            *State.Status*) printf '%s\n' "$GATE_STATE" ;;
            *Config.Env*)
              printf 'BUDGET=12\nBIG_CAP=6\nBIG_COST=4\nLITTLE_COST=2\nDEFER=0\nHOST_TAG=box\nGATE_COMMIT=%s\n' "$GATE_COMMIT_ENV"
              [ -n "${GATE_MEGA_CPUS:-}" ] && printf 'MEGA_CPUS=%s\n' "$GATE_MEGA_CPUS" ;;
          esac ;;
        exec)
          case "$a" in
            *"cat /run/gate/status.json"*) [ -f "$GATE_STATUS" ] && cat "$GATE_STATUS" ;;
            *"test -s /run/gate/pat"*) [ "$GATE_LOCKED" = 0 ] ;;
            *"test -e /run/gate/paused"*) [ -n "$GATE_PAUSED" ] ;;
          esac ;;
        *) return 0 ;;
      esac
    }
    gh() {
      printf 'gh %s\n' "$*" >> "$CALLS"
      local repo slug vname val
      case "${1:-} ${2:-}" in
        "auth status") return 0 ;;
        "variable set")
          [ -n "${FAIL_GH_VAR:-}" ] && return 1
          vname=${3:-}; repo=""; val=""
          shift 3 2>/dev/null || shift $#
          while [ $# -gt 0 ]; do
            case "$1" in
              --repo) repo=${2:-}; shift 2 ;;
              --body) val=${2:-}; shift 2 ;;
              *) shift ;;
            esac
          done
          slug=$(printf '%s' "$repo" | tr '/[:upper:]' '-[:lower:]')
          printf '%s\n' "$val" > "$GHREG/var-$vname-$slug"
          return 0 ;;
        "variable delete")
          [ -n "${FAIL_GH_VAR:-}" ] && return 1
          vname=${3:-}; repo=""
          shift 3 2>/dev/null || shift $#
          while [ $# -gt 0 ]; do
            case "$1" in
              --repo) repo=${2:-}; shift 2 ;;
              *) shift ;;
            esac
          done
          slug=$(printf '%s' "$repo" | tr '/[:upper:]' '-[:lower:]')
          rm -f "$GHREG/var-$vname-$slug"
          return 0 ;;
        "variable get")
          vname=${3:-}; repo=""
          shift 3 2>/dev/null || shift $#
          while [ $# -gt 0 ]; do
            case "$1" in
              --repo) repo=${2:-}; shift 2 ;;
              *) shift ;;
            esac
          done
          slug=$(printf '%s' "$repo" | tr '/[:upper:]' '-[:lower:]')
          [ -f "$GHREG/var-$vname-$slug" ] && cat "$GHREG/var-$vname-$slug"
          return $? ;;
        "repo list") cat "$GHREG/_" 2>/dev/null; return 0 ;;
        "api user/orgs") return 0 ;;
      esac
      case "$*" in
        *actions/runners*) printf '{"runners":[{"name":"r1","status":"online","busy":false,"labels":[{"name":"local-docker"}]}]}\n' ;;
        *releases/latest*) return 1 ;;
      esac
      return 0
    }
    export -f docker gh

    mega_fresh() {
      T=$(mktemp -d -p "$ROOT")
      export HOME="$T/home" CI_RUNNER_STATE_DIR="$T/state" CI_RUNNER_WORK_ROOT="$T/work"
      export CALLS="$T/calls" IMAGES_OK="$T/images" GHREG="$T/gh" GATE_STATUS="$T/gate-status.json"
      export GATE_STATE=running GATE_LOCKED=0 GATE_PAUSED="" GATE_COMMIT_ENV=abc1234 GATE_MEGA_CPUS=14 FAIL_GH_VAR=""
      mkdir -p "$HOME" "$GHREG" "$T/empty" "$T/elsewhere"
      : > "$CALLS"
      printf 'o/r\no/other\n' > "$GHREG/_"
      jq -n '{schema:1, ts:"2026-11-05T00:00:00Z", locked:false, paused:false, repos:["o/r"],
        queue:[], busy:0, used:0, budget:12, big_used:0, big_cap:6, class_costs:{big:4,little:2,mega:12},
        memory_available_mb:8000, memory_floor_mb:2048, load:0.5, load_ceiling:7, waiting:null, commit:"abc1234"}' > "$GATE_STATUS"
    }
    crj() { local d=$1; shift; JSON=$(cd "$d" && bash "$CR" "$@" 2>"$T/err" </dev/null); RC=$?; OUT="$JSON"; }
    crf() { local d=$1; shift; OUT=$(cd "$d" && bash "$CR" "$@" 2>&1 </dev/null); RC=$?; }
    jqs() { [ -n "$JSON" ] && printf '%s' "$JSON" | jq -e "$1" >/dev/null 2>&1; }
    rc_zero() { [ "$RC" -eq 0 ]; }
    rc_nonzero() { [ "$RC" -ne 0 ]; }
    ci_gets_are() { [ "$(grep -E '^gh variable get CI_RUNNER( |$)' "$CALLS" | grep -Ec -- "--repo $1( |\$)" || true)" -eq "$2" ]; }
    mega_gets_are() { [ "$(grep -E '^gh variable get CI_RUNNER_LABEL_MEGA( |$)' "$CALLS" | grep -Ec -- "--repo $1( |\$)" || true)" -eq "$2" ]; }
    mkco() { git init -q "$1" && git -C "$1" remote add origin "$2"; }

    mega_fresh
    printf '0\n' > "$GHREG/var-CI_RUNNER-o-r"
    crj "$T/empty" status --json
    check "mega cache setup: o/r starts with mega null and ci_runner 0" \
      jqs '(.repositories[] | select(.repo == "o/r") | .mega) == null and (.repositories[] | select(.repo == "o/r") | .ci_runner) == 0'
    crf "$T/elsewhere" mega on o/r
    check "mega on: exits 0" rc_zero
    crj "$T/empty" status --json
    check "mega on: status --json immediately reflects mega == local-docker-mega within 60s" \
      jqs '(.repositories[] | select(.repo == "o/r") | .mega) == "local-docker-mega"'
    check "mega on: no extra gh variable get CI_RUNNER_LABEL_MEGA within 60s" mega_gets_are o/r 1
    check "mega on: preserves cached ci_runner == 0" \
      jqs '(.repositories[] | select(.repo == "o/r") | .ci_runner) == 0'
    check "mega on: sibling repository mega cache stays null" \
      jqs '(.repositories[] | select(.repo == "o/other") | .mega) == null'

    mega_fresh
    printf '1\n' > "$GHREG/var-CI_RUNNER-o-r"
    printf 'local-docker-mega\n' > "$GHREG/var-CI_RUNNER_LABEL_MEGA-o-r"
    printf 'local-docker-mega\n' > "$GHREG/var-CI_RUNNER_LABEL_MEGA-o-other"
    crj "$T/empty" status --json
    check "mega off setup: o/r starts with mega local-docker-mega" \
      jqs '(.repositories[] | select(.repo == "o/r") | .mega) == "local-docker-mega"'
    crf "$T/elsewhere" mega off o/r
    check "mega off: exits 0" rc_zero
    crj "$T/empty" status --json
    check "mega off: status --json immediately reflects mega == null within 60s" \
      jqs '(.repositories[] | select(.repo == "o/r") | .mega) == null'
    check "mega off: no extra gh variable get CI_RUNNER_LABEL_MEGA within 60s" mega_gets_are o/r 1
    check "mega off: preserves cached ci_runner == 1" \
      jqs '(.repositories[] | select(.repo == "o/r") | .ci_runner) == 1'
    check "mega off: sibling repository mega cache stays local-docker-mega" \
      jqs '(.repositories[] | select(.repo == "o/other") | .mega) == "local-docker-mega"'

    mega_fresh
    printf '0\n' > "$GHREG/var-CI_RUNNER-o-r"
    printf 'local-docker-mega\n' > "$GHREG/var-CI_RUNNER_LABEL_MEGA-o-r"
    crj "$T/empty" status --json
    crf "$T/elsewhere" on o/r
    crj "$T/empty" status --json
    check "on alongside mega: status --json immediately reflects ci_runner == 1 within 60s" \
      jqs '(.repositories[] | select(.repo == "o/r") | .ci_runner) == 1'
    check "on alongside mega: preserves cached mega == local-docker-mega" \
      jqs '(.repositories[] | select(.repo == "o/r") | .mega) == "local-docker-mega"'
    check "on alongside mega: no extra gh variable get CI_RUNNER within 60s" ci_gets_are o/r 1

    mega_fresh
    printf '1\n' > "$GHREG/var-CI_RUNNER-o-r"
    printf 'local-docker-mega\n' > "$GHREG/var-CI_RUNNER_LABEL_MEGA-o-r"
    crj "$T/empty" status --json
    crf "$T/elsewhere" off o/r
    crj "$T/empty" status --json
    check "off alongside mega: status --json immediately reflects ci_runner == 0 within 60s" \
      jqs '(.repositories[] | select(.repo == "o/r") | .ci_runner) == 0'
    check "off alongside mega: preserves cached mega == local-docker-mega" \
      jqs '(.repositories[] | select(.repo == "o/r") | .mega) == "local-docker-mega"'
    check "off alongside mega: no extra gh variable get CI_RUNNER within 60s" ci_gets_are o/r 1

    mega_fresh
    mkco "$T/co" https://github.com/o/r.git
    : > "$IMAGES_OK"
    crf "$T/elsewhere" up --label zzz-box
    crj "$T/empty" status --json
    crf "$T/elsewhere" mega on "$T/co"
    crj "$T/empty" status --json
    check "mega on (custom label, path): status --json immediately reflects zzz-box-mega" \
      jqs '(.repositories[] | select(.repo == "o/r") | .mega) == "zzz-box-mega"'
    crf "$T/elsewhere" mega off "$T/co"
    crj "$T/empty" status --json
    check "mega off (round-trip, path): status --json immediately reflects mega == null" \
      jqs '(.repositories[] | select(.repo == "o/r") | .mega) == null'
    crf "$T/elsewhere" mega on "$T/co"
    crj "$T/empty" status --json
    check "mega on (round-trip, path): status --json immediately reflects zzz-box-mega again" \
      jqs '(.repositories[] | select(.repo == "o/r") | .mega) == "zzz-box-mega"'
    check "mega round-trip within 60s makes only one gh variable get CI_RUNNER_LABEL_MEGA" mega_gets_are o/r 1

    mega_fresh
    GATE_MEGA_CPUS=""
    jq -n '{schema:1, ts:"2026-11-05T00:00:00Z", locked:false, paused:false, repos:["o/r"],
      queue:[], busy:0, used:0, budget:12, big_used:0, big_cap:6, class_costs:{big:4,little:2},
      memory_available_mb:8000, memory_floor_mb:2048, load:0.5, load_ceiling:7, waiting:null, commit:"abc1234"}' > "$GATE_STATUS"
    crj "$T/empty" status --json
    crf "$T/elsewhere" mega on o/other
    check "mega on without capable gate: exits non-zero" rc_nonzero
    crj "$T/empty" status --json
    check "mega on without capable gate: keeps cached mega == null" \
      jqs '(.repositories[] | select(.repo == "o/other") | .mega) == null'

    mega_fresh
    printf 'zzz-box-mega\n' > "$GHREG/var-CI_RUNNER_LABEL_MEGA-o-r"
    crj "$T/empty" status --json
    FAIL_GH_VAR=1
    crf "$T/elsewhere" mega off o/r
    check "mega off when gh variable delete fails: exits non-zero" rc_nonzero
    FAIL_GH_VAR=""
    crj "$T/empty" status --json
    check "mega off failure: keeps cached zzz-box-mega" \
      jqs '(.repositories[] | select(.repo == "o/r") | .mega) == "zzz-box-mega"'

    mega_fresh
    printf 'Acme/Api\n' > "$GHREG/_"
    crj "$T/empty" status --json
    crf "$T/elsewhere" mega on Acme/Api
    crj "$T/empty" status --json
    check "mega on (mixed-case slug): status --json immediately reflects local-docker-mega" \
      jqs '(.repositories[] | select(.repo == "Acme/Api") | .mega) == "local-docker-mega"'
    check "mega on (mixed-case slug): no extra gh variable get within 60s" mega_gets_are Acme/Api 1

    mega_fresh
    printf 'Acme/Api\n' > "$GHREG/_"
    printf 'local-docker-mega\n' > "$GHREG/var-CI_RUNNER_LABEL_MEGA-acme-api"
    crj "$T/empty" status --json
    crf "$T/elsewhere" mega off Acme/Api
    crj "$T/empty" status --json
    check "mega off (mixed-case slug): status --json immediately reflects mega == null" \
      jqs '(.repositories[] | select(.repo == "Acme/Api") | .mega) == null'
    check "mega off (mixed-case slug): no extra gh variable get within 60s" mega_gets_are Acme/Api 1

    exit "$fail"
  ) || fail=1

  exit "$fail"
)

# ==============================================================================
# Section 3: Per-repository volume flock (.inuse & .sync)
# ==============================================================================
section_3() (
  D="$here"
  T=$(mktemp -d); trap 'jobs -p | xargs -r kill 2>/dev/null; rm -rf "$T"' EXIT
  fail=0
  check() {
    local label=$1; shift
    if "$@"; then printf "ok    %s\n" "$label"; else printf "FAIL  %s\n" "$label"; fail=1; fi
  }
  check "flock(1) is available" command -v flock
  fill() { mkdir -p "$1/sub"; head -c "$(($2 * 1048576))" /dev/zero > "$1/sub/blob"; : > "$1/.hidden"; }
  kept() { [ -f "$1/sub/blob" ] && [ -f "$1/.hidden" ]; }
  gone() { [ ! -e "$1/sub/blob" ] && [ ! -e "$1/.hidden" ]; }
  HOLD_PIDS=()
  wait_locked() {
    local i=0
    while [ "$i" -lt 100 ]; do
      flock -n -x "$1" true || return 0
      sleep 0.02
      i=$((i + 1))
    done
    return 1
  }
  hold_lock() {
    ( exec 9>"$2"; flock "$1" 9; exec sleep "$3" ) &
    LAST_LOCK_PID=$!
    wait_locked "$2"
  }
  hold_shared() {
    hold_lock -s "$1/.inuse" "$2"
    HOLD_PIDS+=("$LAST_LOCK_PID")
  }
  release_holds() {
    if [ "${#HOLD_PIDS[@]}" -gt 0 ]; then
      kill "${HOLD_PIDS[@]}" 2>/dev/null || true
      wait "${HOLD_PIDS[@]}" 2>/dev/null || true
      HOLD_PIDS=()
    fi
  }

  mkdir -p "$T/stub"
  cat > "$T/stub/rsync" <<'STUB'
#!/usr/bin/env bash
del=0; args=(); for a in "$@"; do case "$a" in --delete) del=1 ;; -*) ;; *) args+=("$a") ;; esac; done
src=${args[0]}; dst=${args[1]}
[ -n "${RSYNC_LOG:-}" ] && echo start >> "$RSYNC_LOG"
[ -n "${RSYNC_SLEEP:-}" ] && sleep "$RSYNC_SLEEP"
mkdir -p "$dst"
if [ "${RSYNC_FAIL:-0}" = 1 ]; then
  echo half > "$dst/partial"; [ -n "${RSYNC_LOG:-}" ] && echo end >> "$RSYNC_LOG"; exit 23
fi
[ $del = 1 ] && find "$dst" -mindepth 1 -delete
cp -a "$src." "$dst"
[ -n "${RSYNC_LOG:-}" ] && echo end >> "$RSYNC_LOG"
exit 0
STUB
  cat > "$T/stub/chown" <<'STUB'
#!/bin/sh
exit 0
STUB
  cat > "$T/stub/runuser" <<'STUB'
#!/bin/sh
i=0
for p in $VOLS; do
  i=$((i+1))
  if flock -n -x "$p/.inuse" true; then echo free > "$PROBE.$i"; else echo held > "$PROBE.$i"; fi
done
sleep 0.05
exit 0
STUB
  chmod +x "$T/stub/"*

  echo "== cache-cap.sh"
  for v in git npm cache pnpm; do fill "$T/cap-$v" 3; done
  hold_shared "$T/cap-git" 1.5; hold_shared "$T/cap-npm" 1.5
  bash "$D/cache-cap.sh" 2 "$T/cap-git" "$T/cap-npm" "$T/cap-cache" "$T/cap-pnpm" > "$T/cap.out" 2>&1
  check "cap: a volume under a shared lock is not emptied (npm)" kept "$T/cap-npm"
  check "cap: the git volume under a shared lock is not emptied" kept "$T/cap-git"
  check "cap: it says it skipped because the volume is in use" grep -qi "in use" "$T/cap.out"
  check "cap: unlocked volumes over the cap are still emptied" gone "$T/cap-cache"
  check "cap: unlocked pnpm volume still emptied" gone "$T/cap-pnpm"
  release_holds
  fill "$T/cap-free" 3
  bash "$D/cache-cap.sh" 2 "$T/cap-free" > /dev/null 2>&1
  check "cap: with nobody holding the lock it still caps" gone "$T/cap-free"
  fill "$T/cap-skip" 3; hold_shared "$T/cap-skip" 1.5
  bash "$D/cache-cap.sh" 2 "$T/cap-skip" > /dev/null 2>&1; rc=$?
  check "cap: skipping a busy volume still exits 0" test "$rc" -eq 0
  check "cap: ...and keeps it" kept "$T/cap-skip"
  release_holds

  echo "== entrypoint.sh"
  E="$T/ep"; mkdir -p "$E/ubin" "$E/opt/runner" "$E/opt/seed" "$E/opt/hostedtoolcache" "$E/pw"
  VOLS=("$E/var/cache/ci-runner/git" "$E/home/runner/.npm" "$E/home/runner/.cache" "$E/home/runner/.local/share/pnpm")
  for v in "${VOLS[@]}"; do mkdir -p "$v"; done
  mkdir -p "${VOLS[0]}/.git"; : > "${VOLS[0]}/.git/config"
  cp "$D/cache-cap.sh" "$D/autolink-node.sh" "$E/ubin/"
  cat > "$E/ubin/scrub-git.sh" <<STUB
#!/bin/sh
if flock -n -x "${VOLS[0]}/.sync" true; then echo free > "$E/scrub.probe"; else echo held > "$E/scrub.probe"; fi
STUB
  chmod +x "$E/ubin/"*
  sed -e "s|/var/cache/ci-runner|$E/var/cache/ci-runner|g" -e "s|/home/runner|$E/home/runner|g" \
      -e "s|/opt/|$E/opt/|g" -e "s|/usr/local/bin|$E/ubin|g" -e "s|/usr/local/lib|$E/ulib|g" \
      "$D/entrypoint.sh" > "$E/entrypoint.sh"
  PATH="$T/stub:$PATH" JITCONFIG=x CI_REPO=o/r PLAYWRIGHT_BROWSERS_PATH="$E/pw" \
    VOLS="${VOLS[*]}" PROBE="$E/probe" bash "$E/entrypoint.sh" > "$E/ep.out" 2>&1
  check "entrypoint: the stubbed runner was reached (harness sanity)" test -f "$E/probe.1"
  n=0
  for v in "${VOLS[@]}"; do
    n=$((n+1))
    check "entrypoint: shared lock held on $(basename "$v") while the runner runs" grep -q held "$E/probe.$n"
    check "entrypoint: lock on $(basename "$v") released at exit" flock -n -x "$v/.inuse" true
  done
  check "entrypoint: git copy-out holds the exclusive .sync lock" grep -q held "$E/scrub.probe"
  check "entrypoint: .sync is free again afterwards" flock -n -x "${VOLS[0]}/.sync" true

  echo "== job-completed.sh sync-back"
  mk_ws() {
    mkdir -p "$T/$1"; git init -q "$T/$1/ws"
    ( cd "$T/$1/ws" && git config user.name t && git config user.email ci-test@example.com && echo x > f && git add f && git commit -q -m i )
  }
  mk_hook() { sed -e "s|/var/cache/ci-runner/git|$1|g" -e "s|/usr/local/bin/scrub-git.sh|true|g" "$D/job-completed.sh" > "$1.hook.sh"; }
  old_volume() { mkdir -p "$1/.git"; echo old-config > "$1/.git/config"; echo keep > "$1/.git/old-marker"; }

  mk_ws fail; V="$T/fail/vol"; old_volume "$V"; mk_hook "$V"
  PATH="$T/stub:$PATH" RSYNC_FAIL=1 GITHUB_WORKSPACE="$T/fail/ws" bash "$V.hook.sh" > /dev/null 2>&1
  check "sync-back: a failed sync keeps the old .git config" test "$(cat "$V/.git/config")" = old-config
  check "sync-back: a failed sync keeps the old .git files" test -f "$V/.git/old-marker"
  check "sync-back: a failed sync leaves no half copy in .git" test ! -e "$V/.git/partial"
  check "sync-back: a failed sync leaves no .git.new behind" test ! -e "$V/.git.new"

  mk_ws ok; V="$T/ok/vol"; old_volume "$V"; mk_hook "$V"
  PATH="$T/stub:$PATH" GITHUB_WORKSPACE="$T/ok/ws" bash "$V.hook.sh" > /dev/null 2>&1
  check "sync-back: success swaps the new copy in" test -d "$V/.git/objects"
  check "sync-back: success drops files the new copy lacks" test ! -e "$V/.git/old-marker"
  check "sync-back: success leaves no .git.new behind" test ! -e "$V/.git.new"
  check "sync-back: .sync is released afterwards" flock -n -x "$V/.sync" true

  mk_ws held; V="$T/held/vol"; old_volume "$V"; mk_hook "$V"
  hold_lock -x "$V/.sync" 1.5
  lock_pid=$LAST_LOCK_PID
  PATH="$T/stub:$PATH" GITHUB_WORKSPACE="$T/held/ws" bash "$V.hook.sh" > /dev/null 2>&1 &
  hp=$!; sleep 0.3
  check "sync-back: waits while .sync is held elsewhere" bash -c "kill -0 $hp 2>/dev/null && test -f '$V/.git/old-marker'"
  kill "$lock_pid" 2>/dev/null || true; wait "$lock_pid" 2>/dev/null || true
  wait "$hp"
  check "sync-back: proceeds once .sync is released" test -d "$V/.git/objects"

  mk_ws ser; V="$T/ser/vol"; old_volume "$V"; mk_hook "$V"
  for n in 1 2; do
    RSYNC_LOG="$T/ser/log" RSYNC_SLEEP=0.4 PATH="$T/stub:$PATH" GITHUB_WORKSPACE="$T/ser/ws" bash "$V.hook.sh" > /dev/null 2>&1 &
  done
  wait
  check "sync-back: two concurrent syncs do not interleave" test "$(tr "\n" " " < "$T/ser/log")" = "start end start end "

  exit "$fail"
)

# ==============================================================================
# Section 4: ETag 304, idle runner skip, stale backoff, circuit breaker, status
# ==============================================================================
section_4() (
  GATE="$here/gate/gate.sh"
  ROOT=$(mktemp -d)
  GPID=""
  cleanup() { stop_gate; rm -rf "$ROOT"; }
  trap cleanup EXIT
  fail=0
  POLLS=0.2

  check() {
    local label=$1; shift
    if "$@"; then printf 'ok    %s\n' "$label"
    else
      printf 'FAIL  %s\n' "$label"
      [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | tail -4 | sed 's/^/        | /'
      fail=1
    fi
  }

  docker() {
    printf 'docker %s\n' "$*" >> "$CALLS"
    case "${1:-}" in
      ps)
        shift
        local filters=() fmt="" name slug slot class ok f
        while [ $# -gt 0 ]; do
          case $1 in
            --filter) filters+=("$2"); shift 2 ;;
            --format) fmt=$2; shift 2 ;;
            --all|--quiet|--no-trunc) shift ;;
            *) printf 'UNEXPECTED docker ps %s\n' "$1" >> "$CALLS"; return 1 ;;
          esac
        done
        while IFS='|' read -r name slug slot class; do
          [ -n "$name" ] || continue
          ok=1
          for f in "${filters[@]+"${filters[@]}"}"; do
            case $f in
              label=ci-runner.gate) ;;
              label=ci-runner.gate=*) [ "${f#label=ci-runner.gate=}" = "$slug" ] || ok=0 ;;
              label=ci-runner.class=*) [ "${f#label=ci-runner.class=}" = "$class" ] || ok=0 ;;
              *) printf 'UNEXPECTED docker ps filter %s\n' "$f" >> "$CALLS"; return 1 ;;
            esac
          done
          [ $ok = 1 ] || continue
          case "$fmt" in
            '{{.Names}}'|'') printf '%s\n' "$name" ;;
            '{{.Label "ci-runner.slot"}}') printf '%s\n' "$slot" ;;
            '{{.Label "ci-runner.class"}}') printf '%s\n' "$class" ;;
            *) printf 'UNEXPECTED docker ps format %s\n' "$fmt" >> "$CALLS"; return 1 ;;
          esac
        done < "$STATE/running"
        ;;
      run)
        shift
        local rname="" rslug="" rslot="" rclass=""
        while [ $# -gt 0 ]; do
          case $1 in
            --detach|--rm|--init) shift ;;
            --name) rname=$2; shift 2 ;;
            --label)
              case $2 in
                ci-runner.gate=*) rslug=${2#*=} ;;
                ci-runner.slot=*) rslot=${2#*=} ;;
                ci-runner.class=*) rclass=${2#*=} ;;
              esac
              shift 2 ;;
            --*) shift 2 ;;
            *) shift ;;
          esac
        done
        printf '%s|%s|%s|%s\n' "$rname" "$rslug" "$rslot" "$rclass" >> "$STATE/running"
        printf 'container-id\n'
        ;;
      rm)
        local last="${*: -1}"
        grep -v "^$last|" "$STATE/running" > "$STATE/running.tmp"; mv "$STATE/running.tmp" "$STATE/running"
        ;;
      *) printf 'UNEXPECTED docker %s\n' "$*" >> "$CALLS"; return 1 ;;
    esac
  }

  sleep() {
    printf 'gate_sleep %s\n' "$1" >> "$CALLS"
    command sleep 0.05
  }

  curl() {
    local url="" method=GET path repo slug id dump_hdr="" write_out="" out_file=""
    local inm="" tok="" has_fail=0 h=""
    while [ $# -gt 0 ]; do
      case $1 in
        --request|-X) method=$2; shift 2 ;;
        --header|-H)
          h=$2
          case "$h" in
            If-None-Match:*|if-none-match:*) inm=${h#*: }; inm=${inm# } ;;
            Authorization:*|authorization:*) tok=${h#Authorization: Bearer }; tok=${tok#authorization: bearer } ;;
          esac
          shift 2 ;;
        --dump-header|-D) dump_hdr=$2; shift 2 ;;
        --write-out|-w) write_out=$2; shift 2 ;;
        --output|-o) out_file=$2; shift 2 ;;
        --data|-d) shift 2 ;;
        --fail) has_fail=1; shift ;;
        -*) shift ;;
        *) url=$1; shift ;;
      esac
    done
    printf 'curl %s %s\n' "$method" "$url" >> "$CALLS"
    path=${url#https://api.github.com}
    [ -n "$inm" ] && printf 'curl-inm %s %s %s\n' "$method" "$path" "$inm" >> "$CALLS"
    [ -n "$tok" ] && printf 'curl-tok %s %s %s\n' "$method" "$path" "$tok" >> "$CALLS"

    local rem=4500 lim=5000 rst=1795640000 code_ovr="" rl_owner rl_file="$STATE/rl"
    rl_owner=$(printf '%s' "$path" | sed -n 's|^/repos/\([^/]*\)/.*|\1|p' | tr '[:upper:]' '[:lower:]')
    [ -n "$rl_owner" ] && [ -s "$STATE/rl.$rl_owner" ] && rl_file="$STATE/rl.$rl_owner"
    if [ -s "$rl_file" ]; then
      IFS='|' read -r rem lim rst code_ovr < "$rl_file"
    fi

    local etag=""
    if [ -s "$STATE/etags" ]; then
      etag=$(awk -F'|' -v p="$path" '$1 == p { print $2; exit }' "$STATE/etags")
    fi

    local code=200 body=""
    if [ -n "$code_ovr" ] && [ "$code_ovr" != "200" ]; then
      code=$code_ovr
      body='{"message":"API rate limit exceeded"}'
    elif [ -n "$etag" ] && [ -n "$inm" ] && [ "$inm" = "$etag" ]; then
      code=304
      body=""
    else
      case "$method $path" in
        "POST /repos/"*"/actions/runners/generate-jitconfig") body='{"encoded_jit_config":"jit"}' ;;
        "GET /repos/"*"/actions/runners")
          repo=${path#/repos/}; repo=${repo%%/actions/*}; slug=$(printf '%s' "$repo" | tr '/' '-')
          if [ -s "$STATE/runners-$slug.json" ]; then body=$(cat "$STATE/runners-$slug.json")
          else body='{"runners":[]}'; fi ;;
        "GET /repos/"*"/actions/runs?status=queued"*)
          repo=${path#/repos/}; repo=${repo%%/actions/*}; slug=$(printf '%s' "$repo" | tr '/' '-')
          if [ -s "$STATE/runs-$slug.json" ]; then body=$(cat "$STATE/runs-$slug.json")
          else body='{"workflow_runs":[]}'; fi ;;
        "GET /repos/"*"/actions/runs/"*"/jobs")
          id=${path%/jobs}; id=${id##*/}
          if [ -s "$STATE/jobs-$id.json" ]; then body=$(cat "$STATE/jobs-$id.json")
          else body='{"jobs":[]}'; fi ;;
        *) printf 'UNEXPECTED curl %s %s\n' "$method" "$path" >> "$CALLS"; return 22 ;;
      esac
    fi

    if [ -n "$dump_hdr" ]; then
      {
        printf 'HTTP/1.1 %s OK\r\n' "$code"
        [ -n "$etag" ] && printf 'ETag: %s\r\n' "$etag"
        printf 'X-RateLimit-Remaining: %s\r\n' "$rem"
        printf 'X-RateLimit-Limit: %s\r\n' "$lim"
        printf 'X-RateLimit-Reset: %s\r\n' "$rst"
        printf '\r\n'
      } > "$dump_hdr"
    fi
    printf 'curl-resp %s %s %s\n' "$code" "$method" "$path" >> "$CALLS"

    if [ "$has_fail" = 1 ] && [ "$code" -ge 400 ]; then
      return 22
    fi

    if [ -n "$out_file" ]; then
      printf '%s\n' "$body" > "$out_file"
      [ -n "$write_out" ] && printf '%s' "$code"
    else
      if [ -n "$write_out" ]; then
        printf '%s\n%s' "$body" "$code"
      else
        [ -n "$body" ] && printf '%s\n' "$body"
      fi
    fi
    return 0
  }
  export -f docker curl sleep

  setup() {
    STATE=$(mktemp -d -p "$ROOT"); CALLS="$STATE/calls"; : > "$CALLS"; : > "$STATE/running"
    mkdir -p "$STATE/limits" "$STATE/work" "$STATE/pat.d"
    printf 'o/r\n' > "$STATE/repos"; printf 'token-1\n' > "$STATE/pat"
    printf 'MemTotal:       20971520 kB\nMemFree:          102400 kB\nMemAvailable:   %d kB\nBuffers: 1 kB\n' $((8192 * 1024)) > "$STATE/meminfo"
    printf '0.50 0.50 0.40 1/300 1234\n' > "$STATE/loadavg"
    LIMITS="$STATE/limits"; EXTRA=(); POLL_USED=$POLLS; OUT=""
    export STATE CALLS
  }
  set_mem() {
    printf 'MemTotal:       20971520 kB\nMemFree:          102400 kB\nMemAvailable:   %d kB\nBuffers: 1 kB\n' $(($1 * 1024)) > "$STATE/meminfo"
  }
  start_gate() {
    env WORK_ROOT="$STATE/work" TOKEN_FILE="$STATE/pat" TOKEN_DIR="$STATE/pat.d" \
      REPOS_FILE="$STATE/repos" PAUSE_FILE="$STATE/paused" BUDGET_FILE="$STATE/budget" \
      MEMINFO_FILE="$STATE/meminfo" LOADAVG_FILE="$STATE/loadavg" LIMITS_DIR="$LIMITS" \
      STATUS_FILE="$STATE/status.json" POLL="$POLL_USED" "${EXTRA[@]+"${EXTRA[@]}"}" \
      timeout -s KILL 40 bash "$GATE" > "$STATE/out" 2>&1 &
    GPID=$!
  }
  stop_gate() {
    local g
    [ -n "$GPID" ] || return 0
    g=$(pgrep -P "$GPID" | head -1)
    if [ -n "$g" ]; then pkill -KILL -P "$g" 2>/dev/null; kill -KILL "$g" 2>/dev/null; fi
    kill -KILL "$GPID" 2>/dev/null
    { wait "$GPID"; } 2>/dev/null
    GPID=""
    [ -f "$STATE/out" ] && OUT=$(cat "$STATE/out")
  }
  passes() { grep -c '^docker ps --all' "$CALLS" || true; }
  wait_passes() {
    local i
    for i in $(seq 1 200); do [ "$(passes)" -ge "$1" ] && return 0; command sleep 0.05; done
    return 1
  }
  wait_status() {
    local i
    for i in $(seq 1 100); do jq -e . "$STATE/status.json" >/dev/null 2>&1 && return 0; command sleep 0.05; done
    return 1
  }
  sj() { jq -e "$1" "$STATE/status.json" >/dev/null 2>&1; }
  call_count() { grep -Ec -- "$1" "$CALLS" || true; }

  echo '== 1. ETag 304 caching preserves W/"..." and re-keys on token rotation'
  setup; set_mem 1000
  printf '/repos/o/r/actions/runs?status=queued&per_page=10|W/"runs-tag-1"\n' > "$STATE/etags"
  printf '/repos/acme/api/actions/runs?status=queued&per_page=10|W/"acme-tag-1"\n' >> "$STATE/etags"
  printf 'o/r\nacme/api\n' > "$STATE/repos"
  printf 'acme-tok-1\n' > "$STATE/pat.d/acme"
  printf '{"workflow_runs":[{"id":101,"run_attempt":1,"name":"CI","head_branch":"main","created_at":"2026-11-25T00:00:00Z"}]}\n' > "$STATE/runs-o-r.json"
  printf '{"jobs":[{"id":1001,"status":"queued","labels":["local-docker"],"created_at":"2026-11-25T00:00:00Z"}]}\n' > "$STATE/jobs-101.json"
  start_gate; wait_passes 3; wait_status
  check 'etag: If-None-Match sends verbatim W/"runs-tag-1"' \
    grep -qF 'curl-inm GET /repos/o/r/actions/runs?status=queued&per_page=10 W/"runs-tag-1"' "$CALLS"
  check 'etag: 304 response occurred and reuses cached queued body' \
    bash -c 'grep -qF "curl-resp 304 GET /repos/o/r/actions/runs?status=queued&per_page=10" "$1"' _ "$CALLS"
  check 'etag: queue keeps the waiting job on 304' \
    sj '(.queue | length) == 1 and .queue[0].repo == "o/r"'
  # Rotate only acme's token; o/r should keep its cached ETag while acme/api drops its old ETag
  check 'etag rotation setup: acme/api sent If-None-Match before rotation' \
    grep -qF 'curl-inm GET /repos/acme/api/actions/runs?status=queued&per_page=10 W/"acme-tag-1"' "$CALLS"
  : > "$CALLS"
  printf 'acme-tok-2\n' > "$STATE/pat.d/acme"
  P=$(passes); wait_passes $((P + 2)); stop_gate
  check 'etag rotation: acme/api clears ETag on token change (first call after rotation has no If-None-Match)' \
    bash -c 'awk "/curl-tok GET \/repos\/acme\/api\/actions\/runs.*acme-tok-2/{if(prev ~ /^curl-inm /) exit 1; seen=1; exit 0} {prev=\$0} END{exit !seen}" "$1"' _ "$CALLS"
  check 'etag scoping: o/r keeps sending its ETag when only acme token rotated' \
    grep -qF 'curl-inm GET /repos/o/r/actions/runs?status=queued&per_page=10 W/"runs-tag-1"' "$CALLS"

  echo '== 2. Idle repos skip /actions/runners between 10-min sweeps'
  setup
  start_gate; wait_passes 5; stop_gate
  check 'idle repo (0 runners, 0 queued): skips /actions/runners on ticks 1..5' \
    test "$(call_count '^curl GET https://api.github.com/repos/o/r/actions/runners$')" -eq 0
  check 'idle repo: still polls /actions/runs?status=queued' \
    test "$(call_count '^curl GET https://api.github.com/repos/o/r/actions/runs\?status=queued')" -ge 5

  setup; printf 'ci-runner-o-r-1-100|o-r|1|big\n' > "$STATE/running"
  start_gate; wait_passes 3; stop_gate
  check 'active repo (running container): polls /actions/runners' \
    test "$(call_count '^curl GET https://api.github.com/repos/o/r/actions/runners$')" -ge 3

  echo '== 3. Stale >1h non-local and 0-job ghost runs back off to RUN_RECHECK_STALE'
  setup
  EXTRA=(RUN_RECHECK=1 RUN_RECHECK_STALE=100)
  YOUNG_TS=$(date -u -d '10 minutes ago' '+%Y-%m-%dT%H:%M:%SZ')
  STALE_TS=$(date -u -d '2 hours ago' '+%Y-%m-%dT%H:%M:%SZ')
  printf '{"workflow_runs":[{"id":201,"run_attempt":1,"name":"young","head_branch":"main","created_at":"%s"},{"id":202,"run_attempt":1,"name":"stale-nonlocal","head_branch":"dep","created_at":"%s"},{"id":203,"run_attempt":1,"name":"stale-ghost","head_branch":"main","created_at":"%s"}]}\n' \
    "$YOUNG_TS" "$STALE_TS" "$STALE_TS" > "$STATE/runs-o-r.json"
  printf '{"jobs":[{"id":2001,"status":"queued","labels":["ubuntu-latest"],"created_at":"%s"}]}\n' "$YOUNG_TS" > "$STATE/jobs-201.json"
  printf '{"jobs":[{"id":2002,"status":"queued","labels":["ubuntu-latest"],"created_at":"%s"}]}\n' "$STALE_TS" > "$STATE/jobs-202.json"
  printf '{"jobs":[]}\n' > "$STATE/jobs-203.json"
  start_gate
  for _ in $(seq 1 60); do
    [ "$(call_count '^curl GET .*/actions/runs/201/jobs$')" -ge 2 ] && break
    command sleep 0.05
  done
  wait_passes $(( $(passes) + 2 ))
  stop_gate
  check 'young <1h non-local run: rechecked at RUN_RECHECK=1 (>= 2 calls)' \
    test "$(call_count '^curl GET .*/actions/runs/201/jobs$')" -ge 2
  check 'stale >1h non-local run: backed off to RUN_RECHECK_STALE (1 call)' \
    test "$(call_count '^curl GET .*/actions/runs/202/jobs$')" -eq 1
  check 'stale >1h 0-job ghost run: backed off to RUN_RECHECK_STALE (1 call)' \
    test "$(call_count '^curl GET .*/actions/runs/203/jobs$')" -eq 1

  setup; set_mem 1000
  EXTRA=(RUN_RECHECK=1 RUN_RECHECK_STALE=100)
  YOUNG_TS=$(date -u -d '10 seconds ago' '+%Y-%m-%dT%H:%M:%SZ')
  STALE_TS=$(date -u -d '2 hours ago' '+%Y-%m-%dT%H:%M:%SZ')
  printf '{"workflow_runs":[{"id":204,"run_attempt":2,"name":"rerun-fresh","head_branch":"main","created_at":"%s","run_started_at":"%s"}]}\n' \
    "$STALE_TS" "$YOUNG_TS" > "$STATE/runs-o-r.json"
  start_gate; wait_passes 1
  printf '{"jobs":[{"id":2004,"status":"queued","labels":["local-docker"],"created_at":"%s"}]}\n' "$YOUNG_TS" > "$STATE/jobs-204.json"
  for _ in $(seq 1 60); do
    [ "$(call_count '^curl GET .*/actions/runs/204/jobs$')" -ge 2 ] && break
    command sleep 0.05
  done
  wait_passes $(( $(passes) + 2 )); wait_status; stop_gate
  check 're-run with old created_at + fresh run_started_at: rechecked at RUN_RECHECK=1 (>= 2 calls)' \
    test "$(call_count '^curl GET .*/actions/runs/204/jobs$')" -ge 2
  check 're-run with old created_at + fresh run_started_at: queued job reaches queue[]' \
    sj 'any(.queue[]; .run_id == 204)'

  echo '== 4. Enriched status.json: queue[], non_local_queued, rate_limit'
  setup; set_mem 1000
  printf '4200|5000|1795640000|200\n' > "$STATE/rl"
  printf '{"workflow_runs":[{"id":301,"run_attempt":1,"name":"CI Build","head_branch":"feat/test","created_at":"2026-11-25T00:00:00Z"},{"id":302,"run_attempt":1,"name":"Dependabot","head_branch":"dependabot/npm","created_at":"2026-11-25T00:01:00Z"},{"id":303,"run_attempt":1,"name":"Ghost","head_branch":"main","created_at":"2026-11-25T00:02:00Z"}]}\n' > "$STATE/runs-o-r.json"
  printf '{"jobs":[{"id":3001,"status":"queued","labels":["local-docker"],"created_at":"2026-11-25T00:00:00Z"}]}\n' > "$STATE/jobs-301.json"
  printf '{"jobs":[{"id":3002,"status":"queued","labels":["ubuntu-latest"],"created_at":"2026-11-25T00:01:00Z"}]}\n' > "$STATE/jobs-302.json"
  printf '{"jobs":[]}\n' > "$STATE/jobs-303.json"
  start_gate; wait_passes 2; wait_status; stop_gate
  check 'status.json: queue item has run_id, name, branch' \
    sj '.queue[0].run_id == 301 and .queue[0].name == "CI Build" and .queue[0].branch == "feat/test"'
  check 'status.json: non_local_queued counts non-local run (1), excludes 0-job ghost' \
    sj '.non_local_queued == 1'
  check 'status.json: rate_limit reports remaining, limit, reset_at, throttled=false' \
    sj '.rate_limit.remaining == 4200 and .rate_limit.limit == 5000 and (.rate_limit.reset_at != null) and .rate_limit.throttled == false'

  echo '== 5. Adaptive poll & rate-limit circuit breaker'
  setup; POLL_USED=20; EXTRA=(POLL_IDLE=30)
  printf '4500|5000|1795640000|200\n' > "$STATE/rl"
  start_gate; wait_passes 2; stop_gate
  check 'adaptive poll: idle (0 runners, 0 queued) sleeps POLL_IDLE=30' \
    grep -q '^gate_sleep 30$' "$CALLS"

  setup; POLL_USED=20; EXTRA=(POLL_IDLE=30); set_mem 1000
  printf '4500|5000|1795640000|200\n' > "$STATE/rl"
  printf '{"workflow_runs":[{"id":401,"run_attempt":1,"name":"CI","head_branch":"main","created_at":"2026-11-25T00:00:00Z"}]}\n' > "$STATE/runs-o-r.json"
  printf '{"jobs":[{"id":4001,"status":"queued","labels":["local-docker"],"created_at":"2026-11-25T00:00:00Z"}]}\n' > "$STATE/jobs-401.json"
  start_gate; wait_passes 2; stop_gate
  check 'adaptive poll: active (queued job) sleeps POLL=20' \
    grep -q '^gate_sleep 20$' "$CALLS"

  setup; POLL_USED=20; EXTRA=(POLL_IDLE=30)
  printf '300|5000|1795640000|200\n' > "$STATE/rl"
  start_gate; wait_passes 2; wait_status; stop_gate
  check 'throttle (150 <= remaining < 500): sleeps max(POLL*3, 60) = 60' \
    grep -q '^gate_sleep 60$' "$CALLS"
  check 'throttle (remaining=300): status.json sets rate_limit.throttled=true' \
    sj '.rate_limit.throttled == true and .rate_limit.remaining == 300'

  setup; POLL_USED=20; EXTRA=(POLL_IDLE=30)
  printf '100|5000|1795640000|200\n' > "$STATE/rl"
  start_gate; wait_passes 2; stop_gate
  check 'throttle (50 <= remaining < 150): sleeps 120' \
    grep -q '^gate_sleep 120$' "$CALLS"

  setup; POLL_USED=20; EXTRA=(POLL_IDLE=30)
  printf 'ci-runner-o-r-1-100|o-r|1|big\n' > "$STATE/running"
  RST=$(($(date +%s) + 60))
  printf '0|5000|%s|403\n' "$RST" > "$STATE/rl"
  start_gate; wait_passes 2; wait_status; stop_gate
  check 'circuit breaker (403 remaining=0): sets throttled=true and does not reap busy runner' \
    sj '.rate_limit.throttled == true and .rate_limit.remaining == 0'
  check 'circuit breaker: no docker rm called' \
    bash -c '! grep -q "^docker rm " "$1"' _ "$CALLS"
  check 'circuit breaker: pauses with sleep between 50 and 300s' \
    bash -c 'awk "/^gate_sleep /{if(\$2 >= 50 && \$2 <= 300) ok=1} END{exit !ok}" "$1"' _ "$CALLS"

  setup; POLL_USED=20; EXTRA=(POLL_IDLE=30)
  printf 'acme/api\no/r\n' > "$STATE/repos"
  printf 'acme-tok-1\n' > "$STATE/pat.d/acme"
  RST=$(($(date +%s) + 180))
  printf '30|5000|%s|200\n' "$RST" > "$STATE/rl.acme"
  printf '4900|5000|%s|200\n' "$RST" > "$STATE/rl"
  start_gate; wait_passes 3; wait_status; stop_gate
  check 'per-scope rate limit: skips exhausted acme scope on later ticks (1 call)' \
    test "$(call_count '^curl GET https://api.github.com/repos/acme/api/actions/runs\?status=queued')" -eq 1
  check 'per-scope rate limit: keeps polling healthy o/r scope (>= 3 calls)' \
    test "$(call_count '^curl GET https://api.github.com/repos/o/r/actions/runs\?status=queued')" -ge 3
  check 'per-scope rate limit: status.json reports exhausted acme scope' \
    sj '.rate_limit.throttled == true and .rate_limit.remaining == 30'

  setup; POLL_USED=20; EXTRA=(POLL_IDLE=30)
  printf 'acme/api\no/r\n' > "$STATE/repos"
  printf 'acme-tok-1\n' > "$STATE/pat.d/acme"
  RST=$(($(date +%s) + 3))
  printf '30|5000|%s|200\n' "$RST" > "$STATE/rl.acme"
  printf '4900|5000|%s|200\n' "$RST" > "$STATE/rl"
  start_gate; wait_passes 2; wait_status
  check 'per-scope recovery: initially skips exhausted acme scope (1 call)' \
    test "$(call_count '^curl GET https://api.github.com/repos/acme/api/actions/runs\?status=queued')" -eq 1
  printf '4900|5000|%s|200\n' "$(($(date +%s) + 180))" > "$STATE/rl.acme"
  while [ "$(date +%s)" -lt "$((RST + 6))" ]; do command sleep 0.5; done
  wait_passes $(( $(passes) + 2 )); wait_status; stop_gate
  check 'per-scope recovery: probes acme again after reset + margin (>= 2 calls)' \
    test "$(call_count '^curl GET https://api.github.com/repos/acme/api/actions/runs\?status=queued')" -ge 2
  check 'per-scope recovery: status.json reports throttled=false after recovery' \
    sj '.rate_limit.throttled == false and .rate_limit.remaining == 4900'

  exit "$fail"
)

run_sections_parallel section_1 section_2 section_3 section_4
exit $?
