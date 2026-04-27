#!/usr/bin/env bash
# commits.sh — query and format the commit range base-commit..HEAD.
#
# Usage:
#   commits.sh list <feature>                # prints "<sha> <msg>" one per line
#   commits.sh yaml <feature>                # prints YAML list: [{sha, msg}, ...] (ready to paste into requirements.md)
#   commits.sh populate-requirements <feature>
#                                            # writes the YAML list into requirements.md's `commits:` field
#   commits.sh changed-files <feature>       # prints "<status>\t<adds>\t<dels>\t<path>" one per line
#                                            # status ∈ {A,M,D,R,C}; adds/dels are "-" for binary diffs.
#                                            # Renamed/copied paths normalize numstat brace syntax
#                                            # (`dir/{old => new}/file`) back to the post-rename path
#                                            # so renamed text files carry valid line stats. Used by
#                                            # mo-generate-implementation-diagrams and
#                                            # /mo-update-blueprint to bound their codebase reads.
#   commits.sh change-summary-fresh <feature>
#                                            # exit 0 if implementation/change-summary.md exists with
#                                            #   frontmatter base-commit + head matching the current
#                                            #   base..HEAD (cache hit — caller can reuse);
#                                            # exit 1 if it exists but is stale (cache miss — regenerate);
#                                            # exit 2 if the file is missing (no cache — generate fresh).
#                                            # No output; the caller branches on the exit code.
#
# Manual regression checks (run from a throwaway repo with `progress.sh init`
# + `progress.sh activate` + `progress.sh set base-commit=<sha>` already done;
# see `scripts/progress.sh` for the helper signatures):
#
#   # `yaml` should emit one entry per commit (regression for the
#   # heredoc-shadowed-stdin bug).
#   commits.sh yaml <feature>
#
#   # `changed-files` should report real adds/dels for renamed text files
#   # (regression for the numstat brace-expansion bug).
#   git mv old.txt new.txt && echo more >> new.txt && git commit -am rename
#   commits.sh changed-files <feature>   # expect: R\t<adds>\t<dels>\tnew.txt
#
#   # change-summary frontmatter should validate when the SHA happens to be
#   # all-numeric (regression for the YAML int-coercion bug):
#   frontmatter.sh init change-summary /tmp/x.md \
#     REQUIREMENTS_ID=11111111-1111-4111-8111-111111111111 \
#     FEATURE=alpha BASE_COMMIT=abcdef1 HEAD=1234567
#   frontmatter.sh validate /tmp/x.md change-summary

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

cmd="${1:-}"; shift || true

get_range() {
  local base
  base="$(mo_fm_get "$(mo_progress_file)" '.active.base-commit')"
  [[ -n "$base" && "$base" != "null" ]] || mo_die "base-commit not set in progress.md (no active feature, or stage < 3)"
  echo "${base}..HEAD"
}

case "$cmd" in
  list)
    feature="${1:?feature required}"
    range="$(get_range)"
    git log --pretty=format:'%H %s' "$range"
    echo
    ;;

  yaml)
    feature="${1:?feature required}"
    range="$(get_range)"
    # Run git log inside Python so the heredoc-as-script doesn't shadow stdin —
    # the same pattern populate-requirements uses.
    python3 - "$range" <<'PYEOF'
import sys, subprocess, yaml
rng = sys.argv[1]
log = subprocess.check_output(['git', 'log', '--pretty=format:%H\t%s', rng], text=True)
shas = []
for line in log.splitlines():
    if not line.strip():
        continue
    sha, msg = line.split('\t', 1)
    shas.append({'sha': sha, 'msg': msg})
print(yaml.safe_dump(shas, default_flow_style=False, sort_keys=False), end='')
PYEOF
    ;;

  populate-requirements)
    feature="${1:?feature required}"
    requirements_file="$(mo_blueprints_current "$feature")/requirements.md"
    [[ -f "$requirements_file" ]] || mo_die "requirements.md not found"
    range="$(get_range)"
    python3 - "$requirements_file" "$range" <<'PYEOF'
import sys, subprocess, re, yaml
path, rng = sys.argv[1], sys.argv[2]
log = subprocess.check_output(['git', 'log', '--pretty=format:%H\t%s', rng], text=True)
commits = []
for line in log.splitlines():
    if not line.strip(): continue
    sha, msg = line.split('\t', 1)
    commits.append({'sha': sha, 'msg': msg})
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
fm['commits'] = commits
with open(path, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
print(f'mo: populated {len(commits)} commits into {path}', file=sys.stderr)
PYEOF
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$requirements_file" requirements >/dev/null
    ;;

  changed-files)
    feature="${1:?feature required}"
    range="$(get_range)"
    base="${range%..*}"
    python3 - "$base" <<'PYEOF'
import re, sys, subprocess
base = sys.argv[1]
ns = subprocess.check_output(['git', 'diff', '--name-status', f'{base}..HEAD'], text=True)
nu = subprocess.check_output(['git', 'diff', '--numstat', f'{base}..HEAD'], text=True)

# name-status emits one of: "A\tpath", "M\tpath", "D\tpath", "Rxxx\told\tnew", "Cxxx\told\tnew".
status = {}
for line in ns.splitlines():
    if not line.strip():
        continue
    parts = line.split('\t')
    s = parts[0][0]  # first char: A/M/D/R/C
    path = parts[2] if s in ('R', 'C') else parts[1]
    status[path] = s

# numstat brace expansion: "dir/{a => b}/file" → ("dir/a/file", "dir/b/file").
# Used for rename/copy paths so we can match numstat lines back to the new path
# that name-status records.
brace_re = re.compile(r'\{([^{}]*) => ([^{}]*)\}')

def expand_brace(p):
    m = brace_re.search(p)
    if not m:
        return p, p
    old, new = m.group(1), m.group(2)
    old_path = brace_re.sub(old, p, count=1)
    new_path = brace_re.sub(new, p, count=1)
    # Collapse double slashes from empty segments (e.g. "{ => dir}/x" → "/dir/x").
    old_path = re.sub(r'/+', '/', old_path).strip('/')
    new_path = re.sub(r'/+', '/', new_path).strip('/')
    return old_path, new_path

# numstat emits "adds\tdels\tpath"; "-" for both on binary diffs.
stats = {}
for line in nu.splitlines():
    if not line.strip():
        continue
    parts = line.split('\t')
    if len(parts) < 3:
        continue
    adds, dels = parts[0], parts[1]
    raw_path = '\t'.join(parts[2:])  # numstat may emit "adds\tdels\told\tnew" for renames without -M
    if '\t' in raw_path:
        # Old-style numstat rename: "adds\tdels\told\tnew". The new path is what
        # name-status reports.
        old_path, new_path = raw_path.split('\t', 1)
        stats[new_path] = (adds, dels)
        stats[old_path] = (adds, dels)
    elif ' => ' in raw_path:
        old_path, new_path = expand_brace(raw_path)
        stats[new_path] = (adds, dels)
        stats[old_path] = (adds, dels)
    else:
        stats[raw_path] = (adds, dels)

for path, s in sorted(status.items()):
    a, d = stats.get(path, ('-', '-'))
    print(f'{s}\t{a}\t{d}\t{path}')
PYEOF
    ;;

  change-summary-fresh)
    feature="${1:?feature required}"
    summary_file="$(mo_impl_dir "$feature")/change-summary.md"
    if [[ ! -f "$summary_file" ]]; then
      exit 2
    fi
    cur_base="$(mo_fm_get "$(mo_progress_file)" '.active.base-commit')"
    cur_head="$(git rev-parse HEAD)"
    cached_base="$(mo_fm_get "$summary_file" base-commit 2>/dev/null || echo "")"
    cached_head="$(mo_fm_get "$summary_file" head 2>/dev/null || echo "")"
    if [[ "$cur_base" == "$cached_base" && "$cur_head" == "$cached_head" ]]; then
      exit 0
    fi
    exit 1
    ;;

  *)
    echo "usage: commits.sh {list|yaml|populate-requirements|changed-files|change-summary-fresh} ..." >&2
    exit 2
    ;;
esac
