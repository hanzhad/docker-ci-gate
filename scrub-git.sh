#!/usr/bin/env bash
#
# scrub-git.sh <path>… — remove from each checkout's or bare repository's .git
# whatever could run code in the next job of this repository.
#
# The persistent volume ci-runner-git-$slug outlives the container, and the next
# job's checkout reuses this .git rather than cloning from scratch, with
# safe.directory=* in force (Dockerfile). That next job may be a release job
# with secrets. So hooks are emptied, and every config key that names a program
# or pulls in another file is removed: core.hooksPath, core.fsmonitor,
# include/includeIf, core.sshCommand, core.gitProxy, core.pager, core.editor,
# core.askPass, diff.external, gpg.program, credential.helper, filter.*,
# diff.*.textconv and alias.*. Read with --file, so the planted config is never
# loaded in order to be cleaned, and git is never pointed at the folder.
#
# Called twice around every job: by job-completed.sh when a job reaches its
# end before syncing .git back to the volume, and by entrypoint.sh before the
# runner pre-populates the workspace.
#
# Never fails: a scrub that cannot run is a folder to look at, not a red check.
set -u

for ws in "$@"; do
  git_dir="$ws"
  if [ -d "$ws/.git" ]; then
    git_dir="$ws/.git"
  fi
  [ -d "$git_dir" ] || continue
  rm -rf "$git_dir/hooks" 2>/dev/null; mkdir -p "$git_dir/hooks" 2>/dev/null
  cfg="$git_dir/config"
  [ -f "$cfg" ] || continue
  git config --file "$cfg" --name-only --list 2>/dev/null \
    | grep -iE '^(core\.(hookspath|fsmonitor|sshcommand|gitproxy|pager|editor|askpass)|include\..*|includeif\..*|diff\.external|gpg\..*program|credential\..*helper|filter\..*|diff\..*\.textconv|alias\..*)$' \
    | sort -u \
    | while read -r key; do git config --file "$cfg" --unset-all "$key" 2>/dev/null; done
done

exit 0
