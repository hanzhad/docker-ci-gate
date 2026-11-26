#!/usr/bin/env bash
#
# Store the credential in the gate, in memory only.
#
# Run inside the gate container with the token on stdin — never as an argument.
# An argument would put the token in the host's process list (`ps` shows the
# full `docker exec` command line) and in the shell history of whoever typed
# it, which are two of the places a credential harvester looks first.
#
# $TOKEN_FILE lives on a tmpfs, so a reboot, a `docker stop`, or a crash all
# leave nothing behind. That is the property being bought: the machine at rest
# holds no credential for this at all. The cost is that CI is dead after every
# reboot until somebody unlocks it — which is why the gate says `locked` rather
# than failing quietly, and why `status` prints it.
set -euo pipefail

REPO=${GITHUB_REPO:?}
TOKEN_FILE=${TOKEN_FILE:-/run/gate/pat}
# GATE_OWNER set: this is one owner's token (`ci-runner.sh unlock --owner`),
# stored where gate.sh's token_for looks, and REPO is one of that owner's.
if [ -n "${GATE_OWNER:-}" ]; then
  owner=$(printf '%s' "$GATE_OWNER" | tr '[:upper:]' '[:lower:]')
  install -d -m 0700 "${TOKEN_DIR:-/run/gate/pat.d}"
  TOKEN_FILE=${TOKEN_DIR:-/run/gate/pat.d}/$owner
fi

token=$(cat)
token=$(printf '%s' "$token" | tr -d '[:space:]')
[ -n "$token" ] || { echo "✗ nothing on stdin" >&2; exit 64; }

# Validated against the one endpoint that has to work — listing runners for
# this repository. A token that authenticates but cannot administer runners
# would otherwise be accepted here and fail ten minutes later, in a log
# nobody is reading.
headers=$(mktemp)
code=$(curl --silent --output /dev/null --dump-header "$headers" --write-out '%{http_code}' \
  --header "Authorization: Bearer $token" \
  --header "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/actions/runners")

case "$code" in
  200) ;;
  401) echo "✗ GitHub rejected the token (401) — expired, or revoked." >&2; exit 77 ;;
  403|404) echo "✗ the token authenticates but cannot administer runners on $REPO (HTTP $code)." >&2
           echo "  a fine-grained token needs: Repository permissions -> Administration: Read and write" >&2
           exit 77 ;;
  *) echo "✗ unexpected HTTP $code from GitHub." >&2; exit 75 ;;
esac

install -m 0600 /dev/null "$TOKEN_FILE"
printf '%s' "$token" > "$TOKEN_FILE"

# The expiry is kept beside the token, on the same tmpfs, purely so `status`
# can show it. An expired token is the failure that looks like a broken CI —
# the gate logs an API error and jobs quietly queue — so the date has to be
# visible before it arrives, not deduced afterwards. GitHub returns it as a
# response header on every authenticated call, so nothing is computed here.
expiry=$(sed -n 's/^[Gg][Ii][Tt][Hh][Uu][Bb]-[Aa]uthentication-[Tt]oken-[Ee]xpiration: *//p' "$headers" | tr -d '\r')
rm -f "$headers"
printf '%s' "${expiry:-unknown}" > "${TOKEN_FILE}.expiry"
echo "✓ unlocked — the gate can mint runner credentials again"
[ -n "$expiry" ] && echo "  this token expires: $expiry" \
                 || echo "  no expiry reported (a token with no expiry — the one control this design has is its lifetime)"
