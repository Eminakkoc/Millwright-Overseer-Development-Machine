# Blueprint regeneration

Runbook for first-time blueprint generation by **`mo-apply-impact`** at stage 2. Generates the content of `workflow-stream/<feature>/blueprints/current/` — specifically `requirements.md`, `config.md`, and `diagrams/` — from the **active cycle's quest data** (the journal digest captured at stage 1, living under `quest/<active-slug>/`) plus the codebase, scoped to PENDING items for the active feature.

**Journal is NOT a stage-2 input.** The active cycle's `summary.md` (under `quest/<active-slug>/`; the slug is recorded in `quest/active.md`) is the authoritative digest of the journal, written by `/mo-run` at stage 1; stage 2 relies on it instead of re-reading `journal/`. This keeps the data flow one-way (`journal → quest cycle → blueprint → implementation`) and aligns with the design principle restated in `commands/mo-update-blueprint.md` ("journal and quest are intake artifacts that don't drift after stage 1.5"). If the cycle's `summary.md` is missing context this cycle needs, that is a stage-1 quality issue — surface it to the overseer rather than backfilling by re-reading the journal at stage 2.

This runbook is **not** used for mid-cycle blueprint refreshes. After stage 3, the implementation exists and is the source of truth for what the blueprint should reflect; mid-cycle refreshes are handled by `/mo-update-blueprint`, which has its own inline regeneration logic (see `commands/mo-update-blueprint.md` Step 4) that reads from the codebase + previous blueprint instead of quest data.

## Caller contract

Before following these steps, the caller must have:

- `$active_feature` — the kebab-case feature name (from `progress.md`'s `active.feature`).
- `$active_item_ids` — the newline-separated list of PENDING item ids in scope for this cycle. Compute via `todo.sh list PENDING --feature "$active_feature"`.
- An **empty** `blueprints/current/` directory. The caller runs `blueprints.sh ensure-current "$active_feature"` to guarantee the `current/` and `current/diagrams/` subpaths exist.

## Step A — Generate `requirements.md` (AI work)

Resolve the active cycle's quest folder and the workflow data root once and reuse them in the rest of this runbook:

```bash
quest_dir="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir)"
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
```

Read `$quest_dir/todo-list.md` and `$quest_dir/summary.md` (the journal digest from stage 1). Do NOT read `journal/` directly — the cycle's `summary.md` is the authoritative digest; stage 2 is purely quest-driven.

`summary.md` is feature-indexed. Read **only** `## Cross-cutting constraints`, `## Out-of-scope`, and `## Feature: <$active_feature>` — other features' sections belong to other cycles. The `features:` frontmatter lists what's available; if `$active_feature` isn't in there, that's a stage-1 quality issue and should be surfaced rather than backfilled.

Also gather the backlog set:

```bash
planned_ids="$($CLAUDE_PLUGIN_ROOT/scripts/todo.sh list TODO --feature "$active_feature")"
```

Create the file. `TODO_ITEM_IDS` must be a comma-separated list — `$active_item_ids` arrives from `todo.sh list` as newline-separated, so reshape it before substituting:

```bash
dest="$data_root/workflow-stream/$active_feature/blueprints/current/requirements.md"
todo_list_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get \
  "$quest_dir/todo-list.md" id)"
todo_item_ids_csv="$(printf '%s\n' "$active_item_ids" | paste -sd, -)"
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init requirements "$dest" \
  "TODO_LIST_ID=$todo_list_id" \
  "TODO_ITEM_IDS=$todo_item_ids_csv" \
  "FEATURE=$active_feature"
```

The schema requires `todo-item-ids` to be a non-empty array of strings. Each item-id (e.g. `PAY-001`, `AUD-002`) is alphanumeric, so the comma-separated list lands cleanly inside the template's `[{{TODO_ITEM_IDS}}]` brackets.

Then write the requirements body with **three clearly-labeled scope sections**:

1. **`## Goals (this cycle)`** — describe what the active items (`$active_item_ids`) deliver: goals, constraints, acceptance criteria. This is the primary deliverable.

2. **`## Planned (future cycles)`** — list each unselected TODO item (`$planned_ids`) from the same feature with a short line that names the item id, what it delivers, and **what architectural seam the current implementation needs to leave open for it**. Example:

   ```markdown
   ## Planned (future cycles)

   These items belong to the `authentication` feature and will land in a later cycle. The implementation in this cycle must not lock in choices that would require a rewrite when they arrive.

   - **AUTH-003** — JWT with role claim (Employee | Admin).
     Design guidance: the current session primitive should be wrapped behind a
     narrow interface (`getCurrentUser()` / `requireRole()`) so the underlying
     mechanism can swap to JWT without touching call sites. Do not leak session
     shape (cookies, session table) into domain code.
   ```

   Skip this section entirely if `$planned_ids` is empty.

3. **`## Non-goals (out of scope)`** — reserved for things **explicitly excluded from the feature's roadmap** — captured at stage 1 in the cycle's `summary.md` (any journal-sourced exclusions are already digested there; under `quest/<active-slug>/`), or in `config.md`'s `## Overseer Additions`, or via overseer statements in chat. These are NOT on the TODO list. If there are none, omit the section.

**Critical distinction:** "Planned (future cycles)" items WILL be implemented — just later. The design of this cycle must accommodate them. "Non-goals" items are truly out of scope and can be assumed away.

**Note on scope of `todo-item-ids`.** The array captures the items that *initiated* the current cycle — not every concern discovered during brainstorming. Scope expansions that surface mid-cycle land in the requirements body but do not retroactively invent new todo ids; manage those via `/mo-update-todo-list add ... IMPLEMENTING`.

## Step B — Generate `config.md` (auto + manual sections)

Scan `.claude/skills/` and `.claude/rules/` in the current project. Summarize each skill and rule in one or two lines. Write these summaries **only between the `<!-- auto:start -->` and `<!-- auto:end -->` markers** in the template.

**Relevance filter (critical for token cost).** `config.md` is loaded into the brainstorming primer at stage 3 and re-loaded on every chain re-entry during the review loop. Every line in the auto block costs tokens repeatedly.

**Quantitative budget.** Across the three auto-block sections combined: **≤ 10 entries total, ≤ 2 lines each**. Cite the canonical path on every entry — that lets the chain pull more detail on demand without bloating the primer. If you find yourself wanting more than 10 entries, demote the borderline cases to `## Load on demand` rather than expanding the always-loaded sections.

**Three-tier structure.** The auto block has three sections, in this order:

1. **`## Skills`** — skills that are likely to be consulted while implementing the active Goals. Cycle-specific. Each entry: `- <name>: <one-line reason>; path: .claude/skills/<name>/SKILL.md`.
2. **`## Rules`** — rules that constrain the implementation. Same format with `path: .claude/rules/<name>.md`.
3. **`## Load on demand`** — skills/rules that exist in the project and may apply if a related concern surfaces during brainstorming or review, but aren't required up front for the active Goals. Examples: `mobile-react-native` listed here when the feature is web-only but might cross over later; `ci-templates` when CI changes are possible but not planned. Each entry: `- <name>: <when to load>; path: ...`.

For skills/rules that are clearly off-topic (e.g., `github-actions-templates` when no CI change is in scope and there's no realistic future need this cycle), **omit them entirely** — they remain discoverable via `.claude/skills/` if a need surfaces.

When uncertain whether something is relevant: prefer `## Load on demand` over `## Skills` / `## Rules`. The chain pays nothing for `## Load on demand` entries unless it explicitly opts in.

```bash
requirements_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get \
  "$dest" id)"
config_dest="$data_root/workflow-stream/$active_feature/blueprints/current/config.md"
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init config "$config_dest" \
  "REQUIREMENTS_ID=$requirements_id"
```

Then, using Edit, replace the auto-section placeholder with the real skill/rule summaries. If `config.md` already exists from a prior run (e.g., the overseer aborted and restarted `mo-apply-impact` for the same feature without rotating), preserve content below the `## GIT BRANCH` heading AND below the `## Overseer Additions` heading — only the auto block is overwritten. (This is a same-cycle re-run case. For mid-cycle preservation across rotations, see `commands/mo-update-blueprint.md` Step 4d, which calls `blueprints.sh preserve-overseer-sections`.)

**Pre-fill `## GIT BRANCH` if possible.** Immediately after writing the auto block, check the current HEAD:

```bash
head_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
```

If `head_branch` is non-empty and is NOT `main`, `master`, or `HEAD` (detached) — AND the overseer hasn't already filled the `## GIT BRANCH` section (e.g., from a prior run) — write `head_branch` as the bare line under the heading, above the commented placeholder. This is a convenience default; the overseer can edit it before advancing to stage 3.

If HEAD is `main`/`master`/detached, leave the section unfilled — `/mo-plan-implementation` will prompt the overseer at stage 3.

## Step C — Generate requirement-level diagrams (AI work)

Generate diagrams into `millwright-overseer/workflow-stream/$active_feature/blueprints/current/diagrams/`. Follow the rules in `docs/workflow-spec.md` § "Diagram conventions":

- **Mandatory**: one `use-case-<feature>.puml` use-case diagram.
- **Conditional**: one `sequence-<flow>.puml` per distinct end-to-end flow from `requirements.md`. Aim for 1–5.
- **Conditional**: one `class-<domain>.puml` only if the feature introduces 3+ new domain classes with non-trivial relationships.

Use the `plantuml` MCP to render each diagram; save the `.puml` source alongside any generated artifact. Also write a `diagrams/README.md` with the `requirements-id` back-reference and a listing of all diagrams.
