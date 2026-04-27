---
description: Render diagrams of the implementation (commit range base-commit..HEAD) into implementation/diagrams/. Overseer-invokable wrapper around mo-generate-implementation-diagrams; auto-fired by mo-continue's Review-Resume Handler when the overseer wants a diagram refresh after the review session committed new code.
argument-hint: "[--target=implementation]"
---

# mo-draw-diagrams

**User-facing diagram generator.** Generic launcher for diagram rendering against the active feature's commit range. Currently supports `--target=implementation` (the default and only mode); future targets may extend this command without churn at the call sites.

## When invoked

- **Manually** by the overseer at any point during stages 4–7 to refresh the implementation diagrams (e.g., the brainstorming review session just shipped fixes and the overseer wants to look at the updated picture before stage 8 archives it).
- **Auto-fired** by the Review-Resume Handler in `/mo-continue` (see `commands/mo-continue.md`) when the overseer answers `y` to the Step 2.5 diagram-refresh prompt.

## Preconditions

- A feature is active in `progress.md` (`active != null`).
- `active.base-commit` is set (stage 3+).
- The PlantUML MCP server is available (verified by `/mo-doctor`).

## Execution

### Step 1 — Parse `$ARGUMENTS`

```bash
target="implementation"
for arg in $ARGUMENTS; do
  case "$arg" in
    --target=*)        target="${arg#--target=}" ;;
    --target)          shift; target="$1" ;;
    *)                 echo "warn: ignoring unrecognized argument: $arg" >&2 ;;
  esac
done
```

If `target` is not `implementation`, error out:

> "Only `--target=implementation` is supported today. To regenerate requirements-level diagrams, use `/mo-update-blueprint <reason>` (which rotates the blueprint and regenerates `requirements.md` / `config.md` / `diagrams/` from the implementation)."

### Step 2 — Dispatch to the implementation generator

For `--target=implementation`, run the body of `mo-generate-implementation-diagrams.md`. This is a thin wrapper — no behavior change. The implementation generator handles:

- ensuring `implementation/change-summary.md` is current via `commits.sh change-summary-fresh` (regenerates if stale);
- reading the commit range `active.base-commit..HEAD`;
- rendering use-case, sequence, and (if relevant) class diagrams via the PlantUML MCP into `workflow-stream/$active_feature/implementation/diagrams/`;
- framing pre-existing system elements as shaded context next to the new functionality;
- writing `implementation/diagrams/README.md` with the `requirements-id` back-reference.

See `commands/mo-generate-implementation-diagrams.md` for the full step-by-step recipe.

### Step 3 — Report

The implementation generator already prints its own report (`Implementation diagrams generated at $dest_dir (N diagrams). Existing-system context is shaded; new functionality is highlighted.`). Pass that through unchanged.

## Notes

- This command is the **public** name overseers should use; `mo-generate-implementation-diagrams` remains as the **internal** implementation that the workflow's auto-firing paths invoke (the Resume Handler at stage 4, the Review-Resume Handler at stage 6 → 7, and `/mo-update-blueprint`'s diagram regeneration). Keeping both names valid means existing wiring isn't broken; new manual invocations use the simpler name.
- Diagrams under `implementation/diagrams/` are **deleted at stage 8** by `mo-complete-workflow` — they're transient artifacts that exist only for the overseer's stage-5 review and any post-review re-look. They are NOT archived into `blueprints/history/`. If you want to preserve a snapshot, copy the `.puml` files out before running `/mo-complete-workflow` — but the `.puml` files in `blueprints/current/diagrams/` (which DO get archived) cover the requirements-level view of the same flows.
- The PlantUML `.svg` renders are intentionally not produced — the `.puml` source is what the overseer diffs.
