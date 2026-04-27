#!/usr/bin/env bash
# frontmatter.sh — read/write/init/validate YAML frontmatter in workflow .md files.
#
# Usage:
#   frontmatter.sh init <template-name> <dest-file> [KEY=VAL ...]
#   frontmatter.sh get <file> <field>
#   frontmatter.sh set <file> <field> <value>
#   frontmatter.sh validate <file> <schema-name>

set -euo pipefail
source "$(dirname "$0")/internal/common.sh"

cmd="${1:-}"; shift || true

case "$cmd" in
  init)
    tmpl_name="${1:?template name required}"
    dest="${2:?dest file required}"
    shift 2
    tmpl="${MO_PLUGIN_ROOT}/templates/${tmpl_name}.md.tmpl"
    [[ -f "$tmpl" ]] || mo_die "template not found: $tmpl"
    # If UUID wasn't passed, auto-generate and prepend.
    has_uuid=0
    for kv in "$@"; do [[ "${kv%%=*}" == "UUID" ]] && has_uuid=1; done
    if [[ $has_uuid -eq 0 ]]; then
      set -- "UUID=$("${MO_PLUGIN_ROOT}/scripts/uuid.sh")" "$@"
    fi
    mo_render_template "$tmpl" "$dest" "$@"
    # Validate immediately so a bad substitution fails at write time rather
    # than later when something else tries to read the file. Skip validation
    # for templates that have no schema by the same name (e.g. ad-hoc
    # templates introduced for tooling but not registered in schemas/).
    schema_path="${MO_PLUGIN_ROOT}/schemas/${tmpl_name}.schema.yaml"
    if [[ -f "$schema_path" ]]; then
      "${MO_PLUGIN_ROOT}/scripts/internal/validate-frontmatter.sh" "$dest" "$tmpl_name" >/dev/null
    fi
    mo_info "initialized $dest from $tmpl_name template"
    ;;

  get)
    file="${1:?file required}"
    field="${2:?field required}"
    mo_fm_get "$file" "$field"
    ;;

  set)
    file="${1:?file required}"
    field="${2:?field required}"
    value="${3:?value required}"
    mo_fm_set "$file" "$field" "$value"
    mo_info "set $field in $file"
    ;;

  validate)
    file="${1:?file required}"
    schema_name="${2:?schema name required}"
    exec "${MO_PLUGIN_ROOT}/scripts/internal/validate-frontmatter.sh" "$file" "$schema_name"
    ;;

  *)
    echo "usage: frontmatter.sh {init|get|set|validate} ..." >&2
    exit 2
    ;;
esac
