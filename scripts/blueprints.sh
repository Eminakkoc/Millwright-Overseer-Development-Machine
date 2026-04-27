#!/usr/bin/env bash
# blueprints.sh — manage workflow-stream/<feature>/blueprints/.
#
# Usage:
#   blueprints.sh ensure-current <feature>       # create blueprints/current/ + diagrams/
#   blueprints.sh rotate <feature> \
#     --reason-kind <kind> \
#     --reason-summary <text>                    # move current/ into history/v[N+1]/;
#                                                # write reason.md; prints N+1
#   blueprints.sh preserve-overseer-sections \
#     <feature> <from-version>                   # copy ## GIT BRANCH and
#                                                # ## Overseer Additions bodies from
#                                                # history/v<from-version>/config.md
#                                                # into current/config.md (headings
#                                                # stay; only bodies are replaced).
#                                                # Idempotent. Use after rotate +
#                                                # regenerate to keep overseer-authored
#                                                # sections alive across rotations.
#
# Valid --reason-kind values:
#   completion | spec-update | re-spec-cascade | re-plan-cascade | manual
# See schemas/reason.schema.yaml for the authoritative enum.

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

cmd="${1:-}"; shift || true

case "$cmd" in
  ensure-current)
    feature="${1:?feature required}"
    current="$(mo_blueprints_current "$feature")"
    mkdir -p "$current/diagrams"
    mo_info "ensured $current and $current/diagrams"
    ;;

  rotate)
    feature="${1:?feature required}"; shift
    reason_kind=""
    reason_summary=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --reason-kind)
          reason_kind="${2:?--reason-kind requires a value}"
          shift 2
          ;;
        --reason-summary)
          reason_summary="${2:?--reason-summary requires a value}"
          shift 2
          ;;
        *)
          mo_die "unknown flag: $1"
          ;;
      esac
    done
    [[ -n "$reason_kind" ]] || mo_die "--reason-kind is required (see schemas/reason.schema.yaml for valid values)"
    [[ -n "$reason_summary" ]] || mo_die "--reason-summary is required (one-line explanation of the rotation)"

    current="$(mo_blueprints_current "$feature")"
    history="$(mo_blueprints_history "$feature")"
    [[ -d "$current" ]] || mo_die "blueprints/current not found for feature=$feature"
    mkdir -p "$history"
    # Find highest existing v[N]; next is N+1.
    next_n=1
    if compgen -G "$history/v*" >/dev/null; then
      next_n=$(ls -d "$history"/v* 2>/dev/null | \
               sed -n 's|.*/v\([0-9]\+\)$|\1|p' | \
               sort -n | tail -1)
      next_n=$((next_n + 1))
    fi
    dest="$history/v${next_n}"
    mkdir -p "$dest"
    # Move all children of current/ into dest/.
    shopt -s dotglob nullglob
    for entry in "$current"/*; do
      mv "$entry" "$dest/"
    done
    shopt -u dotglob nullglob

    # Write reason.md into the new history folder.
    triggered_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    "${MO_PLUGIN_ROOT}/scripts/frontmatter.sh" init reason "$dest/reason.md" \
      "KIND=$reason_kind" \
      "TRIGGERED_AT=$triggered_at" \
      "SUMMARY=$reason_summary" >/dev/null

    mo_info "rotated blueprints/current to history/v${next_n} (kind=$reason_kind)"
    echo "$next_n"
    ;;

  preserve-overseer-sections)
    feature="${1:?feature required}"
    from_version="${2:?from-version required (numeric, e.g. 3 for history/v3/)}"
    src="$(mo_blueprints_history "$feature")/v${from_version}/config.md"
    dest="$(mo_blueprints_current "$feature")/config.md"
    [[ -f "$src" ]]  || mo_die "history config.md not found: $src"
    [[ -f "$dest" ]] || mo_die "current config.md not found: $dest (regenerate before invoking preserve-overseer-sections)"

    python3 - "$src" "$dest" <<'PYEOF'
import sys, re
src_path, dest_path = sys.argv[1:3]
with open(src_path) as f:
    src = f.read()
with open(dest_path) as f:
    dest = f.read()

def extract_section(text, heading):
    """Return the body under `heading` (everything from the line after the heading
    up to the next `## ` heading or EOF). None if heading is absent."""
    pat = re.compile(rf'^{re.escape(heading)}[ \t]*\n', re.MULTILINE)
    m = pat.search(text)
    if not m:
        return None
    start = m.end()
    nxt = re.search(r'^## ', text[start:], re.MULTILINE)
    end = start + nxt.start() if nxt else len(text)
    return text[start:end].rstrip('\n') + '\n'

def replace_section(text, heading, new_body):
    """Replace the body under `heading` with `new_body`. Heading line is preserved.
    Returns text unchanged if heading is missing in `text`."""
    pat = re.compile(
        rf'(^{re.escape(heading)}[ \t]*\n)(.*?)(?=^## |\Z)',
        re.DOTALL | re.MULTILINE,
    )
    m = pat.search(text)
    if not m:
        return text
    return text[:m.end(1)] + new_body + ('\n' if not new_body.endswith('\n\n') else '') + text[m.end(2):]

preserved = []
for heading in ('## GIT BRANCH', '## Overseer Additions'):
    body = extract_section(src, heading)
    if body is None:
        continue
    new_dest = replace_section(dest, heading, body)
    if new_dest != dest:
        preserved.append(heading)
        dest = new_dest

with open(dest_path, 'w') as f:
    f.write(dest)
sys.stderr.write(f"preserved {len(preserved)} section(s) from {src_path} → {dest_path}: {', '.join(preserved) or 'none'}\n")
PYEOF
    ;;

  *)
    echo "usage: blueprints.sh {ensure-current|rotate|preserve-overseer-sections} ..." >&2
    exit 2
    ;;
esac
