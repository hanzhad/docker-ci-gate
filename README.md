# ci-runner — GitHub Actions on this machine

Layout: the folder is ``; `ci-runner` at the repository root is a symlink to it that the stored PIN receivers and `~/.local/bin/ci-runner` on the PC run through, so it stays until the Mac has pulled.

Two containers. The **gate** holds the credential and decides how many runners
exist; it never executes anything from a repository. A **runner** is where a
pull request's own code runs, and it holds one single-use credential good for
exactly one job, then exits. Nothing is kept warm: every repository is polled
every tick, and a runner is raised only when GitHub has a job queued for it.
Two classes share one machine-wide budget in cores — `big` for the expensive
jobs (e2e), `little` for the cheap ones (lint, typecheck, unit) — priced by
`--cpu-shares`, not by the `--cpus` ceiling, because a quota is not a
reservation under contention.

Nothing listens. Everything here dials GitHub outward, so there is no tunnel,
no port forwarding, no static IP and no DNS record involved — see *Why no
tunnel* at the bottom. The reasoning for the whole design is the design docs;
this file is how to run it, and how to repair it a year from now.

```
ci-gate                     always up (restart unless-stopped), holds the token in RAM
  └── ci-runner-<slug>-<host>-N   one per job, --rm, holds a one-job credential
                             (class big or little — see ci-runner.sh status)
```

---

## First time on a machine

### 1. Build the images

```sh
~/Projects/host-repo/ci-runner.sh build
```

Two images: `ci-runner:local` (~1.8 GB — Ubuntu, the Actions runner, Chromium's
libraries) and `ci-gate:local` (~30 MB — alpine, curl, jq, docker CLI).

`install` is the same step for a machine that will be used from the command
line every day:

```sh
~/Projects/host-repo/ci-runner.sh install [--budget 10 --host mybox ...]
```

It builds and seeds only if the images are missing (a machine that has them just
re-seeds; `build` stays the way to rebuild on purpose, because it pulls the
latest runner and `gh`), stores the flags it was given for `up` (below), and
writes `~/.local/bin/ci-runner`, a small script that runs `ci-runner.sh` from
where it really is. A script and not a symlink, because the tool finds
`seed.list`, the awk file and the build context next to itself. If
`~/.local/bin` is not on your `PATH`, `install` says so. It never starts,
stops or reconfigures a gate, and never touches the live budget.

### 2. Make a token for the gate

The gate needs one permission and no more: the right to register runners on one
repository.

- Create it here → **https://github.com/settings/personal-access-tokens/new**
- *Repository access* → **Only select repositories** → pick the one repository.
- *Repository permissions* → **Administration: Read and write** (this is what
  registers runners), plus **Actions: Read-only** — nothing is kept warm, so
  every repository is asked whether work is queued, every tick, and that is
  the `Actions` permission rather than `Administration`. `Metadata: Read` is
  added automatically and is required. **Nothing else.**
- Expiry: pick a date. It has to be renewed; that is the point of it having one.
- Copy it. Store it in **Passwords.app** (`/System/Applications/Passwords.app`)
  as a new entry — that is where you will get it after every reboot.

Existing tokens live at **https://github.com/settings/personal-access-tokens** —
that page also shows when each expires and lets you regenerate one in place.

**An organisation's repository needs a token of its own.** A fine-grained
token has one *Resource owner*, so the account's token cannot register runners
on, say, `acme-org/acme-org`. Make a second one the same way with *Resource
owner* set to the organisation (an organisation that requires approval for
fine-grained tokens holds it as pending until an owner approves), then give it
to the gate as that owner's:

```bash
pin-vault add gate-acme-org    # receiver: /home/<you>/.local/bin/ci-runner unlock --stdin --wait --owner acme-org
```

The gate uses each owner's token for that owner's repositories and the main
one for everything else; `status` lists the owners that have one. With the PIN
vault the second token is one more file under the same PIN, and the logon unlock opens both.
`registry` already lists the organisations' repositories with the topic — until
the owner's token is in, the gate logs a 404 for them and their jobs queue.

### 3. Say which repositories this machine serves

```sh
~/Projects/host-repo/ci-runner.sh adopt <owner>/<repo>     # or a checkout path
~/Projects/host-repo/ci-runner.sh list                     # the registry
~/Projects/host-repo/ci-runner.sh forget <owner>/<repo>
```

The list is a **topic on the repository** — `ci-local` — so it lives on GitHub
and not in a file here: visible and editable from the web, identical from a
second machine, and nothing to restore when this one is rebuilt. Being on the
list means *eligible*, not *running here*; that is still `CI_RUNNER`.

`adopt` refuses a public repository outright. A self-hosted runner on a public
repository executes code from anybody's fork on this machine, and that is not
something a convenience command should be able to switch on.

`adopt` then prints a report of what the repository still needs, and
`doctor <owner/repo>` prints the same one later, with no checkout. Both read the
default branch through `gh api` and write nothing into the project; `adopt`
exits 0 whatever the report finds, `doctor` exits non-zero on a `✗` line. It
says which jobs are off the switch (`!`, or "split" where other jobs of that
workflow follow it) and which switch is malformed (`✗`; the shape is compared,
the fallback is not, so `ubuntu-latest` and `ubuntu-24.04` both pass), which
steps need docker, which Node or Playwright version a workflow asks for that
`seed.list` does not hold, whether the gate holds a token for an owner other
than the account (named, never shown), and the `runs-on` lines to paste. A
workflow it cannot read is an error, not a clean result. `seed.list` stays the
trust list: the report names a gap and a person bumps the file.

After that there is nothing per repository to start: the gate is one for the
machine, reads this list, and `up`, `down` and `unlock` take no path. `on`
and `off` take a checkout or `owner/repo`, and `status` still names a checkout,
because the switch is a variable on that one repository.

### 4. Start the gate

```sh
~/Projects/host-repo/ci-runner.sh up
```

Flags, all optional: `--budget 10` (machine-wide, in cores), `--big-cap 8` (the most big runners may hold of it together), `--big-cpus 4`
`--big-memory 4g` `--big-shares 2048` (the expensive class — e2e), `--little-cpus 4`
`--little-memory 2g` `--little-shares 1024` (the cheap one — lint, typecheck,
unit), `--label local-docker`, `--poll 10`, `--defer 0`, `--host TAG`.

Every one of these except `--label` can be given to `install`, which stores
them in `machine/flags` under the state directory (`KEY=value` lines, read
as text and never executed). `up` with no flags then starts the gate with the
stored values; a flag on the `up` line wins for that start and is not stored, and
`install` again with a flag replaces just that one. The label is kept apart, in
`machine/label`, written by `up --label`; `on`, `status` and `doctor` read the
same file, so they agree with the gate.

`cpus` is the same for both classes on purpose — it is what Playwright reads
to size its worker pool, not what makes a class light, and without a quota a
job runs seven Chromium contexts on this machine where the hosted runner runs
two. What separates the classes is `cpu-shares`: measured 2026-09-16, a
`--cpus 4` runner beside three other busy slots got about one core regardless
of its quota — a ceiling is not a reservation under contention, and
`cpu-shares` is the priority that actually matters when several runners want
the same cores at once. `--budget` is the ceiling, in cores rather than
containers, so raising a class's cost only leaves room for fewer at once.

It comes up **locked**: it has no credential and will do nothing until given
one.

### 5. Unlock it

Copy the token from Passwords.app, then:

```sh
~/Projects/host-repo/ci-runner.sh unlock
```

It reads the clipboard (or stdin if you pipe into it), checks the token against
GitHub before storing it, prints its expiry date, and puts it on a **tmpfs**
inside the gate. Nothing is written to disk — not on the host, not in the
container's layers, not in `docker inspect`.

Nothing shows up in `status` until a job is actually queued for this
machine's labels — that is the trade for not keeping anything warm.

### 6. Make the workflow able to switch

Every job that should be movable reads the variable. A job that does not say
it is light is big — that is the safe default, since e2e is the job a wrong
guess would hurt:

```yaml
jobs:
  verify:
    runs-on: ${{ vars.CI_RUNNER == '1' && (vars.CI_RUNNER_LABEL || 'local-docker') || 'ubuntu-latest' }}
  lint:
    runs-on: ${{ vars.CI_RUNNER == '1' && (vars.CI_RUNNER_LABEL_LIGHT || 'local-docker-light') || 'ubuntu-latest' }}
```

A job that follows the switch cannot use docker here: no `services:`, no
`container:`, no `docker run`. `ci-runner.sh on` and the watch read the
default branch's workflows and refuse a repository that has any, naming the file
and line. A job that truly needs docker takes a fixed `runs-on: ubuntu-latest`,
which keeps it on GitHub whatever the switch says.

There is a third label, `<label>-now`, for work that should be served before
older jobs — a hotfix pipeline, or a release. It is a `big` runner in
everything that costs: same cores, same memory, the same price against the
budget and the same cap. The only difference is that the queue is sorted with
it first, and ordinary jobs keep their own order behind it.

What it does **not** do is start sooner than a slot exists. Every runner here
is single-use and nothing is preempted, so an urgent job still waits for one
of the running jobs to finish — the wait becomes one job long instead of one
queue long. Guaranteeing an immediate start needs a runner kept idle for the
chance of urgent work, which costs that runner all the time; this costs
nothing and is usually what was actually wanted.

Give it out sparingly. A label that everything carries is a label that orders
nothing.

### The mega class: one job that takes the whole machine

A fourth label, `<label>-mega`, is for the one job that wants every core —
acme-org's mutation run. It is not a bigger tier with its own arithmetic: it
costs the *whole budget*, read live. So it starts only on an empty machine,
holds the machine while it runs (nothing else fits), and a queued mega job stops
everything behind it from starting — the gate drains, which is the only way a
stream of small jobs ever lets the machine empty. It is sized from the machine:
all cores but 2 and all memory but 4 GiB (`--mega-cpus`, `--mega-memory`).

The switch is the repository variable `CI_RUNNER_LABEL_MEGA`, written by
`ci-runner.sh mega on|off <path|owner/repo>`. With it unset, the job's
`runs-on` falls through to `CI_RUNNER_LABEL` and it runs as an ordinary big.
Likewise with `--mega-cpus 0` (the default on a mac, and the right one there:
its Docker VM is the machine): the label is still served, as an ordinary big.
`mega on` refuses unless the running gate serves mega, so **deploy the gate
before `mega on`**. A run queued before `off` keeps its mega label.

The workflow edit, on the one job that needs it and no other (not a label
array — `runs-on: [a, b]` means *both*):

```yaml
    runs-on: ${{ vars.CI_RUNNER == '1' && (vars.CI_RUNNER_LABEL_MEGA || vars.CI_RUNNER_LABEL || 'local-docker') || 'ubuntu-latest' }}
```

A hold longer than `MEGA_DRAIN_WARN` (`--mega-drain-warn`, 1800s) is logged once
and shown by `status` and in `status.json` as `draining`; nothing is killed. A
busy mega runner is removed after `MEGA_MAX_BUSY` (`--mega-max-busy`, 7200s);
the ordinary 2700s swept a mutation job that was working.

Four variables, because they answer different questions and change at
different rates:

| variable | means | who writes it |
| --- | --- | --- |
| `CI_RUNNER` | is this on — `1` here, `0` or unset for GitHub | you, weekly, via `on`/`off` or the web UI |
| `CI_RUNNER_LABEL` | where "here" is, for the big class | `on`, copied from the gate's own label |
| `CI_RUNNER_LABEL_LIGHT` | where "here" is, for the little class | `on`, the same label plus `-light` |
| `CI_RUNNER_LABEL_MEGA` | the whole-machine class is on for this repository | `mega on`/`off`; unset means an ordinary big |

The flag is `1`/`0` rather than a label because a label is a routing key: mistype
it and the job queues, nothing claims it, and GitHub never says which label it
was waiting for. The destination stays a variable so that "somewhere other than
GitHub" is not hard-coded to this laptop — a third-party runner provider's label
goes in `CI_RUNNER_LABEL` and CI moves without touching the workflow. `doctor`
compares both against the gate's own labels.

Unset is the default, so a fork or a fresh clone still gets a hosted runner.
Move **every** job in a workflow together — a self-hosted pull-request check
and a hosted merge check would hide the architecture difference in the one
place nobody looks. `doctor` fails if no workflow interpolates it.

### 7. Point CI here

```sh
~/Projects/host-repo/ci-runner.sh on <owner>/<repo>
```

and back:

```sh
~/Projects/host-repo/ci-runner.sh off <owner>/<repo>
```

`on` and `off` take `owner/repo` as well as a checkout path, from any directory,
so the repository need not be cloned where you are. A name that is neither a
directory nor `owner/repo` is refused, and so is a repository that does not
exist.

---

## Every day

Nothing — until the machine reboots. Then, once:

1. Start Docker Desktop.
2. `ci-runner.sh unlock` (token from Passwords.app).

That is the price of keeping no credential on disk. Between the reboot and the
unlock, jobs queue and nothing fails loudly; `status` says `LOCKED`, and the
gate's log says it too.

## When the machine is busy with something else

The gate counts its own runners against the budget, and also looks at the
machine. Before it starts a job it reads the free memory (`MemAvailable`) and
the one-minute load average. Below the memory floor, or above the load ceiling,
the job waits and the gate logs why, once per wait; the next tick that finds
enough room starts it. Runners the gate starts in the same pass count as
using their `--memory` ceiling. A runner that is already idle for a job takes
it with no check.

The two limits are one number each, one file each, in
`~/.config/machine-limits/` (mounted read-only at `/etc/machine-limits`):

| file | meaning | default |
|---|---|---|
| `memory-floor-mb` | start a job only if at least this many MiB are available | 2048 |
| `load-ceiling` | start a job only if the one-minute load is not above this | the number of cores the gate sees |

Absent means the default. A value that is not an integer also means the
default and is named once in the gate log. To change one, write the file
(`echo 4096 > ~/.config/machine-limits/memory-floor-mb`); the gate reads both
at the start of every tick, so no restart and no unlock. `up` creates the
directory but never writes a value into it.

This makes jobs queue instead of hanging the machine. It does not create room:
a machine already full of something else stays full, and CI waits for it.

## Reading it from outside, and replacing the gate

`ci-runner.sh status --json` is the contract for the panel: one JSON document
on stdout, described by `status.schema.json` next to this file, and nothing
else on stdout. It takes no path. It carries the gate (`state`, `locked`,
`paused`, the `commit` it was built from, the token expiries), the file the gate
rewrites every tick at `/run/gate/status.json` (the queue, runners busy, cores
used against the budget, free memory and load against their limits, and why a
job is waiting; passed through as it is, so its `ts` says how fresh it is), and
each registered repository's `CI_RUNNER` switch. The switch is read from GitHub
and kept for 60 seconds, so asking often costs nothing. The gate file holds no
token, and `status --json` reads none: only whether one exists and the expiry
files beside it.

`ci-runner.sh on <repo> --json` (also `--all`) answers the same way: `ok`, and
on a refusal every blocker as one entry, instead of the lines it prints
otherwise. It still exits non-zero when something was refused.

`ci-runner.sh redeploy [--yes]` replaces the gate with one built from this
checkout, for a gate change that should not cost a job:

1. It says what it will do (the new gate is locked and needs the PIN; the live
   budget resets) and asks, at a terminal. With no terminal and no `--yes` it
   refuses and changes nothing.
2. It pauses and waits for the jobs running here (`drain`). If they do not
   finish in time it resumes and stops, the gate as it was.
3. It tags the old image `ci-gate:previous`, builds the gate image alone (the
   runner image is not rebuilt, the latest runner is not looked up) with the
   commit as `GATE_COMMIT`, and starts it with the flags `install` stored.
4. It opens the PIN prompt, where there is one (the `pin-vault unlock`
   scheduled task of a Windows host; elsewhere it says to unlock).

What it does not do: rebuild the runner image or reseed, change the registry,
the label or any repository's switch, or carry the credential across (nothing
can; it lives on the old gate's tmpfs). **It resets the live budget to the boot
flags**, because the live override is a file on that tmpfs. A gate that was paused when it started is paused again once the new one is
up, and a failed drain or build leaves that pause alone; only a pause redeploy
itself set is lifted. It reads the override
before it writes anything, and the last line it prints is the command that puts
it back, e.g. `ci-runner.sh budget 23 --big-cap 13`. A failed build leaves the
old gate running and resumed. To go back to the previous image:
`docker tag ci-gate:previous ci-gate:local`, then `ci-runner.sh up`.

## Turning it off

- **For a while, keeping the credential**: `ci-runner.sh pause` — running
  jobs finish, nothing new starts, the gate stays up and unlocked;
  `ci-runner.sh resume` takes work again with no unlock. `status` says
  `PAUSED`. A reboot clears the pause along with the token.
- **Before a reboot, a `wsl --shutdown`, or a game**: `ci-runner.sh drain`
  — a pause that returns once GitHub reports nothing of this gate's busy
  (`--timeout N`, default 30 minutes), so whatever comes next costs nobody
  a job.
- **For now**: stop `ci-gate` in Docker Desktop, or `ci-runner.sh down`.
  Stopped stays stopped. The gate removes its idle runners on the way
  out and leaves a busy one to finish its job. Coming back is `up` and an
  unlock — which is why `pause` exists.
- **Also stop sending work here**: `ci-runner.sh off <path>` — otherwise CI
  queues against runners that no longer exist.
- **Completely**: `ci-runner.sh purge --all` — gates, runners, images, the
  cache volumes, a work folder an older gate left (it names what needs
  `sudo`), and any leftover launchd job.

## Moving to another machine

1. Clone the host-repo repository there.
2. `ci-runner.sh build`
3. `ci-runner.sh up` and `unlock` with the same token from
   Passwords.app — it is not tied to a machine.

Nothing else is carried: no registration, no state, no key material. The old
machine is retired by stopping its gate; its runner registrations are
single-use and expire on their own, and `prune` removes any stragglers.

## A second machine that helps when it is on

Same three steps, same label (the default, `local-docker`), same token — and
no variable changes anywhere. The two gates never learn about each other;
what keeps them from both answering one job is that the machine that should
yield starts with a delay:

```sh
ci-runner.sh up --defer 30        # on the laptop: leave a job alone for 30s
ci-runner.sh up                   # on the desktop: take it at once
```

A job the desktop takes is `in_progress` before the laptop looks again; a job
the desktop cannot take — it is off, or at its budget — ages past thirty
seconds and the laptop takes it. Overflow spills across machines by itself,
and a desktop that goes away leaves nothing behind, because nothing pointed
at it. `status` prints which side a gate is on.

The desktop is the taking side because it has more cores and is x64 — the
same architecture as GitHub's runners — and because the one race left (a
duplicate runner inside the ~10s registration window) should cost the machine
with room to spare. Expect a job to land on either architecture depending on
what is on; a workflow that passes only on one of them is not fixed.

## On a Windows host

The gate runs inside WSL2, not from a Windows shell: the machine-limits
directory is bind-mounted from the host, and from Windows that path is
`C:\…` to the shell and `/mnt/c/…` to the daemon — the "mounts an empty
directory" row in the failure table. Inside WSL2 the host is Linux and
`ci-runner.sh` runs as it does on the mac.

1. `wsl --install -d Ubuntu-24.04`, with `systemd=true` in `/etc/wsl.conf`.
2. Docker Desktop with WSL integration for that distro, or docker-ce inside
   it — the gate is indifferent. Docker Desktop is the one with the window.
3. Inside WSL: clone the host-repo to `~/Projects/host-repo`, `gh auth login`,
   `ci-runner.sh build`, `ci-runner.sh install` (it writes
   `~/.local/bin/ci-runner`, which the receiver below names; the logon task
   reads no `~/.profile`), `ci-runner.sh up`.
4. `tools/pin-vault/pin-vault add gate` — asks for a PIN and then
   `/home/<you>/.local/bin/ci-runner unlock --stdin --wait` as the receiver, written out, and the token (hidden), and
   stores them in `~/.local/share/pin-vault/gate.bin`. `pin-vault unlock`
   hands the token to the gate and asks for the PIN only; link the command
   into `~/.local/bin` as `tools/pin-vault/README.md` says. A token for an
   organisation is `pin-vault add gate-<owner>` with `... unlock --stdin
   --wait --owner <owner>` (`--owner acme-org`, `gate-acme-org`). `--wait` makes the receiver return at once and
   wait for Docker and the gate in a process of its own (`--timeout N`,
   default 300 seconds); if it gives up the token is dropped and
   `~/.local/state/ci-runner/machine/unlock.log` says why. The window does
   not show whether the gate came up: `ci-runner.sh status` and that log do. Tokens stored in the old format, in
   `~/.config/ci-runner/`, move once with
   `tools/pin-vault/move-old-tokens.sh ~/.config/ci-runner`.
5. From a Windows PowerShell, once: `windows/install-tasks.ps1`, a
   hidden logon task that holds the WSL VM open — WSL stops it a minute after
   the last Windows process detaches, whatever runs inside — and
   `tools\pin-vault\windows\install-logon-task.ps1`, a visible one that opens a window
   for the PIN (`pin-vault unlock`, which waits for nothing) and removes the
   old `ci-runner unlock` task. `-Remove` takes each out.

After a reboot: sign in, type the PIN, done. Between the two, jobs queue and
`status` says `LOCKED`, exactly as on the mac. Why a PIN rather than a script
that unlocks by itself is in the docs: a passphrase next to the blob is an
encoding, and the PIN is the one key that is not on the machine.

On a mac it is the same `pin-vault`, with the login Keychain holding the
outer layer instead of DPAPI (`tools/pin-vault/macos/keychain.sh` — one random
key in the Keychain, an AES pass under it, shared by every file). To change
the PIN, `pin-vault repin`; to replace a token, `pin-vault update <name> --token`, which asks for the PIN and the new value and leaves the receiver and the note as they were.

## When the allowance runs out on its own

```sh
~/Projects/host-repo/ci-runner.sh watch ~/Projects/<repo> --reserve 30
```

Checks every fifteen minutes; under 30 included minutes it sets the switch, and
clears it again when the monthly allowance resets — but only if it was the
thing that set it, so a switch you flipped by hand is never undone by a timer.
This is the one piece that still uses launchd, because it runs on your own `gh`
credential rather than the gate's; `unwatch` removes it. It works where
`launchctl` exists, which is macOS. On WSL and plain Linux `watch` and
`unwatch` refuse, naming launchd, before they write anything; run `autoswitch`
from your own scheduler there.

Reading the balance needs a scope `gh auth login` does not grant:

```sh
gh auth refresh -h github.com -s user
```

Without it `autoswitch` still works, one failed run later: it watches for runs
GitHub refused to start. `ci-runner.sh autoswitch <path> --dry-run` says what it
would do.

---

## Every URL you will want in a year

| what | where |
| --- | --- |
| the registry (repos tagged `ci-local`) | https://github.com/settings/repositories — or `ci-runner.sh list` |
| create the gate's token | https://github.com/settings/personal-access-tokens/new |
| see / renew / revoke it | https://github.com/settings/personal-access-tokens |
| classic tokens (if one was ever used) | https://github.com/settings/tokens |
| the repository's runners | `https://github.com/<owner>/<repo>/settings/actions/runners` |
| the repository's variables (`CI_RUNNER` lives here) | `https://github.com/<owner>/<repo>/settings/variables/actions` |
| minutes used this month | https://github.com/settings/billing |
| what a run actually did | `https://github.com/<owner>/<repo>/actions` |
| revoke an OAuth app (e.g. `gh`) | https://github.com/settings/applications |

## What is in the runner image

Ubuntu 24.04, the Actions runner, `git`, `gh`, `jq`, `python3`, `psql`, a PostgreSQL 16 server (no cluster — a job that needs a database runs `initdb` and `pg_ctl` itself, as the hosted image also allows), and Chromium's shared
libraries so `npx playwright install chromium` works without `--with-deps`. No
docker client: a job starts what it needs inside its own container.

**Node is deliberately absent.** `actions/setup-node` finds it in
`/opt/hostedtoolcache`, so the local runner and the hosted one agree about which
node a job got.

**What a job can and cannot write between jobs.** The toolchain every
job executes — node, and Playwright's browsers — comes from the volume
`ci-runner-seed`, mounted read-only and linked into the tool cache and
`PLAYWRIGHT_BROWSERS_PATH` at start. Only `ci-runner.sh seed` writes it, from
the pinned versions in `seed.list`, in a container with no checkout and no
job; `build` runs it last. A version that is not seeded still works: the job
downloads it into its own container and it is gone afterwards. Bump
`seed.list` and run `seed` to make it warm. `~/.npm` and `~/.cache` are
per repository (`ci-runner-npm-<slug>`, `ci-runner-cache-<slug>`), and
`~/.npm/_npx` is cleared before every job. Until an earlier change all three were single
volumes shared read-write by every job of every repository, so a pull
request's dependency could rewrite the npm a later job anywhere would run. A
workflow needing a tool not listed above gets a line in the `Dockerfile` and a
rebuild — never an `apt-get` inside the job, which is undone on the next
container and paid for on every run.

**The four per-repository volumes are locked between concurrent runners.** Every runner holds a shared `flock` on `<volume>/.inuse` from its
entrypoint until the runner process ends, so `cache-cap.sh` (which takes the
same file exclusively, without waiting) skips a busy volume with an "in use"
line instead of emptying it under a running job; it is capped by the next job
to start when nobody is on it. The git volume has a second lock, `.sync`,
taken exclusively by the entrypoint's copy-out and by the sync-back in
`job-completed.sh`; the sync-back builds `.git.new` and swaps it in with `mv`,
so a sync that fails half way leaves the old `.git` whole. Changing these
takes an image rebuild only, not a gate restart.

## When something does not run

| symptom | cause |
| --- | --- |
| `status` says `LOCKED` | the machine rebooted — unlock it |
| gate log: `404 — not on the token` | that repository is missing from the token's list; add it (the token value does not change) and unlock |
| gate log: `403 … GitHub wants: actions=read` | this repository needs `Actions: Read-only`; the header quotes the exact permission |
| gate log: `401` | the token expired or was revoked — make a new one and unlock |
| a repository never wakes | almost always the `Actions` permission above; the gate says so once per repository |
| job queued, nothing picks it up | the variable's value and the runner's label disagree — `status` prints both, for both classes |
| nothing at all after a reboot | Docker Desktop is not running; the gate cannot start without it |
| a service on `localhost:<port>` is unreachable from a step | add the port to `CI_RUNNER_LOOPBACK_PORTS` (default `5432`) in the runner image |
| runner list on GitHub fills with offline entries | the gate prunes every five minutes; `ci-runner.sh prune <path>` does it now |
| a runner container will not start | `docker logs ci-gate` — the gate logs every `docker run` it attempts |
| e2e runs take several times longer than alone, and fail on their own timeouts | more cost queued than the budget holds — `ci-runner.sh status` shows `used/BUDGET`; `--cpu-shares` is priority, not a promise of cores |
| `budget: N/BUDGET used, <class> for <repo> waits` in the log | expected under load — FIFO means it gets a runner as soon as one frees up; raise `--budget` only if the machine actually has the cores |
| a job waits ~30s before anything starts, only on one machine | that gate runs with `--defer` — it is yielding to the other machine, which is off; `status` prints the value |
| `<class> already answered by another machine on this label` in the log | the other gate got there first; this one skipped the tick. Expected with two machines; a duplicate anyway is the ~10s registration window |
| (Windows) CI dies a minute after the terminal is closed | WSL stopped the VM — the `ci-runner keepalive` logon task is missing or stopped; `install-tasks.ps1` |
| (Windows) Docker Desktop: `rename …sock …sock.stale: The file cannot be accessed by the system` | a socket left by a Docker process that died; the kernel holds it until reboot. Quit, rename `%LOCALAPPDATA%\Docker\run` (and any other directory holding a `.sock`) out of the way, start again |
| a job's own steps finished and the check still says `in_progress`, so the pull request will not merge | the runner is wedged in a post step. Measured 2026-09-22 on the Windows host: 127 seconds of work, then 27 minutes in `Post Run actions/checkout@v7`, and the workflow's own `timeout-minutes` did not cut it — that limit is enforced by the runner process, which is the thing that is stuck. The gate now removes one of its own containers busy longer than `MAX_BUSY` (45 min); GitHub then marks the job failed, and `gh run rerun` is the fix. To cut it sooner, `gh run cancel` |
| gate log: `removing <runner> — busy Ns, past MAX_BUSY` | the line above, fired. Expected to be rare; if it repeats on one machine, that machine's Docker or filesystem is the place to look |
| `useradd … exit code 4` during `build` | the host uid is already a user in the base image (1000 is `ubuntu` on `ubuntu:24.04`). The Dockerfile evicts it; if this fires, the eviction is gone |
| `~/.ci-runner/work` is gigabytes and `rm -rf` says `Permission denied` | left by a gate older than an earlier change, which kept each runner's checkout there; nothing uses it now. The slot contents are yours to remove; the `work/<repo>` directories were made by docker as root and need `sudo rm -rf ~/.ci-runner/work` |
| a job log starts with `▸ /home/runner/.npm holds N MiB, over the … cap — emptied` | that repository's cache passed `CI_CACHE_CAP_MB` (2048) and this job rebuilds it; expected now and then, not every job |

## Why no tunnel, and why a dynamic IP does not matter

There is nothing for a tunnel to connect to. Both containers dial GitHub over
HTTPS and hold the connection open; jobs arrive as responses on connections
this machine opened. No inbound port, no public hostname, no DNS record, and
therefore no need for a static address — NAT, CGNAT, a phone hotspot and a VPN
are all fine. What is needed is outbound 443 to `github.com`, `api.github.com`,
`*.actions.githubusercontent.com` and `objects.githubusercontent.com`, plus
whatever a job itself fetches. An address that changes mid-job costs at most
that job.

The webhook-driven design — GitHub calling you when a job is queued — is the
one that would need the tunnel. This polls instead, which is also what GitHub's
own runner scale sets do.
