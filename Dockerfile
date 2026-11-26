# The self-hosted CI runner — the design docs.
#
# Built to be a plausible stand-in for `ubuntu-latest`, not a minimal image: a
# workflow that runs on GitHub's runner and then here should fail for reasons
# in the code, not because a binary the workflow assumed is missing. Everything
# installed below is here because some step of a real workflow shells out to
# it. Nothing is installed speculatively — when a workflow needs a new tool the
# honest fix is a line here and a rebuild, not `apt-get` inside the job.
#
# What is deliberately NOT here: node. `actions/setup-node` finds it in the tool
# cache, where entrypoint.sh has linked in what `ci-runner.sh seed` installed
# from seed.list; a version not seeded is downloaded into the container
# and dies with it. Baking a node in would shadow that and make the local
# runner disagree with the hosted one about which node a job actually got.
FROM ubuntu:24.04

# Both resolved by `ci-runner.sh build` against the GitHub API and passed in;
# the defaults are what was current when this file was written, so a build
# without the wrapper still works and is merely stale.
ARG RUNNER_VERSION=2.336.0
ARG GH_VERSION=2.97.0
# The uid of the host user, passed in by `ci-runner.sh build`. It had to match
# while the work folder was a bind mount from the host (until an earlier change): its files
# carried the *host* uid, and a tool that checks ownership rejected the
# checkout outright. git is talked out of that by the /etc/gitconfig written
# below — but libgit2 is not git and ignores safe.directory entirely, so
# cocogitto depended on this uid matching. It failed with "repository path ...
# is not owned by current user" on run 32246300597, three steps after the
# checkout every other tool had been happy with. The checkout is now made by
# `runner` inside the container, so it always matches; the host uid is kept
# because nothing is gained by changing the image's uid under the volumes.
#
# For a year this comment claimed safe.directory was already in force. It was
# not — nothing set it anywhere, and the claim is a large part of why the same
# root cause was diagnosed from scratch twice (demo-app an earlier change, then an earlier change).
ARG RUNNER_UID=1001
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

# Three groups, one layer:
#   - the runner's own dependencies (libicu, krb5, lttng) — it is a .NET
#     binary and fails at startup with a linker error, not a clear message,
#     when they are absent;
#   - what workflows shell out to: git, curl, jq, python3, psql, zip — and a
#     postgres server, which a job that needs a database starts itself with
#     initdb/pg_ctl as `runner`, in its own temp dir, and loses with the
#     container. The hosted image ships the same (PostgreSQL 16, service
#     off). This is what replaced `docker run postgres` once the socket went
#     (an earlier change, demo-app an earlier change). The cluster apt creates on install is dropped
#     below: nothing would start it, and a job must not find a database it
#     did not make;
#   - Chromium's shared libraries, because `npx playwright install chromium`
#     installs the browser and not its system dependencies. On the hosted
#     image those are already present, which is why workflows drop
#     `--with-deps`; dropping it here has to be paid for at build time.
# socat is not a workflow dependency — it is what entrypoint.sh forwards
# CI_RUNNER_LOOPBACK_PORTS through. See that file. No docker client: from
# 2026-09-21 to 2026-11-03 the image carried one plus a shim in front of it,
# for the repositories that got the host's socket; none does now.
RUN apt-get update && apt-get install --yes --no-install-recommends \
      ca-certificates curl wget gnupg lsb-release apt-transport-https \
      git jq unzip zip tar xz-utils rsync openssh-client socat sudo \
      libicu74 libkrb5-3 liblttng-ust1 libssl3t64 zlib1g \
      python3 python3-venv python3-pip postgresql-client postgresql-16 \
      build-essential \
      fonts-liberation fonts-noto-color-emoji \
      libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 \
      libcairo2 libcups2t64 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 \
      libnspr4 libnss3 libpango-1.0-0 libpangocairo-1.0-0 \
      libx11-6 libx11-xcb1 libxcb1 libxcomposite1 libxdamage1 libxext6 \
      libxfixes3 libxi6 libxkbcommon0 libxrandr2 libxrender1 libxshmfence1 \
      libxss1 libxtst6 libwayland-client0 \
    && pg_dropcluster 16 main \
    && rm --recursive --force /var/lib/apt/lists/*

# GitHub's arch names, not Debian's: the runner tarball is `arm64`/`x64`, and
# gh is `arm64`/`amd64`.
RUN set -eux; \
    case "${TARGETARCH:-arm64}" in \
      arm64) runner_arch=arm64; gh_arch=arm64 ;; \
      amd64) runner_arch=x64;   gh_arch=amd64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    \
    curl --fail --location --silent --show-error \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${gh_arch}.tar.gz" \
      | tar --extract --gzip --directory /usr/local --strip-components=1 \
            "gh_${GH_VERSION}_linux_${gh_arch}/bin/gh"; \
    \
    mkdir --parents /opt/runner; \
    curl --fail --location --silent --show-error \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${runner_arch}-${RUNNER_VERSION}.tar.gz" \
      | tar --extract --gzip --directory /opt/runner; \
    \
    gh --version; /opt/runner/bin/Runner.Listener --version

# The runner refuses to run as root, and it is right to: a job here executes
# the pull request's own dependency tree (the design docs), and Chromium will not
# start as root without --no-sandbox — which the workflow does not pass,
# because on the hosted runner it does not have to. The name stays `runner` as
# on GitHub's images; the uid follows the host instead, for the reason above.
# One piece of parity with GitHub's image that is invisible until a workflow
# needs it, and then looks like a broken workflow rather than a wrong runner:
# `runner` can write to /usr/local/bin. Real steps install tools with a bare
# `install -m 0755 ... /usr/local/bin/x` and no sudo, which works there and
# failed here with "Permission denied" — found by run 32245948670, the first
# real job this runner took. The other piece, passwordless sudo, was removed on
# 2026-11-03 when work folders and tool caches were shared across
# repositories. Under an earlier change the work folder lives inside the ephemeral container
# and dies with it (--rm), the seed volume is mounted read-only (:ro), and
# persistent caches are isolated per-slug and auto-repaired by entrypoint.sh.
# Passwordless sudo is restored so community actions using `sudo apt-get install`
# or `sudo install` work out of the box, with parity to GitHub's ubuntu-latest.
#
# The uid may already be taken: ubuntu:24.04 ships a user `ubuntu` at 1000,
# which is also the first user on every Linux host. macOS starts at 501, so
# this never fired there and `useradd` exited 4 the first time the image was
# built on a Linux host (2026-09-21). Whoever holds the uid is removed first —
# by uid, not by name, so a future base image with a different placeholder
# does not bring it back.
RUN set -eux; \
    existing=$(getent passwd "${RUNNER_UID}" | cut -d: -f1); \
    [ -z "${existing}" ] || userdel --remove "${existing}"; \
    useradd --create-home --shell /bin/bash --uid "${RUNNER_UID}" runner \
    && mkdir --parents /opt/hostedtoolcache /opt/ms-playwright /opt/seed \
                       /home/runner/.npm /home/runner/.cache /home/runner/.local/share/pnpm \
                       /var/cache/ci-runner/git \
    && chown --recursive runner:runner /opt/runner /opt/hostedtoolcache /opt/ms-playwright /home/runner /var/cache/ci-runner \
    && chown runner:runner /usr/local/bin \
    && echo "runner ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/runner \
    && chmod 0440 /etc/sudoers.d/runner

# git's dubious-ownership check, turned off for this container and only this
# container — demo-app an earlier change.
#
# The work folder is a VirtioFS bind mount of a macOS path. Its files are the
# host uid on the host, and `RUNNER_UID` above exists so that matches inside.
# It does not always: six consecutive stats of one live runner's checkout
# returned owner 0:0 for files that are uid 501 on the host, git exited 128
# through all of them, and minutes later the same commands returned 501:1001
# and exit 0 with nothing having written to the directory. The trigger is
# Docker Desktop's; the failure is ours to absorb.
#
# What it looks like when it lands is worse than the condition: `git diff`
# accepts --no-index, so it takes git's gentle repository discovery, downgrades
# an ownership rejection to "there is no repository here", and then rejects the
# revision range as a usage error. One condition, two messages, two exit codes
# (128 and 129), and neither of them says "ownership" — which is how demo-app
# an earlier change was closed as an environment blip with the word `dubious` sitting in its
# own log.
#
# Why here and not in a workflow step: `actions/checkout` does add the checkout
# as a safe.directory, but into a HOME it overrides for that step alone and
# throws away — it says so in its own log. Every later step runs without it.
# And the exposed callers are not all ours: `changesets/action` runs git commit,
# push and tag after checkout, inside a third-party action nobody can add a step
# to. /etc/gitconfig covers every step of every job and every action in them.
#
# Why `*` and not a path list: the path changed per repository and per slot
# while work folders were host directories, and a stale list fails exactly
# like no list at all. Since an earlier change the checkout is `runner`'s own and the
# ownership check would pass without this; it stays because the VirtioFS case
# above is Docker Desktop's to reintroduce through any future mount.
#
# The cost, stated rather than buried: git will no longer refuse to operate on a
# repository owned by someone else. That check exists because a repository
# carries executable configuration — hooks, and config like core.fsmonitor — so
# running git inside one you do not own can run its code. Here the container is
# single-use, and the only mounts it can write are that repository's own ~/.npm
# and ~/.cache. The shared toolchain is the read-only seed. From
# 2026-09-21 to 2026-11-02 this comment said "exactly one bind mount" while a
# read-write tool cache and ~/.cache were shared by every job of every
# repository; it was found by reading, not by anything failing.
# Until an earlier change the work folder itself outlived the container, so a repository
# planted with a hook by one job was opened by the next job of that repository
# (scrub-git.sh emptied what it could, an earlier change). It no longer outlives it. If
# this changes — another shared writable mount, or a runner reused across
# jobs — this line has to be revisited rather than inherited.
RUN printf '[safe]\n\tdirectory = *\n' > /etc/gitconfig && chmod 0644 /etc/gitconfig

# ImageOS is what setup-node and friends read to pick a download; getting it
# wrong is a 404 halfway through a job rather than at startup.
ENV RUNNER_MANUALLY_TRAP_SIG=1 \
    ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/usr/local/bin/job-completed.sh \
    AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache \
    PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
    ImageOS=ubuntu24

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
# Empties a per-repository cache that has grown past its cap — see its header.
COPY cache-cap.sh /usr/local/bin/cache-cap.sh
# Runs after every job to scrub and sync .git back to the persistent volume.
COPY job-completed.sh /usr/local/bin/job-completed.sh
COPY scrub-git.sh /usr/local/bin/scrub-git.sh
# Autolinks seeded node/npm into /usr/local/bin for ubuntu-latest parity.
COPY autolink-node.sh /usr/local/bin/autolink-node.sh
# Not run by a job — `ci-runner.sh seed` runs it in a container of its own.
COPY seed.sh /usr/local/bin/seed.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/cache-cap.sh /usr/local/bin/job-completed.sh /usr/local/bin/scrub-git.sh /usr/local/bin/autolink-node.sh /usr/local/bin/seed.sh

# Propagate container CPU quota to test runners and Node runtime.
COPY ci-runner-cgroup.js /usr/local/lib/ci-runner-cgroup.js
RUN chmod 0644 /usr/local/lib/ci-runner-cgroup.js

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
