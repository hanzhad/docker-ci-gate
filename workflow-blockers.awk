# Reads one workflow file and prints `line: what` for everything a job that
# follows the CI_RUNNER switch does that the runner image cannot: it has no
# docker client and no socket. A job with a fixed `runs-on` is not
# reported, because the switch never moves it, which is how a job that truly
# needs docker stays on GitHub.
#
# Line by line rather than a YAML parser: the host has none to rely on, and the
# only structure wanted here is where each job starts.

function flush_job(i) {
  if (follows_switch) for (i = 0; i < found; i++) print hits[i]
  found = 0; follows_switch = 0
}
function hit(what) { hits[found++] = FNR ": " what }

/^[ \t]*(#.*)?$/ { next }

/^jobs:/ { in_jobs = 1; job_indent = -1; next }
/^[^ \t]/ { if (in_jobs) flush_job(); in_jobs = 0; next }
!in_jobs { next }

{
  match($0, /^ */)
  if (job_indent < 0) job_indent = RLENGTH
  if (RLENGTH == job_indent) { flush_job(); next }
}

/^[ \t]*runs-on:/ && /CI_RUNNER/ { follows_switch = 1 }
/^[ \t]*services:/ { hit("services: needs docker on the runner") }
/^[ \t]*(- )?container:/ { hit("container: needs docker on the runner") }
/uses:[ \t]*["']?docker:\/\// { hit("a docker:// action needs docker on the runner") }
/(^|[^[:alnum:]_.\/-])docker(-compose)?[ \t]+(run|compose|build|exec|pull|up)([ \t]|$)/ { hit("calls docker") }

END { if (in_jobs) flush_job() }
