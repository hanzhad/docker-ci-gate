#!/usr/bin/env bash
# Consolidated runner image (cache-cap, scrub-git, job-completed, autolink-node,
# Dockerfile/entrypoint wiring) and workflow-blockers tests for ci-runner
# (upstream issue).
# Consolidates:
#   - test-ci-runner-runner-image.sh
#   - test-ci-runner-workflow-blockers.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
overall_fail=0

# ==============================================================================
# Section 1: Runner image scripts, hooks, and Dockerfile/entrypoint wiring
# ==============================================================================
(
  D="$here"
  CAP="$D/cache-cap.sh"
  SCRUB="$D/scrub-git.sh"
  HOOK="$D/job-completed.sh"
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  fail=0
  check() {
    local label=$1; shift
    if "$@"; then printf 'ok    %s\n' "$label"; else printf 'FAIL  %s\n' "$label"; fail=1; fi
  }
  fill() {
    mkdir -p "$1/sub"
    head -c "$(($2 * 1048576))" /dev/zero > "$1/sub/blob"
    : > "$1/.hidden"
  }
  empty_dir() { [ -d "$1" ] && [ -z "$(ls -A "$1")" ]; }
  emptied() { [ -d "$1" ] && [ -z "$(ls -A "$1" | grep -vxE ".inuse|.sync")" ]; }
  kept() { [ -f "$1/sub/blob" ] && [ -f "$1/.hidden" ]; }

  echo '== cache-cap.sh'
  check "cap: the script exists and is executable" test -x "$CAP"

  fill "$T/big" 3; fill "$T/small" 1
  bash "$CAP" 2 "$T/big" "$T/small" > "$T/out" 2>&1; rc=$?
  check "cap: exits 0" test "$rc" -eq 0
  check "cap: a directory over the cap is emptied, dotfiles too" emptied "$T/big"
  check "cap: a directory under the cap is untouched" kept "$T/small"
  check "cap: it says which directory it emptied" grep -q "$T/big" "$T/out"

  fill "$T/bad" 3
  bash "$CAP" lots "$T/bad" > /dev/null 2>&1; rc=$?
  check "cap: a non-integer cap exits 0" test "$rc" -eq 0
  check "cap: a non-integer cap empties nothing" kept "$T/bad"

  bash "$CAP" 2 "$T/does-not-exist" > /dev/null 2>&1; rc=$?
  check "cap: a missing directory is not an error" test "$rc" -eq 0

  echo '== scrub-git.sh'
  check "scrub: the script exists and is executable" test -x "$SCRUB"

  mkdir -p "$T/repo/.git/hooks"
  echo '#!/bin/sh' > "$T/repo/.git/hooks/pre-commit"
  chmod +x "$T/repo/.git/hooks/pre-commit"
  cat <<'EOF' > "$T/repo/.git/config"
[core]
	repositoryformatversion = 0
	filemode = true
	bare = false
	hookspath = /tmp/evil-hooks
	fsmonitor = /tmp/evil-fsmonitor
[alias]
	evil = !touch /tmp/evil
[safe]
	directory = *
[extensions]
	partialclone = origin
[remote "origin"]
	promisor = true
	partialclonefilter = blob:none
[filter "evil"]
	clean = /tmp/evil-clean
EOF

  bash "$SCRUB" "$T/repo"
  check "scrub: exits 0" test $? -eq 0
  check "scrub: hooks directory is emptied" empty_dir "$T/repo/.git/hooks"
  check "scrub: core.hookspath is removed" bash -c "! git config --file '$T/repo/.git/config' --get core.hookspath"
  check "scrub: core.fsmonitor is removed" bash -c "! git config --file '$T/repo/.git/config' --get core.fsmonitor"
  check "scrub: filter.evil is removed" bash -c "! git config --file '$T/repo/.git/config' --get filter.evil.clean"
  check "scrub: alias is removed" bash -c "! git config --file '$T/repo/.git/config' --get-regexp '^alias\.'"
  check "scrub: safe.directory remains" bash -c "git config --file '$T/repo/.git/config' --get safe.directory"
  check "scrub: partial clone promisor remains" bash -c "git config --file '$T/repo/.git/config' --get remote.origin.promisor"
  check "scrub: partial clone filter remains" bash -c "[ \"\$(git config --file '$T/repo/.git/config' --get remote.origin.partialclonefilter)\" = 'blob:none' ]"
  check "scrub: extensions.partialclone remains" bash -c "git config --file '$T/repo/.git/config' --get extensions.partialclone"

  echo '== job-completed.sh'
  check "hook: the script exists and is executable" test -x "$HOOK"

  mkdir -p "$T/fake-ws/.git" "$T/fake-cache/git" "$T/stub-bin"
  if ! command -v rsync >/dev/null 2>&1; then
    cat > "$T/stub-bin/rsync" <<'STUB'
#!/usr/bin/env bash
del=0; args=()
for a in "$@"; do
  case "$a" in
    --delete) del=1 ;;
    -*) ;;
    *) args+=("$a") ;;
  esac
done
src="${args[0]}"
dst="${args[1]}"
mkdir -p "$dst"
[ "$del" -eq 1 ] && find "$dst" -mindepth 1 -delete
cp -a "${src%/}/." "$dst"
STUB
    chmod +x "$T/stub-bin/rsync"
  fi

  git init -q "$T/fake-ws"
  (
    cd "$T/fake-ws"
    git config user.name "test"
    git config user.email "test@example.com"
    echo "test" > file.txt
    git add file.txt
    git commit -q -m "initial commit"
  )
  touch "$T/fake-ws/.git/gc.log.lock" "$T/fake-ws/.git/gc.pid"
  mkdir -p "$T/fake-ws/.git/worktrees"

  sed -e "s|/var/cache/ci-runner/git|$T/fake-cache/git|g" \
      -e "s|/usr/local/bin/scrub-git.sh|$D/scrub-git.sh|g" \
      "$HOOK" > "$T/test-hook.sh"
  chmod +x "$T/test-hook.sh"
  PATH="$T/stub-bin:$PATH" GITHUB_WORKSPACE="$T/fake-ws" "$T/test-hook.sh"
  check "hook: locks are cleaned" test ! -f "$T/fake-ws/.git/gc.log.lock"
  check "hook: worktrees removed" test ! -d "$T/fake-ws/.git/worktrees"
  check "hook: .git synced to persistent cache" test -f "$T/fake-cache/git/.git/config"
  check "hook: synchronous gc ran in hook script" grep -q 'gc.autoDetach=false' "$HOOK"

  echo '== autolink-node.sh'
  check "autolink: script exists and is executable" test -x "$D/autolink-node.sh"

  out=$(bash "$D/autolink-node.sh" "$T/missing-tc" "$T/bin" 2>&1)
  rc=$?
  check "autolink: missing node exits 0" test "$rc" -eq 0
  check "autolink: missing node produces warning" bash -c "printf '%s' '$out' | grep -q 'warning: no seeded node found'"
  check "autolink: missing node creates no symlinks" test ! -e "$T/bin/node"

  arch=$(case "$(uname -m)" in x86_64) echo x64 ;; aarch64) echo arm64 ;; *) echo x64 ;; esac)
  mkdir -p "$T/tc/node/18.20.0/$arch/bin" "$T/tc/node/20.18.0/$arch/bin" "$T/tc/node/22.11.0/$arch/bin"
  for v in 18.20.0 20.18.0 22.11.0; do
    touch "$T/tc/node/$v/$arch/bin/node" "$T/tc/node/$v/$arch/bin/npm" "$T/tc/node/$v/$arch/bin/npx" "$T/tc/node/$v/$arch/bin/corepack"
    echo "$v" > "$T/tc/node/$v/$arch/bin/node"
  done

  bash "$D/autolink-node.sh" "$T/tc" "$T/bin"
  check "autolink: creates /usr/local/bin/node" test -L "$T/bin/node"
  check "autolink: creates /usr/local/bin/npm" test -L "$T/bin/npm"
  check "autolink: creates /usr/local/bin/npx" test -L "$T/bin/npx"
  check "autolink: creates /usr/local/bin/corepack" test -L "$T/bin/corepack"
  check "autolink: selects highest version 22.11.0" bash -c "grep -q '22.11.0' '$T/bin/node'"

  CI_DEFAULT_NODE_VERSION=20.18.0 bash "$D/autolink-node.sh" "$T/tc" "$T/bin"
  check "autolink: preferred version overrides highest" bash -c "grep -q '20.18.0' '$T/bin/node'"

  mkdir -p "$T/setup-node-bin"
  echo '#!/bin/sh' > "$T/setup-node-bin/node"
  echo 'echo 18.20.0' >> "$T/setup-node-bin/node"
  chmod +x "$T/setup-node-bin/node"
  check "autolink: setup-node prepended to PATH cleanly overrides default" bash -c "PATH='$T/setup-node-bin:$T/bin:$PATH' && [ \"\$(node)\" = '18.20.0' ]"

  echo '== ci-runner-cgroup.js'
  check "cgroup: script exists" test -f "$D/ci-runner-cgroup.js"

  echo '== sudo parity'
  check "image: sudo package is in apt-get install in Dockerfile" \
    bash -c "sed -n '/apt-get install/,/build-essential/p' '$D/Dockerfile' | grep -q '\bsudo\b'"
  check "image: runner has passwordless sudo in Dockerfile" grep -q 'runner ALL=(ALL) NOPASSWD:ALL' "$D/Dockerfile"

  echo '== image wiring and entrypoint'
  check "image: ACTIONS_RUNNER_HOOK_JOB_COMPLETED is set in Dockerfile" \
    grep -q 'ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/usr/local/bin/job-completed.sh' "$D/Dockerfile"
  check "image: job-completed.sh is copied in Dockerfile" grep -q 'job-completed.sh' "$D/Dockerfile"
  check "image: scrub-git.sh is copied in Dockerfile" grep -q 'scrub-git.sh' "$D/Dockerfile"
  check "image: cache-cap.sh is copied in Dockerfile" grep -q 'cache-cap.sh' "$D/Dockerfile"
  check "image: autolink-node.sh is copied in Dockerfile" grep -q 'autolink-node.sh' "$D/Dockerfile"
  check "image: ci-runner-cgroup.js is copied in Dockerfile" grep -q 'ci-runner-cgroup.js' "$D/Dockerfile"
  check "image: git cache and pnpm dirs created in Dockerfile" \
    grep -Eq '/var/cache/ci-runner/git' "$D/Dockerfile"

  check "entrypoint: caps all 4 directories" \
    bash -c "grep -q '/var/cache/ci-runner/git' '$D/entrypoint.sh' && grep -q '/home/runner/\.local/share/pnpm' '$D/entrypoint.sh'"
  check "entrypoint: repairs persistent cache ownership recursively" \
    grep -q 'chown -R runner:runner' "$D/entrypoint.sh"
  check "entrypoint: calls autolink-node.sh" grep -q 'autolink-node.sh' "$D/entrypoint.sh"
  check "entrypoint: git pre-population handles CI_REPO" \
    grep -q 'CI_REPO' "$D/entrypoint.sh"
  check "entrypoint: configures partial clone for CI_REPO" \
    grep -q 'partialclonefilter' "$D/entrypoint.sh"
  check "entrypoint: sets NODE_OPTIONS with ci-runner-cgroup.js" grep -q 'ci-runner-cgroup.js' "$D/entrypoint.sh"
  check "entrypoint: sets test concurrency variables" grep -q 'VITEST_MAX_THREADS' "$D/entrypoint.sh"
  check "entrypoint: no RUNNER_WORK_FOLDER left" \
    bash -c "! grep -q RUNNER_WORK_FOLDER '$D/entrypoint.sh'"

  exit "$fail"
) || overall_fail=1

# ==============================================================================
# Section 2: workflow-blockers.awk and ci-runner.sh `on` blocker checks
# ==============================================================================
(
  awkfile="$here/workflow-blockers.awk"
  fail=0

  expect() {
    local got; got=$(awk -f "$awkfile")
    if [ "$got" = "$2" ]; then printf 'ok    %s\n' "$1"
    else printf 'FAIL  %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$got"; fail=1; fi
  }

  switch="runs-on: \${{ vars.CI_RUNNER == '1' && 'local-docker' || 'ubuntu-latest' }}"

  expect 'a service in a switched job' '5: services: needs docker on the runner' <<YAML
name: CI
jobs:
  test:
    $switch
    services:
      postgres:
        image: postgres:16
    steps:
      - run: pnpm test
YAML

  expect 'a job container in a switched job' '4: container: needs docker on the runner' <<YAML
jobs:
  test:
    $switch
    container: node:22
    steps:
      - run: pnpm test
YAML

  expect 'the switch may come after the service' '3: services: needs docker on the runner' <<YAML
jobs:
  test:
    services:
      postgres:
        image: postgres:16
    $switch
YAML

  expect 'docker in a step and a docker action' '5: calls docker
6: a docker:// action needs docker on the runner' <<YAML
jobs:
  test:
    $switch
    steps:
      - run: docker compose up -d
      - uses: docker://alpine:3
YAML

  expect 'a fixed runs-on stays on GitHub, so it may use docker' '' <<YAML
jobs:
  images:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
    steps:
      - run: docker build .
YAML

  expect 'only the switched job is reported' '8: services: needs docker on the runner' <<YAML
jobs:
  images:
    runs-on: ubuntu-latest
    steps:
      - run: docker build .
  test:
    $switch
    services:
      postgres:
        image: postgres:16
YAML

  expect 'comments and words that are not the command' '' <<YAML
jobs:
  test:
    $switch
    # services: were here before an earlier change, and docker run with them
    steps:
      - run: scripts/no-docker run
      - run: echo docker
      - run: my.docker build
YAML

  expect 'a job called services is a job' '' <<YAML
jobs:
  services:
    $switch
    steps:
      - run: pnpm test
YAML

  expect 'a key after jobs ends the last job' '4: services: needs docker on the runner' <<YAML
jobs:
  test:
    $switch
    services:
      postgres:
        image: postgres:16
permissions:
  contents: read
YAML

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  git -C "$tmp" init -q
  git -C "$tmp" remote add origin https://github.com/example/app.git
  gh() {
    case "$*" in
      "auth status") return 0 ;;
      *contents/.github/workflows\ *)
        while [ "$1" != --jq ]; do shift; done
        jq -r "$2" "$FAKE_LISTING" ;;
      *contents/.github/workflows/*) echo "$2" >>"$FAKE_READS"; base64 "$FAKE_WORKFLOW" ;;
      *actions/runners*) echo '{"runners":[]}' ;;
      variable\ set*) echo "$*" >>"$FAKE_GH_LOG" ;;
    esac
  }
  export -f gh
  export FAKE_GH_LOG="$tmp/gh.log" FAKE_WORKFLOW="$tmp/ci.yml" FAKE_LISTING="$tmp/listing.json" FAKE_READS="$tmp/reads.log"
  cat >"$FAKE_LISTING" <<'JSON'
[{"name":"ci.yml","path":".github/workflows/ci.yml"},
 {"name":"notes.txt","path":".github/workflows/notes.txt"},
 {"name":"x.yaml","path":".github/workflows/x.yaml"}]
JSON

  printf 'jobs:\n  test:\n    %s\n    services:\n      postgres:\n        image: postgres:16\n' "$switch" >"$tmp/ci.yml"
  : >"$FAKE_GH_LOG"
  if out=$("$here/ci-runner.sh" on "$tmp" 2>&1); then echo "FAIL  on accepted a service"; fail=1
  elif [ -s "$FAKE_GH_LOG" ]; then echo "FAIL  on set a variable while refusing"; fail=1
  elif ! printf '%s' "$out" | grep -q '.github/workflows/ci.yml:4: services'; then echo "FAIL  on did not name the line: $out"; fail=1
  else echo 'ok    on refuses a service and sets nothing'; fi

  printf 'jobs:\n  test:\n    %s\n    steps:\n      - run: pnpm test\n' "$switch" >"$tmp/ci.yml"
  : >"$FAKE_GH_LOG"
  if "$here/ci-runner.sh" on "$tmp" >/dev/null 2>&1 && grep -q 'variable set CI_RUNNER --repo example/app --body 1' "$FAKE_GH_LOG"
  then echo 'ok    on moves a clean repository'
  else echo "FAIL  on did not move a clean repository"; fail=1; fi

  reads=$(sed 's|.*/||' "$FAKE_READS" | sort -u | tr '\n' ' ')
  if [ "$reads" = 'ci.yml x.yaml ' ]; then echo 'ok    the listing filter keeps the yaml files only'
  else echo "FAIL  the listing filter read: $reads"; fail=1; fi

  exit "$fail"
) || overall_fail=1

exit "$overall_fail"
