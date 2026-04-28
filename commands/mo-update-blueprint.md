---
description: Rotate blueprints/current/ into history with a reason, then regenerate from the implementation (codebase + base-commit..HEAD diff) plus the previous blueprint (for non-derivable sections). Manual overseer trigger.
argument-hint: "<reason summary>"
---

# mo-update-blueprint

Manual overseer-triggered blueprint refresh. Rotates the current blueprint into history with a `reason.md`, then regenerates `requirements.md`, `config.md`, `diagrams/`, and `primer.md` from:

- **The implementation** — codebase + `git diff base-commit..HEAD` — for `## Goals (this cycle)` content and the diagrams.
- **The previous blueprint** (just rotated to `history/v[<version>]/`) — for sections the implementation alone can't reconstruct: `todo-item-ids` / `todo-list-id` (frontmatter), `## Planned (future cycles)`, `## Non-goals (out of scope)`, `## GIT BRANCH`, and `## Overseer Additions`.

The journal and the active cycle's quest files (`quest/<active-slug>/todo-list.md`, `quest/<active-slug>/summary.md`, `journal/`) are **not** inputs. Mid-cycle refreshes consult only what's already in the workflow's own state — the implementation describes what was actually built; the previous blueprint carries everything else forward.

Use this command when changes discussed during brainstorming or reviews need to be reflected in the blueprint and you don't want to wait for an auto-trigger (the post-chain drift prompt at stage 4 also calls this command).

## Invocation

```
/mo-update-blueprint <reason summary>
```

The reason summary is a one-line free-form description of why the blueprint is being updated (e.g., `"webhook retry logic added during brainstorming"`). Required. Becomes the `summary` field of the new `history/v[N+1]/reason.md`.

## Preconditions

- `progress.md`'s `active` is non-null (a feature is in flight). Fails fast otherwise.
- `blueprints/current/` exists with content to rotate. Fails fast otherwise.
- `active.base-commit` is non-null (stage 3 has captured it). Fails fast otherwise — without `base-commit`, the diff that drives Goals regeneration can't be computed.

## Execution

### Step 1 — Resolve active feature and guard

```bash
active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active)"
[[ -n "$active_feature" && "$active_feature" != "null" ]] || {
  echo "error: no active feature — /mo-update-blueprint requires an in-flight workflow" >&2
  exit 1
}
base_commit="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit)"
[[ -n "$base_commit" && "$base_commit" != "null" ]] || {
  echo "error: active.base-commit is null — /mo-update-blueprint needs a stage-3+ workflow" >&2
  exit 1
}
```

Reason summary comes from `$ARGUMENTS`:

```bash
reason_summary="$ARGUMENTS"
[[ -n "$reason_summary" ]] || {
  echo "error: reason summary required. Usage: /mo-update-blueprint <reason summary>" >&2
  exit 1
}
```

### Step 2 — Rotate blueprint to history

```bash
version="$($CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh rotate "$active_feature" \
  --reason-kind manual \
  --reason-summary "$reason_summary")"
echo "Previous blueprint archived into history/v${version}"
```

After this step, `blueprints/current/` is empty and `blueprints/history/v[<version>]/` holds the previous `requirements.md`, `config.md`, `diagrams/`, and the new `reason.md`.

### Step 3 — Recreate the empty `current/` tree

```bash
$CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh ensure-current "$active_feature"
```

### Step 4 — Regenerate `blueprints/current/` content

The previous blueprint is now at `history/v[<version>]/` and the implementation is in `base-commit..HEAD`. Reconstruct `current/` by re-deriving Goals + diagrams from the code, and copying everything else forward from history.

#### Step 4a — Read context (AI work)

Resolve the data root and the path to the just-rotated previous `requirements.md` up front. Both are needed by the change-summary regen path below (which uses `$prev_req` to read the previous `id`) and by Step 4b (which carries `todo-list-id` and `todo-item-ids` forward).

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
prev_req="$data_root/workflow-stream/$active_feature/blueprints/history/v${version}/requirements.md"
```

Read into working memory:

- **Previous `requirements.md`:** `$prev_req` (default `data_root` is `millwright-overseer`). Capture the frontmatter (`id`, `todo-list-id`, `todo-item-ids`) and the bodies of `## Planned (future cycles)` and `## Non-goals (out of scope)` (verbatim — these are preserved as-is).
- **Previous `config.md`:** `$data_root/workflow-stream/$active_feature/blueprints/history/v${version}/config.md`. The `## GIT BRANCH` and `## Overseer Additions` sections are preserved at Step 4d via `blueprints.sh preserve-overseer-sections` — you don't need to copy them by hand.
- **Implementation reality (cached):**

  Use `implementation/change-summary.md` as the source of truth for what the implementation delivers. The same artifact backs `mo-generate-implementation-diagrams` so the analysis runs once per `base-commit..HEAD` range:

  ```bash
  if $CLAUDE_PLUGIN_ROOT/scripts/commits.sh change-summary-fresh "$active_feature"; then
    echo "change-summary.md is current — reading from cache"
  else
    echo "change-summary.md missing or stale — regenerating before reading"
    # See `commands/mo-generate-implementation-diagrams.md` Step 2a for the
    # full body-fill recipe (template + section guide + bounded context policy).
    # The summary block below covers the steps inline so this command is
    # self-contained.
  fi
  ```

  When regeneration is needed, follow the same recipe documented in `mo-generate-implementation-diagrams.md` Step 2a:

  ```bash
  base_commit_sha="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit)"
  head_sha="$(git rev-parse HEAD)"
  # Note: requirements.md hasn't been written yet at this step in mo-update-blueprint,
  # so use the previous requirements.md's id for now. Step 5 (review.sh sync-refs)
  # re-points the requirements-id after the new requirements.md is written in 4b.
  prev_req_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$prev_req" id)"
  $CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init change-summary \
    "$data_root/workflow-stream/$active_feature/implementation/change-summary.md" \
    "REQUIREMENTS_ID=$prev_req_id" \
    "FEATURE=$active_feature" \
    "BASE_COMMIT=$base_commit_sha" \
    "HEAD=$head_sha"
  $CLAUDE_PLUGIN_ROOT/scripts/commits.sh changed-files "$active_feature"
  ```

  Then fill the body of `change-summary.md` per its template guide (`## Range`, `## Changed files`, `## Detected entrypoints`, `## Suspected flows`, `## Omitted from analysis`), applying the bounded context policy from `mo-generate-implementation-diagrams.md` Step 2a (diff hunks first; ≤ 3 callers/callees per file; skip generated/vendor/lock; record skips).

  Goals re-derivation in Step 4b reads from `change-summary.md` plus targeted diff hunks for the entrypoints it lists. Do NOT re-walk the whole codebase here.

- **Codebase context** for skills/rules summaries: re-scan `.claude/skills/` and `.claude/rules/` (used at Step 4d).

**Hard exclusion:** never read `blueprints/current/diagrams/*.svg` or `blueprints/history/*/diagrams/*.svg`. The `.puml` sources carry the same information at a fraction of the size.

#### Step 4b — Write the new `requirements.md`

```bash
new_req="$data_root/workflow-stream/$active_feature/blueprints/current/requirements.md"
# $prev_req is already set in Step 4a.

# Carry these from prev — they identify which todo items initiated the cycle and
# survive blueprint refreshes (todo state hasn't changed mid-cycle).
prev_todo_list_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$prev_req" todo-list-id)"
# `frontmatter.sh get todo-item-ids` returns a YAML array literal like
# `[PAY-001, AUD-002]`. The requirements template has `todo-item-ids:
# [{{TODO_ITEM_IDS}}]` (already wrapped in flow brackets), so strip the
# outer `[ ]` from the captured value before substituting — otherwise the
# template would produce `[[PAY-001, AUD-002]]`, a nested array that the
# requirements schema rejects (items must be strings, not arrays).
prev_todo_item_ids_csv="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$prev_req" todo-item-ids \
  | sed -E 's/^\[//; s/\]$//')"

$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init requirements "$new_req" \
  "TODO_LIST_ID=$prev_todo_list_id" \
  "TODO_ITEM_IDS=$prev_todo_item_ids_csv" \
  "FEATURE=$active_feature"
```

Then write the body using `Edit`. Three sections, in this order:

1. **`## Goals (this cycle)`** — **re-derive from the implementation.** Each goal item references the IMPLEMENTING todo IDs from the preserved `todo-item-ids` and describes what the code actually does. Use the diff + unchanged-side context to write accurate acceptance criteria, including any drift from the original spec (new fields, new endpoints, refactored boundaries — whatever the chain decided to do).

2. **`## Planned (future cycles)`** — **copy verbatim** from the previous `requirements.md`. The implementation has no signal about future work; the overseer's planned roadmap survives unchanged. Skip the section entirely if the previous file didn't have one (no planned items).

3. **`## Non-goals (out of scope)`** — **copy verbatim** from the previous `requirements.md`. The implementation can't tell you what was deliberately excluded. Skip the section entirely if the previous file didn't have one.

The frontmatter `commits` array stays empty — `mo-complete-workflow` populates it at stage 8.

#### Step 4c — Write the new `config.md`

```bash
new_cfg="$data_root/workflow-stream/$active_feature/blueprints/current/config.md"
new_req_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$new_req" id)"
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init config "$new_cfg" \
  "REQUIREMENTS_ID=$new_req_id"
```

Then, using `Edit`, fill the auto-section (between `<!-- auto:start -->` and `<!-- auto:end -->`) with summaries of the relevant skills and rules from `.claude/skills/` + `.claude/rules/`.

Same relevance filter, budget, and three-section structure as `docs/blueprint-regeneration.md` Step B:

- ≤ 10 entries combined across `## Skills`, `## Rules`, and `## Load on demand`; ≤ 2 lines each; always cite the canonical path.
- `## Skills` and `## Rules` carry only the entries likely to be consulted up front for the regenerated Goals.
- `## Load on demand` carries situational entries that may apply if a related concern surfaces; the chain opts in only when needed.
- Off-topic skills/rules are omitted entirely — they remain discoverable via `.claude/skills/` and `.claude/rules/`.

Leave `## GIT BRANCH` and `## Overseer Additions` empty / template-only here — Step 4d copies the previous content into them.

#### Step 4d — Restore overseer-authored sections

```bash
$CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh preserve-overseer-sections "$active_feature" "$version"
```

This reads `## GIT BRANCH` and `## Overseer Additions` bodies from `history/v[<version>]/config.md` and splices them into the matching headings in the new `current/config.md`. Headings stay; only the bodies are replaced. If those sections were empty in the previous file, the new file's matching sections are left as-is (template-empty).

#### Step 4e — Regenerate diagrams

Generate diagrams into `$data_root/workflow-stream/$active_feature/blueprints/current/diagrams/` (default `data_root` is `millwright-overseer`) per `docs/workflow-spec.md` § "Diagram conventions":

- **Mandatory**: one `use-case-<feature>.puml`.
- **Conditional**: one `sequence-<flow>.puml` per significant end-to-end flow described in the new `requirements.md`. Aim for 1–5.
- **Conditional**: one `class-<domain>.puml` only if the implementation introduces 3+ new classes/modules with non-trivial relationships.

Use the `plantuml` MCP to render each diagram; save the `.puml` source. Also write a `diagrams/README.md` with the new `requirements-id` back-reference.

These are **requirements-level** diagrams (capability, intent, structure). They differ from `implementation/diagrams/` — those carry the existing-vs-new framing convention to highlight the diff. Requirements-level diagrams describe the feature as if it were being designed fresh from the new Goals.

#### Step 4f — Regenerate `primer.md`

The just-rotated history version carried its own primer; the regenerated `current/` needs a fresh one pointing at the new `requirements.md` UUID. Branch and base-commit are already settled (this command runs mid-cycle — stage 3+ — so `progress.md` has both).

```bash
primer_dest="$data_root/workflow-stream/$active_feature/blueprints/current/primer.md"
new_req_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$new_req" id)"
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init primer "$primer_dest" \
  "REQUIREMENTS_ID=$new_req_id" \
  "FEATURE=$active_feature" \
  "DATA_ROOT=$data_root"
```

Then fill the body via `Edit`. Resolve values up front (the body has no token substitution beyond frontmatter):

```bash
primer_branch="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get branch)"
primer_base_commit="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit)"
implementing_ids="$($CLAUDE_PLUGIN_ROOT/scripts/todo.sh list IMPLEMENTING --feature "$active_feature")"
```

Then write each section per the same guide as `mo-plan-implementation` Step 3.5:

- `## Active scope` — `branch: <primer_branch>`, `base-commit: <primer_base_commit>`, one bullet per id in `implementing_ids` (description from the active cycle's `todo-list.md`; resolve via `quest.sh dir`).
- `## Goals (this cycle)` — 5–20 line excerpt from the new `requirements.md` `## Goals (this cycle)` (re-derived from the implementation in Step 4b).
- `## Journal context (active feature)` — 5–20 line digest from the active cycle's `summary.md` `## Feature: <active_feature>` plus relevant `## Cross-cutting constraints`.
- `## Likely-relevant skills & rules` — ≤ 5 entries from the new `config.md` auto-block (Step 4c).

The `## On-demand canonical files` section is template-emitted and does not need editing.

### Step 5 — Sync review files to new UUIDs

```bash
$CLAUDE_PLUGIN_ROOT/scripts/review.sh sync-refs "$active_feature"
```

This updates any existing `overseer-review.md` frontmatter to point at the newly-regenerated `requirements.md` id. Silently skips when the review file doesn't exist.

### Step 6 — Report

Tell the overseer:

> "Blueprint for `$active_feature` rotated to `history/v${version}/` (reason: `<summary>`) and regenerated from the implementation. Review the refreshed `requirements.md`, `config.md`, `diagrams/`, and `primer.md` under `blueprints/current/`. Overseer-authored sections (`## GIT BRANCH`, `## Overseer Additions`) and roadmap sections (`## Planned`, `## Non-goals`) are preserved from the previous version. Any in-flight review file has been re-pointed at the new requirements UUID."

## Notes

- Does **not** touch the active cycle's `todo-list.md`. Blueprint updates and todo edits are independent — use `/mo-update-todo-list` for todo changes.
- Does **not** read the active cycle's `todo-list.md` or `summary.md` (under `quest/<slug>/`), nor `journal/`. Mid-cycle refreshes are reverse-engineered from the implementation; the journal and quest are intake artifacts that don't drift after stage 1.5.
- Does **not** cascade into brainstorming / writing-plans / executing-plans. This is a pure refresh of the blueprint content; it does not re-run the chain.
- Does **not** change `progress.md`'s `active.current-stage` or any runtime flags. The workflow stays where it was.
- Cannot be invoked at stage 2 — there's no implementation to derive Goals from yet. Use `/mo-apply-impact` for stage-2 first-time blueprint generation.

## Delegation (optional)

When `change-summary.md` needs regeneration in Step 4a and the diff touches many areas, the body-fill is a good delegation candidate (see `docs/workflow-spec.md` § "Delegation guidance"). One sub-agent at "strong code-analysis, high effort" tier; output artifact is `implementation/change-summary.md`; the chat reply stays under 20 lines per the contract. The millwright then proceeds with Step 4b reading from the just-written artifact. When the cache is fresh, no delegation is needed.
