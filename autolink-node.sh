#!/usr/bin/env bash
# Autolinks the highest (or preferred) seeded Node version's binaries
# (node, npm, npx, corepack) into /usr/local/bin.
# This provides default node/npm on $PATH like ubuntu-latest before actions/setup-node.
set -euo pipefail

toolcache_dir=${1:-/opt/hostedtoolcache}
target_bin_dir=${2:-/usr/local/bin}

case "$(uname -m)" in
  x86_64) arch=x64 ;;
  aarch64) arch=arm64 ;;
  *) arch=* ;;
esac

preferred_version=${CI_DEFAULT_NODE_VERSION:-}
node_bin=""

if [ -n "$preferred_version" ]; then
  if [ -d "$toolcache_dir/node/$preferred_version/$arch/bin" ]; then
    node_bin="$toolcache_dir/node/$preferred_version/$arch/bin"
  fi
fi

if [ -z "$node_bin" ] && [ -d "$toolcache_dir/node" ]; then
  node_bin=$(find -L "$toolcache_dir/node" -mindepth 3 -maxdepth 3 -path "*/$arch/bin" -type d 2>/dev/null | sort --version-sort | tail -n 1)
fi

if [ -n "$node_bin" ] && [ -d "$node_bin" ]; then
  mkdir -p "$target_bin_dir"
  for b in node npm npx corepack; do
    if [ -e "$node_bin/$b" ]; then
      ln -sfn "$node_bin/$b" "$target_bin_dir/$b"
    fi
  done
else
  echo "ci-runner: warning: no seeded node found in $toolcache_dir/node; default node links skipped" >&2
fi
