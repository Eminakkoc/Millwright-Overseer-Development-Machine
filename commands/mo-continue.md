---
description: Universal advancement signal for the mo-workflow. Dispatches to the right handler for the current state — pre-flight (after marking todos / approving blueprints), post-chain resume, overseer-review, or post-review-session resume.
---

# mo-continue

**The single advancement signal the overseer types throughout the workflow.** Reads `progress.md` (and a few sibling files) for the current state, decides where we are, and runs the appropriate handler.

The overseer types `/mo-continue` at every gate where they previously typed a free-form approval:

1. **After marking PENDING items** in the active cycle's `todo-list.md` (stage 1.5; lives under `quest/<active-slug>/todo-list.md`). Runs the Pre-flight Handler — promotes the marked items, analyzes feature dependencies, and proposes a workflow order.
2. **After accepting the proposed queue order** (stage 1.5, second invocation). Runs the Pre-flight Handler — writes the cycle's `queue-rationale.md`, reorders the queue, and auto-fires `/mo-apply-impact`.
3. **After reviewing the blueprint** (stage 2). Runs the Approve Handler — auto-fires `/mo-plan-implementation`.
4. **After the brainstorming chain has fully exited and returned control** (stage 3 → 4; the chain produced commits in `base-commit..HEAD`). Runs the Resume Handler — generates implementation diagrams and hands off to overseer review. **Do not type `/mo-continue` while the chain is mid-prompt** (e.g., while `finishing-a-development-branch` is asking for approval); answer the chain first.
5. **After writing findings into `overseer-review.md`** (stage 5; or leaving it empty to approve). Runs the Overseer Handler — auto-completes if there are no findings, or invokes `/mo-review` and returns control to the overseer.
6. **(only if findings were present)** **After the brainstorming review session has fully exited and returned control** (stage 6 → 7). Runs the Review-Resume Handler — offers a diagram refresh, sanity-checks findings, advances, and auto-fires `/mo-complete-workflow`. **Do not type `/mo-continue` while the review session is mid-prompt**; answer the chain first.

For any other workflow state, this command falls through to `/mo-resume-workflow` to give the overseer a state diagnosis instead of erroring out.

## Execution

### Step 1 — Read state

```bash
active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active 2>/dev/null || echo 'null')"
queue_count="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
# todo-list.md lives inside the active quest cycle's subfolder; resolve via quest.sh.
quest_dir="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir 2>/dev/null || echo "")"
todo_file="$quest_dir/todo-list.md"
```

If `progress.md` (or `quest/active.md` / the active cycle subfolder) is missing, the calls fail — surface the error and stop (no recovery here; the overseer should run `/mo-run` first).

### Step 2 — Dispatch

The dispatcher picks a handler based on whether a feature is active and, when active, on `current-stage` + `sub-flow`. Pre-flight cases (no active feature) live above the table:

**Pre-flight cases (`active_feature == "null"`):**

| Condition | Handler |
| --- | --- |
| `[x] TODO` lines exist in `todo-list.md` (selections not yet promoted) | **Pre-flight Step 2A** — promote + propose order |
| no `[x] TODO` lines, `queue_count > 0`, `queue-rationale.md` missing | **Pre-flight Step 2B** — confirm proposed order + auto-fire `/mo-apply-impact` |
| `queue_count == 0` and no `[x] TODO` lines | Delegate to `/mo-resume-workflow` |

**Active cases (`active_feature != "null"`):**

```bash
current_stage="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get current-stage)"
sub_flow="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get sub-flow)"
```

| Current stage | Sub-flow      | Handler                                                       |
| ------------- | ------------- | ------------------------------------------------------------- |
| 2             | (any)         | **Approve Handler** — auto-fire `/mo-plan-implementation`     |
| 3             | (any)         | Post-chain resume (see Resume Handler below)                  |
| 5             | (any)         | Overseer-review received (see Overseer Handler below)         |
| 6             | reviewing     | Post-review-session resume (see Review-Resume Handler below)  |
| any other     | —             | Delegate to `/mo-resume-workflow` for state diagnosis         |

For the "any other" case (active or pre-flight), invoke `/mo-resume-workflow` and stop — let it report state and recommend the next command.

---

## Pre-flight Handler (active=null, queue or selections pending)

Runs at stage 1.5 — between `/mo-run` (which scaffolded the queue from journal content) and `/mo-apply-impact` (which will activate the first feature). Two sub-states, distinguished by what's still pending in the source files.

### Pre-flight Step 2A — Promote selections + propose order

Reached when the overseer has just finished marking items (`[x] TODO` lines exist).

1. **Promote the marked items.**
   ```bash
   $CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining >/dev/null  # confirms progress.md exists
   $CLAUDE_PLUGIN_ROOT/scripts/todo.sh pend-selected
   ```
   `pend-selected` rejects any `[x] TODO` line missing an `(assignee)` tag — relay the offenders to the overseer, ask for assignee names, and stop. The overseer fixes the file and re-types `/mo-continue`.
2. **Group PENDING items by feature.** Read `todo-list.md` and collect the set of feature section headings (`## <feature>`) that contain `[x] PENDING` lines.
3. **Detect the queue source state.**
   ```bash
   queue_count="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh queue-remaining 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
   ```
   - **If `queue_count > 0`:** the queue was seeded by `/mo-run` (initial cycle). It already lists every feature found in the journal, in some default order. Skip to step 5.
   - **If `queue_count == 0`:** mid-cycle re-entry (Finding 6 — the cycle's first batch already completed and the overseer is marking more items now). The queue must be repopulated from the freshly-PENDING feature names:
     ```bash
     $CLAUDE_PLUGIN_ROOT/scripts/progress.sh enqueue <feat1> [<feat2> ...]
     ```
     where `<featN>` is the de-duplicated set of feature headings that hold PENDING items in `todo-list.md`. `enqueue` refuses duplicates against `queue ∪ completed`, so a feature already finished in this cycle would error out — surface that to the overseer (they probably wrote a TODO under the wrong heading).
4. **Analyze codebase for cross-feature dependencies.** For ≥ 2 features in the queue, do a bounded inspection (grep for cross-feature imports, references in shared modules) to surface ordering hints. Skip when there's only one feature.
5. **Propose the prioritized order.** Print the order as a numbered list and the dependency reasoning underneath. End the message with:
   > "Reply `/mo-continue` to accept this order, or paste a different order (one feature per line) and then `/mo-continue` to confirm."
6. **Stop.** Do NOT write `queue-rationale.md` yet — that lands in Step 2B after the overseer confirms.

### Pre-flight Step 2B — Confirm order + auto-fire `/mo-apply-impact`

Reached when `[x] TODO` lines have been promoted (none remain) but `queue-rationale.md` is missing — i.e., the overseer is responding to Step 2A's proposal.

1. **Resolve the confirmed order.** If the overseer typed a custom order in the previous turn, parse it. Otherwise, use the proposal from Step 2A (which the millwright still has in conversation context — if the session was compacted, re-derive it by re-grouping PENDING items + re-running dependency analysis).
2. **Validate the order.** It must be a permutation of the current `progress.md` queue. If the overseer's custom order is malformed (extras, missing entries, duplicates), surface the error and ask them to retype.
3. **Write the cycle's `queue-rationale.md`.** Same recipe as `mo-run.md` Step 6 — paths resolve through the active-quest pointer:
   ```bash
   quest_dir="$($CLAUDE_PLUGIN_ROOT/scripts/quest.sh dir)"
   todo_list_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get \
     "$quest_dir/todo-list.md" id)"
   $CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init queue-rationale \
     "$quest_dir/queue-rationale.md" \
     "TODO_LIST_ID=$todo_list_id" \
     "FEATURES=<comma-joined confirmed order>"
   ```
   Then fill the body via `Edit` per the template's section guide (`## Order`, `## Dependencies`, `## Notes`).
4. **Reorder the queue.**
   ```bash
   $CLAUDE_PLUGIN_ROOT/scripts/progress.sh reorder <feature1> <feature2> ...
   ```
5. **Auto-fire `/mo-apply-impact`.** Same as the prior end-of-stage-1.5 transition.

---

## Approve Handler (current-stage = 2)

Runs after the overseer has reviewed the blueprint files (`requirements.md`, `config.md`, `diagrams/`) and is ready to advance into the planning chain.

### Approve Step 1 — Sanity-check blueprint files

```bash
bp_dir="millwright-overseer/workflow-stream/$active_feature/blueprints/current"
for f in "$bp_dir/requirements.md" "$bp_dir/config.md"; do
  [[ -f "$f" ]] || { echo "error: missing $f — run /mo-apply-impact first" >&2; exit 1; }
done
[[ -d "$bp_dir/diagrams" ]] || { echo "error: missing $bp_dir/diagrams/ — run /mo-apply-impact first" >&2; exit 1; }
```

### Approve Step 2 — Auto-fire `/mo-plan-implementation`

`/mo-plan-implementation` handles its own preconditions: branch validation against `config.md`'s `## GIT BRANCH`, todo promotion (PENDING → IMPLEMENTING), `base-commit` capture, primer composition, planning-mode prompt, and chain launch.

```bash
/mo-plan-implementation
```

If `mo-plan-implementation` errors (branch missing, branch mismatch, etc.), relay the error to the overseer; they fix the underlying issue and type `/mo-continue` again.

---

## Resume Handler (current-stage = 3)

Runs after the brainstorming chain has fully exited and returned control. Generates implementation diagrams (with pre-existing system framed as shaded context), optionally rotates the blueprint if requirements changed during brainstorming, and hands off to the overseer for review.

### Resume Step 1 — Mark sub-flow

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "sub-flow=resuming"
```

### Resume Step 2 — Verify the chain produced commits

```bash
base_commit="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit)"
commit_count="$(git rev-list --count "$base_commit..HEAD")"
(( commit_count > 0 )) || { echo "error: no commits since base-commit; the chain did not produce implementation. Make sure the brainstorming chain has fully exited (its final step asks for approval) before running /mo-continue." >&2; exit 1; }
```

In the happy path, the mo-workflow does **not** track or read the spec / plan files the chain produced under `docs/superpowers/` — those are the chain's own artefacts and `base-commit..HEAD` is the canonical implementation contract. Step 2.5 below is the single exception: when commits exist *and* a plan file from this chain run is detected, the handler reads the plan/spec **read-only** to compose a resume primer if the overseer reports the chain was interrupted mid-run.

### Resume Step 2.5 — Confirm chain completion (abandoned-chain recovery)

A session that was closed mid-chain looks identical to a clean exit at this point: both have commits in `base-commit..HEAD` and `sub-flow=chain-in-progress`. To distinguish, look for plan files written by *this* chain run and ask the overseer.

1. **Locate this run's plan candidates.** Combine plans added/modified in `base-commit..HEAD` (committed by the chain) with any plan files currently in the working tree under `docs/superpowers/plans/` (the chain may have written but not yet committed). Filtering by `base-commit..HEAD` excludes plans from earlier features.

   ```bash
   plan_candidates="$(
     {
       git log --diff-filter=AM --name-only --format= "$base_commit..HEAD" -- 'docs/superpowers/plans/*.md' 2>/dev/null
       git status --porcelain -- docs/superpowers/plans/ 2>/dev/null \
         | sed -E 's/^.. //; s/^.*-> //' \
         | grep '\.md$' || true
     } | sort -u
   )"
   ```

2. **If `plan_candidates` is empty** — no plan from this chain run was found (e.g., `planning-mode=direct` skips writing-plans, or the chain committed without dropping a plan file). Skip the recovery branch entirely and fall through to Step 3. No prompt; no behavior change versus the pre-recovery happy path.

3. **If `plan_candidates` has entries** — for each, count `- [x]` (done) and `- [ ]` (remaining) checkboxes:

   ```bash
   commit_count_total="$(git rev-list --count "$base_commit..HEAD")"
   last_commit="$(git log -1 --format='%h %s' HEAD)"
   while IFS= read -r plan; do
     [[ -z "$plan" ]] && continue
     done_count="$(grep -cE '^[[:space:]]*-[[:space:]]*\[[xX]\]' "$plan" 2>/dev/null || echo 0)"
     remaining_count="$(grep -cE '^[[:space:]]*-[[:space:]]*\[[[:space:]]\]' "$plan" 2>/dev/null || echo 0)"
     echo "$plan|$done_count|$remaining_count"
   done <<< "$plan_candidates"
   ```

4. **Prompt the overseer.** Render the candidates as a numbered list with their checkbox counts and ask:

   > "Stage 4 — chain-completion check.
   >
   > Plan file(s) written during this chain run:
   >
   >   1. `<path>` — done: N, remaining: M
   >   2. `<path>` — done: P, remaining: Q  *(only if multiple candidates)*
   >
   > Commits since base-commit: K (latest: `<sha> <subject>`)
   >
   > Did the brainstorming chain finish cleanly, or was the session interrupted mid-chain?
   >
   >   - `completed` — advance to overseer review (3 → 4). Use this when the chain ran through `finishing-a-development-branch` and exited normally; remaining `- [ ]` checkboxes are stale (the chain doesn't always tick the very last step).
   >   - `abandoned <N>` — re-launch the brainstorming chain with plan #N (the number from the list above) as the resume target. I'll point the chain at the existing plan + spec + commit history so it picks up from the next un-done step. Stage stays at 3 until the chain finishes; you'll type `/mo-continue` again afterward and this same handler will route to `completed`.
   >   - `abandoned` — same as above; valid only when there's exactly one plan candidate (the `<N>` is implied)."

5. **On `completed`** — fall through to Step 3.

6. **On `abandoned [<N>]`** — resolve `<N>` to the picked plan file (default to the only candidate when omitted; if multiple candidates and `<N>` is missing or out of range, surface the error and re-prompt). Then find the matching spec by the same git-log-filter pattern applied to `docs/superpowers/specs/*.md`:

   ```bash
   spec_candidates="$(
     {
       git log --diff-filter=AM --name-only --format= "$base_commit..HEAD" -- 'docs/superpowers/specs/*.md' 2>/dev/null
       git status --porcelain -- docs/superpowers/specs/ 2>/dev/null \
         | sed -E 's/^.. //; s/^.*-> //' \
         | grep '\.md$' || true
     } | sort -u
   )"
   ```

   - 0 spec candidates → omit the spec line from the resume primer (the chain works from the plan alone).
   - 1 spec candidate → reference it as `<picked_spec_path>` in the primer.
   - >1 spec candidates → list all of them in the primer; the chain decides which is canonical.

   Reset sub-flow back to `chain-in-progress` (the chain is about to be live again):

   ```bash
   $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "sub-flow=chain-in-progress"
   ```

   Then invoke the `brainstorming` Skill with this **resume primer** (substitute literals for the `<...>` placeholders, paste the actual `git log` output where indicated):

   ```
   I'm RESUMING an interrupted implementation session for the "<active_feature>" feature. The previous session ended mid-chain — some commits were made but the plan isn't fully executed.

   **Required first reads (in order):**

   1. millwright-overseer/workflow-stream/<active_feature>/blueprints/current/primer.md — the original stage-3 launch primer (active scope, goals, journal context, likely-relevant skills/rules).
   2. <picked_plan_path> — the plan you wrote in the previous session. Checkbox state (`- [x]` vs `- [ ]`) reflects what's been executed; the next `- [ ]` is where you pick up.
   3. <picked_spec_path> — the spec the plan implements. *(omit this line if no spec candidates were found)*

   **Already shipped** (commits in <base_commit>..HEAD):

   <paste output of `git log --oneline <base_commit>..HEAD` here>

   **Resume strategy:**

   Read the primer, plan, and spec. The plan's checkbox state tells you what was executed; the commit log tells you what physically landed. If they disagree (plan checkboxes can lag if the previous session was killed before the check was written), reconcile based on the commits — they're authoritative. Then continue executing-plans / subagent-driven-development from the next un-done Task or Step.

   If the plan is fundamentally incompatible with what's been committed (e.g., the previous session diverged and the plan is now stale), surface that to the overseer; they can run `/mo-abort-workflow` to start over. Otherwise: resume execution.

   Do NOT worry about the mo-workflow — when you finish, the overseer types `/mo-continue` to resume mo-workflow at stage 4.
   ```

   After invoking the Skill, **stop here**. Do NOT advance the stage. Do NOT mark `implementation-completed`. The stage stays at 3, sub-flow at `chain-in-progress`. The overseer drives the chain to completion (same isolation model as the original stage-3 launch); when it finishes, they type `/mo-continue` and this handler runs again, this time routing to `completed` (or back through Step 2.5 if the second run was also interrupted).

### Resume Step 3 — Mark implementation completed and advance

Idempotent: if `current-stage` is already past 3 from a prior partial run, skip `advance` (the script will reject a stage mismatch).

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "implementation-completed=true"

current_stage="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get current-stage)"
if (( current_stage == 3 )); then
  # Prompt the overseer for execution-mode if unknown, then:
  $CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "execution-mode=<subagent-driven|inline>"
  $CLAUDE_PLUGIN_ROOT/scripts/progress.sh advance 3
fi
```

### Resume Step 4 — Blueprint drift check (overseer-driven)

Brainstorming may have surfaced new requirements, dropped some, or shifted scope mid-session. Without inspecting the chain's spec/plan files (mo-workflow doesn't read those), the overseer is the authority on whether `blueprints/current/requirements.md` still matches what was actually built.

Prompt the overseer:

> "Stage-4 drift check: did anything in the requirements change during brainstorming? Reply:
>
>   - `<short reason>` — I'll run `/mo-update-blueprint <reason>` to rotate `blueprints/current/` into history and regenerate `requirements.md` / `config.md` / `diagrams/` from the **implementation** (codebase + `base-commit..HEAD` diff) plus the just-rotated history version. The previous blueprint's `todo-item-ids`, `## Planned`, `## Non-goals`, `## GIT BRANCH`, and `## Overseer Additions` are preserved verbatim. The active quest cycle's `todo-list.md` and `summary.md` (under `quest/<slug>/`) and `journal/` are NOT consulted.
>   - `continue` — proceed without updating the blueprint. Any drift will surface as findings during overseer review.
>
> Skipping is fine — the review loop catches drift via `re-spec` / `re-plan` findings if needed."

If the overseer replies with a reason, invoke `/mo-update-blueprint "<reason>"`. The blueprint command handles rotation, regeneration, and `review.sh sync-refs`. Otherwise (`continue` or any non-reason reply), proceed.

### Resume Step 5 — Generate implementation diagrams

Run `/mo-draw-diagrams` (the user-facing wrapper around `mo-generate-implementation-diagrams`). The command renders the diagram set of `base-commit..HEAD` into `implementation/diagrams/`, framing pre-existing participants/classes/flows as shaded context next to the new functionality.

### Resume Step 6 — Create overseer-review skeleton and hand off

Initialize the overseer-review skeleton (idempotent — `review.sh init` refuses to overwrite, so skip the call if the file already exists), then advance 4 → 5:

```bash
ov_file="millwright-overseer/workflow-stream/$active_feature/implementation/overseer-review.md"
[[ -f "$ov_file" ]] || $CLAUDE_PLUGIN_ROOT/scripts/review.sh init "$active_feature"
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh advance 4
```

Tell the overseer:

> "Stage 5 — ready for your review. Look at: commits `$base_commit..HEAD` and diagrams under `implementation/diagrams` (existing-system context is shaded grey; new functionality is highlighted). Write your findings into `implementation/overseer-review.md` (or leave it empty to approve). Type `/mo-continue` when done."

Stop here.

---

## Overseer Handler (current-stage = 5)

Runs after the overseer has reviewed the implementation and either filled `overseer-review.md` with findings or left it empty.

### Overseer Step 1 — Verify overseer-review.md exists

```bash
ov_file="millwright-overseer/workflow-stream/$active_feature/implementation/overseer-review.md"
[[ -f "$ov_file" ]] || {
  echo "overseer-review.md not found — did you mean to approve with no findings?" >&2
  read -p "Create empty overseer-review.md and approve? (y/n): " ans
  [[ "$ans" == "y" ]] || exit 1
  $CLAUDE_PLUGIN_ROOT/scripts/review.sh init "$active_feature"
}
```

### Overseer Step 1.5 — Canonicalize free-form findings

The overseer is encouraged to write findings as plain sentences — one per line or paragraph — under `## Implementation Review`. Before checking for open findings, normalize the file so every finding is in `### IR-NNN — ...` block format. Without this step, a free-form finding would slip past `list-open` (which only matches structured `### IR-NNN` headings with a `- status: open` line) and the workflow would silently auto-finalize as "approved with no findings."

```bash
unstructured="$($CLAUDE_PLUGIN_ROOT/scripts/review.sh canonicalize "$active_feature" || true)"
canon_exit=$?
```

`canonicalize` exits `0` (already canonical — skip to Step 2), `3` (unstructured spans found — proceed below), or non-zero (error — surface and abort). When spans are found, `stdout` carries one TSV row per span: `<line-start>\t<line-end>\t<flattened-text>`.

For each TSV row, the millwright (the LLM, not the script) classifies and converts:

1. **Read the text snippet.** Use it as the basis for the structured block's summary and details.
2. **Classify severity** (default `major`):
   - `blocker` if the text contains absolute language (`must`, `critical`, `breaks`, `required`, `cannot ship`).
   - `minor` if the text is hedged (`nit`, `prefer`, `could`, `maybe`, `optional`).
   - `major` otherwise.
3. **Classify scope** (default `re-implement` for refactoring suggestions, `fix` for small patches):
   - `fix` — small patch (typo, edge case, single-line behavior change, missing test).
   - `re-implement` — refactoring an existing module without changing the spec ("move to common folder", "rename", "extract", "should be generic").
   - `re-plan` — adds tasks not in the original plan ("also add X", "wire up Y", "missing handler for Z").
   - `re-spec` — challenges the design ("wrong abstraction", "should use a different pattern", "this approach won't scale").
4. **Generate a one-line summary** (≤ 80 chars) capturing the finding's intent.
5. **Add the structured block:**
   ```bash
   echo "<full original text>" | $CLAUDE_PLUGIN_ROOT/scripts/review.sh add \
     "$active_feature" "<severity>" "<scope>" "<summary>"
   ```
   The original text becomes the block's `details:` body so the overseer's wording is preserved verbatim.
6. **Strip the original freeform span.** After all spans have been added, call `strip-freeform` for each one **in reverse line order** (highest line first) so earlier line numbers stay valid:
   ```bash
   $CLAUDE_PLUGIN_ROOT/scripts/review.sh strip-freeform "$active_feature" <line-start> <line-end>
   ```

When all spans are converted, tell the overseer:

> "I converted **N** free-form finding(s) into `### IR-NNN` blocks. Severity and scope are my classifications — open `overseer-review.md` to override before the review session begins. Continuing to review..."

Then fall through to Step 2 (which re-runs `list-open` and now sees the freshly-added structured findings).

### Overseer Step 2 — Check for open findings

```bash
open_ids="$($CLAUDE_PLUGIN_ROOT/scripts/review.sh list-open "$active_feature")"
```

### Overseer Step 3a — No findings

If `open_ids` is empty:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "overseer-review-completed=true"
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh advance 5
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh advance 6
```

Tell the overseer: "Approved — no findings. Auto-finalizing via `/mo-complete-workflow`."

Then auto-invoke `/mo-complete-workflow` immediately. Do not wait for a further overseer signal — the loop's clean exit is itself the trigger.

### Overseer Step 3b — Findings present

Hand the review off to a **brainstorming review session** by invoking `/mo-review`. The session runs **isolated from mo-workflow — same isolation model as stage 3**. After invoking `/mo-review`, control returns to the overseer, who drives the session through to its terminal state (typing `approve`).

```bash
# /mo-review handles sub-flow=reviewing, the stage 5→6 advance, and the Skill invocation,
# then hands off. It does NOT block on the Skill.
/mo-review
```

After `/mo-review` returns, **stop**. Do not advance the stage. Do not auto-fire `/mo-complete-workflow`. The Review-Resume Handler will run when the overseer types `/mo-continue` again after the brainstorming review session exits.

Tell the overseer: "Brainstorming review session is now live (isolated from mo-workflow). Drive it to completion (typing `approve` when ready), then type `/mo-continue` to resume the mo-workflow."

**Why no scope-tier dispatch here.** Earlier versions of mo-workflow encoded a scope-tier cascade (re-spec → re-plan → re-implement → fix) inside this handler. That logic moved into the brainstorming session itself: the chain reads each finding's `scope:` as a hint and chooses the smallest cascade that resolves the root cause. Mo-workflow no longer needs to know about scopes during the loop — only that brainstorming exited cleanly.

**No iteration cap.** Brainstorming controls its own loop; the overseer ends it by typing `approve`. If the overseer accumulates many findings and the loop runs long, it's their judgment call to interrupt with `/mo-abort-workflow`.

---

## Review-Resume Handler (current-stage = 6, sub-flow = reviewing)

Runs after the brainstorming review session has fully exited and returned control. Sanity-checks the findings status, advances 6 → 7, and auto-fires `/mo-complete-workflow`.

This handler exists because stage 6's brainstorming review session runs **isolated from mo-workflow** — same as the stage-3 chain. There is no programmatic signal that the session ended; the overseer's `/mo-continue` is the explicit resumption signal.

### Review-Resume Step 1 — Open-findings completion check

```bash
remaining_open="$($CLAUDE_PLUGIN_ROOT/scripts/review.sh list-open "$active_feature")"
```

If `remaining_open` is empty, fall through to Step 2 (advance and finalize).

If `remaining_open` is non-empty, the review session ended without resolving every finding — the same ambiguity as the stage-3 abandoned-chain case. The session may have exited cleanly with deferred findings, or it may have been interrupted mid-loop. Prompt the overseer:

> "Review session ended with **N** open finding(s): `<id-list>`. Did the session finish, or was it interrupted?
>
>   - `completed` — keep them open and proceed; the workflow advances 6 → 7 with the finding(s) still `open`. Use this if you and the chain agreed to defer them. `mo-complete-workflow` archives `overseer-review.md` into `blueprints/history/v[N]/implementation/` at stage 8, so the deferred findings remain queryable in the historical record. (If you want them *addressed* in this cycle instead of just archived, run `/mo-review` to re-launch the loop.)
>   - `abandoned` — re-launch the brainstorming review session via `/mo-review` to address the remaining findings. Stage stays at 6 until the session exits cleanly; you'll type `/mo-continue` again afterward.
>   - `abort` — cancel the workflow via `/mo-abort-workflow`."

- **On `completed`** — fall through to Step 2.
- **On `abandoned`** — invoke `/mo-review` (which reads the open findings, prompts for a review-mode, and re-launches the loop) and **stop**. Do NOT advance past stage 6. The next `/mo-continue` after the new session exits will re-enter this handler.
- **On `abort`** — invoke `/mo-abort-workflow` and stop.

### Review-Resume Step 2 — Mark complete and advance

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh set \
  "sub-flow=none" \
  "overseer-review-completed=true"
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh advance 6
```

### Review-Resume Step 2.5 — Offer diagram refresh

The review session may have committed new code. The implementation diagrams under `implementation/diagrams/` reflect the state at the post-chain Resume Handler — they don't capture review-loop fixes. Before finalizing, give the overseer the option to refresh:

```bash
review_commits="$(git rev-list --count "$base_commit..HEAD" 2>/dev/null || echo 0)"
diagram_commits="$(git log --format=%H -- "millwright-overseer/workflow-stream/$active_feature/implementation/diagrams/" | head -1)"
new_since_diagrams="$(git rev-list --count "${diagram_commits:-$base_commit}..HEAD" 2>/dev/null || echo 0)"
```

Prompt the overseer:

> "The review session committed **N** additional commits since the original implementation diagrams were generated. Regenerate the diagrams to reflect the final state of `base-commit..HEAD`?
>
>   - `y` — re-run `/mo-draw-diagrams` before finalizing (~30 seconds; useful for a final visual sanity check before the diagrams are deleted at stage 8).
>   - `n` — proceed directly to `/mo-complete-workflow`. The diagrams stay at the post-chain snapshot; they're deleted at stage 8 anyway.
>
> (y/n)"

Skip the prompt entirely when `new_since_diagrams == 0` (no review-loop commits — diagrams are already current). On `y`, invoke `/mo-draw-diagrams` and continue. On `n`, continue. Either way, fall through to Step 3.

### Review-Resume Step 3 — Auto-fire /mo-complete-workflow

Tell the overseer: "Overseer-review session approved. Auto-finalizing via `/mo-complete-workflow`."

Then auto-invoke `/mo-complete-workflow` immediately. Do not wait for a further overseer signal — the third `/mo-continue` is itself the trigger.

## Notes

- `/mo-continue` is a dispatcher — it reads state and acts. It never asks the overseer which stage we're at.
- For state outside the known stages (3, 5, or 6+reviewing), the dispatcher falls through to `/mo-resume-workflow` for diagnosis rather than erroring out.
- The mo-workflow does not read or modify the chain's spec/plan files under `docs/superpowers/` in the happy path. Re-entry into `brainstorming` / `writing-plans` / `executing-plans` for `re-spec` / `re-plan` cascades is via concern-bundle primers; the chain regenerates its own artefacts internally and produces fresh commits in `base-commit..HEAD`. **The single exception** is the abandoned-chain recovery branch in Resume Step 2.5, which reads the chain's plan and spec **read-only** to compose a resume primer when the overseer reports an interrupted run. No mo-workflow command writes to `docs/superpowers/`.
- Both the stage-3 chain and the stage-6 brainstorming review session run **isolated from mo-workflow**. Neither auto-detects skill completion — the explicit `/mo-continue` from the overseer is the resumption signal in both cases.
- If invariants are violated (e.g., `current-stage=4` but `implementation-completed=false`), stop and recommend `/mo-resume-workflow` for diagnosis.
