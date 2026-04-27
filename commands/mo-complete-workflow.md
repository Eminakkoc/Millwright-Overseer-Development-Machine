---
description: Finalize the active feature's workflow — archive blueprints, clear implementation, advance the queue. Stage 8.
---

# mo-complete-workflow

**Stage 8 finalizer.** Archives the blueprint into `history/`, clears the implementation folder, resets `progress.md`, and advances the workflow queue to the next feature.

## Invocation

The millwright auto-invokes this command on **stage-7 clean exit** — that is, immediately after the `/mo-continue` handler sets `overseer-review-completed=true` and advances `active.current-stage` to 7. (Stage 8 is conceptual — it names the finalizer phase but is not a persisted `active.current-stage` value; this command's `progress.sh finish` call sets `active=null` rather than incrementing the stage counter to 8.) The overseer does **not** type `/mo-complete-workflow` in the happy path; reaching stage 7 is itself the signal.

The command remains manually invokable for recovery — e.g. when `/mo-resume-workflow` recommends it because an auto-fire was interrupted.

## Preconditions

- `overseer-review-completed` is `true` in `progress.md` (stage 7 has exited clean).

## Execution

### Step 1 — Resolve inputs

```bash
active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active)"

# Verify overseer-review-completed
oc="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get overseer-review-completed)"
[[ "$oc" == "true" ]] || { echo "error: overseer-review not complete; run /mo-continue first" >&2; exit 1; }
```

The chain's plan / spec files under `docs/superpowers/` are not touched by this command — those artefacts belong to the brainstorming chain, not the mo-workflow. Cross-referencing between requirements and commits lives in `requirements.md`'s `commits:` field (populated below).

### Step 2 — Transition todos IMPLEMENTING → IMPLEMENTED

```bash
$CLAUDE_PLUGIN_ROOT/scripts/todo.sh bulk-transition IMPLEMENTING IMPLEMENTED --feature "$active_feature"
```

The `--feature` filter scopes the transition to items under the active feature's section header only, so sibling features still mid-flight in a multi-feature queue are not touched.

### Step 3 — Populate commits in requirements.md

```bash
$CLAUDE_PLUGIN_ROOT/scripts/commits.sh populate-requirements "$active_feature"
```

### Step 4 — Rotate blueprints/current → history/v[N+1]

```bash
version="$($CLAUDE_PLUGIN_ROOT/scripts/blueprints.sh rotate "$active_feature" \
  --reason-kind completion \
  --reason-summary "completed at stage 8 for $active_feature")"
echo "Blueprints archived into history/v${version}"
```

### Step 5 — Archive implementation/ into the rotated history version

Stage 4 rotated `blueprints/current/` into `blueprints/history/v${version}/`. The just-finished implementation artifacts (`overseer-review.md`, `review-context.md`, `change-summary.md`, and `diagrams/`) are part of the same audit record, so move them into a sibling `implementation/` subfolder under the new history version. This preserves every finding (including any `status: open` ones the overseer chose to defer) and the diagrams of `base-commit..HEAD` for posterity. The live `implementation/` folder is then empty and the next feature's stage-2 launcher re-creates children there.

```bash
impl_dir="millwright-overseer/workflow-stream/$active_feature/implementation"
archive_dir="millwright-overseer/workflow-stream/$active_feature/blueprints/history/v${version}/implementation"
mkdir -p "$archive_dir"

# Move each artifact if it exists. Using `mv -n` keeps it idempotent if the
# command is re-invoked after a partial run; mv would otherwise refuse to
# overwrite an existing target.
for artifact in overseer-review.md review-context.md change-summary.md; do
  [[ -e "$impl_dir/$artifact" ]] && mv -n "$impl_dir/$artifact" "$archive_dir/$artifact"
done
[[ -d "$impl_dir/diagrams" ]] && mv -n "$impl_dir/diagrams" "$archive_dir/diagrams"
# Leave the implementation/ folder itself in place (empty) — next workflow re-creates children.
```

The historical snapshot is then complete: `blueprints/history/v${version}/` carries the rotated `requirements.md`, `config.md`, `diagrams/`, `primer.md`, `reason.md`, AND `implementation/` (review file, review-context, change-summary, implementation diagrams). PMs querying past cycles can read the full audit trail from this single folder per feature-version.

### Step 6 — Finish the active feature

Archive the active feature into `completed` and set `active` to null. Under the two-step activation model, `/mo-apply-impact` will activate the next feature from the queue when it's invoked next.

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh finish >/dev/null
remaining="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining 2>/dev/null || echo '')"
```

### Step 7 — Report and auto-continue

If `remaining` is empty, check whether unmarked TODO items still exist in the cycle's `todo-list.md`. If so, the overseer can extend this cycle by marking more items rather than running `/mo-run` from scratch:

```bash
todo_count="$($CLAUDE_PLUGIN_ROOT/scripts/todo.sh list TODO 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
```

- **If `todo_count > 0`:**

  Resolve the active quest's todo-list path for the user-facing message:

  ```bash
  active_quest_dir="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir)"
  ```

  > "Workflow for `$active_feature` complete. Queue is now empty, but **$todo_count items still in `[ ] TODO`** state in `$active_quest_dir/todo-list.md`. To continue this cycle, mark the items you want next (`[x] (assignee) TODO — ...`) and type `/mo-continue` — I'll promote them to PENDING, enqueue their features, and resume from stage 1.5. Or run `/mo-run <folders> --archive-active` to retire this cycle (preserved as a historical subfolder under `quest/`) and start a brand-new one."

  Stop here; the Pre-flight Handler in `mo-continue.md` (active=null, queue_count=0, `[x] TODO` lines present) takes over once the overseer marks items and types `/mo-continue`. It uses `progress.sh enqueue` to repopulate the queue without calling `progress.sh init` (which would refuse because `progress.md` already exists). The active-quest pointer stays `active`; this is still the same cycle.

- **If `todo_count == 0`:**

  The cycle is fully complete — every item the overseer marked has shipped, and nothing else is queued. Archive the active-quest pointer so a fresh `/mo-run` can open a new cycle without `--archive-active`. The cycle's subfolder under `quest/<slug>/` stays intact as a historical record.

  ```bash
  finished_slug="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh current 2>/dev/null || echo "")"
  $CLAUDE_PLUGIN_ROOT/scripts/quest.sh end
  ```

  > "Workflow for `$active_feature` complete. Queue empty and no TODO items remain. Cycle `$finished_slug` is now archived (subfolder preserved under `quest/$finished_slug/` for future reference). Run `/mo-run <folders>` for a new cycle."

  Stop here; nothing else to do.

If `remaining` is non-empty, the first line is the next feature (soft announce-and-continue):

```bash
next="$(printf '%s\n' "$remaining" | head -1)"
```

> "Workflow for $active_feature complete. Next in queue: $next. Proceeding automatically — interrupt now or run `/mo-abort-workflow` to pause."

Then, without waiting for a further overseer reply, auto-invoke `/mo-apply-impact`. It will call `progress.sh activate` internally, which pops `$next` into the `active` block and starts stage 2 for it. If the overseer interrupts with a non-affirmative message before or during stage 2 execution, defer to their instruction. Manual `/mo-apply-impact` invocation remains available.
