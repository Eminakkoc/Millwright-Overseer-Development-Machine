---
description: Generate blueprints/current/ for the active feature — requirements.md, config.md, and diagrams/. Stage 2 of the mo-workflow.
---

# mo-apply-impact

**Stage 2 launcher.** Pops the next feature off the queue, creates its `progress.md`, and generates the blueprint artifacts (requirements, config, diagrams).

## Invocation

The millwright auto-invokes this command on two triggers — the overseer does **not** type it in the happy path:

1. **End of stage 1.5.** Immediately after the overseer types `/mo-continue` to confirm the prioritized queue order (the Pre-flight Handler in `commands/mo-continue.md` writes `queue-rationale.md`, runs `progress.sh reorder`, then auto-fires this command).
2. **End of stage 8 (queue loop).** After `mo-complete-workflow` archives the finished feature and leaves `active: null` with more features in the queue, the millwright re-enters at stage 2 for the next feature (soft announce-and-continue). This command calls `progress.sh activate` internally to pop `queue[0]` into a fresh `active` block.

The command is still invokable manually for recovery — for example after `/mo-abort-workflow` (to regenerate blueprints from scratch) or when `/mo-resume-workflow` explicitly recommends it.

## Preconditions

- The active cycle's `todo-list.md`, `summary.md`, and `progress.md` exist (from stage 1; under `quest/<active-slug>/`).
- The overseer has marked at least one todo item as `PENDING`.
- The overseer has confirmed the workflow queue order (or the previous feature has just finished via `mo-complete-workflow`, leaving `active: null` in `progress.md`).

## Execution

### Step 1 — Activate the next feature

Pop `queue[0]` into the `active` block with fresh runtime state (current-stage=2, branch=null, everything else default). The command fails if `active` is already non-null — run `/mo-abort-workflow` or `/mo-complete-workflow` first to clear it.

```bash
active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh activate)"
echo "Starting workflow for feature: $active_feature"
$CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh ensure-current "$active_feature"
```

If the queue is empty, the script errors out — tell the overseer and stop. Branch is declared per-feature in `config.md`'s `## GIT BRANCH` section (written later in this command) and validated at stage 3; `/mo-plan-implementation` will persist it into `active.branch`.

### Step 2 — Regenerate `blueprints/current/` content

The content flow — write `requirements.md`, write `config.md` (auto-block + GIT BRANCH pre-fill), and generate diagrams — lives in [`docs/blueprint-regeneration.md`](../docs/blueprint-regeneration.md). Follow its Steps A, B, C with this caller context:

```bash
# Scope: PENDING items (first-time generation at stage 2).
active_item_ids="$($CLAUDE_PLUGIN_ROOT/scripts/todo.sh list PENDING --feature "$active_feature")"
```

Pass `$active_feature` and `$active_item_ids` through to the shared steps. The shared runbook handles: computing `$planned_ids`, initializing frontmatter, writing the three requirements body sections, scanning skills/rules for the config auto-block, pre-filling the GIT BRANCH section from HEAD, and rendering use-case/sequence/class diagrams with the PlantUML MCP.

### Step 3 — Hand off (no stage advance)

Do NOT call `progress.sh advance` here — `progress.sh activate` (Step 1) already set `current-stage=2`, which represents "blueprints generated, awaiting overseer approval." Stage 2 → 3 is owned by `/mo-plan-implementation` (which calls `progress.sh advance 2` after branch validation, todo promotion, and base-commit capture). Calling `advance 2` here would cause `/mo-plan-implementation` to fail with a stage mismatch on the next step.

Tell the overseer:

> "Blueprints generated for `$active_feature` at `workflow-stream/$active_feature/blueprints/current/`. Review `requirements.md`, `config.md`, and `diagrams/`. If adjustments are needed, edit the files directly — pay attention to `config.md`'s `## GIT BRANCH` section (declare the feature branch there if it isn't pre-filled). When ready, type **`/mo-continue`** — the Approve Handler in `mo-continue.md` will validate the blueprint files and auto-launch `mo-plan-implementation`."

Then stop and wait for the overseer to type `/mo-continue`. Do NOT auto-advance to stage 3 without that signal — this is the mandatory review gate. The Approve Handler in `commands/mo-continue.md` (current-stage = 2) handles the rest: blueprint sanity check, then auto-fire of `/mo-plan-implementation`.
