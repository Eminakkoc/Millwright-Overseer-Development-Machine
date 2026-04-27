---
description: Launch a brainstorming review session for the active feature. Reads open findings from overseer-review.md and invokes brainstorming with those findings as work definition. The session runs ISOLATED from mo-workflow — same isolation model as stage 3. The overseer types /mo-continue after the session ends to resume the workflow.
---

# mo-review

**Review-loop launcher — pure launcher, no driver logic.** Reads `overseer-review.md`, collects all open findings, and invokes the `brainstorming` Skill with those findings as the work definition. Brainstorming runs the review loop end-to-end — addressing findings (deciding internally between fix / re-implement / re-plan / re-spec), asking the overseer for approval, and re-reading `overseer-review.md` if the overseer adds new findings mid-session — until the overseer approves and the chain exits.

**The session runs isolated from mo-workflow — same isolation model as stage 3.** `mo-review` does NOT block on the Skill, does NOT advance past stage 6, and does NOT auto-fire `/mo-complete-workflow`. After the brainstorming session exits, the overseer types `/mo-continue` to resume mo-workflow; the post-review-session resume handler in `/mo-continue` finalizes (advances 6 → 7 and auto-fires `/mo-complete-workflow`).

There is no AI-driven review pass. Findings are authored by the overseer (during stage 5, and any time during the review loop). `mo-review` is a hand-off mechanism, not a reviewer.

## When invoked

- **Auto-fired** by `/mo-continue`'s Overseer Handler when the overseer types `/mo-continue` after writing findings into `overseer-review.md`.
- **Manually invokable** by the overseer at any point during stage 5 — useful if the overseer wants to start the brainstorming review session before the auto-fire path.

## Preconditions

- `progress.md`'s `active.current-stage` is 5 or 6.
- `overseer-review.md` exists.
- At least one finding in `overseer-review.md` has `status: open`. (If none are open, the workflow auto-completes — see `commands/mo-continue.md` Overseer Step 3a.)

## Execution

### Step 1 — Resolve inputs

```bash
active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active)"
ov_file="millwright-overseer/workflow-stream/$active_feature/implementation/overseer-review.md"
[[ -f "$ov_file" ]] || { echo "error: overseer-review.md not found at $ov_file" >&2; exit 1; }

open_ids="$($CLAUDE_PLUGIN_ROOT/scripts/review.sh list-open "$active_feature")"
[[ -n "$open_ids" ]] || { echo "no open findings — nothing to review. Type /mo-continue to run the clean-review finalizer (advances to stage 7 and auto-fires /mo-complete-workflow)." >&2; exit 0; }
```

### Step 2 — Mark sub-flow

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "sub-flow=reviewing"
# Advance 5 → 6 if not already past.
current_stage="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get current-stage)"
if (( current_stage == 5 )); then
  $CLAUDE_PLUGIN_ROOT/scripts/progress.sh advance 5
fi
```

### Step 2.5 — Generate `implementation/review-context.md`

Compose a compact snapshot of the context the brainstorming review session needs at every loop trip — active scope, goals, implemented surface, and open-findings cheat sheet. The chain stays in this snapshot for the common case and drops into canonical files only when a finding requires deeper context.

```bash
ctx_dest="millwright-overseer/workflow-stream/$active_feature/implementation/review-context.md"
requirements_file="millwright-overseer/workflow-stream/$active_feature/blueprints/current/requirements.md"
requirements_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$requirements_file" id)"
# frontmatter.sh init overwrites — safe to re-run if /mo-review is invoked again.
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init review-context "$ctx_dest" \
  "REQUIREMENTS_ID=$requirements_id" \
  "FEATURE=$active_feature"
```

Then fill the body via `Edit`, following the template's section guide:

- **`## Active scope`** — write `branch` and `base-commit` from `progress.md` (`progress.sh get branch`, `progress.sh get base-commit`).
- **`## Goals (this cycle)`** — 5–20 line excerpt from `requirements.md` `## Goals (this cycle)`.
- **`## Implemented surface`** — two short lists. (a) Changed areas: prefer reading from `implementation/change-summary.md`'s `## Changed files` section when fresh — it already groups paths by area and notes adds/dels per file; check freshness with `commits.sh change-summary-fresh "$active_feature"`. If stale or missing, fall back to `commits.sh changed-files "$active_feature"` and group manually. Either way, do not paste diffs. (b) Diagrams: list every file under `implementation/diagrams/` with a one-line purpose pulled from its `diagrams/README.md`.
- **`## Open findings (snapshot)`** — one line per `IR-NNN` from `review.sh list-open "$active_feature"`, in the order they appear in `overseer-review.md`. Format: `IR-NNN (<severity>): <summary>`.

The `## On-demand canonical files` section is template-emitted and does not need editing.

### Step 2.6 — Ask the overseer to pick a review mode

Prompt the overseer:

> "Review session — pick a mode for addressing the open findings on `$active_feature`:
>
>   - **`brainstorming`** (default) — launches an isolated brainstorming review session. The chain reads each finding's `scope:` as a hint and decides per-finding whether to `fix` (patch), `re-implement`, `re-plan`, or `re-spec`. Best when findings span scope tiers, or when you want the chain to drive the decision.
>   - **`direct`** — I address the findings myself in this session, applying patches directly. Best when every finding is `fix` or simple `re-implement` (small refactors with clear acceptance criteria) and you want to skip the chain ceremony.
>
> Reply `brainstorming` or `direct`."

Wait for the reply. Persist:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/progress.sh set "review-mode=<choice>"
```

Then dispatch on the value:

- `brainstorming` → continue to **Step 3a**.
- `direct` → continue to **Step 3b**.

### Step 3a — Brainstorming mode: invoke the Skill

Use the `Skill` tool to invoke the `brainstorming` skill with the following primer message. Substitute `<$active_feature>` with the actual feature name. **The Skill is invoke-and-hand-off, not invoke-and-block** — same as `/mo-plan-implementation` at stage 3. The brainstorming session runs in an isolated interactive flow driven by the overseer; `mo-review` returns immediately after the Skill is invoked.

```
I'm addressing overseer review findings on the "<$active_feature>" feature. The implementation already exists in `base-commit..HEAD`; your job is to address the open findings the overseer wrote, ask for approval, and loop if more findings are added.

**Context loading order** (read in this order; only escalate when a gap appears):

1. **Required first read** — millwright-overseer/workflow-stream/<$active_feature>/implementation/review-context.md
   Compact snapshot of active scope, goals, implemented surface, and open-findings cheat sheet. For most loop trips this plus overseer-review.md is all you need.

2. **Canonical findings (always)** — millwright-overseer/workflow-stream/<$active_feature>/implementation/overseer-review.md
   The source of truth for findings. Re-read on `go again` to pick up any new entries the overseer added mid-session.

3. **On demand** — only if review-context.md leaves a gap on a specific topic:
   - millwright-overseer/workflow-stream/<$active_feature>/blueprints/current/requirements.md — full goals / planned / non-goals
   - millwright-overseer/workflow-stream/<$active_feature>/blueprints/current/config.md — full skills/rules + GIT BRANCH + Overseer Additions
   - millwright-overseer/workflow-stream/<$active_feature>/blueprints/current/primer.md — original stage-3 launch primer
   - millwright-overseer/quest/<active-slug>/summary.md — feature-indexed journal digest for the active cycle (the slug is in `quest/active.md`). Read `## Cross-cutting constraints` and `## Feature: <$active_feature>` first

**Work definition** (open findings to address):
Each open finding (`status: open`) is a block under `## Implementation Review` (or `## Iteration N` on later passes) in overseer-review.md with: id (IR-NNN), severity, scope (hint), details.

**How to address findings:**
The `scope` field on each finding is a hint, not a directive. Decide for yourself the smallest rework that genuinely addresses the root cause:
- `fix` — patch the existing code directly. Commit. Mark resolved.
- `re-implement` — chain into `executing-plans` / `subagent-driven-development` for the affected sections; the existing plan stays.
- `re-plan` — chain into `writing-plans` (with the concern bundle), then cascade through `executing-plans`. The existing spec stays; the chain regenerates the plan internally.
- `re-spec` — full re-design from this skill. Cascade through `writing-plans` + `executing-plans`. The chain regenerates spec + plan + commits internally.

Process findings in descending order of impact: re-spec → re-plan → re-implement → fix. A higher-tier action supersedes lower-tier findings in the same pass — mark them `fixed` with `fix-note: "superseded by re-spec at iteration N"` (or re-plan, etc.).

**For each finding addressed**, call:
```bash
$CLAUDE_PLUGIN_ROOT/scripts/review.sh set-status <feature> <IR-NNN> fixed "<one-line fix-note>"
```

(`<feature>` is `<$active_feature>`. Use `wontfix` instead of `fixed` if you and the overseer agree to skip it.)

**Loop pattern (this is the review loop):**
1. Read `overseer-review.md`. List all `open` findings.
2. Address them per the rules above. Commit your changes. Mark each finding resolved.
3. Tell the overseer: *"All open findings addressed (resolved: <ids>). Either: (a) reply `approve` to exit the review session — then type `/mo-continue` to resume mo-workflow and finalize; (b) write new findings into `overseer-review.md` (any text editor; same `### IR-NNN` block format the overseer-review template shows) and reply `go again` so I can re-read."*
4. On `approve` reply: tell the overseer *"Review session approved. Type `/mo-continue` to resume the mo-workflow and finalize."* Then exit cleanly. Do NOT call `set-status` or `progress.sh` for completion — those are mo-workflow's job, triggered by the overseer's `/mo-continue`.
5. On `go again` reply: re-call `review.sh list-open` to pick up new finding ids, then go to step 1.
6. On any other reply: treat as a verbal concern. Either (a) ask the overseer to write it into `overseer-review.md` first if it's a substantive review finding, or (b) address it inline if it's a clarifying question.

**One-iteration discipline:** within step 2, fix ALL open findings before asking for approval. Do not partially fix and ask. Each loop trip is one full address-pass.

**Existing scope rules** (the same ones the overseer review template references): pick the smallest tier that genuinely resolves the root cause. If a narrower tier would leave the cause in place, escalate.

Do NOT worry about the mo-workflow — when you exit, the overseer types `/mo-continue` to resume mo-workflow, which sanity-checks findings, advances stages, and finalizes the workflow via `/mo-complete-workflow`.
```

### Step 3b — Direct mode: address findings in this session

The millwright (this session) addresses each finding directly — no Skill is invoked. The overseer interacts with the millwright in chat as fixes happen.

1. **Read the required first reads:**
   - `implementation/review-context.md` — compact snapshot of active scope, goals, implemented surface, open-findings cheat sheet.
   - `implementation/overseer-review.md` — canonical findings (re-read on every `go again`).
2. **Process open findings in descending impact order:** `re-spec` → `re-plan` → `re-implement` → `fix`. A higher-tier action supersedes lower-tier findings in the same pass; mark superseded findings `fixed` with `fix-note: "superseded by re-spec at iteration N"` (or re-plan, etc.).
   - **Direct mode caveat:** if a finding's scope is `re-plan` or `re-spec`, it likely needs the chain's design / plan gates that direct mode skips. Surface that to the overseer and ask if they want to switch to `brainstorming` for the rest of the session — re-set `review-mode=brainstorming` and proceed to Step 3a. Only stay in direct mode for `fix` / simple `re-implement` findings.
3. **For each finding addressed**, commit the change and call:
   ```bash
   $CLAUDE_PLUGIN_ROOT/scripts/review.sh set-status "$active_feature" <IR-NNN> fixed "<one-line fix-note>"
   ```
   Use `wontfix` instead of `fixed` if the overseer agrees to skip it.
4. **One-iteration discipline:** address ALL open findings before asking for approval. Do not partially fix and ask.
5. **Loop pattern (same as brainstorming mode, just driven from this session):**
   1. Read `overseer-review.md`; list `open` findings.
   2. Address them per the rules above; commit; mark each resolved.
   3. Tell the overseer: *"All open findings addressed (resolved: \<ids\>). Either: (a) reply `approve` to end the review session — then type `/mo-continue` to resume mo-workflow and finalize; (b) add new findings to `overseer-review.md` (plain sentences are fine — I'll canonicalize them) and reply `go again` so I re-read."*
   4. On `approve`: tell the overseer *"Review session approved. Type `/mo-continue` to resume the mo-workflow and finalize."* Then stop. Do NOT call `progress.sh` for completion — that's mo-workflow's job, triggered by `/mo-continue`.
   5. On `go again`: re-canonicalize free-form additions (run `review.sh canonicalize` + `review.sh add` per Finding-5 step in `mo-continue.md` Overseer Step 1.5), then re-call `review.sh list-open` and go to step 1.
6. **Existing scope rules** apply unchanged: pick the smallest tier that genuinely resolves the root cause; escalate if narrower tier leaves the cause in place.

### Step 4 — Hand off

After Step 3a (brainstorming) or Step 3b (direct), stop driving the mo-workflow. Both modes converge on the same terminal: the overseer types `approve` to end the session, then types `/mo-continue` to resume mo-workflow.

- **Brainstorming mode (Step 3a):** runs **isolated from mo-workflow** — same isolation model as stage 3. The overseer drives the session through to its terminal state (typing `approve`), then types `/mo-continue` to resume the mo-workflow.
- **Direct mode (Step 3b):** runs in the main session. The overseer reviews fixes inline; when satisfied, types `approve` to end the loop, then `/mo-continue` to resume.

`mo-review` does **not** advance past stage 6. The Review-Resume Handler in `/mo-continue` (see `commands/mo-continue.md`) handles the post-session work when the overseer types `/mo-continue` after the session ends: sanity-checking no `open` findings remain, marking `overseer-review-completed=true`, setting `sub-flow=none`, advancing 6 → 7, and auto-firing `/mo-complete-workflow`.

**Do not type `/mo-continue` while the brainstorming review session is mid-prompt** (e.g., while the chain is asking for `approve` / `go again`). Answer the chain first; type `/mo-continue` only after the chain has fully exited and returned control to the main session.

## Delegation (optional)

When `overseer-review.md` has more than ~5 open findings, finding clustering is a good delegation candidate (see `docs/workflow-spec.md` § "Delegation guidance"). Spawn one sub-agent per cluster with **disjoint** read/write scopes — each writes a per-cluster context file (e.g., `implementation/findings/<cluster>.md`) and proposes per-cluster scope (`fix` / `re-implement` / `re-plan` / `re-spec`). Capability tier: "general reasoning, medium effort" for fix/re-implement clusters; escalate to "most capable, high effort" for re-plan or re-spec clusters. The brainstorming session reads those per-cluster files instead of re-deriving context per finding. With ≤ 5 open findings, the chain handles them inline without delegation.

## Notes

- The brainstorming primer is a **layered load**: `review-context.md` + `overseer-review.md` are the required first reads; `requirements.md`, `config.md`, `summary.md`, and `primer.md` are on-demand fallbacks. The chain reads the codebase as needed.
- `review-context.md` is a snapshot taken when `/mo-review` is invoked. Its body is NOT auto-refreshed if `/mo-update-blueprint` runs mid-loop — only the `requirements-id` frontmatter is re-pointed by `review.sh sync-refs`. The chain re-reads canonical files (`overseer-review.md`, `requirements.md`) when current state matters.
- `mo-review` does not generate findings. Authoring is the overseer's job (subjective concerns) and brainstorming's job (concerns surfaced during the session, written into `overseer-review.md` directly via the same `review.sh add` interface).
- Brainstorming exits in one of three ways:
  - **Approval (clean exit):** all findings resolved + overseer types `approve` → session ends. The overseer then types `/mo-continue`, which fires the Review-Resume Handler in `/mo-continue` to advance 6→7 and auto-fire `/mo-complete-workflow`.
  - **Abort:** overseer types `/mo-abort-workflow` mid-session → see `commands/mo-abort-workflow.md` for cleanup.
  - **Stuck / dead-end:** brainstorming may exit without addressing all findings. The Review-Resume Handler (triggered when the overseer types `/mo-continue`) detects open findings remaining and prompts the overseer to retry with `/mo-review` or to abort.
- The chain's spec/plan files (under `docs/superpowers/`) are not inputs and not tracked. Brainstorming regenerates its own artefacts internally as part of any cascade.
- There is no iteration cap. Brainstorming controls its own loop; the overseer ends it by typing `approve`.
