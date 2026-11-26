#!/usr/bin/env bash
# Consolidated CLI, status/redeploy/cache, doctor/adopt report, and unlock --wait
# tests for ci-runner (upstream issue).
# Consolidates:
#   - test-ci-runner-cli.sh
#   - test-ci-runner-status.sh
#   - test-ci-runner-report.sh
#   - test-ci-runner-unlock-wait.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
. "$here/tests/lib-parallel.sh"

# ==============================================================================
# Section 1: ci-runner.sh CLI, unlock --stdin, wrapper, flags, launchd, symlink
# ==============================================================================
section_1() (
  CR="$here/ci-runner.sh"
  ROOT=$(mktemp -d)
  trap 'rm -rf "$ROOT"' EXIT
  fail=0

  check() {
    local label=$1; shift
    if "$@"; then printf 'ok    %s\n' "$label"
    else
      printf 'FAIL  %s\n' "$label"
      [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | tail -3 | sed 's/^/        | /'
      fail=1
    fi
  }
  rc_zero() { [ "$RC" -eq 0 ]; }
  rc_nonzero() { [ "$RC" -ne 0 ]; }
  called() { grep -Eq -- "$1" "$CALLS"; }
  not_called() { ! grep -Eq -- "$1" "$CALLS"; }
  var_set() {
    grep -E -- "^gh variable set $1( |\$)" "$CALLS" | grep -E -- " --repo $2( |\$)" | grep -Eq -- " --body $3( |\$)"
  }
  no_var_set() { ! var_set "$@"; }
  last_gate_run() { grep -E '^docker run .*ci-gate' "$CALLS" | tail -1; }
  gate_has() { last_gate_run | grep -Eq -- " $1( |\$)"; }
  no_budget_write() { ! grep -F '/run/gate/budget' "$CALLS" | grep -vq ' cat /run/gate/budget'; }
  exists_file() { [ -f "$1" ] && [ ! -L "$1" ] && [ -x "$1" ]; }
  no_library() { [ ! -e "$HOME/Library" ]; }
  says_launchd() { printf '%s\n' "$OUT" | grep -qi launchd; }
  file_is() { [ "$(cat "$1" 2>/dev/null)" = "$2" ]; }
  images_present() { : > "$IMAGES_OK"; }

  docker() {
    local a="$*" x interactive=0
    for x in "$@"; do case $x in --interactive|-i) interactive=1 ;; esac; done
    printf 'docker %s\n' "$a" >> "$CALLS"
    if [ $interactive = 1 ]; then
      case "$a" in
        *unlock.sh*) cat > "$UNLOCK_IN" ;;
        *seed.sh*) cat > "$SEED_IN" ;;
        *) cat > /dev/null ;;
      esac
    fi
    case "${1:-}" in
      image) [ -e "$IMAGES_OK" ] ;;
      build) : > "$IMAGES_OK" ;;
      exec) case "$a" in
              *"cat /run/gate/budget"*) echo "99 9" ;;
              *"cat /run/gate/status.json"*) [ -f "$GATE_STATUS_FAKE" ] && cat "$GATE_STATUS_FAKE" ;;
            esac ;;
      inspect) [ -z "${GATE_ENV:-}" ] || printf '%s\n' "$GATE_ENV" ;;
      *) return 0 ;;
    esac
  }
  gh() {
    printf 'gh %s\n' "$*" >> "$CALLS"
    local owner=""
    case "${1:-} ${2:-}" in
      "auth status") return 0 ;;
      "variable set") return 0 ;;
      "variable get") [ -f "$GHREG/var-$3" ] && { cat "$GHREG/var-$3"; return 0; }; return 1 ;;
      "repo list") shift 2; case "${1:-}" in --*|"") ;; *) owner=$1 ;; esac
        cat "$GHREG/${owner:-_}" 2>/dev/null; return 0 ;;
      "api user/orgs") cat "$GHREG/orgs" 2>/dev/null; return 0 ;;
    esac
    case "$*" in
      *actions/runners*) printf '{"runners":[]}\n' ;;
      *releases/latest*) return 1 ;;
      *hanzhad/blocked/contents/.github/workflows/ci.yml*) base64 < "$BLOCKED_YML" | tr -d '\n' ;;
      *hanzhad/blocked/contents/.github/workflows\ --jq*)
        printf '.github/workflows/ci.yml\n' ;;
    esac
    return 0
  }
  export -f docker gh

  fresh() {
    T=$(mktemp -d "$ROOT/t.XXXXXX")
    export HOME="$T/home" CI_RUNNER_STATE_DIR="$T/state" CI_RUNNER_WORK_ROOT="$T/work"
    export CALLS="$T/calls" UNLOCK_IN="$T/unlock.in" SEED_IN="$T/seed.in" IMAGES_OK="$T/images" \
      GHREG="$T/gh" BLOCKED_YML="$T/blocked.yml" GATE_STATUS_FAKE="$T/gate-status.json"
    unset GATE_ENV
    mkdir -p "$HOME" "$GHREG" "$T/elsewhere" "$T/empty"
    : > "$CALLS"
    printf 'hanzhad/demo\n' > "$GHREG/_"
    cat > "$BLOCKED_YML" <<YAML
jobs:
  test:
    runs-on: \${{ vars.CI_RUNNER == '1' && 'local-docker' || 'ubuntu-latest' }}
    services:
      postgres:
        image: postgres:16
YAML
    STDIN_FILE=/dev/null; OUT=""; RC=0
  }
  runx() {
    local dir=$1; shift
    OUT=$(cd "$dir" && "$@" 2>&1 <"$STDIN_FILE"); RC=$?
  }
  cr() { local d=$1; shift; runx "$d" bash "$CR" "$@"; }
  mkco() { git init -q "$1" && git -C "$1" remote add origin "$2"; }

  unlock_setup() {
    fresh
    printf 'hanzhad/main\nhanzhad/other\n' > "$GHREG/_"
    printf 'acme\n' > "$GHREG/orgs"; printf 'acme/api\nacme/web\n' > "$GHREG/acme"
    STDIN_FILE="$T/tok"
  }
  echo '# unlock --stdin'
  unlock_setup; printf 's3cret-token' > "$STDIN_FILE"
  cr "$T/elsewhere" unlock --stdin
  check 'unlock --stdin exits 0' rc_zero
  check 'unlock --stdin: the token reaches unlock.sh on stdin' file_is "$UNLOCK_IN" s3cret-token
  check 'unlock --stdin: the token is in no argument of any call' not_called 's3cret-token'
  check 'unlock --stdin: GITHUB_REPO is the first repository' called '^docker exec .*GITHUB_REPO=hanzhad/main .*unlock\.sh'
  check 'unlock --stdin: GATE_OWNER is empty' called 'GATE_OWNER= .*unlock\.sh'

  unlock_setup; printf 'org-token' > "$STDIN_FILE"
  cr "$T/elsewhere" unlock --stdin --owner acme
  check 'unlock --owner exits 0' rc_zero
  check 'unlock --owner: the token reaches unlock.sh on stdin' file_is "$UNLOCK_IN" org-token
  check 'unlock --owner: the token is in no argument' not_called 'org-token'
  check 'unlock --owner: GITHUB_REPO is the owner'"'"'s first repository' called 'GITHUB_REPO=acme/api .*unlock\.sh'
  check 'unlock --owner: GATE_OWNER is the owner' called 'GATE_OWNER=acme .*unlock\.sh'

  unlock_setup; printf 'tok' > "$STDIN_FILE"
  cr "$T/elsewhere" unlock --stdin --owner nobody
  check 'unlock --owner with no repository in the registry is refused' rc_nonzero
  check 'unlock --owner refused: unlock.sh is never reached' not_called 'unlock\.sh'

  unlock_setup; : > "$STDIN_FILE"
  cr "$T/elsewhere" unlock --stdin
  check 'unlock --stdin with nothing on stdin is refused' rc_nonzero
  check 'unlock --stdin refused: unlock.sh is never reached' not_called 'unlock\.sh'

  echo '# on / off by owner/repo'
  fresh
  cr "$T/empty" on hanzhad/demo
  check 'on owner/repo from a directory with no checkout exits 0' rc_zero
  check 'on owner/repo sets CI_RUNNER=1 on that repository' var_set CI_RUNNER hanzhad/demo 1
  check 'on owner/repo writes the label too' var_set CI_RUNNER_LABEL hanzhad/demo local-docker
  cr "$T/empty" off hanzhad/demo
  check 'off owner/repo exits 0' rc_zero
  check 'off owner/repo sets CI_RUNNER=0 on that repository' var_set CI_RUNNER hanzhad/demo 0

  fresh
  mkco "$T/co" https://github.com/hanzhad/pathrepo.git
  cr "$T/elsewhere" on "$T/co"
  check 'on <checkout path> still works' var_set CI_RUNNER hanzhad/pathrepo 1
  cr "$T/elsewhere" off "$T/co"
  check 'off <checkout path> still works' var_set CI_RUNNER hanzhad/pathrepo 0

  echo '# the wrapper written by install'
  fresh; images_present
  cr "$T/elsewhere" install
  W="$HOME/.local/bin/ci-runner"
  check 'install exits 0' rc_zero
  check 'install writes $HOME/.local/bin/ci-runner as an executable script, not a symlink' exists_file "$W"
  runx "$T/empty" "$W" on hanzhad/demo
  check 'wrapper: on owner/repo from another directory sets CI_RUNNER=1' var_set CI_RUNNER hanzhad/demo 1
  runx "$T/empty" "$W" off hanzhad/demo
  check 'wrapper: off owner/repo sets CI_RUNNER=0' var_set CI_RUNNER hanzhad/demo 0
  runx "$T/empty" "$W" on hanzhad/blocked
  check 'wrapper: workflow-blockers.awk still resolves (a blocked repository is refused)' rc_nonzero
  check 'wrapper: the refusal says the workflows need docker' grep -q 'stays on GitHub' <<<"$OUT"
  check 'wrapper: a blocked repository is not switched' no_var_set CI_RUNNER hanzhad/blocked 1
  : > "$CALLS"
  runx "$T/empty" "$W" build
  build_ctx() { grep '^docker build ' "$CALLS" | awk '{print $NF}' | tr '\n' ' '; }
  check 'wrapper: build context resolves to the real ci-runner and gate directories' \
    test "$(build_ctx)" = "$here $here/gate "
  check 'wrapper: seed.list still resolves' file_is "$SEED_IN" "$(cat "$here/seed.list")"

  fresh; images_present
  ODD="$T/it's here"; mkdir -p "$ODD"; mkdir -p "$ODD/ci-runner" && cp -R "$here"/*.sh "$here"/*.awk "$here"/seed.list "$here"/gate "$ODD/ci-runner/"
  runx "$T/elsewhere" bash "$ODD/ci-runner/ci-runner.sh" install
  runx "$T/empty" "$HOME/.local/bin/ci-runner" on hanzhad/demo
  check 'wrapper: a path with an apostrophe and a space still runs the tool' var_set CI_RUNNER hanzhad/demo 1

  echo '# label after up'
  fresh; images_present
  mkco "$T/co" https://github.com/hanzhad/demo.git
  cr "$T/elsewhere" up --label zzz-box
  check 'up --label exits 0' rc_zero
  check 'no per-repository label file exists' test ! -e "$CI_RUNNER_STATE_DIR/hanzhad-demo/label"
  cr "$T/elsewhere" on "$T/co"
  check 'on writes CI_RUNNER_LABEL from the label up was given' var_set CI_RUNNER_LABEL hanzhad/demo zzz-box
  check 'on writes CI_RUNNER_LABEL_LIGHT as that label plus -light' var_set CI_RUNNER_LABEL_LIGHT hanzhad/demo zzz-box-light

  echo '# up with and without flags'
  fresh; images_present
  cr "$T/elsewhere" install --budget 12 --big-cap 6 --host tshost --defer 45
  check 'install with machine flags exits 0' rc_zero
  : > "$CALLS"
  cr "$T/elsewhere" up
  check 'up with no flags exits 0' rc_zero
  check 'up with no flags: stored budget' gate_has BUDGET=12
  check 'up with no flags: stored big cap' gate_has BIG_CAP=6
  check 'up with no flags: stored host' gate_has HOST_TAG=tshost
  check 'up with no flags: stored defer' gate_has DEFER=45

  : > "$CALLS"
  cr "$T/elsewhere" up --budget 20 --big-cap 10 --host other --defer 5
  check 'up with flags: the command line wins for budget' gate_has BUDGET=20
  check 'up with flags: the command line wins for big cap' gate_has BIG_CAP=10
  check 'up with flags: the command line wins for host' gate_has HOST_TAG=other
  check 'up with flags: the command line wins for defer' gate_has DEFER=5
  : > "$CALLS"
  cr "$T/elsewhere" up --budget 20
  check 'up with one flag: that flag wins' gate_has BUDGET=20
  check 'up with one flag: the rest stay stored' gate_has HOST_TAG=tshost
  : > "$CALLS"
  cr "$T/elsewhere" up
  check 'a flag given to one up does not change what is stored (budget)' gate_has BUDGET=12
  check 'a flag given to one up does not change what is stored (host)' gate_has HOST_TAG=tshost

  echo '# up mounts the machine limits directory read-only'
  fresh; images_present
  cr "$T/elsewhere" up
  check 'up exits 0' rc_zero
  check 'up creates $HOME/.config/machine-limits' test -d "$HOME/.config/machine-limits"
  check 'up mounts it read-only at /etc/machine-limits, as a directory' \
    bash -c 'grep -E "^docker run .*ci-gate" "$1" | tail -1 | grep -Fq -- "--volume $2/.config/machine-limits:/etc/machine-limits:ro"' _ "$CALLS" "$HOME"
  check 'up: the gate keeps its credential tmpfs' \
    bash -c 'grep -E "^docker run .*ci-gate" "$1" | tail -1 | grep -Fq -- " --tmpfs /run/gate:rw,noexec,nosuid,mode=0700 "' _ "$CALLS"
  check 'up: the limits volume and the tmpfs are separate arguments, no stray positional between them' \
    bash -c 'grep -E "^docker run .*ci-gate" "$1" | tail -1 | grep -Fq -- "/etc/machine-limits:ro --tmpfs /run/gate:"' _ "$CALLS"
  check 'up: the last argument of the gate run is exactly the gate image' \
    bash -c '[ "$(grep -E "^docker run .*ci-gate" "$1" | tail -1 | awk "{print \$NF}")" = ci-gate:local ]' _ "$CALLS"
  check 'up: labels the gate container with com.docker.compose.project=0-ci' \
    gate_has '--label com.docker.compose.project=0-ci'
  check 'up: does not use legacy com.docker.compose.project=ci-runner' \
    bash -c '! grep -E "^docker run .*ci-gate" "$1" | tail -1 | grep -Fq -- "com.docker.compose.project=ci-runner"' _ "$CALLS"
  check 'up: keeps the ci-gate container name unchanged' \
    gate_has '--name ci-gate'
  check 'up: keeps com.docker.compose.service=gate' \
    gate_has '--label com.docker.compose.service=gate'
  check 'up creates no work folder' test ! -e "$CI_RUNNER_WORK_ROOT"
  check 'up passes the gate no WORK_ROOT' \
    bash -c '! grep -E "^docker run .*ci-gate" "$1" | tail -1 | grep -q WORK_ROOT' _ "$CALLS"

  echo '# install and the live gate'
  fresh; images_present
  cr "$T/elsewhere" install --budget 12 --big-cap 6 --host tshost --defer 45
  check 'install (images built) exits 0' rc_zero
  check 'install (images built) does not write the live budget' no_budget_write
  check 'install (images built) does not stop, remove or restart a gate' not_called '^docker (stop|rm|restart|kill) '
  check 'install (images built) does not start a gate' not_called '^docker run .*ci-gate'
  check 'install (images built) does not rebuild the images' not_called '^docker build '
  check 'install (images built) seeds' called '^docker run .*seed\.sh'

  fresh
  cr "$T/elsewhere" install --budget 12 --big-cap 6
  check 'install (images missing) exits 0' rc_zero
  check 'install (images missing) builds both images' test "$(grep -c '^docker build ' "$CALLS")" -eq 2
  check 'install (images missing) does not write the live budget' no_budget_write
  check 'install (images missing) does not start or stop a gate' not_called '^docker (stop|rm|restart|kill) |^docker run .*ci-gate'

  echo '# watch / unwatch without launchd'
  if PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin command -v launchctl >/dev/null 2>&1; then
    echo 'skip  this host has launchd, so there is no absent case to test'
  else
    fresh
    mkco "$T/co" https://github.com/hanzhad/demo.git
    cr "$T/elsewhere" watch "$T/co"
    check 'watch without launchd exits non-zero' rc_nonzero
    check 'watch without launchd names launchd' says_launchd
    check 'watch without launchd writes nothing under $HOME/Library' no_library
    fresh
    mkco "$T/co" https://github.com/hanzhad/demo.git
    cr "$T/elsewhere" unwatch "$T/co"
    check 'unwatch without launchd exits non-zero' rc_nonzero
    check 'unwatch without launchd names launchd' says_launchd
    check 'unwatch without launchd writes nothing under $HOME/Library' no_library
  fi
  echo '# watch / unwatch with a stubbed launchctl'
  fresh
  mkco "$T/co" https://github.com/hanzhad/demo.git
  launchctl() { printf 'launchctl %s\n' "$*" >> "$CALLS"; }
  export -f launchctl
  cr "$T/elsewhere" watch "$T/co"
  check 'watch with launchctl proceeds' rc_zero
  check 'watch with launchctl bootstraps the timer' called '^launchctl bootstrap '
  cr "$T/elsewhere" unwatch "$T/co"
  check 'unwatch with launchctl proceeds' rc_zero
  check 'unwatch with launchctl boots the timer out' called '^launchctl bootout '
  unset -f launchctl

  echo '# purge removes git and pnpm volumes'
  fresh; images_present
  mkco "$T/co" https://github.com/hanzhad/demo.git
  cr "$T/elsewhere" purge "$T/co"
  check 'purge project removes git and pnpm volumes' \
    called '^docker volume rm ci-runner-git-hanzhad-demo ci-runner-npm-hanzhad-demo ci-runner-cache-hanzhad-demo ci-runner-pnpm-hanzhad-demo'

  echo '# mega on / off / status'
  fresh; mkco "$T/co" https://github.com/hanzhad/demo.git
  export GATE_ENV=$(printf 'MEGA_CPUS=14\nMEGA_MEMORY=16384m')
  cr "$T/elsewhere" mega on "$T/co"
  check 'mega on (gate advertises mega) exits 0' rc_zero
  check 'mega on sets CI_RUNNER_LABEL_MEGA=local-docker-mega on the repository' \
    var_set CI_RUNNER_LABEL_MEGA hanzhad/demo local-docker-mega
  unset GATE_ENV

  fresh; mkco "$T/co" https://github.com/hanzhad/demo.git
  cr "$T/elsewhere" mega on "$T/co"
  check 'mega on (gate without mega) exits non-zero' rc_nonzero
  check 'mega on (gate without mega) sets no variable' not_called '^gh variable set CI_RUNNER_LABEL_MEGA'
  check 'mega on (gate without mega) says mega' bash -c 'printf "%s" "$1" | grep -qi mega' _ "$OUT"

  fresh; mkco "$T/co" https://github.com/hanzhad/demo.git
  cr "$T/elsewhere" mega off "$T/co"
  check 'mega off exits 0' rc_zero
  check 'mega off deletes CI_RUNNER_LABEL_MEGA on the repository' \
    called '^gh variable delete CI_RUNNER_LABEL_MEGA( .*)? --repo hanzhad/demo|^gh variable delete .*--repo hanzhad/demo.* CI_RUNNER_LABEL_MEGA'

  fresh; images_present; mkco "$T/co" https://github.com/hanzhad/demo.git
  printf 'local-docker-mega\n' > "$GHREG/var-CI_RUNNER_LABEL_MEGA"
  cr "$T/elsewhere" status "$T/co"
  check 'status with the variable set prints a mega line saying ON' bash -c 'printf "%s\n" "$1" | grep -Eq "^mega .*ON"' _ "$OUT"
  fresh; images_present; mkco "$T/co" https://github.com/hanzhad/demo.git
  cr "$T/elsewhere" status "$T/co"
  check 'status without the variable prints a mega line saying OFF' bash -c 'printf "%s\n" "$1" | grep -Eq "^mega .*OFF"' _ "$OUT"
  fresh; images_present; mkco "$T/co" https://github.com/hanzhad/demo.git
  printf '%s\n' '{"schema":1,"waiting":"draining for mega job hanzhad/demo 5/9: 4/10 cores still in use, 120s","draining":{"repo":"hanzhad/demo","ref":"5/9","since":"2026-11-09T00:00:00Z","seconds":120,"overdue":false}}' > "$GATE_STATUS_FAKE"
  cr "$T/elsewhere" status "$T/co"
  check 'status while holding prints the draining line from status.json' \
    bash -c 'printf "%s\n" "$1" | grep -Eq "draining.*hanzhad/demo.*120s"' _ "$OUT"

  echo '# ci-runner.sh symlink resolution'
  mkdir -p "$T/linkbin"
  ln -sf "$CR" "$T/linkbin/ci-runner"
  same_help() {
    local a b
    a=$("$T/linkbin/ci-runner" help 2>&1); b=$("$CR" help 2>&1)
    [ -n "$a" ] && [ "$a" = "$b" ]
  }
  check 'ci-runner.sh through a symlink prints what the real path prints' same_help

  exit "$fail"
)

# ==============================================================================
# Section 2: status --json, on --json, redeploy, and cache invalidation
# ==============================================================================
section_2() (
  ROOT=$(mktemp -d)
  trap 'rm -rf "$ROOT"' EXIT
  fail=0
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

  check() {
    local label=$1; shift
    if "$@"; then printf 'ok    %s\n' "$label"
    else
      printf 'FAIL  %s\n' "$label"
      [ -n "${SHOW:-}" ] && printf '%s\n' "$SHOW" | tail -3 | sed 's/^/        | /'
      fail=1
    fi
  }
  rc_zero() { [ "$RC" -eq 0 ]; }
  rc_nonzero() { [ "$RC" -ne 0 ]; }
  called() { grep -Eq -- "$1" "$CALLS"; }
  not_called() { ! grep -Eq -- "$1" "$CALLS"; }
  count_of() { grep -Ec -- "$1" "$CALLS" || true; }
  count_is() { [ "$(count_of "$1")" -eq "$2" ]; }
  first_line() { grep -nE -- "$1" "$CALLS" | head -1 | cut -d: -f1; }
  before() {
    local a b; a=$(first_line "$1"); b=$(first_line "$2")
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
  }
  WRITES='^docker (tag|build|stop|rm|run|kill|restart|pull) |^docker exec .* (touch|rm) |tee /run/gate/budget|^schtasks '
  no_writes() { ! grep -Eq -- "$WRITES" "$CALLS"; }
  no_budget_write() { ! grep -F '/run/gate/budget' "$CALLS" | grep -vq ' cat /run/gate/budget'; }
  last_gate_run() { grep -E '^docker run .*ci-gate' "$CALLS" | tail -1; }
  gate_has() { last_gate_run | grep -Eq -- " $1( |\$)"; }
  jqs() { [ -n "$JSON" ] && printf '%s' "$JSON" | jq -e "$1" >/dev/null 2>&1; }
  out_has() { printf '%s\n' "$OUT" | grep -Eq -- "$1"; }
  out_has_i() { printf '%s\n' "$OUT" | grep -Eqi -- "$1"; }

  is_write() {
    case "$*" in
      "tag "*|"build "*|"stop "*|"rm "*|"run "*|"kill "*|"restart "*|"pull "*) return 0 ;;
      "exec ci-gate touch"*|"exec ci-gate rm"*) return 0 ;;
    esac
    return 1
  }
  docker() {
    local a="$*" interactive=0 x
    for x in "$@"; do case $x in --interactive|-i) interactive=1 ;; esac; done
    printf 'docker %s\n' "$a" >> "$CALLS"
    [ $interactive = 1 ] && cat > /dev/null
    if is_write "$@"; then [ -e "$FIRST_WRITE" ] || wc -c < "$OUTF" > "$FIRST_WRITE"; fi
    case "${1:-}" in
      image) [ -e "$IMAGES_OK" ] ;;
      build) [ -e "$FAIL_BUILD" ] && return 1; : > "$IMAGES_OK" ;;
      stop) : > "$STOPPED" ;;
      inspect)
        [ "$GATE_STATE" = absent ] && return 1
        case "$a" in
          *State.Status*) printf '%s\n' "$GATE_STATE" ;;
          *Config.Env*)
            printf 'BUDGET=12\nBIG_CAP=6\nBIG_COST=4\nLITTLE_COST=2\nDEFER=0\nHOST_TAG=box\nGATE_COMMIT=%s\n' "$GATE_COMMIT_ENV"
            [ -n "${GATE_MEGA_CPUS:-}" ] && printf 'MEGA_CPUS=%s\n' "$GATE_MEGA_CPUS" ;;
        esac ;;
      ps)
        case "$a" in *label=ci-runner.gate*) [ -z "$BUSY_NAME" ] || printf '%s\n' "$BUSY_NAME" ;; esac
        return 0 ;;
      exec)
        case "$a" in
          *"sh -c"*pat.d*) printf 'acme (2026-12-02) ' ;;
          *"cat /run/gate/budget"*) [ -z "$LIVE_BUDGET" ] || [ -e "$STOPPED" ] || printf '%s\n' "$LIVE_BUDGET" ;;
          *"cat /run/gate/status.json"*) [ -f "$GATE_STATUS" ] && cat "$GATE_STATUS" ;;
          *"cat /run/gate/pat.expiry"*) [ "$GATE_LOCKED" = 0 ] && printf '2026-12-01\n' ;;
          *"test -s /run/gate/pat"*) [ "$GATE_LOCKED" = 0 ] ;;
          *"test -e /run/gate/paused"*) [ -n "$GATE_PAUSED" ] ;;
        esac ;;
      *) return 0 ;;
    esac
  }
  gh() {
    printf 'gh %s\n' "$*" >> "$CALLS"
    local repo slug vname val add_t rem_t
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
        [ "$vname" = CI_RUNNER ] && rm -f "$GHREG/var-$slug"
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
        if [ -f "$GHREG/var-$vname-$slug" ]; then
          cat "$GHREG/var-$vname-$slug"
          return 0
        elif [ "$vname" = CI_RUNNER ] && [ -f "$GHREG/var-$slug" ]; then
          cat "$GHREG/var-$slug"
          return 0
        fi
        return 1 ;;
      "repo view")
        jq -n --arg v "${VIS:-PRIVATE}" --argjson r "${ARCH:-false}" '{visibility:$v, isArchived:$r}'
        return 0 ;;
      "repo edit")
        [ -n "${FAIL_GH_EDIT:-}" ] && return 1
        repo=${3:-}; add_t=""; rem_t=""
        shift 3 2>/dev/null || shift $#
        while [ $# -gt 0 ]; do
          case "$1" in
            --add-topic) add_t=${2:-}; shift 2 ;;
            --remove-topic) rem_t=${2:-}; shift 2 ;;
            *) shift ;;
          esac
        done
        if [ "$add_t" = ci-local ] && [ -n "$repo" ]; then
          touch "$GHREG/_"
          grep -qxF "$repo" "$GHREG/_" || printf '%s\n' "$repo" >> "$GHREG/_"
        fi
        if [ "$rem_t" = ci-local ] && [ -n "$repo" ] && [ -f "$GHREG/_" ]; then
          grep -vxF "$repo" "$GHREG/_" > "$GHREG/_.tmp" || true
          mv "$GHREG/_.tmp" "$GHREG/_"
        fi
        return 0 ;;
      "repo list") cat "$GHREG/_" 2>/dev/null; return 0 ;;
      "api user/orgs") return 0 ;;
      "api user") [ "${3:-}" = --jq ] && [ "${4:-}" = .login ] && printf '%s\n' "${ACCOUNT:-hanzhad}" || jq -n --arg l "${ACCOUNT:-hanzhad}" '{login:$l}'; return 0 ;;
    esac
    case "$*" in
      *actions/runners*--jq*) [ -z "$BUSY_NAME" ] || printf '%s\n' "$BUSY_NAME"; return 0 ;;
      *actions/runners*) printf '{"runners":[{"name":"r1","status":"online","busy":false,"labels":[{"name":"local-docker"}]}]}\n' ;;
      *releases/latest*) return 1 ;;
      *hanzhad/blocked/contents/.github/workflows/ci.yml*) base64 < "$BLOCKED_YML" | tr -d '\n' ;;
      *hanzhad/blocked/contents/.github/workflows\ --jq*) printf '.github/workflows/ci.yml\n' ;;
    esac
    return 0
  }
  sleep() { :; }
  export -f docker gh sleep is_write

  fresh() {
    T=$(mktemp -d "$ROOT/t.XXXXXX")
    export HOME="$T/home" CI_RUNNER_STATE_DIR="$T/state" CI_RUNNER_WORK_ROOT="$T/work"
    export CALLS="$T/calls" IMAGES_OK="$T/images" GHREG="$T/gh" BLOCKED_YML="$T/blocked.yml" \
      GATE_STATUS="$T/gate-status.json" STOPPED="$T/stopped" FAIL_BUILD="$T/fail-build" \
      FIRST_WRITE="$T/first-write" OUTF="$T/out" CI_RUNNER_SCHTASKS="$T/schtasks.exe"
    export GATE_STATE=running GATE_LOCKED=0 GATE_PAUSED="" LIVE_BUDGET="" GATE_COMMIT_ENV=abc1234 BUSY_NAME="" \
      GATE_MEGA_CPUS="" VIS=PRIVATE ARCH=false FAIL_GH_VAR="" FAIL_GH_EDIT="" ACCOUNT=hanzhad
    mkdir -p "$HOME" "$GHREG" "$T/empty" "$T/elsewhere"
    : > "$CALLS"; : > "$OUTF"
    printf 'hanzhad/demo\nhanzhad/other\n' > "$GHREG/_"
    printf '1\n' > "$GHREG/var-hanzhad-demo"
    cat > "$BLOCKED_YML" <<YAML
jobs:
  test:
    runs-on: \${{ vars.CI_RUNNER == '1' && 'local-docker' || 'ubuntu-latest' }}
    services:
      postgres:
        image: postgres:16
    steps:
      - run: docker compose up -d
  e2e:
    runs-on: \${{ vars.CI_RUNNER == '1' && 'local-docker' || 'ubuntu-latest' }}
    container: node:22
YAML
    OUT=""; JSON=""; ERR=""; RC=0; SHOW=""
    CR="$here/ci-runner.sh"
  }
  images_present() { : > "$IMAGES_OK"; }
  gate_status_file() {
    jq -n --argjson l "$1" '{schema:1, ts:"2026-11-05T00:00:00Z", locked:$l, paused:false, repos:["hanzhad/demo"],
      queue:[], busy:0, used:0, budget:12, big_used:0, big_cap:6, class_costs:{big:4,little:2},
      memory_available_mb:8000, memory_floor_mb:2048, load:0.5, load_ceiling:7, waiting:null, commit:"abc1234"}' > "$GATE_STATUS"
  }
  crj() { local d=$1; shift
    JSON=$(cd "$d" && bash "$CR" "$@" 2>"$T/err" </dev/null); RC=$?; ERR=$(cat "$T/err"); SHOW="$JSON"
  }
  crf() { local d=$1; shift
    (cd "$d" && bash "$CR" "$@" > "$OUTF" 2>&1 </dev/null); RC=$?; OUT=$(cat "$OUTF"); SHOW="$OUT"
  }
  mkrepo() {
    R="$T/repo"; mkdir -p "$R"
    cp -R "$here"/*.sh "$here"/*.awk "$here"/*.js "$here"/seed.list "$here"/Dockerfile "$here"/status.schema.json "$here"/gate "$R/"
    git -C "$R" init -q && git -C "$R" add -A && git -C "$R" commit -q -m init
    SHA=$(git -C "$R" rev-parse --short HEAD); CR="$R/ci-runner.sh"
  }
  mk_schtasks() { printf '#!/bin/sh\nprintf "schtasks %%s\n" "$*" >> "$CALLS"\n' > "$CI_RUNNER_SCHTASKS"; chmod +x "$CI_RUNNER_SCHTASKS"; }

  SCHEMA="$here/status.schema.json"
  schema_ok() { jq -e . "$SCHEMA" >/dev/null 2>&1; }
  schema_documented() {
    jq -e '(.description | type == "string" and length > 0) and (.["$schema"] | type == "string")
      and ([.properties[] | .description | type == "string" and length > 0] | all)
      and ([.properties.gate.properties[] | .description | type == "string" and length > 0] | all)' "$SCHEMA" >/dev/null 2>&1
  }
  schema_requires() {
    local where=$1 k; shift
    for k in "$@"; do jq -e --arg k "$k" "$where | index(\$k)" "$SCHEMA" >/dev/null 2>&1 || return 1; done
  }
  has_required() {
    local k
    for k in $(jq -r '.required[]' "$SCHEMA" 2>/dev/null); do jqs "has(\"$k\")" || return 1; done
    for k in $(jq -r '.properties.gate.required[]' "$SCHEMA" 2>/dev/null); do jqs ".gate | has(\"$k\")" || return 1; done
    [ -n "$(jq -r '.required[]' "$SCHEMA" 2>/dev/null)" ]
  }

  echo '# the schema file'
  check 'status.schema.json exists and is valid JSON' schema_ok
  check 'status.schema.json is documented: a description on the schema and on every property' schema_documented
  check 'status.schema.json requires schema, gate, status and repositories' \
    schema_requires '.required' schema gate status repositories
  check 'status.schema.json requires state, locked, paused, commit, token_expires and owner_tokens in gate' \
    schema_requires '.properties.gate.required' state locked paused commit token_expires owner_tokens
  check 'status.schema.json defines enriched queue item fields (run_id, name, branch)' \
    bash -c 'jq -e "(.properties.status.properties.queue.items.properties | has(\"run_id\") and has(\"name\") and has(\"branch\"))" "$1" >/dev/null' _ "$SCHEMA"
  check 'status.schema.json defines non_local_queued as integer' \
    bash -c 'jq -e ".properties.status.properties.non_local_queued.type == \"integer\"" "$1" >/dev/null' _ "$SCHEMA"
  check 'status.schema.json defines rate_limit with remaining, limit, reset_at, throttled' \
    bash -c 'jq -e "(.properties.status.properties.rate_limit.properties | has(\"remaining\") and has(\"limit\") and has(\"reset_at\") and has(\"throttled\"))" "$1" >/dev/null' _ "$SCHEMA"

  echo '# status --json, gate absent'
  fresh; GATE_STATE=absent
  crj "$T/empty" status --json
  check 'gate absent: exits 0' rc_zero
  check 'gate absent: stdout is valid JSON' jqs .
  check 'gate absent: schema is 1' jqs '.schema == 1'
  check 'gate absent: every key the schema requires is there' has_required
  check 'gate absent: gate.state is absent' jqs '.gate.state == "absent"'
  check 'gate absent: status is null' jqs '.status == null'
  check 'gate absent: no owner tokens' jqs '.gate.owner_tokens == []'
  check 'gate absent: the repositories come from the registry' \
    jqs '(.repositories | map(.repo) | sort) == ["hanzhad/demo","hanzhad/other"]'
  check 'gate absent: nothing was written to the gate or the images' no_writes

  echo '# status --json, gate running and locked'
  fresh; GATE_LOCKED=1; gate_status_file true
  crj "$T/empty" status --json
  check 'locked: exits 0' rc_zero
  check 'locked: stdout is valid JSON' jqs .
  check 'locked: every key the schema requires is there' has_required
  check 'locked: gate.state is running and gate.locked is true' jqs '.gate.state == "running" and .gate.locked == true'
  check 'locked: gate.paused is false' jqs '.gate.paused == false'
  check 'locked: there is no token, so no expiry' jqs '.gate.token_expires == null'
  check 'locked: status is the file the gate holds, verbatim' \
    bash -c '[ -n "$1" ] && printf "%s" "$1" | jq -e --slurpfile f "$2" ".status == \$f[0]" >/dev/null' _ "$JSON" "$GATE_STATUS"

  echo '# status --json, gate running and unlocked'
  fresh; gate_status_file false; GATE_PAUSED=1
  crj "$T/empty" status --json
  check 'unlocked: exits 0' rc_zero
  check 'unlocked: stdout is valid JSON' jqs .
  check 'unlocked: every key the schema requires is there' has_required
  check 'unlocked: gate.locked is false, gate.paused is true' jqs '.gate.locked == false and .gate.paused == true'
  check 'unlocked: gate.commit is the commit the gate runs' jqs '.gate.commit == "abc1234"'
  check 'unlocked: token_expires is the expiry' jqs '.gate.token_expires == "2026-12-01"'
  check 'unlocked: owner_tokens lists the owner and its expiry' \
    jqs '.gate.owner_tokens == [{"owner":"acme","expires":"2026-12-02"}]'
  check 'unlocked: status carries the gate file' jqs '.status.schema == 1 and .status.budget == 12'
  check 'unlocked: no token value is read (only expiry files)' not_called 'cat /run/gate/pat( |$)'

  echo '# status --json takes no path, and the human output is unchanged'
  fresh; gate_status_file false
  crj "$T/elsewhere" status --json
  check 'status --json from a directory that is no checkout works' jqs '.schema == 1'
  mkdir -p "$T/co"; git init -q "$T/co"; git -C "$T/co" remote add origin https://github.com/hanzhad/demo.git
  crf "$T/elsewhere" status "$T/co"
  check 'status <path> still exits 0' rc_zero
  check 'status <path> still names the repository' out_has '^repository +hanzhad/demo'
  check 'status <path> still has the gate line' out_has '^gate +running'
  check 'status <path> is not JSON' bash -c '! printf "%s" "$1" | jq -e . >/dev/null 2>&1' _ "$OUT"

  echo '# the cached CI_RUNNER read'
  var_gets() { grep -E '^gh variable get CI_RUNNER( |$)' "$CALLS" | grep -Ec -- "--repo $1( |\$)" || true; }
  gets_are() { [ "$(var_gets "$1")" -eq "$2" ]; }
  cache_files() { find "$CI_RUNNER_STATE_DIR" -type f 2>/dev/null | grep -c . || true; }
  age_cache() { find "$CI_RUNNER_STATE_DIR" -type f -exec touch -d "$1" {} + 2>/dev/null; }
  fresh; gate_status_file false
  crj "$T/empty" status --json
  check 'cache: ci_runner is read from the variable (demo is 1)' jqs '(.repositories[] | select(.repo == "hanzhad/demo") | .ci_runner | tostring) == "1"'
  check 'cache: a gh failure for a repository gives ci_runner null, not a crash' \
    jqs '(.repositories[] | select(.repo == "hanzhad/other") | .ci_runner) == null'
  check 'cache: the first call makes one gh variable get for demo' gets_are hanzhad/demo 1
  check 'cache: something is kept under the state dir' test "$(cache_files)" -gt 0
  crj "$T/empty" status --json
  check 'cache: the second call exits 0 and is still valid JSON' jqs '.schema == 1'
  check 'cache: two calls inside the window make one gh variable get per repository' gets_are hanzhad/demo 1
  check 'cache: the second call gives the same ci_runner' jqs '(.repositories[] | select(.repo == "hanzhad/demo") | .ci_runner | tostring) == "1"'
  age_cache '30 seconds ago'
  crj "$T/empty" status --json
  check 'cache: 30 seconds old is still inside the window' gets_are hanzhad/demo 1
  age_cache '10 minutes ago'
  crj "$T/empty" status --json
  check 'cache: 10 minutes old is still inside the 900s default window' gets_are hanzhad/demo 1
  age_cache '16 minutes ago'
  crj "$T/empty" status --json
  check 'cache: a call past the 900 seconds reads the variable again' gets_are hanzhad/demo 2
  check 'cache: past the window it still gives the value' jqs '(.repositories[] | select(.repo == "hanzhad/demo") | .ci_runner | tostring) == "1"'
  age_cache '2 minutes ago'
  CI_RUNNER_CACHE_TTL=60 crj "$T/empty" status --json
  check 'cache: CI_RUNNER_CACHE_TTL=60 overrides the 900s default' gets_are hanzhad/demo 3

  echo '# on --json'
  fresh
  crj "$T/empty" on hanzhad/blocked --json
  check 'on blocked --json: exits non-zero' rc_nonzero
  check 'on blocked --json: stdout is JSON' jqs .
  check 'on blocked --json: schema 1, the repository, ok false' jqs '.schema == 1 and .repo == "hanzhad/blocked" and .ok == false'
  check 'on blocked --json: every blocker is there, one per entry (3 here, not only the last)' jqs '(.blockers | length) == 3'
  check 'on blocked --json: the services blocker is an entry' jqs '.blockers | any(.[]; type == "string" and test("services"))'
  check 'on blocked --json: the container blocker is an entry' jqs '.blockers | any(.[]; type == "string" and test("container"))'
  check 'on blocked --json: the docker call blocker is an entry' jqs '.blockers | any(.[]; type == "string" and test("calls docker"))'
  check 'on blocked --json: nothing is switched' not_called '^gh variable set CI_RUNNER '

  fresh; crj "$T/empty" on hanzhad/demo --json
  check 'on --json when it works: exits 0' rc_zero
  check 'on --json when it works: stdout is JSON, nothing else on it' jqs .
  check 'on --json when it works: ok true for the repository' jqs '.schema == 1 and .repo == "hanzhad/demo" and .ok == true'
  check 'on --json when it works: the switch is set' called '^gh variable set CI_RUNNER( .*)? --body 1'

  fresh; printf 'hanzhad/demo\nhanzhad/blocked\n' > "$GHREG/_"
  crj "$T/empty" on --all --json
  check 'on --all --json: exits non-zero while one is refused' rc_nonzero
  check 'on --all --json: stdout is JSON with schema 1' jqs '.schema == 1'
  check 'on --all --json: a results entry per repository' jqs '(.results | length) == 2'
  check 'on --all --json: demo is ok' jqs '.results | any(.[]; .repo == "hanzhad/demo" and .ok == true)'
  check 'on --all --json: blocked is not ok and carries its blockers' \
    jqs '.results | any(.[]; .repo == "hanzhad/blocked" and .ok == false and (.blockers | length) == 3)'

  redeploy_setup() {
    fresh; mkrepo; images_present; mk_schtasks
    bash "$CR" install --budget 12 --big-cap 6 --host tshost --defer 45 >/dev/null 2>&1
    : > "$CALLS"; : > "$OUTF"; rm -f "$FIRST_WRITE" "$STOPPED"
  }
  first_write_at() { cat "$FIRST_WRITE" 2>/dev/null || echo -1; }
  warning_at() { grep -ob 'PIN' "$OUTF" | head -1 | cut -d: -f1; }
  warned_before_writing() { local w f; w=$(warning_at); f=$(first_write_at); [ -n "$w" ] && [ "$f" -ge 0 ] && [ "$w" -lt "$f" ]; }
  build_lines() { grep '^docker build ' "$CALLS"; }
  no_runner_build() { ! build_lines | grep -Eq -- "$R/.( |\$)"; }
  in_order() {
    local f=$1 prev=0 n p; shift
    for p in "$@"; do
      n=$(grep -nE -- "$p" "$f" | head -1 | cut -d: -f1)
      [ -n "$n" ] && [ "$n" -gt "$prev" ] || return 1
      prev=$n
    done
  }
  build_has_commit() {
    grep '^docker build ' "$CALLS" | grep -E -- " $R/gate\$" \
      | grep -Eq -- "--build-arg[ =]GATE_COMMIT=$SHA$1( |\$)"
  }

  echo '# redeploy without --yes and no terminal: warns, changes nothing'
  redeploy_setup; LIVE_BUDGET="23 13"
  crf "$T/elsewhere" redeploy
  check 'redeploy without --yes: exits non-zero' rc_nonzero
  check 'redeploy without --yes: the warning names the PIN' out_has 'PIN'
  check 'redeploy without --yes: the warning says the live budget resets' out_has_i 'budget.*reset|reset.*budget'
  check 'redeploy without --yes: it shows the live override (23 cores)' out_has '(^|[^0-9])23([^0-9]|$)'
  check 'redeploy without --yes: it shows the big cap of the override (13)' out_has '(^|[^0-9])13([^0-9]|$)'
  check 'redeploy without --yes: no docker call writes, no pause, no schtasks' no_writes
  check 'redeploy without --yes: /run/gate/paused is not touched' not_called 'paused'
  check 'redeploy without --yes: the budget file is not written' no_budget_write

  redeploy_setup
  crf "$T/elsewhere" redeploy
  check 'redeploy without --yes, no live override: still refuses' rc_nonzero
  check 'redeploy without --yes, no live override: still warns about the PIN' out_has 'PIN'
  check 'redeploy without --yes, no live override: nothing written' no_writes

  echo '# redeploy --yes: the order of the calls'
  redeploy_setup; LIVE_BUDGET="23 13"
  crf "$T/elsewhere" redeploy --yes
  check 'redeploy --yes: exits 0' rc_zero
  check 'redeploy --yes: the gate is paused' called '^docker exec ci-gate touch /run/gate/paused'
  check 'redeploy --yes: the old image is tagged ci-gate:previous' called '^docker tag ci-gate:local ci-gate:previous( |$)'
  check 'redeploy --yes: exactly one docker build' count_is '^docker build ' 1
  check 'redeploy --yes: that build is the gate context' test "$(build_lines | awk '{print $NF}')" = "$R/gate"
  check 'redeploy --yes: it carries GATE_COMMIT=<short sha>' build_has_commit ''
  check 'redeploy --yes: there is no build of the runner context' no_runner_build
  check 'redeploy --yes: no latest-release lookup' not_called 'releases/latest'
  check 'redeploy --yes: no docker pull' not_called '^docker pull '
  check 'redeploy --yes: the runner image is neither tagged nor removed' not_called '^docker (tag|rmi|image rm) .*ci-runner:local( |$)'
  check 'redeploy --yes: nothing writes /run/gate/budget' no_budget_write
  check 'redeploy --yes: the gate is stopped' called '^docker stop ci-gate( |$)'
  check 'redeploy --yes: the gate is started again from ci-gate:local' called '^docker run .*ci-gate:local$'
  check 'redeploy --yes: pause, then tag, then build, then stop, then run' in_order "$CALLS" \
    '^docker exec ci-gate touch /run/gate/paused' '^docker tag ' '^docker build ' '^docker stop ci-gate' '^docker run .*ci-gate'
  check 'redeploy --yes: the new gate gets the stored budget' gate_has BUDGET=12
  check 'redeploy --yes: the new gate gets the stored big cap' gate_has BIG_CAP=6
  check 'redeploy --yes: the new gate gets the stored host' gate_has HOST_TAG=tshost
  check 'redeploy --yes: the new gate gets the stored defer' gate_has DEFER=45
  check 'redeploy --yes: the warning is written before the first write' warned_before_writing
  check 'redeploy --yes: the PIN window is opened through schtasks after the gate is up' in_order "$CALLS" \
    '^docker run .*ci-gate' '^schtasks /Run /TN pin-vault unlock$'
  check 'redeploy --yes: it ends with the line that restores the live override' \
    bash -c 'tail -1 "$1" | grep -Eq -- "budget 23 --big-cap 13"' _ "$OUTF"

  echo '# redeploy --yes without the Windows task runner'
  redeploy_setup; rm -f "$CI_RUNNER_SCHTASKS"
  crf "$T/elsewhere" redeploy --yes
  check 'no schtasks.exe: exits 0' rc_zero
  check 'no schtasks.exe: a note says to run pin-vault unlock' bash -c 'tail -4 "$1" | grep -q "pin-vault unlock"' _ "$OUTF"
  check 'no schtasks.exe: no budget line when there was no override' bash -c '! grep -Eq -- "budget [0-9]+ --big-cap" "$1"' _ "$OUTF"

  echo '# redeploy refuses where there are no stored flags'
  fresh; mkrepo; images_present; mk_schtasks
  crf "$T/elsewhere" redeploy --yes
  check 'no machine/flags: redeploy exits non-zero' rc_nonzero
  check 'no machine/flags: it refuses in words, naming the flags' out_has_i '^✗.*(flags|install)'
  check 'no machine/flags: nothing changed (no pause, tag, build, stop, run)' no_writes

  echo '# a failed drain or build resumes the gate and leaves it running'
  redeploy_setup; BUSY_NAME=ci-runner-hanzhad-demo-1-100
  crf "$T/elsewhere" redeploy --yes
  check 'failed drain: exits non-zero' rc_nonzero
  check 'failed drain: the gate is not stopped' not_called '^docker stop '
  check 'failed drain: nothing is built' not_called '^docker build '
  check 'failed drain: the gate is resumed after the pause' in_order "$CALLS" \
    '^docker exec ci-gate touch /run/gate/paused' '^docker exec ci-gate rm -f /run/gate/paused'
  check 'failed drain: no new gate was started' not_called '^docker run .*ci-gate'
  redeploy_setup; : > "$FAIL_BUILD"
  crf "$T/elsewhere" redeploy --yes
  check 'failed build: exits non-zero' rc_nonzero
  check 'failed build: the gate is not stopped' not_called '^docker stop '
  check 'failed build: no new gate was started' not_called '^docker run .*ci-gate'
  check 'failed build: the gate is resumed after the pause' in_order "$CALLS" \
    '^docker exec ci-gate touch /run/gate/paused' '^docker exec ci-gate rm -f /run/gate/paused'
  check 'failed build: the PIN window is not opened' not_called '^schtasks '

  echo '# build and GATE_COMMIT'
  fresh; mkrepo
  crf "$T/elsewhere" build
  check 'build: exits 0' rc_zero
  check 'build: the gate build carries GATE_COMMIT=<short sha>' build_has_commit ''
  fresh; mkrepo; printf '# edited\n' >> "$R/gate/gate.sh"
  crf "$T/elsewhere" build
  check 'build with an edited gate: the commit is <sha>-dirty' build_has_commit '-dirty'

  echo '# status --json, gate stopped'
  fresh; GATE_STATE=exited
  crj "$T/empty" status --json
  check 'stopped: exits 0' rc_zero
  check 'stopped: state is exited, locked, paused and commit are null' \
    jqs '.gate.state == "exited" and .gate.locked == null and .gate.paused == null and .gate.commit == null'
  check 'stopped: status is null and every required key is there' bash -c '[ -n "$1" ] && printf "%s" "$1" | jq -e ".status == null" >/dev/null' _ "$JSON"
  check 'stopped: nothing was executed inside the gate' not_called '^docker exec '
  schema_nullable() {
    jq -e "$1 | (if type == \"array\" then . else [.] end) | index(\"null\")" "$SCHEMA" >/dev/null 2>&1
  }
  for f in locked paused commit token_expires; do
    check "schema: gate.$f may be null" schema_nullable ".properties.gate.properties.$f.type"
  done
  check 'schema: status may be null' schema_nullable '.properties.status.type'
  check 'schema: ci_runner may be null' schema_nullable '.properties.repositories.items.properties.ci_runner.type'

  echo '# status --json with gh failing'
  fresh; gate_status_file false
  orig_gh=$(declare -f gh)
  gh() { printf 'gh %s\n' "$*" >> "$CALLS"; return 1; }; export -f gh
  crj "$T/empty" status --json
  eval "$orig_gh"; export -f gh
  check 'gh failing: exits 0' rc_zero
  check 'gh failing: still valid JSON with schema 1 and the gate' jqs '.schema == 1 and .gate.state == "running"'
  check 'gh failing: repositories is an empty list' jqs '.repositories == []'
  check 'gh failing: gh auth status is not asked for' not_called '^gh auth status'

  echo '# the registry is cached for 900 seconds'
  repo_lists() { grep -c '^gh repo list ' "$CALLS" || true; }
  fresh; gate_status_file false
  crj "$T/empty" status --json
  check 'registry cache: the first call lists the registry once' test "$(repo_lists)" -eq 1
  crj "$T/empty" status --json
  check 'registry cache: a second call inside the window lists it no more' test "$(repo_lists)" -eq 1
  check 'registry cache: and still gives both repositories' jqs '(.repositories | length) == 2'
  age_cache '10 minutes ago'
  crj "$T/empty" status --json
  check 'registry cache: 10 minutes old is still inside the 900s default window' test "$(repo_lists)" -eq 1
  age_cache '16 minutes ago'
  crj "$T/empty" status --json
  check 'registry cache: past the window it lists again' test "$(repo_lists)" -eq 2
  fresh; gate_status_file false; : > "$GHREG/_"
  crj "$T/empty" status --json; crj "$T/empty" status --json
  check 'registry cache: an empty registry is never kept' test "$(repo_lists)" -eq 2
  no_stray_temp() { [ -z "$(find "$CI_RUNNER_STATE_DIR/cache" -name '*.new*' 2>/dev/null)" ]; }
  check 'registry cache: no temp file is left behind' no_stray_temp

  echo '# redeploy when the new gate will not start'
  redeploy_setup; LIVE_BUDGET="23 13"
  orig_docker=$(declare -f docker)
  eval "real_${orig_docker}"
  docker() {
    case "$*" in "run "*ci-gate:local) printf 'docker %s\n' "$*" >> "$CALLS"; return 1 ;; esac
    real_docker "$@"
  }
  export -f docker real_docker
  crf "$T/elsewhere" redeploy --yes
  eval "$orig_docker"; export -f docker
  check 'gate will not start: exits non-zero' rc_nonzero
  check 'gate will not start: it says the old gate is stopped' out_has_i 'did not start'
  check 'gate will not start: it prints how to go back' out_has 'docker tag ci-gate:previous ci-gate:local'
  check 'gate will not start: and to run up' out_has 'ci-runner.sh up'

  echo '# redeploy keeps a pause it found'
  resumed() { grep -Eq -- '^docker exec ci-gate rm -f /run/gate/paused' "$CALLS"; }
  not_resumed() { ! resumed; }
  last_touch_after_run() {
    local t r
    t=$(grep -nE -- '^docker exec ci-gate touch /run/gate/paused' "$CALLS" | tail -1 | cut -d: -f1)
    r=$(grep -nE -- '^docker run .*ci-gate' "$CALLS" | tail -1 | cut -d: -f1)
    [ -n "$t" ] && [ -n "$r" ] && [ "$t" -gt "$r" ]
  }
  redeploy_setup; GATE_PAUSED=1; : > "$FAIL_BUILD"
  crf "$T/elsewhere" redeploy --yes
  check 'paused before, failed build: exits non-zero' rc_nonzero
  check 'paused before, failed build: the gate is not resumed' not_resumed
  redeploy_setup; GATE_PAUSED=1; BUSY_NAME=ci-runner-hanzhad-demo-1-100
  crf "$T/elsewhere" redeploy --yes
  check 'paused before, failed drain: exits non-zero' rc_nonzero
  check 'paused before, failed drain: the gate is not resumed' not_resumed
  redeploy_setup; : > "$FAIL_BUILD"
  crf "$T/elsewhere" redeploy --yes
  check 'not paused before, failed build: it still resumes' resumed
  redeploy_setup; GATE_PAUSED=1
  crf "$T/elsewhere" redeploy --yes
  check 'paused before, success: exits 0' rc_zero
  check 'paused before, success: the new gate is paused after it is up' last_touch_after_run
  check 'paused before, success: the warning says the pause is kept' out_has_i 'paused.*(stay|kept|keep|again)|(stay|kept|keep).*paus'
  redeploy_setup
  crf "$T/elsewhere" redeploy --yes
  check 'not paused before, success: the new gate is not paused after it is up' bash -c '! grep -Eq "^docker exec ci-gate touch" "$1" || [ "$(grep -cE "^docker exec ci-gate touch" "$1")" -eq 1 ]' _ "$CALLS"

  echo '# cache refresh on on/off and invalidation on adopt/forget'
  mkco() { git init -q "$1" && git -C "$1" remote add origin "$2"; }

  fresh; gate_status_file false; rm -f "$GHREG/var-"*
  printf '0\n' > "$GHREG/var-CI_RUNNER-hanzhad-demo"
  crj "$T/empty" status --json
  check 'cache refresh (on setup): demo cached as 0, other as null' \
    jqs '(.repositories[] | select(.repo == "hanzhad/demo") | .ci_runner) == 0 and (.repositories[] | select(.repo == "hanzhad/other") | .ci_runner) == null'
  crf "$T/elsewhere" on hanzhad/demo
  check 'on (from cached 0): exits 0' rc_zero
  crj "$T/empty" status --json
  check 'on (from cached 0): status --json immediately reflects ci_runner == 1 within 60s' \
    jqs '(.repositories[] | select(.repo == "hanzhad/demo") | .ci_runner) == 1'
  check 'on (from cached 0): no extra gh variable get within 60s' gets_are hanzhad/demo 1
  check 'on (from cached 0): sibling repository ci_runner cache stays null' \
    jqs '(.repositories[] | select(.repo == "hanzhad/other") | .ci_runner) == null'

  crf "$T/elsewhere" on hanzhad/other
  check 'on (from cached null): exits 0' rc_zero
  crj "$T/empty" status --json
  check 'on (from cached null): status --json immediately reflects ci_runner == 1 within 60s' \
    jqs '(.repositories[] | select(.repo == "hanzhad/other") | .ci_runner) == 1'
  check 'on (from cached null): no extra gh variable get within 60s' gets_are hanzhad/other 1

  fresh; gate_status_file false; rm -f "$GHREG/var-"*
  mkco "$T/co" https://github.com/hanzhad/demo.git
  printf '0\n' > "$GHREG/var-CI_RUNNER-hanzhad-demo"
  crj "$T/empty" status --json
  crj "$T/elsewhere" on "$T/co" --json
  check 'on <path> --json: exits 0 and emits ok JSON' jqs '.schema == 1 and .ok == true and .repo == "hanzhad/demo"'
  crj "$T/empty" status --json
  check 'on <path> --json: status --json immediately reflects ci_runner == 1 within 60s' \
    jqs '(.repositories[] | select(.repo == "hanzhad/demo") | .ci_runner) == 1'
  check 'on <path> --json: no extra gh variable get within 60s' gets_are hanzhad/demo 1

  fresh; gate_status_file false; rm -f "$GHREG/var-"*
  printf '1\n' > "$GHREG/var-CI_RUNNER-hanzhad-demo"
  printf '1\n' > "$GHREG/var-CI_RUNNER-hanzhad-other"
  printf 'local-docker-mega\n' > "$GHREG/var-CI_RUNNER_LABEL_MEGA-hanzhad-demo"
  crj "$T/empty" status --json
  check 'off setup: demo cached as 1 with mega local-docker-mega' \
    jqs '(.repositories[] | select(.repo == "hanzhad/demo") | .ci_runner) == 1 and (.repositories[] | select(.repo == "hanzhad/demo") | .mega) == "local-docker-mega"'
  crf "$T/elsewhere" off hanzhad/demo
  check 'off <owner/repo>: exits 0' rc_zero
  crj "$T/empty" status --json
  check 'off <owner/repo>: status --json immediately reflects ci_runner == 0 (integer) within 60s' \
    jqs '(.repositories[] | select(.repo == "hanzhad/demo") | .ci_runner) == 0'
  check 'off <owner/repo>: no extra gh variable get within 60s' gets_are hanzhad/demo 1
  check 'off <owner/repo>: sibling repository ci_runner cache stays 1' \
    jqs '(.repositories[] | select(.repo == "hanzhad/other") | .ci_runner) == 1'
  check 'off <owner/repo>: preserves cached mega value' \
    jqs '(.repositories[] | select(.repo == "hanzhad/demo") | .mega) == "local-docker-mega"'

  fresh; gate_status_file false; rm -f "$GHREG/var-"*
  mkco "$T/co" https://github.com/hanzhad/demo.git
  printf '1\n' > "$GHREG/var-CI_RUNNER-hanzhad-demo"
  crj "$T/empty" status --json
  crf "$T/elsewhere" off "$T/co"
  check 'off <path>: exits 0' rc_zero
  crj "$T/empty" status --json
  check 'off <path>: status --json immediately reflects ci_runner == 0 within 60s' \
    jqs '(.repositories[] | select(.repo == "hanzhad/demo") | .ci_runner) == 0'
  check 'off <path>: no extra gh variable get within 60s' gets_are hanzhad/demo 1

  fresh; gate_status_file false; rm -f "$GHREG/var-"*
  mkco "$T/co" https://github.com/hanzhad/demo.git
  printf '0\n' > "$GHREG/var-CI_RUNNER-hanzhad-demo"
  crj "$T/empty" status --json
  crf "$T/elsewhere" on "$T/co"
  crj "$T/empty" status --json
  check 'round-trip (on from 0): status --json immediately reflects ci_runner == 1 within 60s' \
    jqs '(.repositories[] | select(.repo == "hanzhad/demo") | .ci_runner) == 1'
  crf "$T/elsewhere" off "$T/co"
  crj "$T/empty" status --json
  check 'round-trip (off after on): status --json immediately reflects ci_runner == 0 within 60s' \
    jqs '(.repositories[] | select(.repo == "hanzhad/demo") | .ci_runner) == 0'
  crf "$T/elsewhere" on "$T/co"
  crj "$T/empty" status --json
  check 'round-trip (on after off): status --json immediately reflects ci_runner == 1 within 60s' \
    jqs '(.repositories[] | select(.repo == "hanzhad/demo") | .ci_runner) == 1'
  check 'round-trip on/off/on within 60s still makes one gh variable get' gets_are hanzhad/demo 1

  fresh; gate_status_file false; rm -f "$GHREG/var-"*
  printf 'hanzhad/demo\nhanzhad/blocked\n' > "$GHREG/_"
  printf '0\n' > "$GHREG/var-CI_RUNNER-hanzhad-demo"
  printf '0\n' > "$GHREG/var-CI_RUNNER-hanzhad-blocked"
  crj "$T/empty" status --json
  crf "$T/empty" on --all
  check 'on --all with one blocked repo: exits non-zero' rc_nonzero
  crj "$T/empty" status --json
  check 'on --all (partial): clean repo immediately reflects ci_runner == 1' \
    jqs '(.repositories[] | select(.repo == "hanzhad/demo") | .ci_runner) == 1'
  check 'on --all (partial): blocked repo keeps cached ci_runner == 0' \
    jqs '(.repositories[] | select(.repo == "hanzhad/blocked") | .ci_runner) == 0'

  fresh; gate_status_file false; rm -f "$GHREG/var-"*
  printf '1\n' > "$GHREG/var-CI_RUNNER-hanzhad-demo"
  printf '1\n' > "$GHREG/var-CI_RUNNER-hanzhad-other"
  crj "$T/empty" status --json
  crf "$T/empty" off --all
  check 'off --all: exits 0' rc_zero
  crj "$T/empty" status --json
  check 'off --all: demo immediately reflects ci_runner == 0' \
    jqs '(.repositories[] | select(.repo == "hanzhad/demo") | .ci_runner) == 0'
  check 'off --all: other immediately reflects ci_runner == 0' \
    jqs '(.repositories[] | select(.repo == "hanzhad/other") | .ci_runner) == 0'

  fresh; gate_status_file false; rm -f "$GHREG/var-"*
  printf 'Acme/Api\n' > "$GHREG/_"
  printf '0\n' > "$GHREG/var-CI_RUNNER-acme-api"
  crj "$T/empty" status --json
  crf "$T/elsewhere" on Acme/Api
  crj "$T/empty" status --json
  check 'on (mixed-case slug): status --json immediately reflects ci_runner == 1' \
    jqs '(.repositories[] | select(.repo == "Acme/Api") | .ci_runner) == 1'
  check 'on (mixed-case slug): no extra gh variable get within 60s' gets_are Acme/Api 1

  fresh; gate_status_file false; rm -f "$GHREG/var-"*
  printf 'Acme/Api\n' > "$GHREG/_"
  printf '1\n' > "$GHREG/var-CI_RUNNER-acme-api"
  crj "$T/empty" status --json
  crf "$T/elsewhere" off Acme/Api
  crj "$T/empty" status --json
  check 'off (mixed-case slug): status --json immediately reflects ci_runner == 0' \
    jqs '(.repositories[] | select(.repo == "Acme/Api") | .ci_runner) == 0'
  check 'off (mixed-case slug): no extra gh variable get within 60s' gets_are Acme/Api 1

  fresh; gate_status_file false; rm -f "$GHREG/var-"*
  printf '0\n' > "$GHREG/var-CI_RUNNER-hanzhad-demo"
  crj "$T/empty" status --json
  FAIL_GH_VAR=1
  crf "$T/elsewhere" on hanzhad/demo
  check 'on when gh variable set fails: exits non-zero' rc_nonzero
  FAIL_GH_VAR=""
  crj "$T/empty" status --json
  check 'on when gh variable set fails: cache keeps previous ci_runner == 0' \
    jqs '(.repositories[] | select(.repo == "hanzhad/demo") | .ci_runner) == 0'

  fresh; gate_status_file false; rm -f "$GHREG/var-"*
  printf 'hanzhad/demo\n' > "$GHREG/_"
  printf '1\n' > "$GHREG/var-CI_RUNNER-hanzhad-added"
  crj "$T/empty" status --json
  check 'adopt setup: initial status --json lists only demo' \
    jqs '(.repositories | map(.repo)) == ["hanzhad/demo"]'
  crf "$T/elsewhere" adopt hanzhad/added
  check 'adopt: exits 0' rc_zero
  L=$(repo_lists)
  crj "$T/empty" status --json
  check 'adopt: status --json immediately includes newly adopted repository' \
    jqs '(.repositories | map(.repo) | sort) == ["hanzhad/added","hanzhad/demo"]'
  check 'adopt: newly adopted repository shows its ci_runner value' \
    jqs '(.repositories[] | select(.repo == "hanzhad/added") | .ci_runner) == 1'
  check 'adopt: status --json re-listed the registry once after invalidation' test "$(repo_lists)" -eq $((L + 1))
  crj "$T/empty" status --json
  check 'adopt: subsequent status --json reuses the refreshed registry cache' test "$(repo_lists)" -eq $((L + 1))

  fresh; gate_status_file false; rm -f "$GHREG/var-"*
  printf 'hanzhad/demo\n' > "$GHREG/_"
  crj "$T/empty" status --json
  L=$(repo_lists)
  VIS=PUBLIC
  crf "$T/elsewhere" adopt hanzhad/pub
  VIS=PRIVATE
  check 'adopt public repo: exits non-zero' rc_nonzero
  crj "$T/empty" status --json
  check 'adopt public repo: leaves registry cache intact (no extra repo list)' test "$(repo_lists)" -eq "$L"
  check 'adopt public repo: repositories unchanged' \
    jqs '(.repositories | map(.repo)) == ["hanzhad/demo"]'

  fresh; gate_status_file false; rm -f "$GHREG/var-"*
  mkco "$T/co-other" https://github.com/hanzhad/other.git
  printf 'hanzhad/demo\nhanzhad/other\n' > "$GHREG/_"
  crj "$T/empty" status --json
  check 'forget setup: initial status --json lists both demo and other' \
    jqs '(.repositories | map(.repo) | sort) == ["hanzhad/demo","hanzhad/other"]'
  crf "$T/elsewhere" forget "$T/co-other"
  check 'forget <path>: exits 0' rc_zero
  L=$(repo_lists)
  crj "$T/empty" status --json
  check 'forget <path>: status --json immediately omits forgotten repository' \
    jqs '(.repositories | map(.repo)) == ["hanzhad/demo"]'
  check 'forget <path>: status --json re-listed the registry once after invalidation' test "$(repo_lists)" -eq $((L + 1))
  crj "$T/empty" status --json
  check 'forget <path>: subsequent status --json reuses the refreshed registry cache' test "$(repo_lists)" -eq $((L + 1))

  fresh; gate_status_file false; rm -f "$GHREG/var-"*
  printf 'hanzhad/demo\nhanzhad/other\n' > "$GHREG/_"
  crj "$T/empty" status --json
  crf "$T/elsewhere" forget hanzhad/demo
  check 'forget <owner/repo>: exits 0' rc_zero
  L=$(repo_lists)
  crj "$T/empty" status --json
  check 'forget <owner/repo>: status --json immediately omits forgotten repository' \
    jqs '(.repositories | map(.repo)) == ["hanzhad/other"]'
  check 'forget <owner/repo>: status --json re-listed the registry once after invalidation' test "$(repo_lists)" -eq $((L + 1))

  exit "$fail"
)

# ==============================================================================
# Section 3: doctor / adopt workflow & seed report
# ==============================================================================
section_3() (
  ROOT=$(mktemp -d)
  trap 'rm -rf "$ROOT"' EXIT
  fail=0

  check() {
    local label=$1; shift
    if "$@"; then printf 'ok    %s\n' "$label"
    else
      printf 'FAIL  %s\n' "$label"
      [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | tail -3 | sed 's/^/        | /'
      fail=1
    fi
  }
  rc_zero() { [ "$RC" -eq 0 ]; }
  rc_nonzero() { [ "$RC" -ne 0 ]; }
  called() { grep -Eq -- "$1" "$CALLS"; }
  not_called() { ! grep -Eq -- "$1" "$CALLS"; }
  out_has() { printf '%s\n' "$OUT" | grep -Eq -- "$1"; }
  out_has_f() { printf '%s\n' "$OUT" | grep -Fq -- "$1"; }
  out_lacks() { ! printf '%s\n' "$OUT" | grep -Eq -- "$1"; }
  finding() { local o w; o=$(printf '%s\n' "$OUT" | grep -E '^(!|✗)') || return 1
    for w; do o=$(printf '%s\n' "$o" | grep -Ei -- "$w") || return 1; done; }
  warning() { local o w; o=$(printf '%s\n' "$OUT" | grep -E '^!') || return 1
    for w; do o=$(printf '%s\n' "$o" | grep -Ei -- "$w") || return 1; done; }
  error_line() { local o w; o=$(printf '%s\n' "$OUT" | grep -E '^✗') || return 1
    for w; do o=$(printf '%s\n' "$o" | grep -Ei -- "$w") || return 1; done; }
  no_finding() { ! finding "$@"; }
  no_error_line() { ! error_line "$@"; }
  images_present() { : > "$IMAGES_OK"; }
  gate_up() { mkdir -p "$GATEFS/pat.d"; : > "$GATEFS/up"; echo "99 9" > "$GATEFS/budget"
    echo ghp_FAKEMAINTOKEN0000 > "$GATEFS/pat"; echo '2099-01-01 00:00' > "$GATEFS/pat.expiry"
    echo ghp_FAKEZEDTOKEN1111 > "$GATEFS/pat.d/zed"; echo '2099-01-01 00:00' > "$GATEFS/pat.d/zed.expiry"; }
  gate_owner() { echo "ghp_FAKEOWNERTOKEN_$1" > "$GATEFS/pat.d/$1"; echo '2099-01-01 00:00' > "$GATEFS/pat.d/$1.expiry"; }
  put() { local f="$FIX/$1/$2"; mkdir -p "$(dirname "$f")"; cat > "$f"; }
  no_writes() {
    ! grep -Eq -- '^gh api .*(-X|--method)[ =](PUT|POST|PATCH|DELETE)' "$CALLS" \
    && ! grep -Eq -- '^gh api .* (-f|-F|--field|--raw-field|--input)( |$)' "$CALLS" \
    && ! grep -Eq -- '^gh variable set' "$CALLS" \
    && ! { grep -E '^gh ' "$CALLS" | grep -Evq -- '^gh (auth status|repo (view|edit|list)|api|variable get)'; } \
    && ! { grep -E '^gh repo edit ' "$CALLS" | grep -vq -- '-topic '; }
  }

  loud() { printf 'STUB: unexpected %s\n' "$*" >&2; return 99; }
  docker() {
    local a="$*" x interactive=0
    for x in "$@"; do case $x in --interactive|-i) interactive=1 ;; esac; done
    printf 'docker %s\n' "$a" >> "$CALLS"
    [ $interactive = 1 ] && cat > /dev/null
    case "${1:-}" in
      image) [ -e "$IMAGES_OK" ] ;;
      inspect) case "$a" in
          *State.Status*) [ -e "$GATEFS/up" ] && echo running || return 1 ;;
          *) return 0 ;;
        esac ;;
      exec)
        [ -e "$GATEFS/up" ] || { echo 'Error: No such container: ci-gate' >&2; return 1; }
        shift; while [ $# -gt 0 ] && [ "$1" != ci-gate ]; do shift; done; shift
        case "${1:-}" in
          sh|test|cat|ls) local args=(); for x in "$@"; do args+=("${x//\/run\/gate/$GATEFS}"); done
            "${args[@]}" ;;
          *) loud "docker exec $a" ;;
        esac ;;
      *) return 0 ;;
    esac
  }
  gh_emit() { if [ -n "$JQX" ]; then jq -r "$JQX"; else cat; fi; }
  gh() {
    printf 'gh %s\n' "$*" >> "$CALLS"
    local JQX="" raw=0 method=GET args=("$@") i a p="" owner="" repo="" rest="" f
    for ((i = 0; i < ${#args[@]}; i++)); do
      a=${args[i]}
      case $a in
        --jq|-q) JQX=${args[i+1]:-} ;;
        -H|--header) case "${args[i+1]:-}" in *vnd.github.raw*) raw=1 ;; esac ;;
        -X|--method) method=${args[i+1]:-} ;;
      esac
    done
    case "${1:-} ${2:-}" in
      "auth status") return 0 ;;
      "variable set") return 0 ;;
      "variable get") return 1 ;;
      "repo edit") return 0 ;;
      "repo view") jq -n --arg v "$VIS" --argjson r "$ARCH" \
          '{visibility:$v, isArchived:$r, defaultBranchRef:{name:"main"}}' | gh_emit; return 0 ;;
      "repo list") shift 2; case "${1:-}" in --*|"") ;; *) owner=$1 ;; esac
        cat "$GHREG/${owner:-_}" 2>/dev/null; return 0 ;;
    esac
    [ "${1:-}" = api ] || { loud "gh $*"; return 99; }
    shift
    while [ $# -gt 0 ]; do
      case $1 in
        --jq|-q|-H|--header|-X|--method|-f|-F|--field|--raw-field|--input|-t) shift 2 ;;
        -*) shift ;;
        *) p=$1; break ;;
      esac
    done
    p=${p#/}; p=${p%%\?*}
    [ "$method" = GET ] || return 0
    case "$p" in
      user/orgs) cat "$GHREG/orgs" 2>/dev/null; return 0 ;;
      user) jq -n --arg l "$ACCOUNT" '{login:$l}' | gh_emit; return 0 ;;
      repos/*/*/actions/runners) printf '{"runners":[]}\n' | gh_emit; return 0 ;;
      repos/*/*/contents/*)
        owner=${p#repos/}; owner=${owner%%/*}; repo=${p#repos/*/}; repo=${repo%%/*}
        rest=${p#repos/*/*/contents/}; f="$FIX/$owner/$repo/$rest"
        if [ -d "$f" ]; then
          (cd "$f" && for e in *; do [ -f "$e" ] && printf '%s\n' "$rest/$e"; done) \
            | jq -R -s 'split("\n") | map(select(length > 0)) | map({name: (split("/") | last), path: ., type: "file"})' | gh_emit
        elif [ -f "$f" ]; then
          if [ $raw = 1 ]; then cat "$f"
          elif [ "$rest" = pnpm-lock.yaml ]; then
            jq -n --arg p "$rest" '{path: $p, content: "", encoding: "none"}' | gh_emit
          else base64 < "$f" | jq -R -s '{content: ., encoding: "base64"}' | gh_emit; fi
        else echo 'gh: Not Found (HTTP 404)' >&2; return 1; fi
        return 0 ;;
      repos/*/*) jq -n '{default_branch: "main"}' | gh_emit; return 0 ;;
      repos/actions/runner/releases/latest|repos/cli/cli/releases/latest|users/*/settings/billing/actions) return 1 ;;
    esac
    loud "gh api $p"; return 99
  }
  export -f loud docker gh_emit gh

  fresh() {
    T=$(mktemp -d "$ROOT/t.XXXXXX")
    export HOME="$T/home" CI_RUNNER_STATE_DIR="$T/state" CI_RUNNER_WORK_ROOT="$T/work"
    export CALLS="$T/calls" IMAGES_OK="$T/images" GHREG="$T/gh" FIX="$T/fix" GATEFS="$T/gate" \
      VIS=PRIVATE ARCH=false ACCOUNT=hanzhad
    mkdir -p "$HOME" "$GHREG" "$FIX" "$GATEFS" "$T/elsewhere" "$T/empty"
    : > "$CALLS"
    cp -R "$here" "$T/tool"
    printf 'node 24.21.0\nplaywright 1.61.1\n' > "$T/tool/seed.list"
    cp "$T/tool/seed.list" "$T/seed.list.orig"
    CR="$T/tool/ci-runner.sh"
    printf 'hanzhad/demo\nacme/api\n' > "$GHREG/_"
    images_present; gate_up
    STDIN_FILE=/dev/null; OUT=""; RC=0
  }
  runx() { local dir=$1; shift; OUT=$(cd "$dir" && "$@" 2>&1 <"$STDIN_FILE"); RC=$?; }
  cr() { local d=$1; shift; runx "$d" bash "$CR" "$@"; }
  mkco() { git init -q "$1" && git -C "$1" remote add origin "$2"; }

  echo '# accepted shapes'
  fresh
  put hanzhad/demo .github/workflows/ok.yml <<'YAML'
name: ok
on: push
jobs:
  alpha_job:
    runs-on: ${{ vars.CI_RUNNER == '1' && (vars.CI_RUNNER_LABEL || 'local-docker') || 'ubuntu-latest' }}
    steps:
      - run: echo hi
  beta_job:
    runs-on: ${{ vars.CI_RUNNER == '1' && (vars.CI_RUNNER_LABEL_LIGHT || 'local-docker-light') || 'ubuntu-24.04' }}
    steps:
      - run: echo hi
YAML
  put hanzhad/demo .github/workflows/reuse.yml <<'YAML'
name: reuse
on: push
jobs:
  epsilon_job:
    runs-on: ${{ vars.CI_RUNNER == '1' && (vars.CI_RUNNER_LABEL || 'x') || 'ubuntu-latest' }}
    steps:
      - run: echo hi
  delta_job:
    uses: ./.github/workflows/ok.yml
YAML
  cr "$T/empty" doctor hanzhad/demo
  check 'doctor owner/repo from a directory with no checkout exits 0 on a clean repository' rc_zero
  for j in alpha_job beta_job delta_job epsilon_job; do
    check "doctor: $j (switch, either fallback, or a reusable call) is not flagged" no_finding "$j"
  done
  cr "$T/empty" adopt hanzhad/demo
  check 'adopt owner/repo exits 0 on a clean repository' rc_zero
  for j in alpha_job beta_job delta_job epsilon_job; do
    check "adopt: $j is not flagged" no_finding "$j"
  done

  echo '# a fixed runs-on'
  fresh
  put hanzhad/demo .github/workflows/pin.yml <<'YAML'
name: pin
on: push
jobs:
  pinned_job:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YAML
  for c in doctor adopt; do
    cr "$T/empty" $c hanzhad/demo
    check "$c: a fixed runs-on is a warning (!) naming the job and file:line" warning pinned_job 'pin\.yml:[0-9]+'
    check "$c: a fixed runs-on is not an error (✗)" no_error_line pinned_job
  done
  cr "$T/empty" doctor hanzhad/demo
  check 'doctor: a workflow that reads no switch at all exits non-zero' rc_nonzero
  check 'doctor: ... and says no workflow reads the switch (✗)' error_line 'no workflow reads'
  okwf_in() { put "$1" .github/workflows/ok.yml <<'YAML'
name: ok
on: push
jobs:
  alpha_job:
    runs-on: ${{ vars.CI_RUNNER == '1' && (vars.CI_RUNNER_LABEL || 'x') || 'ubuntu-latest' }}
    steps:
      - run: echo hi
YAML
  }
  okwf_in hanzhad/demo
  cr "$T/empty" doctor hanzhad/demo
  check 'doctor: warnings only, beside a switched job, exits 0' rc_zero

  echo '# a split workflow'
  fresh
  put hanzhad/demo .github/workflows/split.yml <<'YAML'
name: split
on: push
jobs:
  follows_job:
    runs-on: ${{ vars.CI_RUNNER == '1' && (vars.CI_RUNNER_LABEL || 'x') || 'ubuntu-latest' }}
    steps:
      - run: echo hi
  fixed_job:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YAML
  for c in doctor adopt; do
    cr "$T/empty" $c hanzhad/demo
    check "$c: the job that left a switched workflow is flagged as split, with file:line" finding fixed_job split 'split\.yml:[0-9]+'
    check "$c: the job that follows the switch is not flagged" no_finding follows_job
  done

  echo '# a matrix runs-on'
  fresh
  put hanzhad/demo .github/workflows/mat.yml <<'YAML'
name: mat
on: push
jobs:
  matrix_job:
    strategy:
      matrix:
        os: [ubuntu-latest, ubuntu-24.04]
    runs-on: ${{ matrix.os }}
    steps:
      - run: echo hi
YAML
  for c in doctor adopt; do
    cr "$T/empty" $c hanzhad/demo
    check "$c: runs-on from a matrix is flagged with job and file:line" finding matrix_job 'mat\.yml:[0-9]+'
  done

  echo '# a malformed switch'
  fresh
  put hanzhad/demo .github/workflows/bad.yml <<'YAML'
name: bad
on: push
jobs:
  bad_job:
    runs-on: ${{ vars.CI_RUNNER == '1' && 'pc' || 'ubuntu-latest' }}
    steps:
      - run: echo hi
YAML
  put hanzhad/demo .github/workflows/flagtrue.yml <<'YAML'
name: flagtrue
on: push
jobs:
  true_job:
    runs-on: ${{ vars.CI_RUNNER == 'true' && (vars.CI_RUNNER_LABEL || 'x') || 'ubuntu-latest' }}
    steps:
      - run: echo hi
YAML
  for c in doctor adopt; do
    cr "$T/empty" $c hanzhad/demo
    if [ $c = doctor ]; then check 'doctor exits non-zero on a malformed switch' rc_nonzero
    else check 'adopt exits 0 even with a malformed switch: findings do not fail it' rc_zero; fi
    check "$c: a label with no variable is an error (✗) naming job and file:line" error_line bad_job 'bad\.yml:[0-9]+'
    check "$c: the flag compared with 'true' is an error (✗) naming job and file:line" error_line true_job 'flagtrue\.yml:[0-9]+'
  done

  echo '# docker blockers'
  fresh
  put hanzhad/demo .github/workflows/blk.yml <<'YAML'
name: blk
on: push
jobs:
  db_job:
    runs-on: ${{ vars.CI_RUNNER == '1' && (vars.CI_RUNNER_LABEL || 'x') || 'ubuntu-latest' }}
    services:
      postgres:
        image: postgres:16
YAML
  for c in doctor adopt; do
    cr "$T/empty" $c hanzhad/demo
    check "$c: the docker blocker appears in the report with file:line" out_has 'blk\.yml:[0-9]+: services: needs docker'
  done

  node_wf() {
    { cat <<'YAML'
name: node
on: push
jobs:
  node_job:
    runs-on: ${{ vars.CI_RUNNER == '1' && (vars.CI_RUNNER_LABEL || 'x') || 'ubuntu-latest' }}
    steps:
      - uses: actions/setup-node@v4
        with:
YAML
      sed 's/^/          /'; } | put "$2" ".github/workflows/$1.yml"
  }
  echo '# node versions'
  fresh
  echo 'node-version: 22' | node_wf old hanzhad/demo
  for c in doctor adopt; do
    cr "$T/empty" $c hanzhad/demo
    check "$c: node-version 22 is reported with the seeded 24.21.0" finding node '\<22\>' '24\.21\.0'
  done
  fresh
  printf 'node-version: 24\n' | node_wf new hanzhad/demo
  for c in doctor adopt; do
    cr "$T/empty" $c hanzhad/demo
    check "$c: node-version 24 matches any seeded 24.x and is clean" no_finding node
  done
  fresh
  echo "node-version-file: '.nvmrc'" | node_wf nvm hanzhad/demo
  echo 22 | put hanzhad/demo .nvmrc
  for c in doctor adopt; do
    cr "$T/empty" $c hanzhad/demo
    check "$c: node-version-file is read from the default branch (.nvmrc 22 is reported)" finding node '\<22\>' '24\.21\.0'
  done
  echo 24 | put hanzhad/demo .nvmrc
  cr "$T/empty" doctor hanzhad/demo
  check 'doctor: .nvmrc 24 is clean' no_finding node

  echo '# playwright version'
  pw_wf() { put hanzhad/demo .github/workflows/pw.yml <<'YAML'
name: pw
on: push
jobs:
  pw_job:
    runs-on: ${{ vars.CI_RUNNER == '1' && (vars.CI_RUNNER_LABEL || 'x') || 'ubuntu-latest' }}
    steps:
      - run: pnpm exec playwright install chromium --with-deps
YAML
  }
  lock() { put hanzhad/demo pnpm-lock.yaml <<YAML
lockfileVersion: '9.0'
packages:
  playwright-core@$1:
    resolution: {integrity: sha512-aaa}
  playwright@$1:
    resolution: {integrity: sha512-bbb}
YAML
  }
  fresh; pw_wf; lock 1.64.1
  for c in doctor adopt; do
    cr "$T/empty" $c hanzhad/demo
    check "$c: playwright-core 1.64.1 in the lockfile is reported with the seeded 1.61.1" finding playwright '1\.64\.1' '1\.61\.1'
  done
  cr "$T/empty" doctor hanzhad/demo
  check 'doctor: an unseeded version never edits seed.list' cmp -s "$T/tool/seed.list" "$T/seed.list.orig"
  check 'doctor: an unseeded version never runs the seed' not_called 'seed\.sh'
  fresh; pw_wf; lock 1.61.1
  cr "$T/empty" doctor hanzhad/demo
  check 'doctor: the seeded playwright version is clean' no_finding playwright
  fresh; pw_wf
  cr "$T/empty" doctor hanzhad/demo
  check 'doctor: no readable lockfile says the playwright version could not be checked' \
    finding playwright 'could not|cannot|can.t|unable'
  fresh; lock 1.64.1
  put hanzhad/demo .github/workflows/ok.yml <<'YAML'
name: ok
on: push
jobs:
  alpha_job:
    runs-on: ${{ vars.CI_RUNNER == '1' && (vars.CI_RUNNER_LABEL || 'x') || 'ubuntu-latest' }}
    steps:
      - run: echo hi
YAML
  cr "$T/empty" doctor hanzhad/demo
  check 'doctor: no workflow installs playwright, so the lockfile version is not asked about' no_finding playwright

  echo '# a big workflow and repeated references'
  fresh
  { cat <<'YAML'
name: big
on: push
jobs:
  big_job:
    runs-on: ${{ vars.CI_RUNNER == '1' && (vars.CI_RUNNER_LABEL || 'x') || 'ubuntu-latest' }}
    steps:
      - run: pnpm exec playwright install chromium
YAML
    i=0; while [ $i -lt 4000 ]; do echo "      - run: echo padding-padding-padding-padding-padding-$i"; i=$((i + 1)); done; } \
    | put hanzhad/demo .github/workflows/big.yml
  lock 1.64.1
  check 'the big workflow is over 128 KB' test "$(wc -c < "$FIX/hanzhad/demo/.github/workflows/big.yml")" -gt 131072
  cr "$T/empty" doctor hanzhad/demo
  check 'doctor: playwright install near the top of a workflow over 128 KB is still seen' finding playwright '1\.64\.1' '1\.61\.1'

  fresh
  { for n in 1 2 3 4 5 6 7 8 9; do echo "node-version-file: '.nvmrc'"; done; } | node_wf many hanzhad/demo
  echo 22 | put hanzhad/demo .nvmrc
  cr "$T/empty" doctor hanzhad/demo
  check 'doctor: nine references to one .nvmrc make one read' test "$(grep -c 'contents/\.nvmrc' "$CALLS")" -eq 1
  check 'doctor: nine references to one .nvmrc make one line' test "$(printf '%s\n' "$OUT" | grep -E '^(!|✗)' | grep -c '\<22\>')" -eq 1

  echo '# owner token'
  okwf() { put "$1" .github/workflows/ok.yml <<'YAML'
name: ok
on: push
jobs:
  alpha_job:
    runs-on: ${{ vars.CI_RUNNER == '1' && (vars.CI_RUNNER_LABEL || 'x') || 'ubuntu-latest' }}
    steps:
      - run: echo hi
YAML
  }
  fresh; okwf acme/api
  for c in doctor adopt; do
    cr "$T/empty" $c acme/api
    check "$c: no token for the owner names the owner and unlock --owner" finding acme 'unlock --owner acme'
    check "$c: no token value appears in the output" out_lacks 'ghp_'
    check "$c: no token value appears in any call" not_called 'ghp_'
  done
  fresh; okwf acme/api; gate_owner acme
  for c in doctor adopt; do
    cr "$T/empty" $c acme/api
    check "$c: an owner token present is clean" out_lacks 'unlock --owner'
    check "$c: an owner token present: no token value in the output" out_lacks 'ghp_'
  done
  fresh; okwf Acme/api; gate_owner acme
  for c in doctor adopt; do
    cr "$T/empty" $c Acme/api
    check "$c: the token file is the lower-cased owner, as unlock and the gate name it" out_lacks 'unlock --owner'
  done
  fresh; okwf acme/api; rm -f "$GATEFS/up"
  for c in doctor adopt; do
    cr "$T/empty" $c acme/api
    check "$c: gate down says it cannot tell about the owner token" finding acme '(cannot|can.t|could not) tell'
    check "$c: gate down: no token value in the output" out_lacks 'ghp_'
  done
  fresh; okwf hanzhad/demo
  for c in doctor adopt; do
    cr "$T/empty" $c hanzhad/demo
    check "$c: the account's own repository needs no owner token" out_lacks 'unlock --owner'
  done

  echo '# lines to paste'
  fresh; okwf hanzhad/demo
  runx "$T/elsewhere" bash "$CR" up --label zzz-box
  for c in doctor adopt; do
    cr "$T/empty" $c hanzhad/demo
    check "$c: the big runs-on line for the machine label" \
      out_has_f "vars.CI_RUNNER == '1' && (vars.CI_RUNNER_LABEL || 'zzz-box') ||"
    check "$c: the light runs-on line for the machine label" \
      out_has_f "(vars.CI_RUNNER_LABEL_LIGHT || 'zzz-box-light') ||"
    check "$c: the command that switches the repository" out_has 'ci-runner(\.sh)? on hanzhad/demo'
  done

  echo '# adopt writes nothing but the topic'
  fresh
  put hanzhad/demo .github/workflows/pin.yml <<'YAML'
name: pin
on: push
jobs:
  pinned_job:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YAML
  cr "$T/empty" adopt hanzhad/demo
  check 'adopt: names the job that is off the switch' warning pinned_job
  check 'adopt: still adds the topic' called '^gh repo edit hanzhad/demo .*--add-topic ci-local'
  check 'adopt: reads the workflows through gh api' called '^gh api .*contents'
  check 'adopt: no variable, no contents write, no write besides the topic edit' no_writes

  echo '# adopt refusals'
  fresh; VIS=PUBLIC
  cr "$T/empty" adopt hanzhad/demo
  check 'adopt of a public repository is refused' rc_nonzero
  check 'adopt of a public repository adds no topic' not_called '^gh repo edit'
  fresh; ARCH=true
  cr "$T/empty" adopt hanzhad/demo
  check 'adopt of an archived repository is refused' rc_nonzero
  check 'adopt of an archived repository adds no topic' not_called '^gh repo edit'

  echo '# checkout path'
  fresh
  mkco "$T/co" https://github.com/hanzhad/demo.git
  mkdir -p "$T/co/.github/workflows"
  cat > "$T/co/.github/workflows/stale.yml" <<'YAML'
jobs:
  stale_job:
    runs-on: ${{ vars.CI_RUNNER == '1' && (vars.CI_RUNNER_LABEL || 'x') || 'ubuntu-latest' }}
YAML
  put hanzhad/demo .github/workflows/pin.yml <<'YAML'
jobs:
  pinned_job:
    runs-on: ubuntu-latest
YAML
  snap() { (cd "$T/co" && find . -path ./.git -prune -o -type f -print | sort | tr '\n' ' '); }
  before=$(snap)
  for c in doctor adopt; do
    cr "$T/elsewhere" $c "$T/co"
    check "$c <checkout path>: the report names a job of the default branch" warning pinned_job
    check "$c <checkout path>: a job only in the checkout is not what is reported" no_finding stale_job
  done
  check 'adopt <checkout path> leaves the checkout as it was' test "$(snap)" = "$before"

  exit "$fail"
)

# ==============================================================================
# Section 4: unlock --stdin --wait background waiter & serialization
# ==============================================================================
section_4() (
  CR="$here/ci-runner.sh"
  ROOT=$(mktemp -d)
  MARK=unlock-wait-$$-$RANDOM
  fail=0

  check() {
    local label=$1; shift
    if "$@"; then printf 'ok    %s\n' "$label"
    else
      printf 'FAIL  %s\n' "$label"
      [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | tail -3 | sed 's/^/        | /'
      fail=1
    fi
  }
  rc_zero() { [ "$RC" -eq 0 ]; }
  rc_nonzero() { [ "$RC" -ne 0 ]; }
  rc_not() { [ "$RC" -ne "$1" ]; }
  elapsed_le() { [ "$ELAPSED" -le "$1" ]; }
  quick_ok() { [ "$RC" -eq 0 ] && [ "$ELAPSED" -le "$1" ]; }
  done_and_gone() { [ "$(unlock_files)" -ge "$1" ] && [ "$(marked)" = 0 ]; }
  called() { grep -Eq -- "$1" "$CALLS"; }
  called_at_least() {
    local c
    c=$(grep -Ec -- "$1" "$CALLS" 2>/dev/null) || true
    [ "${c:-0}" -ge "$2" ]
  }
  not_called() { ! grep -Eq -- "$1" "$CALLS"; }
  out_has() { printf '%s\n' "$OUT" | grep -Eqi -- "$1"; }
  out_lacks() { ! out_has "$1"; }
  unlock_files() { ls "$UNLOCK_IN".* 2>/dev/null | wc -l | tr -d ' '; }
  unlocks_are() { [ "$(unlock_files)" -eq "$1" ]; }
  got_unlocks() { [ "$(unlock_files)" -ge "$1" ]; }
  got_token() {
    local f n=0
    for f in "$UNLOCK_IN".*; do [ -f "$f" ] && printf '%s' "$1" | cmp -s - "$f" && n=$((n + 1)); done
    [ "$n" -eq 1 ]
  }
  marked() {
    local p n=0
    for p in /proc/[0-9]*; do
      grep -qaF -- "CRTEST_MARK=$MARK" "$p/environ" 2>/dev/null && n=$((n + 1))
    done
    echo "$n"
  }
  none_marked() { [ "$(marked)" = 0 ]; }
  some_marked() { [ "$(marked)" -ge 1 ]; }
  reap() {
    local p
    for p in /proc/[0-9]*; do
      grep -qaF -- "CRTEST_MARK=$MARK" "$p/environ" 2>/dev/null && kill -9 "${p#/proc/}" 2>/dev/null
    done
    return 0
  }
  trap 'reap; rm -rf "$ROOT"' EXIT
  detached() {
    local p fd n=0
    for p in /proc/[0-9]*; do
      grep -qaF -- "CRTEST_MARK=$MARK" "$p/environ" 2>/dev/null || continue
      n=$((n + 1))
      for fd in 0 1 2; do
        [ "$(readlink "$p/fd/$fd" 2>/dev/null)" = "$1" ] && return 1
      done
    done
    [ "$n" -ge 1 ]
  }
  wait_until() {
    local n=$(($1 * 20)); shift
    while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.05; n=$((n - 1)); done
    return 1
  }
  sampler_start() {
    : > "$T/sampling"; : > "$T/leaks.log"; : > "$T/seen.log"
    (
      while [ -e "$T/sampling" ]; do
        for p in /proc/[0-9]*; do
          { read -r stat <"$p/stat"; } 2>/dev/null || continue
          case "${stat##*) }" in Z*) continue ;; esac
          grep -qaF -f "$T/pat" "$p/cmdline" "$p/environ" 2>/dev/null \
            && echo "pid ${p#/proc/}: $(tr '\0' ' ' <"$p/cmdline" | cut -c1-100)" >> "$T/leaks.log"
          grep -qaF -- "CRTEST_MARK=$MARK" "$p/environ" 2>/dev/null \
            && echo "pid ${p#/proc/}: $(tr '\0' ' ' <"$p/cmdline" | cut -c1-100)" >> "$T/seen.log"
        done
        sleep 0.05
      done
    ) &
    SAMPLER=$!
  }
  sampler_stop() { rm -f "$T/sampling"; wait "$SAMPLER" 2>/dev/null; return 0; }
  nonempty() { [ -s "$1" ]; }
  empty() { [ ! -s "$1" ]; }
  token_files() { grep -rlaF -- "$1" "$T" 2>/dev/null | grep -v -e '/tok[0-9]*$' -e '/unlock\.in' -e '/pat$'; }
  no_token_files() { [ -z "$(token_files "$1")" ]; }
  log_files() { grep -rlaF -- 'pin-vault unlock gate' "$T" 2>/dev/null; }
  log_exists() { [ -n "$(log_files)" ]; }
  log_has() { local f; for f in $(log_files); do grep -qaEi -- "$1" "$f" && return 0; done; return 1; }
  no_leftovers() { [ -z "$(find "$T/home" "$T/state" -name '*.lock' -o -name '*.pid' -o -name '*.tmp*' -o -name '*.token*' 2>/dev/null)" ]; }

  docker() {
    local a="$*" x interactive=0
    for x in "$@"; do case $x in --interactive|-i) interactive=1 ;; esac; done
    printf 'docker %s\n' "$a" >> "$CALLS"
    { tr '\0' ' ' </proc/$BASHPID/cmdline; echo; tr '\0' '\n' </proc/$BASHPID/environ; } >> "$INSIDE" 2>/dev/null
    if [ ! -e "$DOCKER_UP" ]; then
      [ $interactive = 1 ] && cat > /dev/null
      return 1
    fi
    case "$a" in
      *unlock.sh*)
        echo start >> "$SEQ"
        cat > "$UNLOCK_IN.$RANDOM$RANDOM"
        sleep "${UNLOCK_SLEEP:-0.4}"
        echo end >> "$SEQ"
        [ ! -e "$UNLOCK_FAIL" ]
        return ;;
    esac
    [ $interactive = 1 ] && cat > /dev/null
    case "${1:-}" in
      inspect) echo true ;;
    esac
    return 0
  }
  gh() {
    printf 'gh %s\n' "$*" >> "$CALLS"
    local owner=""
    case "${1:-} ${2:-}" in
      "repo list") shift 2; case "${1:-}" in --*|"") ;; *) owner=$1 ;; esac
        cat "$GHREG/${owner:-_}" 2>/dev/null; return 0 ;;
      "api user/orgs") cat "$GHREG/orgs" 2>/dev/null; return 0 ;;
    esac
    return 0
  }
  pbpaste() { printf 'pbpaste\n' >> "$CALLS"; printf 'clipboard-token-never-wanted'; }
  export -f docker gh pbpaste

  fresh() {
    T=$(mktemp -d "$ROOT/t.XXXXXX")
    export HOME="$T/home" CI_RUNNER_STATE_DIR="$T/state" CI_RUNNER_WORK_ROOT="$T/work"
    export CALLS="$T/calls" UNLOCK_IN="$T/unlock.in" INSIDE="$T/inside.log" SEQ="$T/seq" \
      DOCKER_UP="$T/docker.up" UNLOCK_FAIL="$T/unlock.fail" GHREG="$T/gh"
    mkdir -p "$HOME" "$GHREG" "$T/elsewhere"
    : > "$CALLS"; : > "$INSIDE"; : > "$SEQ"
    printf 'hanzhad/main\nhanzhad/other\n' > "$GHREG/_"
    printf 'acme\n' > "$GHREG/orgs"; printf 'acme/api\n' > "$GHREG/acme"
    TOKEN="wait-secret-$RANDOM$RANDOM-Zq9"; TOKEN2="wait-other-$RANDOM$RANDOM-Xk4"
    printf '%s' "$TOKEN" > "$T/tok"; printf '%s' "$TOKEN2" > "$T/tok2"
    printf '%s\n%s\n' "$TOKEN" "$TOKEN2" > "$T/pat"
    STDIN_FILE="$T/tok"; OUT=""; RC=0; ELAPSED=0
  }
  crw() {
    local t0=$SECONDS
    OUT=$(cd "$T/elsewhere" && CRTEST_MARK=$MARK timeout 25 bash "$CR" "$@" 2>&1 <"$STDIN_FILE"); RC=$?
    ELAPSED=$((SECONDS - t0))
  }
  out_of_our_session() {
    local p sid ours n=0
    ours=$(awk '{print $6}' /proc/$$/stat)
    for p in /proc/[0-9]*; do
      grep -qaF -- "CRTEST_MARK=$MARK" "$p/environ" 2>/dev/null || continue
      n=$((n + 1))
      sid=$(sed 's/.*) //' "$p/stat" | awk '{print $4}')
      [ "$sid" != "$ours" ] || return 1
    done
    [ "$n" -ge 1 ]
  }

  echo '# unlock --stdin --wait: docker down at the start, up later'
  fresh; sampler_start
  TOK=$TOKEN sleep 60 & held=$!
  wait_until 30 nonempty "$T/leaks.log"
  kill "$held" 2>/dev/null; wait "$held" 2>/dev/null || true
  check 'control: the sampler sees a token in a process environment' nonempty "$T/leaks.log"
  : > "$T/leaks.log"
  printf '%s' "$TOKEN" > "$T/home/ctl"
  check 'control: the file search finds a token under the fake home' test -n "$(token_files "$TOKEN")"
  rm -f "$T/home/ctl"
  crw unlock --stdin --wait --timeout 60
  check 'with docker down, --wait exits 0' rc_zero
  check 'with docker down, --wait returns at once (a caller reading its output is not held)' quick_ok 5
  check '--wait does not read the clipboard' not_called '^pbpaste'
  wait_until 15 called_at_least '^docker info' 2
  sleep 0.2
  check 'while docker is down the token reaches nothing' unlocks_are 0
  check 'a background process is waiting' some_marked
  if [ "$RC" -eq 0 ]; then wait_until 30 nonempty "$T/seen.log"; touch "$DOCKER_UP"; wait_until 40 got_unlocks 1; wait_until 15 done_and_gone 1; fi
  check 'once docker is up, unlock.sh gets the token on stdin, exactly once' unlocks_are 1
  check 'unlock.sh got the token exactly, nothing added' got_token "$TOKEN"
  check 'the unlock goes through docker exec --interactive on stdin' called '^docker exec .*--interactive .*unlock[.]sh'
  check 'the background process ends by itself after the unlock' wait_until 15 done_and_gone 1
  sampler_stop
  check 'control: the sampler saw the processes ci-runner started' nonempty "$T/seen.log"
  check 'control: the docker call dumped its own environment' nonempty "$INSIDE"
  check 'the token is in no argument or environment of any process the run started' empty "$T/leaks.log"
  check 'the token is in no argument of any docker or gh call' not_called "$TOKEN"
  check 'the token is in no file under the fake home, state dir or anywhere beside the test inputs' no_token_files "$TOKEN"
  reap

  echo '# unlock --stdin --wait: when it returns, nothing of it is left in the caller'"'"'s session'
  fresh
  crw unlock --stdin --wait --timeout 20
  check 'the moment it returns, the waiter is in a session of its own' out_of_our_session
  reap

  echo '# unlock --stdin --wait --timeout 2, docker never up'
  fresh; sampler_start
  crw unlock --stdin --wait --timeout 2
  check 'a timeout run still exits 0 at once' rc_zero
  check 'a timeout run returns at once' quick_ok 5
  check 'a timeout run exits 0 at once, before the wait is over' quick_ok 5
  check 'nothing is left running (the 2 s wait is over)' wait_until 20 none_marked
  sampler_stop
  check 'the log exists and names pin-vault unlock gate' log_exists
  check 'the log gives the reason' log_has 'timed out|timeout|gave up|giving up|did not (come|answer|start)|not (up|running|answer)'
  check 'no token reached the gate' unlocks_are 0
  check 'the token is dropped: in no file, log included' no_token_files "$TOKEN"
  check 'the token was in no argument or environment' empty "$T/leaks.log"
  check 'nothing is left behind in the state: no lock, pid or temporary file' no_leftovers
  reap

  echo '# unlock --stdin --wait, docker up, unlock.sh refuses'
  fresh; touch "$DOCKER_UP" "$UNLOCK_FAIL"
  crw unlock --stdin --wait --timeout 20
  check 'exits 0 at once even when the unlock will fail' rc_zero
  check 'returns at once' quick_ok 5
  check 'the background process ends by itself after its one attempt' wait_until 20 done_and_gone 1
  wait_until 1 got_unlocks 2 || true
  check 'the failed unlock is tried once, not retried' unlocks_are 1
  check 'the log names pin-vault unlock gate' log_exists
  check 'the token is dropped: in no file, log included' no_token_files "$TOKEN"
  reap

  echo '# unlock --wait without --stdin'
  fresh; mkfifo "$T/hold"; exec 9<>"$T/hold"
  OUT=$(cd "$T/elsewhere" && CRTEST_MARK=$MARK timeout 10 bash "$CR" unlock --wait 2>&1 <&9); RC=$?
  exec 9>&-
  check '--wait without --stdin is refused' rc_nonzero
  check 'refused before anything is read (stdin was open and idle, no hang)' rc_not 124
  check 'the refusal says --wait needs --stdin, not just "unknown flag"' out_has '--stdin'
  check 'the refusal is not the old "unknown flag"' out_lacks 'unknown flag'
  check 'the clipboard is not read either' not_called '^pbpaste'
  check 'unlock.sh is never reached' not_called 'unlock[.]sh'
  check 'no background process was started' none_marked
  reap

  echo '# unlock --stdin, no --wait (as today)'
  fresh
  crw unlock --stdin
  check 'docker down: plain unlock --stdin fails at once' rc_nonzero
  check 'docker down: it did not wait' elapsed_le 5
  check 'docker down: it says Docker is not running' out_has 'docker'
  check 'docker down: nothing reached unlock.sh' unlocks_are 0
  check 'docker down: no background process' none_marked
  fresh; touch "$DOCKER_UP"
  crw unlock --stdin
  check 'docker up: plain unlock --stdin exits 0' rc_zero
  check 'docker up: the unlock is done by the time it returns' unlocks_are 1
  check 'docker up: the token arrives exactly' got_token "$TOKEN"
  check 'docker up: no background process' none_marked

  echo '# the background process is detached from the caller'
  fresh
  t0=$SECONDS
  CRTEST_MARK=$MARK timeout 25 bash "$CR" unlock --stdin --wait --timeout 20 <"$STDIN_FILE" 2>/dev/null | cat >/dev/null
  P1=${PIPESTATUS[0]}; E1=$((SECONDS - t0))
  check 'a reader of stdout gets EOF at once: exit 0' test "$P1" -eq 0
  check 'a reader of stdout gets EOF at once: not held until the wait ends' test "$E1" -le 5
  check 'the background process holds none of the caller stdin, stdout or stderr as the input file' detached "$T/tok"
  reap
  t0=$SECONDS
  CRTEST_MARK=$MARK timeout 25 bash "$CR" unlock --stdin --wait --timeout 20 <"$STDIN_FILE" 2>&1 >/dev/null | cat >/dev/null
  P2=${PIPESTATUS[0]}; E2=$((SECONDS - t0))
  check 'a reader of stderr gets EOF at once: exit 0' test "$P2" -eq 0
  check 'a reader of stderr gets EOF at once: not held until the wait ends' test "$E2" -le 5
  reap

  echo '# two --wait entries, docker comes up'
  fresh
  STDIN_FILE="$T/tok";  crw unlock --stdin --wait --timeout 60; R1=$RC
  STDIN_FILE="$T/tok2"; crw unlock --stdin --wait --owner acme --timeout 60; R2=$RC
  check 'both entries exit 0' test "$R1" -eq 0 -a "$R2" -eq 0
  if [ "$R1" -eq 0 ] && [ "$R2" -eq 0 ]; then touch "$DOCKER_UP"; wait_until 40 got_unlocks 2; wait_until 15 done_and_gone 2; fi
  check 'each token reaches unlock.sh exactly once' unlocks_are 2
  check 'the first token arrives exactly' got_token "$TOKEN"
  check 'the second token arrives exactly' got_token "$TOKEN2"
  check 'the second one is the owner unlock' called 'GATE_OWNER=acme .*unlock[.]sh'
  check 'the two unlocks of unlock.sh run one after the other, never overlapping' test "$(tr '\n' ' ' <"$SEQ")" = 'start end start end '
  check 'both background processes end by themselves' wait_until 15 done_and_gone 2
  check 'neither token is in any file' no_token_files "$TOKEN"
  reap

  echo '# an unlock that outlasts the lock poll keeps the lock'
  seq_started() { grep -q start "$SEQ"; }
  fresh; export UNLOCK_SLEEP=0.8
  STDIN_FILE="$T/tok";  crw unlock --stdin --wait --timeout 60
  STDIN_FILE="$T/tok2"; crw unlock --stdin --wait --owner acme --timeout 60
  touch "$DOCKER_UP"; wait_until 40 got_unlocks 2; wait_until 15 done_and_gone 2
  check 'a live holder is not taken for a dead one' test "$(tr '\n' ' ' <"$SEQ")" = 'start end start end '
  reap

  echo '# a lock left by a dead holder, two entries'
  fresh; export UNLOCK_SLEEP=0.5
  mkdir -p "$CI_RUNNER_STATE_DIR/machine/unlock-wait.lock"
  sleep 0 & dead=$!; wait "$dead"
  printf '%s %s\n' "$dead" 9999999999 > "$CI_RUNNER_STATE_DIR/machine/unlock-wait.lock/holder"
  STDIN_FILE="$T/tok";  crw unlock --stdin --wait --timeout 60
  STDIN_FILE="$T/tok2"; crw unlock --stdin --wait --owner acme --timeout 60
  touch "$DOCKER_UP"; wait_until 40 got_unlocks 2; wait_until 15 done_and_gone 2
  check 'both unlock, one after the other, past the stale lock' test "$(tr '\n' ' ' <"$SEQ")" = 'start end start end '
  check 'the lock is gone after both' test ! -e "$CI_RUNNER_STATE_DIR/machine/unlock-wait.lock"
  reap

  echo '# the holder overran and another took the lock'
  fresh; export UNLOCK_SLEEP=0.8
  touch "$DOCKER_UP"
  crw unlock --stdin --wait --timeout 60
  wait_until 10 seq_started
  printf '1 9999999999\n' > "$CI_RUNNER_STATE_DIR/machine/unlock-wait.lock/holder"
  wait_until 15 done_and_gone 1
  check 'an old holder leaves the lock of the one that took over' test -e "$CI_RUNNER_STATE_DIR/machine/unlock-wait.lock/holder"
  reap
  unset UNLOCK_SLEEP

  exit "$fail"
)

run_sections_parallel section_1 section_2 section_3 section_4
exit $?
