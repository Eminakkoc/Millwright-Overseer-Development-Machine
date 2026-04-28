#!/usr/bin/env bash
# progress.sh — manage progress.md (central workflow state) inside the
# active quest cycle's subfolder, resolved via quest/active.md →
# millwright-overseer/quest/<slug>/progress.md.
#
# The file tracks the feature queue, completed features, and the currently
# active feature's runtime state. Activation is two-step: finish sets the
# active block to null; activate pops queue[0] into a fresh active block.
#
# Usage:
#   progress.sh init <todo-list-id> <feature1> [<feature2> ...]  # stage 1: scaffold
#   progress.sh activate                     # stage 2: pop queue[0] into active
#   progress.sh finish                       # stage 8: active -> completed, active=null
#   progress.sh requeue                      # abort --drop-feature=requeue: active -> end of queue, active=null
#   progress.sh reset                        # abort recovery: keep feature+branch, reset other active fields
#   progress.sh reorder <feature1> [<feature2> ...]  # stage 1.5: rewrite queue order;
#                                                    # new order MUST be a permutation of the
#                                                    # existing queue (same set of features —
#                                                    # no extras, no missing, no duplicates).
#                                                    # Errors if active is non-null.
#   progress.sh enqueue <feature1> [<feature2> ...]  # mid-cycle re-entry (Finding 6):
#                                                    # append features to the queue while
#                                                    # active is null. Refuses duplicates against
#                                                    # the union of queue + completed + active.feature.
#                                                    # Errors if active is non-null.
#
#   progress.sh get-active                   # prints active.feature or "null"
#   progress.sh queue-remaining              # prints queue entries, one per line
#
#   progress.sh get <field>                  # reads active.<field>; errors if active is null
#   progress.sh set <field>=<value> ...      # writes active.<field>; errors if active is null
#   progress.sh advance <expected-stage>     # increments active.current-stage if it matches
#
#   progress.sh check-worktree               # pre-flight: errors if the current working tree is
#                                            # not the one that activated the cycle. No-op when
#                                            # active is null or the fingerprint isn't recorded
#                                            # (cycles activated before the worktree-fingerprint
#                                            # change shipped). Mutating commands above call the
#                                            # same guard internally; this entry-point exists so
#                                            # command markdowns can fail fast pre-implementation.
#
# Worktree fingerprint:
#   The active block records `worktree-path`, `git-common-dir`, and
#   `git-worktree-dir` at activation time (stage 2). Every state-mutating
#   command compares the current working tree to those values and refuses
#   on mismatch. This protects two `git worktree add` checkouts that
#   share the same data_root from clobbering each other's active state.

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

# progress.md lives inside the active quest cycle's subfolder; resolve it
# every call so the path tracks the active-quest pointer.
progress_file() { mo_progress_file; }

require_file() {
  local file="$1"
  [[ -f "$file" ]] || mo_die "progress.md not found at $file (run /mo-run first)"
}

require_active() {
  local file="$1"
  local a; a="$(mo_fm_get "$file" active)"
  [[ "$a" != "null" && -n "$a" ]] || mo_die "no active feature (active is null — run 'progress.sh activate' first)"
}

cmd="${1:-}"; shift || true

case "$cmd" in
  init)
    todo_list_id="${1:?todo-list-id required}"; shift
    [[ $# -gt 0 ]] || mo_die "at least one feature required"
    dest="$(progress_file)"
    [[ ! -f "$dest" ]] || mo_die "progress.md already exists: $dest"
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" init progress "$dest" \
      "TODO_LIST_ID=$todo_list_id"
    # Populate queue from args.
    python3 - "$dest" "$@" <<'PYEOF'
import sys, re, yaml
path, *features = sys.argv[1:]
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
fm['queue'] = list(features)
with open(path, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
PYEOF
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$dest" progress >/dev/null
    mo_info "progress initialized with $# features in queue"
    ;;

  activate)
    dest="$(progress_file)"
    require_file "$dest"
    # Capture the worktree fingerprint up front so the active block records
    # which working tree owns the cycle. Subsequent state mutations are gated
    # on a match via mo_assert_worktree_match (common.sh).
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      || mo_die "progress.sh activate must run inside a git working tree (current dir: $PWD)"
    wt_path="$PWD"
    git_common_dir="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
    git_worktree_dir="$(cd "$(git rev-parse --git-dir)" && pwd)"
    python3 - "$dest" "$wt_path" "$git_common_dir" "$git_worktree_dir" <<'PYEOF'
import sys, re, yaml
path, wt_path, git_common_dir, git_worktree_dir = sys.argv[1:]
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
if fm.get('active') is not None:
    sys.stderr.write(f"error: active already set to feature={fm['active'].get('feature')}\n")
    sys.exit(1)
if not fm.get('queue'):
    sys.stderr.write("error: queue is empty — nothing to activate\n")
    sys.exit(1)
feat = fm['queue'].pop(0)
fm['active'] = {
    'feature': feat,
    'branch': None,
    'current-stage': 2,
    'sub-flow': 'none',
    'base-commit': None,
    'execution-mode': 'none',
    'planning-mode': 'none',
    'review-mode': 'none',
    'implementation-completed': False,
    'overseer-review-completed': False,
    'worktree-path': wt_path,
    'git-common-dir': git_common_dir,
    'git-worktree-dir': git_worktree_dir,
}
with open(path, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
print(feat)
PYEOF
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$dest" progress >/dev/null
    ;;

  finish)
    dest="$(progress_file)"
    require_file "$dest"
    require_active "$dest"
    mo_assert_worktree_match
    python3 - "$dest" <<'PYEOF'
import sys, re, yaml
path = sys.argv[1]
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
active = fm['active']
fm.setdefault('completed', []).append(active['feature'])
fm['active'] = None
with open(path, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
print(active['feature'])
PYEOF
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$dest" progress >/dev/null
    ;;

  requeue)
    dest="$(progress_file)"
    require_file "$dest"
    require_active "$dest"
    mo_assert_worktree_match
    python3 - "$dest" <<'PYEOF'
import sys, re, yaml
path = sys.argv[1]
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
active = fm['active']
fm.setdefault('queue', []).append(active['feature'])
fm['active'] = None
with open(path, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
print(active['feature'])
PYEOF
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$dest" progress >/dev/null
    ;;

  reset)
    dest="$(progress_file)"
    require_file "$dest"
    require_active "$dest"
    mo_assert_worktree_match
    python3 - "$dest" <<'PYEOF'
import sys, re, yaml
path = sys.argv[1]
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
old = fm['active']
fm['active'] = {
    'feature': old['feature'],
    'branch': old.get('branch'),
    'current-stage': 2,
    'sub-flow': 'none',
    'base-commit': None,
    'execution-mode': 'none',
    'planning-mode': 'none',
    'review-mode': 'none',
    'implementation-completed': False,
    'overseer-review-completed': False,
    'worktree-path': old.get('worktree-path'),
    'git-common-dir': old.get('git-common-dir'),
    'git-worktree-dir': old.get('git-worktree-dir'),
}
with open(path, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
PYEOF
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$dest" progress >/dev/null
    mo_info "reset active feature (feature + branch preserved)"
    ;;

  enqueue)
    [[ $# -gt 0 ]] || mo_die "at least one feature required"
    dest="$(progress_file)"
    require_file "$dest"
    python3 - "$dest" "$@" <<'PYEOF'
import sys, re, yaml
path, *new_features = sys.argv[1:]
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
# enqueue is a mid-cycle re-entry / pre-flight operation; reject if a feature is active.
if fm.get('active') is not None:
    sys.stderr.write(
        f"error: cannot enqueue while a feature is active "
        f"(feature={fm['active'].get('feature')}). "
        f"Wait for the active feature to finish (or run /mo-abort-workflow) first.\n"
    )
    sys.exit(1)
existing_queue = list(fm.get('queue', []))
completed = list(fm.get('completed', []))
known = set(existing_queue) | set(completed)
new_list = list(new_features)
# Refuse duplicates within the new args.
if len(new_list) != len(set(new_list)):
    seen = set()
    dups = []
    for feat in new_list:
        if feat in seen and feat not in dups:
            dups.append(feat)
        seen.add(feat)
    sys.stderr.write(f"error: duplicate features in enqueue args: {', '.join(dups)}\n")
    sys.exit(1)
# Refuse features already in queue or completed.
collisions = sorted(set(new_list) & known)
if collisions:
    in_queue = [f for f in collisions if f in existing_queue]
    in_done  = [f for f in collisions if f in completed]
    parts = []
    if in_queue:
        parts.append(f"already in queue: {', '.join(in_queue)}")
    if in_done:
        parts.append(f"already completed: {', '.join(in_done)}")
    sys.stderr.write(
        "error: enqueue refuses duplicates.\n"
        f"  problems: {'; '.join(parts)}\n"
    )
    sys.exit(1)
fm['queue'] = existing_queue + new_list
with open(path, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
print(f"mo: enqueued {len(new_list)} feature(s); queue is now: {', '.join(fm['queue'])}", file=sys.stderr)
PYEOF
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$dest" progress >/dev/null
    ;;

  reorder)
    [[ $# -gt 0 ]] || mo_die "at least one feature required"
    dest="$(progress_file)"
    require_file "$dest"
    python3 - "$dest" "$@" <<'PYEOF'
import sys, re, yaml
path, *new_order = sys.argv[1:]
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
# reorder is a stage-1.5 operation; reject if a feature is already active.
if fm.get('active') is not None:
    sys.stderr.write(
        f"error: cannot reorder while a feature is active "
        f"(feature={fm['active'].get('feature')}). "
        f"Reorder is a stage-1.5 operation; use /mo-abort-workflow first if needed.\n"
    )
    sys.exit(1)
existing = list(fm.get('queue', []))
existing_set = set(existing)
new_list = list(new_order)
new_set = set(new_list)
# Check for duplicates in the new order.
if len(new_list) != len(new_set):
    seen = set()
    dups = []
    for f in new_list:
        if f in seen and f not in dups:
            dups.append(f)
        seen.add(f)
    sys.stderr.write(f"error: duplicate features in new order: {', '.join(dups)}\n")
    sys.exit(1)
# Check the new order is a permutation of the existing queue.
if existing_set != new_set:
    missing = sorted(existing_set - new_set)
    extra = sorted(new_set - existing_set)
    msg_parts = []
    if missing:
        msg_parts.append(f"missing from new order: {', '.join(missing)}")
    if extra:
        msg_parts.append(f"not in existing queue: {', '.join(extra)}")
    sys.stderr.write(
        "error: new order must be a permutation of the existing queue.\n"
        f"  existing: {', '.join(existing) if existing else '(empty)'}\n"
        f"  problems: {'; '.join(msg_parts)}\n"
    )
    sys.exit(1)
# No-op short-circuit: leave file untouched if order is unchanged.
if existing == new_list:
    sys.stderr.write("mo: reorder is a no-op (queue order unchanged)\n")
    sys.exit(0)
fm['queue'] = new_list
with open(path, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
print(f"mo: queue reordered to: {', '.join(new_list)}", file=sys.stderr)
PYEOF
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$dest" progress >/dev/null
    ;;

  get-active)
    dest="$(progress_file)"
    require_file "$dest"
    mo_fm_get "$dest" '.active.feature'
    ;;

  queue-remaining)
    dest="$(progress_file)"
    require_file "$dest"
    mo_fm_get "$dest" '.queue[]'
    ;;

  get)
    field="${1:?field required}"
    dest="$(progress_file)"
    require_file "$dest"
    require_active "$dest"
    mo_fm_get "$dest" ".active.${field}"
    ;;

  set)
    [[ $# -gt 0 ]] || mo_die "at least one field=value required"
    dest="$(progress_file)"
    require_file "$dest"
    require_active "$dest"
    mo_assert_worktree_match
    for kv in "$@"; do
      field="${kv%%=*}"
      value="${kv#*=}"
      # The worktree fingerprint is captured once at activate; refuse
      # later overwrites so the guard's anchor can't be erased.
      case "$field" in
        worktree-path|git-common-dir|git-worktree-dir)
          mo_die "progress.sh set: $field is immutable after activate (captured at stage 2)"
          ;;
      esac
      python3 - "$dest" "$field" "$value" <<'PYEOF'
import sys, re, yaml
path, field, value = sys.argv[1:]
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
try:
    parsed = yaml.safe_load(value)
except yaml.YAMLError:
    parsed = value
fm['active'][field] = parsed
with open(path, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
PYEOF
    done
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$dest" progress >/dev/null
    ;;

  advance)
    expected="${1:?expected current-stage required}"
    dest="$(progress_file)"
    require_file "$dest"
    require_active "$dest"
    mo_assert_worktree_match
    current="$(mo_fm_get "$dest" '.active.current-stage')"
    if [[ "$current" != "$expected" ]]; then
      mo_die "stage mismatch: active.current-stage=$current, advance expected $expected"
    fi
    next=$((expected + 1))
    python3 - "$dest" "$next" <<'PYEOF'
import sys, re, yaml
path, next_stage = sys.argv[1], int(sys.argv[2])
with open(path) as f:
    content = f.read()
m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
fm['active']['current-stage'] = next_stage
with open(path, 'w') as f:
    f.write('---\n')
    f.write(yaml.safe_dump(fm, default_flow_style=False, sort_keys=False))
    f.write('---\n')
    f.write(m.group(2))
PYEOF
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" validate "$dest" progress >/dev/null
    mo_info "advanced to stage $next"
    ;;

  check-worktree)
    # Public pre-flight gate. Fails with a guidance message when the
    # current working tree is not the one that activated the active
    # feature. No-op when active is null or fingerprint absent.
    mo_assert_worktree_match
    ;;

  *)
    echo "usage: progress.sh {init|activate|finish|requeue|reset|reorder|enqueue|get-active|queue-remaining|get|set|advance|check-worktree} ..." >&2
    exit 2
    ;;
esac
