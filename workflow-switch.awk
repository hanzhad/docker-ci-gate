# Reads one workflow file and prints one finding per job whose `runs-on` is not
# the CI_RUNNER switch, tab-separated: `kind<TAB>line<TAB>job<TAB>what`. Kinds:
#   switch   the job has the switch, in the shape `on` writes
#   bad      the job reads CI_RUNNER but not in that shape
#   fixed    the job has some other runs-on, so the switch never moves it
#   split    like fixed, in a workflow where another job does follow the switch
# A job with no `runs-on` (a reusable-workflow call) is skipped.
#
# The shape is compared and the fallback is not: it differs by project
# (`ubuntu-latest`, `ubuntu-24.04`), and the label is any string, for the same
# reason. What must hold is the flag compared with '1' and the label read from a
# variable, because a label with no variable cannot be moved by `on`.
#
# Line by line rather than a YAML parser, as in workflow-blockers.awk: the host
# has none to rely on, and the only structure wanted is where each job starts.

function finish_job() {
  if (name != "" && runs_line > 0) {
    n++; jname[n] = name; jline[n] = runs_line; jkind[n] = kind
    if (kind != "fixed") any_switch = 1
  }
  name = ""; runs_line = 0; kind = ""
}

/^[ \t]*(#.*)?$/ { next }

/^jobs:/ { in_jobs = 1; job_indent = -1; next }
/^[^ \t]/ { if (in_jobs) finish_job(); in_jobs = 0; next }
!in_jobs { next }

{
  match($0, /^ */)
  if (job_indent < 0) job_indent = RLENGTH
  if (RLENGTH == job_indent) {
    finish_job()
    name = $1; sub(/:.*/, "", name); gsub(/["']/, "", name)
    next
  }
}

/^[ \t]*runs-on:/ && runs_line == 0 {
  runs_line = FNR
  if ($0 ~ /CI_RUNNER/) {
    if ($0 ~ /[$][{][{][ ]*vars[.]CI_RUNNER[ ]*==[ ]*'1'[ ]*[&][&][ ]*[(][ ]*vars[.]CI_RUNNER_LABEL(_LIGHT)?[ ]*[|][|][ ]*'[^']+'[ ]*[)][ ]*[|][|][ ]*'[^']+'[ ]*[}][}]/) kind = "switch"
    else kind = "bad"
  } else kind = "fixed"
}

END {
  if (in_jobs) finish_job()
  for (i = 1; i <= n; i++) {
    if (jkind[i] == "switch") what = "on the switch"
    else if (jkind[i] == "bad") what = "reads CI_RUNNER but is not the switch: vars.CI_RUNNER == '1' && (vars.CI_RUNNER_LABEL || '<label>') || '<fallback>'"
    else if (any_switch) what = "split: the switch moves the other jobs of this workflow, not this one"
    else what = "runs-on is not the switch, so CI_RUNNER never moves it"
    k = jkind[i]; if (k == "fixed" && any_switch) k = "split"
    printf "%s\t%d\t%s\t%s\n", k, jline[i], jname[i], what
  }
}
