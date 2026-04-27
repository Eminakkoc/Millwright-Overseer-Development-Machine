---
description: Safely cancel the active workflow — reverts IMPLEMENTING todos, clears implementation/, resets progress.md. Preserves blueprints/current/ and does NOT touch git.
argument-hint: "[--drop-feature={completed|requeue}]"
---

# mo-abort-workflow

Use when a workflow needs to be cancelled mid-flight — session crash, mind change, merge conflict, corrupted state.

## Execution

### Step 1 — Parse the drop-feature flag and validate

The flag determines what Step 2 does to the todos, so resolve it up front. `--drop-feature=completed` requires real commits in `base-commit..HEAD` (the `completed` list means "this feature actually shipped"); refuse if no commits exist.

```bash
active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active)"
current_stage="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get current-stage)"
drop_mode=""
case "${1:-}" in
  --drop-feature=completed) drop_mode="completed" ;;
  --drop-feature=requeue)   drop_mode="requeue" ;;
  "")                       drop_mode="" ;;
  *) echo "error: unknown flag '$1' (expected --drop-feature=completed|requeue)" >&2; exit 1 ;;
esac

if [[ "$drop_mode" == "completed" ]]; then
  base_commit="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit 2>/dev/null || echo "")"
  if [[ -z "$base_commit" || "$base_commit" == "null" ]]; then
    echo "error: --drop-feature=completed needs a stage-3+ feature (base-commit must be set; no commits could have shipped before stage 3)." >&2
    echo "       Use --drop-feature=requeue to put the feature back on the queue, or omit the flag to retry from stage 2." >&2
    exit 1
  fi
  if (( $(git rev-list --count "$base_commit..HEAD" 2>/dev/null || echo 0) == 0 )); then
    echo "error: --drop-feature=completed refused — no commits exist in $base_commit..HEAD." >&2
    echo "       The 'completed' list is for features that actually shipped. Use --drop-feature=requeue instead." >&2
    exit 1
  fi
fi
```

### Step 2 — Confirm with the overseer

Summarize current state and ask for confirmation. The summary depends on `drop_mode`:

```bash
echo "Active feature: $active_feature"
echo "Current stage:  $current_stage"
echo "This will:"
case "$drop_mode" in
  completed)
    echo "  - mark the active feature's IMPLEMENTING todos as IMPLEMENTED (canonical stage-8 transition)"
    echo "  - move '$active_feature' to progress.md.completed"
    ;;
  requeue|"")
    echo "  - revert IMPLEMENTING todos for the active feature back to PENDING"
    [[ "$drop_mode" == "requeue" ]] && echo "  - move '$active_feature' to the end of progress.md.queue"
    ;;
esac
echo "  - delete implementation/ (overseer-review.md, review-context.md, change-summary.md, diagrams/)"
echo "  - reset progress.md to a fresh stage-2 state (when no --drop-feature flag is set)"
echo "  - keep blueprints/current/ intact"
echo "  - keep the active quest cycle's subfolder under quest/<active-slug>/ intact (cycle stays open — abort only resets the active feature)"
echo "  - NOT touch git (branches and commits remain)"
read -p "Proceed? (y/n): " ans
[[ "$ans" == "y" ]] || exit 0
```

### Step 3 — Transition todos (active feature only)

Scope the transition to the active feature so other queued/in-flight features' todos aren't affected. (`bulk-transition` without `--feature` would touch every IMPLEMENTING line in the file — including any other feature mid-work, which is not what abort means.) The destination state depends on `drop_mode`:

```bash
case "$drop_mode" in
  completed)
    # Canonical stage-8 transition — feature shipped, todos are IMPLEMENTED.
    $CLAUDE_PLUGIN_ROOT/scripts/todo.sh bulk-transition IMPLEMENTING IMPLEMENTED --feature "$active_feature"
    ;;
  requeue|"")
    # Feature did NOT ship; revert so it can be re-implemented (or re-tried from stage 2).
    $CLAUDE_PLUGIN_ROOT/scripts/todo.sh bulk-transition IMPLEMENTING PENDING --feature "$active_feature"
    ;;
esac
```

### Step 4 — Clear implementation

```bash
data_root="$($CLAUDE_PLUGIN_ROOT/scripts/data-root.sh)"
impl_dir="$data_root/workflow-stream/$active_feature/implementation"
rm -rf "$impl_dir"/diagrams
rm -f "$impl_dir"/overseer-review.md
rm -f "$impl_dir"/review-context.md
rm -f "$impl_dir"/change-summary.md
```

### Step 5 — Update progress.md based on `drop_mode`

`progress.sh finish`/`requeue` both set `active=null`, so they replace the `progress.sh reset` path entirely. `reset` only runs when no `--drop-feature` flag was passed (the overseer wants to retry the same feature from stage 2).

```bash
case "$drop_mode" in
  completed)
    # Feature shipped — finish appends to completed[] and clears active.
    $CLAUDE_PLUGIN_ROOT/scripts/progress.sh finish >/dev/null
    ;;
  requeue)
    # Feature did NOT ship — requeue appends to queue end and clears active.
    $CLAUDE_PLUGIN_ROOT/scripts/progress.sh requeue >/dev/null
    ;;
  "")
    # Retry: keep active.feature and active.branch; reset stage to 2.
    $CLAUDE_PLUGIN_ROOT/scripts/progress.sh reset
    ;;
esac
```

### Step 6 — Report

The reporting message depends on `drop_mode`:

- **`completed`**: `> "Workflow aborted. '$active_feature' marked completed (commits in $base_commit..HEAD shipped) and moved to progress.md.completed. Next /mo-apply-impact will activate the next queued feature."`
- **`requeue`**: `> "Workflow aborted. '$active_feature' moved to the end of progress.md.queue. Next /mo-apply-impact will activate whatever is now at queue[0]."`
- **(no flag)**: `> "Workflow aborted. '$active_feature' is back at stage 2 with blueprints preserved. Run /mo-plan-implementation to retry the chain, or /mo-apply-impact to regenerate the blueprint from scratch. (Auto-fire is suspended until you re-enter — both commands are safe to invoke manually here.)"`
