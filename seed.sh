#!/usr/bin/env bash
#
# Fills the read-only seed every runner mounts at /opt/seed — host-repo an earlier change.
#
# Run by `ci-runner.sh seed` (and at the end of `build`) in a container of the
# runner image that has the seed volume mounted read-write and nothing else: no
# checkout, no docker socket, no job. That is the whole point. Until an earlier change the
# tool cache and ~/.cache were filled by whichever job got there first, and
# every later job in every repository ran what it left — the npm worm of
# 2026-07-06 lived in exactly such a file, npm's own lib/cli.js. Here the only
# code that runs is the pinned versions in seed.list, fetched the way setup-node
# and Playwright fetch them, and the runners get the result with :ro.
#
# The list arrives on stdin, one "<tool> <version>" per line, # for comments.
# Each entry is skipped when already complete, so this is cheap to re-run.
set -euo pipefail

SEED=/seed
TOOLCACHE=$SEED/toolcache
BROWSERS=$SEED/ms-playwright

case "$(uname -m)" in
  x86_64) arch=x64 ;;
  aarch64) arch=arm64 ;;
  *) echo "seed: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

# The layout is the tool cache's own: <tool>/<version>/<arch> plus a sibling
# <arch>.complete, which is what setup-node's tc.find() looks for. The tarball
# is nodejs.org's, checked against the SHASUMS256.txt published beside it.
seed_node() {
  local v=$1 dir=$TOOLCACHE/node/$1 tmp file sums
  if [ -e "$dir/$arch.complete" ]; then echo "seed: node $v already there"; return 0; fi
  tmp=$(mktemp --directory)
  file="node-v$v-linux-$arch.tar.xz"
  curl --fail --location --silent --show-error --output "$tmp/$file" "https://nodejs.org/dist/v$v/$file"
  sums=$(curl --fail --location --silent --show-error "https://nodejs.org/dist/v$v/SHASUMS256.txt")
  (cd "$tmp" && printf '%s\n' "$sums" | grep "  $file\$" | sha256sum --check --status) \
    || { echo "seed: node $v failed its checksum — nothing written" >&2; rm -rf "$tmp"; return 1; }
  rm -rf "$dir"; mkdir --parents "$dir/$arch"
  tar --extract --xz --file "$tmp/$file" --directory "$dir/$arch" --strip-components=1
  touch "$dir/$arch.complete"
  rm -rf "$tmp"
  echo "seed: node $v"
}

# Playwright installs its own browsers, so it runs once here on the seed's
# node, against a throwaway npm cache and with install scripts off. It writes
# each browser's INSTALLATION_COMPLETE marker last, and skips one that has it.
seed_playwright() {
  local v=$1 node_bin cache
  node_bin=$(find "$TOOLCACHE/node" -mindepth 3 -maxdepth 3 -path "*/$arch/bin" -type d 2>/dev/null | sort --version-sort | tail -n 1)
  [ -n "$node_bin" ] || { echo "seed: playwright needs a node line above it in seed.list" >&2; return 1; }
  cache=$(mktemp --directory)
  PATH="$node_bin:$PATH" PLAYWRIGHT_BROWSERS_PATH=$BROWSERS \
    npm_config_cache=$cache npm_config_ignore_scripts=true npm_config_update_notifier=false \
    npx --yes "playwright@$v" install chromium
  rm -rf "$cache"
  echo "seed: playwright $v browsers"
}

mkdir --parents "$TOOLCACHE" "$BROWSERS"
rc=0
while read -r tool version _; do
  case "$tool" in ''|'#'*) continue ;; esac
  [ -n "${version:-}" ] || { echo "seed: '$tool' has no version" >&2; rc=1; continue; }
  case "$tool" in
    node) seed_node "$version" || rc=1 ;;
    playwright) seed_playwright "$version" || rc=1 ;;
    *) echo "seed: unknown tool '$tool'" >&2; rc=1 ;;
  esac
done
# Readable by the runner, writable by nobody it can become without the mount
# being :rw — which no runner gets.
chmod --recursive a+rX,go-w "$SEED"
exit $rc
