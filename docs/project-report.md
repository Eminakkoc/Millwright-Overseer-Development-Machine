# Millwright-Overseer Development Machine — Detailed Project Report

  

> **Purpose of this document.** A self-contained, in-depth briefing for AI agents (or new human collaborators) who need a complete mental model of this project without having to crawl the codebase. It explains the philosophy, the actors, the data flow, every command, every stage, and every supporting script. Optimized for context-pasting into another agent's working memory.

  

---

  

## 1. Introduction — The Philosophy

  

### 1.1 Why this project exists

  

Software development has historically revolved around a single primary artifact: **the codebase**. Everything else — requirement documents from project managers, ticket queues in JIRA / Linear, design hand-off in Figma, sprint planning, code-review comments — was *connective tissue* whose only job was to feed the human developer enough context to write code. The developer was the bottleneck and also the only authoritative author of the product.

  

The arrival of capable AI coding agents collapses that center of gravity. The agent can:

  

- read requirement documents and meeting transcripts directly,

- design APIs, draw diagrams, write specs,

- implement features end-to-end,

- and even self-review its own code.

  

This forces a question many developers find disorienting: **if the AI can do all of that, what is left for the developer to do?** The Millwright-Overseer plugin proposes a clean answer: the developer's role is renamed and reframed, not eliminated. Two new roles take the place of the legacy "developer + project manager + reviewer" stack:

  

1. **The Millwright** — an AI coding agent (Claude Code) that does the building. The name is borrowed from factory life: a millwright builds, maintains, and repairs the heavy machines that produce a factory's output. In software, the codebase is the factory and each module/feature is a machine. The AI agent is the modern millwright.

2. **The Overseer** — a human who supplies raw materials (specs, notes, transcripts), defines the work, and reviews every artifact the millwright produces at every stage. The overseer never writes production code; their authority is exercised through documents, prompts, and approvals.

  

The naming is intentional. "Developer" carried so much accumulated meaning (architect, coder, tester, debugger, reviewer) that calling the human a developer in this new world would be misleading. Calling the AI a "developer" would also feed the toxic narrative that "AI took the developer's job." Renaming both sides separates the activity from the historical identity.

  

### 1.2 The reform of tooling and artifacts

  

If the AI agent can read, design, and write directly from raw inputs, many tools that used to live around the codebase become unnecessary or transform:

  

- **Design hand-off tools** are replaced by direct MCP integrations or design-to-code generation (e.g., Figma MCP + plugin).

- **Requirement documents** no longer need a project manager / business analyst to mediate between customer and developer. Customer voice memos become prompts; meeting transcripts go straight into the journal; vibe-coded prototypes can themselves serve as inputs.

- **Task management tools** (JIRA, Linear) are no longer the single source of truth. Tasks live in `quest/todo-list.md` next to the codebase. PMs query the artifacts via natural-language prompts to their own agents ("summarize what mobile shipped today", "is the loyalty feature done?", "how does it interact with auth?"). The *.md files alongside the code are the answer surface.

- **Pull-request review tools** are augmented by structured review files (`overseer-review.md`) that the millwright can re-read on every iteration.

  

The result: only **two** primary components matter — the **codebase** and the **millwright-overseer/** "control room" folder. Everything the workflow needs to remember is on disk in plain Markdown so it survives session breaks, model swaps, and even days-long pauses.

  

### 1.3 Core operating principles

  

Three rules are stamped into every command and stage:

  

1. **Inputs live in files, not in conversation context.** Context is ephemeral; sessions break and get compacted. Every overseer-supplied value (branch name, approval, finding) is captured to disk the moment it arrives. Each command's inputs list is a *file-path contract*, not a parameter list.

2. **Documents cross-link via UUIDs, paths are just navigation hints.** Every generated `.md` carries a UUID v4 in its frontmatter. Cross-references point at IDs, not paths, which gives grep-based discovery, rename-safety, and a clean audit trail when combined with `blueprints/history/`. UUIDs are minted by `scripts/uuid.sh` (never by the AI directly) to eliminate hallucinated IDs.

3. **Layered context loading.** Long-running stages (planning, review) are entered through a small *primer* file rather than by re-reading every canonical file. The chain reads the primer first and only escalates to the canonical files when a gap surfaces. This keeps token consumption bounded across multi-day workflows.

  

A fourth implicit rule: **every artifact is auditable**. Blueprints are rotated into `blueprints/history/v[N]/` on each refresh with a sibling `reason.md` explaining *why*. Findings keep monotonically increasing IR-NNN ids that never reset. Quest cycles and feature cycles have crisp lifecycles with clearly defined entry / exit points. Nothing is ever silently overwritten.

  

---

  

## 2. The Two Roles

  

### 2.1 The Overseer (human)

  

- **Owns**: the journal content, the todo selection, the assignee tags, blueprint approvals, `## Overseer Additions` in `config.md`, the git branch, the findings file, every `/mo-continue` signal.

- **Never writes**: production code, generated specs, generated diagrams, generated requirements, generated quest files. (The overseer *may* hand-edit these in emergencies, but that's a recovery path, not the primary mode.)

- **Touchpoints per feature** (happy path, see §6 for details):

- `/mo-run <folder...>` once at the start of a quest cycle.

- `/mo-continue` ×2 at stage 1.5 (after marking, after queue order proposal).

- `/mo-continue` ×1 after blueprint review at stage 2.

- Picks `planning-mode` (`brainstorming` | `direct`) when prompted.

- `/mo-continue` ×1 after the chain returns at stage 4.

- Edits `overseer-review.md` if needed, then `/mo-continue` at stage 5.

- Picks `review-mode` if findings exist; types `approve` to end the review session.

- `/mo-continue` ×1 after the review session at stage 6 (only when there were findings).

- Optional y/n diagram-refresh, optional blueprint-drift reason.

  

### 2.2 The Millwright (AI agent — Claude Code)

  

- **Owns**: every generated artifact under `quest/`, `workflow-stream/<feature>/blueprints/current/`, and `workflow-stream/<feature>/implementation/`. Owns dispatch — picks the right handler inside `/mo-continue`. Owns auto-fired commands (`mo-apply-impact`, `mo-plan-implementation`, `mo-review`, `mo-complete-workflow`, `mo-draw-diagrams`).

- **Never owns**: git operations beyond reads (no branch creation, no commits to main, no force-push), the `## Overseer Additions` block in `config.md`, the journal content, todo selection or assignee tags.

- **Delegates** (optional, see §3.2): may spawn sub-agents for bounded heavy lifting (per-file journal summarization, queue dependency analysis, change-summary writing, finding-cluster grouping). Sub-agents return ≤ 20-line routing slips; their detailed output goes into artifact files.

  

---

  

## 3. System Architecture

  

### 3.1 The two top-level components

  

1. **Codebase** — whatever the project is building. The mo-workflow does not enforce any particular language or framework on it.

2. **`millwright-overseer/` folder** ("the control room") — the workflow's data root. Path is configurable via `userConfig.data_root` in `plugin.json` (default: `millwright-overseer`; commonly set to `.millwright-overseer` for hidden mode).

  

The control-room folder contains exactly three sub-folders:

  

```

millwright-overseer/

├── journal/ # raw inputs (overseer-authored)

├── quest/ # cycle-wide working state (millwright-generated; overseer marks selections)

└── workflow-stream/ # per-feature blueprints + implementation artifacts

```

  

### 3.2 The journal

  

The journal holds **raw resources**: meeting transcripts, notes, specs, design hand-offs, slack conversation exports — anything that defines or constrains the work. Sub-folders are topic groupings. The overseer drops files in; the workflow reads them.

  

Accepted formats:

- `.md` — must carry YAML frontmatter with `contributors:` and `date:` (YYYY-MM-DD). The overseer authors the frontmatter manually.

- `.txt` — no frontmatter required; read as plain content.

- `.pdf`, `.docx`, `.pptx`, `.xlsx`, `.html`, images (`.png`/`.jpg`/etc.) — supported via `/mo-ingest` (which uses **docling** for document conversion and a stub-md for images / short PDFs). `/mo-run` detects un-ingested files at stage 1 and asks the overseer per file which path to take. Originals stay in place for audit.

  

Example layout:

  

```

journal/

├── pricing-requirements-meeting/

│ ├── meeting-transcript.txt

│ ├── notes.md

│ └── devops-team-concerns.md

└── authentication-related-slack-conversation/

└── conversation.txt

```

  

### 3.3 The quest folder

  

Generated by `/mo-run` at the start of each cycle and **co-replaced as a unit** when the next `/mo-run` opens a new cycle. Four files share this lifecycle:

  

| File | Role |

| ---- | ---- |

| `todo-list.md` | Per-feature checklist of TODO items with assignee tags. The overseer marks items with `[x]` to select for the cycle. |

| `summary.md` | Feature-indexed digest of journal content. `## Cross-cutting constraints`, `## Out-of-scope`, and one `## Feature: <name>` section per feature. Downstream stages read only the active feature's section. |

| `progress.md` | The central workflow state file. Holds the queue, completed list, and the active feature's runtime block. (See §3.5.) |

| `queue-rationale.md` | Audit of stage 1.5's dependency-ordering decision; survives session breaks so the analysis isn't re-derived on resume. |

  

#### Todo-item state machine

  

Items pass through five canonical states:

  

```

TODO → PENDING → IMPLEMENTING → IMPLEMENTED

↘ CANCELED (mid-cycle exit; preserved for audit)

```

  

Checkbox convention:

- `[ ]` = TODO only.

- `[x]` = any selected state (PENDING, IMPLEMENTING, IMPLEMENTED, CANCELED) — the **state word** is the canonical truth.

  

Assignee tag (the name in parentheses between the checkbox and the state word):

- *Optional* on `[ ] TODO` lines (overseer may pre-assign without selecting).

- **Mandatory** on every `[x]` line. `todo.sh pend-selected` rejects unassigned selections with a list of offending IDs so the overseer can fix and retry.

  

Example progression:

  

```

- [ ] TODO — PAY-001: capture webhook (default unselected, unassigned)

- [ ] (emin) TODO — PAY-001: capture webhook (pre-assigned, not selected)

- [x] (emin) PENDING — PAY-001: capture webhook (selected for this cycle)

- [x] (emin) IMPLEMENTING — PAY-001: capture webhook (in workflow)

- [x] (emin) IMPLEMENTED — PAY-001: capture webhook (done)

- [x] (emin) CANCELED — PAY-001: capture webhook (dropped mid-cycle, kept for audit)

```

  

**Refused manual writes.** The plugin refuses manual writes to `PENDING` and `IMPLEMENTED`:

- `PENDING` is only written by stage-1.5's `pend-selected` (it's an audit event tied to bulk selection).

- `IMPLEMENTED` is only written by stage-8's `mo-complete-workflow` (the commits-linkage invariant depends on atomic promotion).

  

### 3.4 The workflow stream

  

Per-feature folders that hold the actual design + implementation artifacts. One folder per feature in `workflow-stream/<feature>/`:

  

```

workflow-stream/<feature>/

├── blueprints/

│ ├── current/

│ │ ├── requirements.md # Goals / Planned / Non-goals

│ │ ├── config.md # auto-summary of skills+rules; ## GIT BRANCH; ## Overseer Additions

│ │ ├── primer.md # compact stage-3 launch primer (layered-load entry point)

│ │ └── diagrams/

│ │ ├── use-case-<feature>.puml

│ │ ├── sequence-<flow>.puml

│ │ └── (optional) class-<domain>.puml

│ └── history/

│ ├── v1/{requirements.md, config.md, primer.md, diagrams/, reason.md}

│ ├── v2/...

│ └── ...

└── implementation/ # cleared at stage 8

├── overseer-review.md # findings file (IR-NNN blocks)

├── review-context.md # compact stage-6 review primer

├── change-summary.md # cached analysis of base-commit..HEAD (cache-keyed reuse)

└── diagrams/ # render of the implementation, with shaded "existing system" framing

```

  

Two regions:

  

1. **`blueprints/`** — *permanent with history*. `current/` holds the live blueprint for the active feature. Every refresh rotates `current/*` into `history/v[N+1]/` with a `reason.md` recording why (`completion`, `manual`, `re-spec-cascade`, `re-plan-cascade`, `spec-update`).

2. **`implementation/`** — *temporary*. Holds findings and implementation-side artifacts. Cleared by `mo-complete-workflow` (stage 8) and `mo-abort-workflow`.

  

### 3.5 `progress.md` — the central state file

  

A single YAML-frontmatter Markdown file at `quest/progress.md`. Its frontmatter is the source of truth for "where are we right now":

  

```yaml

---

id: <uuid>

todo-list-id: <uuid of the related todo-list.md>

queue: [notifications, audit-log] # features still to run, in priority order

completed: [onboarding] # features finalized via mo-complete-workflow

active: # null between workflows; populated while a feature is running

feature: payments

branch: feat/payments/webhook # null until stage 3

current-stage: 5

sub-flow: none # none | chain-in-progress | resuming | reviewing

base-commit: a1b2c3d # null until stage 3

execution-mode: subagent-driven

planning-mode: brainstorming # brainstorming | direct | none

review-mode: none # brainstorming | direct | none

implementation-completed: true

overseer-review-completed: false

---

```

  

Two-step activation lifecycle:

  

| Trigger | Effect on `active` |

| --- | --- |

| `/mo-run` (stage 1) | `active = null`; queue populated. |

| `/mo-apply-impact` → `progress.sh activate` (stage 2) | Pops `queue[0]` into a fresh `active` block (current-stage=2). Fails fast if `active` is already non-null. |

| Stages 2–8 | Mutates `active.*` fields in place via `progress.sh set` and `progress.sh advance`. |

| `mo-complete-workflow` → `progress.sh finish` (stage 8) | Appends `active.feature` to `completed`; sets `active = null`. |

  

On resume, the millwright reads `active`:

- `active` null + non-empty queue → "next feature is waiting; activate it."

- `active` populated → "feature X at stage N with sub-flow Y."

- `active` null + empty queue → "cycle complete (or todo list still has unmarked items — start stage 1.5 again)."

  

---

  

## 4. Roles × Plugin Interaction Table

  

This table summarizes who interacts with which plugin surface, for which purpose, at which stage. It is the single most useful map for understanding the workflow's blast radius.

  

| Actor | Interacts with | Action / Touchpoint | Stage | Notes |

| --- | --- | --- | --- | --- |

| **Overseer** | `journal/<topic>/*.md` `.txt` (and ingested non-text) | Authors raw inputs, frontmatter (`contributors`, `date`), groups them by topic. | 0 | Manual; overseer is the only writer. |

| Overseer | `/mo-init` | First-run wizard; one-prompt dependency install + folder scaffold. | once | Idempotent. |

| Overseer | `/mo-doctor` | Detailed dependency check; per-dep prompts; sudo handling. | recovery / setup | Auto-invoked by `/mo-run`'s preflight. |

| Overseer | `/mo-ingest <folder>` / `--file <path>` / `--stub <path>` | Convert PDF/DOCX/PPTX/XLSX/HTML/images to sibling `.md` (docling or stub). | optional 0.5 | Required for non-text journal files Claude can't `Read` natively. |

| Overseer | `/mo-run <folder1> [<folder2> ...]` | Generate quest files from selected journal sub-folders. | 1 | Pure journal → quest. No branch arg. |

| Overseer | `quest/todo-list.md` | Marks items `[x]` and adds `(assignee)` tag. | 1.5 | Item selection. |

| Overseer | `/mo-continue` (1st in stage 1.5) | Triggers Pre-flight Step 2A: promote `[x] TODO` → `[x] PENDING`, propose queue order. | 1.5 | `pend-selected` rejects unassigned `[x]`. |

| Overseer | `/mo-continue` (2nd in stage 1.5) | Triggers Pre-flight Step 2B: write `queue-rationale.md`, reorder queue, auto-fire `/mo-apply-impact`. | 1.5 → 2 | Overseer may paste a custom order before this. |

| **Millwright (auto)** | `/mo-apply-impact` | Calls `progress.sh activate`; generates `requirements.md`, `config.md`, `diagrams/`, pre-fills `## GIT BRANCH`. | 2 | Quest-driven blueprint via `docs/blueprint-regeneration.md`. |

| Overseer | `blueprints/current/config.md` `## GIT BRANCH` | Edits / confirms feature branch. Refused: `main`, `master`. | 2 | Pre-filled from HEAD if non-trunk; otherwise blank. |

| Overseer | `blueprints/current/` (review) | Visually reviews requirements / config / diagrams. May hand-edit `## Overseer Additions`. | 2 | Pre-implementation gate. |

| Overseer | `/mo-continue` (after blueprint review) | Approve Handler validates blueprint files and auto-fires `/mo-plan-implementation`. | 2 → 3 | One per feature. |

| Millwright (auto) | `/mo-plan-implementation` | Pure launcher: PENDING→IMPLEMENTING, captures base-commit, sets sub-flow, writes `primer.md`, asks for `planning-mode`. | 3 | Hands off to brainstorming chain or direct mode. |

| Overseer | Chat reply (`brainstorming` / `direct`) | Picks `planning-mode`; persisted to `progress.md`. | 3 | `brainstorming` → isolated chain session. `direct` → main-session implementation. |

| Overseer | brainstorming chain (when in `brainstorming` mode) | Drives the brainstorming → writing-plans → executing-plans / subagent-driven-development → finishing-a-development-branch chain. | 3 | Isolated from mo-workflow; overseer interacts as in any normal Claude Code session. |

| Millwright (direct mode) | Codebase, `primer.md` | Implements directly, committing on the active branch. | 3 | Layered-load: primer first, escalate as needed. |

| Overseer | `/mo-continue` (post-implementation) | Resume Handler: verifies commits, advances 3→4, optional `/mo-update-blueprint` drift check, auto-fires `/mo-draw-diagrams`, creates `overseer-review.md` skeleton. | 3 → 4 → 5 | Single resumption signal. |

| Millwright (auto) | `/mo-draw-diagrams` (= `mo-generate-implementation-diagrams`) | Renders use-case + sequence + (optional) class diagrams of `base-commit..HEAD` with shaded "existing system" framing. | 4 | Auto-fired here; manually invokable. |

| Overseer | `implementation/overseer-review.md` | Authors findings as plain sentences or `### IR-NNN` blocks. Empty file = approval. | 5 | Skeleton already created. |

| Overseer | `/mo-continue` (after review) | Overseer Handler: canonicalizes free-form findings (`review.sh canonicalize` + millwright classifies + `review.sh add` + `strip-freeform`); if no open findings, auto-finalize via `mo-complete-workflow`; else auto-fire `/mo-review`. | 5 → (7 \| 6) | Auto-finalizes only when truly empty. |

| Millwright (auto) | `/mo-review` | Pure launcher: writes `review-context.md`, asks for `review-mode`, dispatches to brainstorming review session or direct review loop. | 6 | Sets sub-flow=reviewing, advances 5→6. |

| Overseer | Chat reply (`brainstorming` / `direct`) | Picks `review-mode`. | 6 | Persisted to `progress.md`. |

| Overseer | brainstorming review session OR direct review loop | Addresses findings; chain or millwright marks each `fixed`. Overseer types `approve` to end. | 6 | No iteration cap. |

| Overseer | `/mo-continue` (after review session) | Review-Resume Handler: sanity-check no open findings, advance 6→7, optional diagram refresh y/n, auto-fire `/mo-complete-workflow`. | 6 → 7 → 8 | Only when there were findings. |

| Millwright (auto) | `/mo-complete-workflow` | Updates IMPLEMENTING → IMPLEMENTED, populates `commits:` in `requirements.md`, rotates `blueprints/current/` into `history/v[N+1]/`, clears `implementation/`, calls `progress.sh finish`. Auto-invokes next feature's `/mo-apply-impact` if queue non-empty; else asks for more TODO marks or recommends `/mo-run`. | 8 | Atomic close-out. |

| Overseer | `/mo-abort-workflow [--drop-feature=...]` | Safe cancel: IMPLEMENTING → PENDING revert, clear `implementation/`, reset `active` block, preserve `blueprints/current/`. Never touches git. | recovery | Optional `--drop-feature=completed|requeue`. |

| Overseer | `/mo-resume-workflow` | Diagnostic dispatcher: reads state, prints recommended next command. No mutations. | recovery | Auto-suggestion target for unknown states inside `/mo-continue`. |

| Overseer | `/mo-update-blueprint <reason>` | Manual implementation-driven blueprint refresh: rotate, regenerate from `change-summary.md` + diff hunks + previous history, preserve `## GIT BRANCH` and `## Overseer Additions`, sync `requirements-id` refs. | mid-cycle (3+) | Stage-4 drift check auto-invokes this if overseer supplies a reason. |

| Overseer | `/mo-update-todo-list <subcmd> <args>` | Manual todo edits — `add` (TODO/IMPLEMENTING/CANCELED only), `cancel`, `set-state`. Refuses PENDING / IMPLEMENTED writes. | any | Reminds overseer to follow up with `/mo-update-blueprint` if scope shifts. |

| **PostToolUse hook** | `hooks/validate-on-write.sh` | Auto-validates YAML frontmatter against schemas on every Write/Edit to a workflow `.md` file. Blocks the turn on failure. | always | No-op outside the data root. |

| **MCP server** | `plantuml-mcp-server` | Renders `.puml` sources to images for use-case / sequence / class diagrams. | 2, 4 | Configured automatically via `plugin.json`. |

| Optional companion | `rtk` | Pre-tool-use hook that filters verbose shell output (git diffs, test runs, logs) before Claude sees them. | always (when installed) | Detected by `/mo-doctor`; never required. |

| Optional companion | `docling` | Document → markdown converter. Powers `/mo-ingest`. | optional (stage 0.5) | Only needed for DOCX/PPTX/XLSX/HTML or PDFs >20 pages. |

  

---

  

## 5. The Stages (canonical 0 → 8)

  

Each stage has a precise entry condition, work list, and exit condition. `progress.md`'s `active.current-stage` is advanced at the *end* of each stage by `progress.sh advance`.

  

| Stage | Name | Driver | Entry | Exit |

| ---: | --- | --- | --- | --- |

| 0 | Journal populated | Overseer | `journal/` empty or stale. | Overseer signals intake done by typing `/mo-run`. |

| 1 | Quest generated | Millwright via `/mo-run` | Overseer ran `/mo-run <folder...>`. | `quest/todo-list.md`, `quest/summary.md`, and `progress.md` exist. |

| 1.5 | Selection + ordering | Overseer + Millwright via `/mo-continue` Pre-flight Handler | Overseer marks `[x]` in `todo-list.md`. | `queue-rationale.md` written; queue reordered; `/mo-apply-impact` auto-fires. |

| 2 | Blueprints generated | Millwright via `/mo-apply-impact` | Pre-flight handler auto-fired. | `blueprints/current/requirements.md`, `config.md`, `diagrams/` exist. |

| 3 | Implementation launched | Millwright via `/mo-plan-implementation` (auto) → chain or direct | Overseer typed `/mo-continue` (Approve Handler). | `base-commit` recorded, `planning-mode` set, sub-flow set; chain or direct implementation runs. |

| 4 | Implementation resumed | Millwright via `/mo-continue` Resume Handler | Overseer typed `/mo-continue` after chain/direct returned. | `implementation-completed=true`, diagrams rendered, `overseer-review.md` skeleton created. |

| 5 | Presented for overseer review | Overseer | Stage-4 handoff message printed. | Overseer types `/mo-continue`; `overseer-review.md` exists (empty or populated). |

| 6 | Overseer review session | Overseer + chain/millwright via `/mo-review` | Stage-5 `/mo-continue` found open findings. | Review session exits (overseer types `approve`); overseer types `/mo-continue` again. |

| 7 | Review completed (transitional) | Millwright | Either no-findings path (5 → 7 directly) or with-findings path (6 → 7). | Optional diagram-refresh; `mo-complete-workflow` auto-fires. |

| 8 | Completion | Millwright via `/mo-complete-workflow` | Stage 7 reached. | Blueprint rotated, `implementation/` cleared, IMPLEMENTING → IMPLEMENTED, `progress.sh finish` called. Loop back to next queue feature or wait for more TODO marks. |

  

### 5.1 Detailed flow per stage

  

**Stage 0 — Journal populated.**

The overseer drops `.md` / `.txt` (and optionally non-text via `/mo-ingest`) into topic sub-folders under `journal/`. Frontmatter for `.md` files: `contributors:` + `date:`. No frontmatter for `.txt`. No automation here — pure intake.

  

**Stage 1 — `/mo-run`.**

The millwright reads the named sub-folders, summarizes their content into `quest/summary.md` (feature-indexed), generates `quest/todo-list.md` (kebab-case feature headings + per-item IDs and assignee placeholders), and scaffolds `quest/progress.md` with the queue populated and `active: null`. Per-file ingest decisions are made interactively for any non-text file detected. Sub-agent delegation is allowed for per-file summarization when files exceed thresholds.

  

**Stage 1.5 — Selection + Ordering (Pre-flight Handler in `/mo-continue`).**

- Sub-state A (`[x] TODO` lines exist): runs `todo.sh pend-selected`, groups PENDING items by feature, runs `progress.sh enqueue` if mid-cycle, analyzes cross-feature dependencies for ≥ 2 features, proposes a prioritized order in chat.

- Sub-state B (promotion done, `queue-rationale.md` missing): writes `queue-rationale.md`, runs `progress.sh reorder`, auto-fires `/mo-apply-impact`.

  

**Stage 2 — Blueprint generation (`mo-apply-impact`).**

Calls `progress.sh activate` (pops `queue[0]` into `active`). Then follows `docs/blueprint-regeneration.md` (the *quest-driven runbook*):

- Step A: read `quest/summary.md` (active feature section + cross-cutting + out-of-scope) and write `requirements.md` with `## Goals (this cycle)`, `## Planned (future cycles)`, `## Non-goals (out of scope)`. Distinction matters: Planned items WILL ship later — current implementation must leave architectural seams. Non-goals are truly out of scope and can be assumed away.

- Step B: scan `.claude/skills/` and `.claude/rules/`, write `config.md`'s auto-block (≤ 10 entries / ≤ 2 lines each, three sections: `## Skills`, `## Rules`, `## Load on demand`), pre-fill `## GIT BRANCH` from HEAD if non-trunk, preserve `## Overseer Additions` verbatim.

- Step C: render diagrams via PlantUML MCP — mandatory `use-case-<feature>.puml`, conditional `sequence-<flow>.puml` × N, conditional `class-<domain>.puml`. Plus `diagrams/README.md` with `requirements-id` back-reference.

  

**Stage 3 — Implementation launch (`mo-plan-implementation`).**

Pure launcher with no driver logic:

1. `todo.sh bulk-transition PENDING IMPLEMENTING --feature <active>` (selected items → IMPLEMENTING).

2. `git rev-parse HEAD` → `progress.md.active.base-commit`.

3. Validate `## GIT BRANCH` from `config.md` (refuse main/master, refuse multi-line, refuse mismatch with HEAD).

4. Compose `primer.md` (compact stage-3 launch primer: active scope, goals excerpt, journal context, likely-relevant skills/rules). Layered-load entry point.

5. Ask overseer for `planning-mode` (`brainstorming` | `direct`).

6. **Brainstorming mode**: invoke the `brainstorming` skill with `primer.md` as the required first read; canonical files (`requirements.md`, `config.md`, `summary.md` active section, `todo-list.md`) are fallbacks. The skill chains brainstorming → writing-plans → executing-plans / subagent-driven-development → finishing-a-development-branch in an isolated session. Mo-workflow does NOT interfere.

**Direct mode**: millwright reads `primer.md` itself, escalates to canonicals on demand, implements in the main session, commits as it goes.

  

**Stage 4 — Implementation resumed (Resume Handler in `/mo-continue`).**

1. Set `sub-flow=resuming`.

2. Verify `git rev-list --count base-commit..HEAD > 0`. Abort if no commits.

3. Set `implementation-completed=true`; advance 3 → 4.

4. Optional drift check: prompt overseer for blueprint-drift reason. If supplied, invoke `/mo-update-blueprint <reason>` (which rotates blueprint and regenerates from implementation reality).

5. Auto-fire `/mo-draw-diagrams` (= `mo-generate-implementation-diagrams`). Renders use-case + sequence + (optional) class diagrams of `base-commit..HEAD` with `box "Existing system" #EEEEEE` framing for pre-existing elements, `#888888` arrows, `#EEEEEE` activations, and a `legend right` block documenting the convention.

6. Initialize `overseer-review.md` skeleton via `review.sh init`.

7. Advance 4 → 5; print stage-5 handoff message.

  

**Stage 5 — Presented for overseer review (Overseer Handler in `/mo-continue`).**

1. Verify `overseer-review.md` exists (offer to recreate if missing).

2. **Canonicalize free-form findings**: `review.sh canonicalize` returns TSV rows `<line-start>\t<line-end>\t<text>`. For each row, the millwright classifies severity (blocker/major/minor) and scope (fix/re-implement/re-plan/re-spec) heuristically based on the wording, calls `review.sh add` with the original text as `details:`, and then `review.sh strip-freeform` in reverse line order. Without this step a free-form finding would slip past `list-open` and the workflow would silently auto-finalize.

3. `review.sh list-open <feature>`:

- If empty: set `overseer-review-completed=true`, advance 5 → 6 → 7, auto-fire `/mo-complete-workflow`.

- If non-empty: auto-fire `/mo-review`. Stop after that — the second `/mo-continue` does NOT auto-fire `/mo-complete-workflow`.

  

**Stage 6 — Overseer review session (`mo-review`).**

Pure launcher:

1. Compose `review-context.md` (compact stage-6 review primer: active scope, goals, implemented surface, open-findings cheat sheet).

2. Set `sub-flow=reviewing`; advance 5 → 6.

3. Ask overseer for `review-mode` (`brainstorming` | `direct`).

4. **Brainstorming mode**: invoke the `brainstorming` skill with `review-context.md` + `overseer-review.md` as required first reads. The session loops internally: read findings → cascade-dispatch by scope (re-spec > re-plan > re-implement > fix) → mark each `fixed` via `review.sh set-status` → ask for approval. Overseer ends with `approve`.

**Direct mode**: millwright addresses each finding in the main session, commits per fix, marks each `fixed`, loops on `go again`.

5. Stop. Wait for overseer's `/mo-continue`.

  

**Stage 7 — Review completed (Review-Resume Handler).**

1. Verify no open findings remain (sanity check).

2. Set `sub-flow=none`, `overseer-review-completed=true`; advance 6 → 7.

3. Optional diagram refresh: if review-loop commits exist, prompt y/n to re-run `/mo-draw-diagrams` before stage 8 deletes diagrams.

4. Auto-fire `/mo-complete-workflow`.

  

**Stage 8 — Completion (`mo-complete-workflow`).**

1. `todo.sh bulk-transition IMPLEMENTING IMPLEMENTED --feature <active>`. CANCELED items are left alone.

2. `commits.sh populate-requirements <feature>` writes `commits:` field in `requirements.md` frontmatter (the canonical link between requirements and implementation).

3. `blueprints.sh rotate <feature> --reason-kind completion --reason-summary "..."` moves `current/*` into `history/v[N+1]/` and writes `reason.md`.

4. Delete `implementation/overseer-review.md`, `review-context.md`, `change-summary.md`, `diagrams/`.

5. `progress.sh finish` (active.feature → completed; active = null).

6. If `queue` non-empty: announce next feature and auto-invoke `/mo-apply-impact` (loop back to stage 2).

If `queue` empty AND `[ ] TODO` items remain: ask overseer to mark next batch and type `/mo-continue` (re-enters stage 1.5 via `progress.sh enqueue`).

If `queue` empty AND no `[ ] TODO`: cycle complete; recommend `/mo-run` for a new cycle.

  

---

  

## 6. The Workflow Commands (full reference)

  

All commands live under `commands/` as Markdown files with YAML frontmatter (`description:` and optional `argument-hint:`). The slash-command name matches the file name.

  

### 6.1 Setup / dependency commands

  

#### `/mo-init`

- **Invocation**: overseer, once per workspace.

- **Behavior**: runs `doctor.sh --format=json`; collects all required-and-missing checks into Bash-runnable (cli/pymod) and plugin-kind (slash-command-only) buckets; prints a one-line status; offers a single y/n to install all Bash-runnable deps in batch; prints slash-command instructions for plugin-kind deps; scaffolds `journal/`, `quest/`, `workflow-stream/` under the data root if absent; prints the canonical handoff text describing what to do next.

- **Idempotent**: yes.

  

#### `/mo-doctor`

- **Invocation**: overseer (manual) or auto-invoked by `/mo-run` preflight.

- **Behavior**: detailed dependency check. Per-dep prompts and sudo handling. Returns JSON or human-readable summary.

  

#### `/mo-ingest`

- **Invocation**: overseer.

- **Modes**: `<folder>`, `--file <path>`, `--stub <path>`, `--dry-run`, `--force`.

- **Behavior**: dispatches by extension. Documents (`.pdf`, `.docx`, `.pptx`, `.xlsx`, `.html`) → docling with `--image-export-mode referenced` (figures land in `<stem>.images/` next to the produced `.md`). Standalone images → stub `.md` referencing the original (Claude is a VLM; docling's image pipeline is net-negative for standalones). Short PDFs (≤ 20 pages) default to a stub.

  

### 6.2 Cycle-level commands

  

#### `/mo-run <folder1> [<folder2> ...]`

- **Invocation**: overseer; once per cycle.

- **Behavior**: Step 0 preflight via `doctor.sh --preflight`; Step 1 parse arguments; Step 2 detect non-text files and run per-file ingest decision flow; Step 3+ generate `quest/todo-list.md` (per-feature checklist with `<feature>-NNN` IDs), `quest/summary.md` (feature-indexed digest), and `quest/progress.md` with queue populated. Optionally writes `queue-rationale.md` if dependencies were analyzed at this stage (or defers to stage 1.5).

- **Post-conditions**: quest files + `progress.md` populated. `active=null`. Branch deferred to stage 2.

  

### 6.3 Per-feature workflow commands

  

#### `/mo-apply-impact` (auto-fired)

- **Invocation**: auto-fired by `/mo-continue` Pre-flight Step 2B and by `/mo-complete-workflow` (when queue still has features).

- **Behavior**: `progress.sh activate`, then runs `docs/blueprint-regeneration.md` (Step A requirements, Step B config + branch pre-fill, Step C diagrams).

- **Post-conditions**: `blueprints/current/{requirements.md, config.md, diagrams/}`; `active.current-stage=2`.

  

#### `/mo-plan-implementation` (auto-fired)

- **Invocation**: auto-fired by `/mo-continue` Approve Handler.

- **Behavior**: PENDING→IMPLEMENTING via `todo.sh bulk-transition`; `git rev-parse HEAD` captured into `active.base-commit`; validates `## GIT BRANCH` (refuses main/master, refuses multi-line, refuses mismatch with HEAD); writes `primer.md` (compact stage-3 launch primer); asks overseer for `planning-mode` (`brainstorming` | `direct`); persists choice; brainstorming mode invokes the `brainstorming` skill, direct mode reads primer in main session.

- **Post-conditions**: `active.current-stage=3`, `active.planning-mode` recorded, `active.sub-flow=chain-in-progress` (brainstorming) or `none` (direct).

  

#### `/mo-draw-diagrams [--target=implementation]` (auto-fired or manual)

- **Invocation**: auto-fired by Resume Handler (Step 5) and (optionally) by Review-Resume Handler (Step 2.5). Manually invokable.

- **Behavior**: thin wrapper dispatching on `--target`. Default target `implementation` runs the body of `mo-generate-implementation-diagrams`.

  

#### `/mo-generate-implementation-diagrams` (internal)

- **Behavior**: ensures `implementation/change-summary.md` is current via `commits.sh change-summary-fresh` (cache-keyed by `(base-commit, head)`; exit 0 = fresh, 1 = stale, 2 = missing). Reads commit range `active.base-commit..HEAD`. Renders use-case + sequence + (if relevant) class diagrams via PlantUML MCP into `implementation/diagrams/` with the existing-vs-new framing (shaded `box "Existing system" #EEEEEE` for pre-existing participants, `#888888` arrows, `#EEEEEE` activations, `legend right` block). Codebase reads are bounded (diff hunks first; ≤ 3 callers/callees per changed file; skip generated/vendor/lock; record skipped paths under `## Omitted from analysis` in `change-summary.md`).

  

#### `/mo-review` (auto-fired)

- **Invocation**: auto-fired by `/mo-continue` Overseer Step 3b. Manually invokable.

- **Behavior**: pure launcher. Composes `review-context.md` (compact stage-6 review primer); sets `sub-flow=reviewing`; advances 5 → 6; asks overseer for `review-mode`. Brainstorming mode invokes the `brainstorming` skill with `review-context.md` + `overseer-review.md` as required first reads. Direct mode keeps the loop in the main session. Mo-review does NOT advance past 6 and does NOT auto-fire `mo-complete-workflow` — that's the Review-Resume Handler's job.

  

#### `/mo-complete-workflow` (auto-fired)

- **Invocation**: auto-fired on stage-7 clean exit. Manually invokable for recovery.

- **Behavior**: IMPLEMENTING → IMPLEMENTED via `todo.sh bulk-transition`; populates `commits:` field in `requirements.md` via `commits.sh populate-requirements`; rotates `blueprints/current/` into `history/v[N+1]/` via `blueprints.sh rotate --reason-kind completion`; clears `implementation/`; `progress.sh finish`. Loops to next feature (auto-fires `/mo-apply-impact`) if queue non-empty; else asks for more TODO marks or recommends `/mo-run`.

  

### 6.4 The universal advancement signal

  

#### `/mo-continue` (overseer)

The single touchpoint at every overseer gate. Reads `progress.md` and dispatches to the right handler.

  

| `active` | `current-stage` | `sub-flow` | Pre-conditions in files | Handler |

| --- | --- | --- | --- | --- |

| null | n/a | n/a | `[x] TODO` lines exist in `todo-list.md` | **Pre-flight Step 2A** — `pend-selected`, group, propose order |

| null | n/a | n/a | `[x] TODO` already promoted, queue non-empty, `queue-rationale.md` missing | **Pre-flight Step 2B** — write rationale, reorder, auto-fire `/mo-apply-impact` |

| set | 2 | any | blueprint files exist | **Approve Handler** — sanity-check, auto-fire `/mo-plan-implementation` |

| set | 3 | any | commits exist in `base-commit..HEAD` | **Resume Handler** — verify commits, advance 3→4, optional drift check + `/mo-update-blueprint`, auto-fire `/mo-draw-diagrams`, init review skeleton, advance 4→5 |

| set | 5 | any | overseer-review.md exists | **Overseer Handler** — canonicalize free-form, list-open; if empty auto-finalize via `/mo-complete-workflow`, else auto-fire `/mo-review` |

| set | 6 | reviewing | review session has exited | **Review-Resume Handler** — sanity-check no open findings, advance 6→7, optional diagram refresh, auto-fire `/mo-complete-workflow` |

| any other | — | — | — | Delegate to `/mo-resume-workflow` for diagnosis |

  

### 6.5 Recovery / utility commands

  

#### `/mo-abort-workflow [--drop-feature=completed|requeue]`

- Reverts IMPLEMENTING → PENDING in `todo-list.md`. Deletes `implementation/*`. `progress.sh reset` (keeps feature + branch, clears base-commit + execution-mode + completion flags, sub-flow=none, current-stage=2). Preserves `blueprints/current/`. Never touches git.

- `--drop-feature=completed` → archives to `completed`. `--drop-feature=requeue` → appends to end of queue.

  

#### `/mo-resume-workflow`

- Diagnostic. Reads `progress.md`, validates invariants, prints next-recommended-command. Does not mutate state.

  

#### `/mo-update-blueprint <reason>`

- Manual implementation-driven blueprint refresh (mid-cycle, stage 3+). Rotates `current/` into history; regenerates `requirements.md` Goals + diagrams from `change-summary.md` + diff hunks; copies Planned / Non-goals / `todo-item-ids` / `todo-list-id` verbatim from previous history version; preserves `## GIT BRANCH` and `## Overseer Additions` via `blueprints.sh preserve-overseer-sections`; calls `review.sh sync-refs` to re-point in-flight `requirements-id` references.

- **Deliberately NOT inputs**: `quest/todo-list.md`, `quest/summary.md`, `journal/`. Mid-cycle refreshes are reverse-engineered from the implementation; intake artifacts don't drift after stage 1.5.

  

#### `/mo-update-todo-list <subcmd> <args>`

- `add <feature> <state> <assignee> <item-id> <description>` — append item. State ∈ {TODO, IMPLEMENTING, CANCELED} only.

- `cancel <item-id>` — flip to CANCELED.

- `set-state <item-id> <state>` — flip to state. Refuses PENDING and IMPLEMENTED.

  

---

  

## 7. Technical underpinnings

  

### 7.1 Plugin descriptor (`plugin.json`)

  

```json

{

"name": "millwright-overseer-development-machine",

"version": "0.1.0",

"commands": "./commands/",

"mcpServers": {

"plantuml": { "command": "plantuml-mcp-server", "args": [] }

},

"userConfig": {

"data_root": {

"type": "string", "default": "millwright-overseer", "sensitive": false

}

}

}

```

  

Notable design choice: **`superpowers` is NOT declared as a plugin dependency.** Claude Code's `dependencies:` field is a hard load-time gate; declaring superpowers there would prevent `mo-init` from loading in the first place — which is precisely the command that guides the overseer through the install. Instead, `mo-init` / `mo-doctor` detect missing skills and print the slash commands for the overseer to run.

  

### 7.2 Hook (`hooks/hooks.json` + `hooks/validate-on-write.sh`)

  

A single `PostToolUse` hook matched on `Write|Edit`. Reads the tool-call JSON on stdin, extracts `tool_input.file_path`, and — if the file lives under the data root and matches a known schema — runs `scripts/internal/validate-frontmatter.sh <file> <schema>`. On failure, emits a JSON `{"decision": "block", "reason": "..."}` response to halt the turn until the overseer fixes the frontmatter. The hook is a no-op outside the data root and for unknown filenames, so general project edits proceed normally.

  

Coverage policy:

- **Validated**: `quest/{progress, todo-list, summary, queue-rationale}.md`, `blueprints/current/{requirements, config, primer}.md`, `implementation/{overseer-review, review-context, change-summary}.md`, `blueprints/history/v*/reason.md`.

- **Skipped (audit archive)**: other files under `blueprints/history/v*/` — they were already validated when in `current/` and are immutable post-rotation.

  

### 7.3 Schemas (`schemas/`)

  

JSON-Schema-as-YAML files validated by `ajv-cli` (preferred) or a `yq`-based structural fallback. One schema per artifact type:

  

```

config.schema.yaml

primer.schema.yaml

progress.schema.yaml

queue-rationale.schema.yaml

reason.schema.yaml

requirements.schema.yaml

review-context.schema.yaml

review-file.schema.yaml

change-summary.schema.yaml

summary.schema.yaml

todo-list.schema.yaml

```

  

### 7.4 Templates (`templates/`)

  

Mustache-style templates rendered by `frontmatter.sh init`. The script auto-injects a fresh UUID via `uuid.sh` if `UUID=` isn't passed, then substitutes the remaining `{{KEY}}` placeholders. Templates exist for every workflow artifact:

  

```

change-summary.md.tmpl

config.md.tmpl

overseer-review.md.tmpl

primer.md.tmpl

progress.md.tmpl

queue-rationale.md.tmpl

reason.md.tmpl

requirements.md.tmpl

review-context.md.tmpl

summary.md.tmpl

todo-list.md.tmpl

```

  

### 7.5 Scripts (`scripts/`)

  

| Script | Role |

| --- | --- |

| `uuid.sh` | Generate a single UUID v4. Prefers `uuidgen`; falls back to Python's `uuid` module. The only authority for ID minting. |

| `frontmatter.sh` | Read / write / init / validate YAML frontmatter. Subcommands: `init`, `get`, `set`, `validate`. |

| `progress.sh` | Manage `quest/progress.md` (the central state file). Subcommands: `init`, `activate`, `finish`, `requeue`, `reset`, `reorder`, `enqueue`, `get-active`, `queue-remaining`, `get`, `set`, `advance`. Uses Python heredocs for safe YAML mutation. |

| `todo.sh` | Manage `quest/todo-list.md`. Subcommands: `set-state`, `bulk-transition` (with optional `--feature`), `pend-selected`, `list <state>` (with optional `--feature`). Enforces state-machine paths and assignee invariants. |

| `blueprints.sh` | Manage `workflow-stream/<feature>/blueprints/`. Subcommands: `ensure-current`, `rotate --reason-kind --reason-summary`, `preserve-overseer-sections`. Rotation kinds: `completion`, `spec-update`, `re-spec-cascade`, `re-plan-cascade`, `manual`. |

| `review.sh` | Manage `overseer-review.md`. Subcommands: `init`, `add`, `set-status`, `iterate`, `list-open`, `sync-refs`, `canonicalize` (returns TSV of free-form spans), `strip-freeform`. IDs are `IR-NNN`, monotonically incremented. |

| `commits.sh` | Query and format `base-commit..HEAD`. Subcommands: `list`, `yaml`, `populate-requirements`, `changed-files`, `change-summary-fresh` (cache-keyed by `(base-commit, head)` — exit 0 fresh / 1 stale / 2 missing). |

| `ingest.sh` | Convert non-text journal files to sibling `.md`. Routes by extension (docling for documents, stub for images / short PDFs). |

| `doctor.sh` | Dependency detection and reporting. Outputs JSON or human-readable. `--preflight` mode for fast checks. |

| `internal/common.sh` | Shared helpers: `mo_die`, `mo_info`, `mo_progress_file`, `mo_fm_get`, `mo_render_template`. |

| `internal/validate-frontmatter.sh` | Run by the PostToolUse hook. Loads schema, validates `.md` frontmatter, exits non-zero on failure. |

  

### 7.6 The PlantUML MCP integration

  

`plugin.json` registers `plantuml-mcp-server` as an MCP server. The millwright invokes the server's tools directly to render `.puml` sources to images during stage 2 (`mo-apply-impact`) and stage 4 (`mo-generate-implementation-diagrams`). The overseer must install the binary themselves (e.g. `npm install -g plantuml-mcp-server`); the plugin configures it but does not bundle it.

  

Diagram conventions (enforced by the millwright, not by tooling):

- File naming: `<type>-<subject>.puml` where `<type> ∈ {use-case, sequence, class}`. One diagram per file. Lowercase kebab-case.

- Mandatory: exactly one `use-case-<feature>.puml` per feature.

- Conditional: 1–5 `sequence-<flow>.puml` per significant end-to-end flow. >5 is a signal to decompose the feature; the millwright surfaces this to the overseer.

- Conditional: one `class-<domain>.puml` only if 3+ new domain classes with non-trivial relationships are introduced.

- Implementation diagrams use the **existing-vs-new framing**: `box "Existing system" #EEEEEE { … } end box` for pre-existing participants/classes, `#888888` arrows, `#EEEEEE` activations, fresh skin for new elements, plus a `legend right … endlegend` block documenting the convention.

- A sibling `diagrams/README.md` carries the `requirements-id` back-reference (since `.puml` files have no YAML frontmatter).

  

### 7.7 Optional companions

  

Detected by `/mo-doctor` but never required:

  

- **`rtk`** (rtk-ai/rtk) — pre-tool-use hook that filters verbose shell output (git diffs, test runs, logs). Targets exactly the kinds of commands the brainstorming review session and `/mo-generate-implementation-diagrams` run. Install: `brew install rtk && rtk init -g`. No plugin-level integration; once installed, applies session-wide.

- **`docling`** — IBM's document → markdown converter. Powers `/mo-ingest`. Required for DOCX/PPTX/XLSX/HTML, recommended for PDFs >20 pages, optional for short PDFs, deliberately skipped for standalone images. Pulls ~1–2 GB of ML deps (torch, transformers, OCR engine); first conversion downloads ~200–400 MB of model weights to `~/.cache/huggingface/`.

  

### 7.8 Skill references

  

The brainstorming chain at stage 3 and the brainstorming review session at stage 6 depend on five named skills:

  

- `brainstorming`

- `writing-plans`

- `executing-plans`

- `subagent-driven-development`

- `finishing-a-development-branch`

  

These can come from either:

1. The **superpowers plugin** (resolves names like `superpowers:brainstorming`).

2. Local `SKILL.md` files under `.claude/skills/<name>/`.

  

`mo-doctor` accepts both sources interchangeably and prints the exact `/plugin marketplace add` + `/plugin install` slash commands when missing.

  

### 7.9 Branch contract

  

The git branch is owned by the overseer end-to-end. Mo-workflow never creates, deletes, or force-updates branches.

  

- **Creation**: overseer's responsibility, before `mo-run`, between stages 1–2, or just before approving blueprints.

- **Declaration**: in `blueprints/current/config.md`'s `## GIT BRANCH` section. Pre-filled at stage 2 if HEAD is non-trunk.

- **Validation at stage 3**: exactly one branch line; branch ≠ main/master; branch == current HEAD. Empty section → millwright prompts the overseer (chat or edit-and-retry; either is valid).

- **Persistence**: `progress.md.active.branch` is null until stage 3, then set; `active.base-commit` captured from HEAD at the same time.

- **One branch per feature**: features may share or differ; the plugin doesn't enforce sameness across the queue.

  

### 7.10 The blueprint lifecycle

  

`blueprints/current/` is a *living* snapshot. Refresh triggers:

  

| Trigger | reason.md kind | Source of regeneration |

| --- | --- | --- |

| Stage 8 (`mo-complete-workflow`) | `completion` | n/a — `current/` becomes empty |

| `/mo-continue` post-chain (stage 4) drift check (overseer-supplied reason) | `manual` (via `/mo-update-blueprint`) | implementation-driven |

| Review-loop `re-spec` cascade | `re-spec-cascade` | implementation-driven (chain just regenerated spec) |

| Review-loop `re-plan` cascade (overseer confirms) | `re-plan-cascade` | implementation-driven |

| `/mo-update-blueprint <reason>` (manual) | `manual` | implementation-driven |

  

Implementation-driven means: read from `implementation/change-summary.md` + targeted `git diff base-commit..HEAD` hunks + previous history version. Quest data and journal are *not* consulted post-stage-1.5.

  

### 7.11 The review file schema

  

`overseer-review.md` is the single review artifact. Findings are `### IR-NNN` blocks with monotonically incrementing IDs (never reused). Per finding:

  

- **severity**: `blocker` | `major` | `minor`

- **scope**: `fix` | `re-implement` | `re-plan` | `re-spec`

- **status**: `open` | `fixed` | `wontfix`

- **details**: multi-line markdown body

- **fix-note**: populated on `fixed` / `wontfix`

  

Scope cascade priority (descending impact, tier-0 wins):

1. **re-spec** — re-invokes `brainstorming`; cascades through writing-plans + executing-plans. Invalidates current implementation.

2. **re-plan** — re-invokes `writing-plans`; cascades through executing-plans.

3. **re-implement** — re-invokes `executing-plans` / `subagent-driven-development` against the existing plan.

4. **fix** — direct patch.

  

When a higher-tier scope fires, all open lower-scope findings get `fixed` with `fix-note: "superseded by re-spec at iteration N"` because the code that drew them no longer exists.

  

Iterations are nested under `## Iteration N` headers. IDs stay stable across iterations — a fix landing in iteration 2 is still IR-005, just with `status: fixed`.

  

### 7.12 Layered context loading (Rule 3 in detail)

  

| Stage | Required first read | Canonical fallbacks (on demand) |

| --- | --- | --- |

| 3 (planning) | `blueprints/current/primer.md` | `requirements.md`, `config.md`, `summary.md` (active feature section), `todo-list.md` |

| 6 (review) | `implementation/review-context.md` + `implementation/overseer-review.md` | `requirements.md`, `config.md`, `summary.md` (active feature section), `blueprints/current/primer.md` |

  

Properties:

- Primers are **derived, not canonical**. Canonical files win on conflict.

- Primers are **overwritten on regeneration** by their writer.

- Primers are **rotated with their parent folder** (`primer.md` rotates with `blueprints/current/`; `review-context.md` is cleaned at stage 8 / abort).

- `review.sh sync-refs` keeps `requirements-id` references live across rotations.

- `change-summary.md` is **cache-keyed** by `(base-commit, head)` and shared across `mo-generate-implementation-diagrams` and `/mo-update-blueprint`.

- `summary.md` is **feature-indexed**, so a stage reads only its active feature's section + cross-cutting constraints.

  

### 7.13 Sub-agent delegation (optional, bounded)

  

The millwright may delegate to sub-agents (via `Task` / `Agent` tools) only when delegation actually reduces total context use. Approved delegation points:

  

- Stage 1 — per-file journal summarization for files exceeding size thresholds.

- Stage 1.5 — codebase dependency inspection for ≥ 3 features.

- Stage 2 — skill/rule relevance filtering when `.claude/skills/` + `.claude/rules/` together exceed ~30 entries.

- Stage 4 — `change-summary.md` writing for diffs touching many areas.

- Stage 6 — finding-cluster grouping for >5 open findings (one sub-agent per cluster, disjoint write scopes).

  

Sub-agents return a **≤ 20-line routing slip**:

  

```

## Scope

<one short paragraph: what was inspected>

  

## Findings

- <short, source-linked bullet>

  

## Decisions / Assumptions

- <assumption with confidence>

  

## Artifacts Written

- <path>

  

## Main-Agent Action Needed

- <one concrete next step, or "none">

```

  

Detailed evidence belongs in artifact files, not the chat reply.

  

**Do NOT delegate**: workflow state mutations (`progress.sh`, `todo.sh`, `blueprints.sh`, `review.sh set-status`), stage transitions, command dispatch, final approvals, anything that fits in the millwright's working context.

  

---

  

## 8. End-to-end happy-path walkthrough

  

A single feature, brainstorming planning, brainstorming review, with one finding.

  

```

[Overseer] Drops journal/auth-meeting/{transcript.txt, notes.md}

[Overseer] Types: /mo-init # one-time setup

[Millwright] Installs deps via single y/n; scaffolds folders.

[Overseer] Types: /mo-run auth-meeting

[Millwright] Runs doctor preflight; generates quest/todo-list.md, summary.md, progress.md.

[Overseer] Edits todo-list.md: marks AUTH-001 and AUTH-002 with [x] (emin).

[Overseer] Types: /mo-continue # 1.5 step A

[Millwright] todo.sh pend-selected; groups by feature; proposes order: [auth].

[Overseer] Types: /mo-continue # 1.5 step B (accept)

[Millwright] Writes queue-rationale.md; progress.sh reorder; auto-fires /mo-apply-impact.

[Millwright] progress.sh activate (auth → active block).

Generates blueprints/current/{requirements.md, config.md, diagrams/}.

Pre-fills config.md ## GIT BRANCH from HEAD (feat/auth/jwt).

[Overseer] Reviews requirements + diagrams. Adds custom prompt under ## Overseer Additions.

[Overseer] Types: /mo-continue # stage 2 approve

[Millwright] Approve Handler validates files; auto-fires /mo-plan-implementation.

[Millwright] PENDING → IMPLEMENTING; captures base-commit; writes primer.md;

asks: "planning-mode? brainstorming or direct?"

[Overseer] Types: brainstorming

[Millwright] Persists planning-mode; sets sub-flow=chain-in-progress;

invokes brainstorming skill (isolated session).

[Overseer + chain] brainstorming → writing-plans → executing-plans →

subagent-driven-development → finishing-a-development-branch.

Commits land on feat/auth/jwt.

[Overseer] Types: /mo-continue # post-chain

[Millwright] Resume Handler: verifies commits exist; sets implementation-completed=true;

asks for blueprint-drift reason. Overseer types: continue.

Auto-fires /mo-draw-diagrams (renders implementation diagrams).

Initializes overseer-review.md skeleton. Advances to stage 5.

[Overseer] Reviews implementation/diagrams/ + the diff. Edits overseer-review.md:

"The JWT signing function in auth/jwt.ts hard-codes HS256; should be configurable."

[Overseer] Types: /mo-continue # stage 5

[Millwright] Overseer Handler: review.sh canonicalize finds the free-form span;

classifies severity=major, scope=re-implement; review.sh add creates IR-001

with the original sentence as `details`; review.sh strip-freeform removes the line.

review.sh list-open returns ["IR-001"].

Auto-fires /mo-review.

[Millwright] /mo-review writes review-context.md; sets sub-flow=reviewing;

advances 5 → 6; asks: "review-mode? brainstorming or direct?"

[Overseer] Types: brainstorming

[Millwright] Invokes brainstorming skill (isolated review session).

[Overseer + chain] Chain reads IR-001, classifies as re-implement, edits auth/jwt.ts,

commits. review.sh set-status IR-001 fixed. Asks overseer for approval.

[Overseer] Types: approve

[Overseer] Types: /mo-continue # post-review-session

[Millwright] Review-Resume Handler: list-open is empty (sanity-check passes);

sets sub-flow=none, overseer-review-completed=true; advances 6 → 7;

offers diagram refresh (overseer types y); re-runs /mo-draw-diagrams;

auto-fires /mo-complete-workflow.

[Millwright] mo-complete-workflow:

todo.sh bulk-transition IMPLEMENTING IMPLEMENTED --feature auth;

commits.sh populate-requirements auth (writes commits: field);

blueprints.sh rotate auth --reason-kind completion (current/* → history/v1/);

deletes implementation/*;

progress.sh finish (auth → completed, active = null).

Queue is empty; checks todo-list.md for unmarked [ ] TODO.

None found; recommends /mo-run for next cycle.

```

  

What the overseer typed end-to-end: `/mo-init`, `/mo-run auth-meeting`, edit todo-list, `/mo-continue`, `/mo-continue`, edit config, `/mo-continue`, `brainstorming`, drove the chain, `/mo-continue`, `continue` (drift skip), edit overseer-review.md, `/mo-continue`, `brainstorming`, drove the review session, `approve`, `/mo-continue`, `y` (diagram refresh).

  

What the millwright did automatically: `mo-apply-impact`, `mo-plan-implementation`, `mo-draw-diagrams`, `mo-review`, `mo-draw-diagrams` (refresh), `mo-complete-workflow`, plus all script invocations.

  

---

  

## 9. Glossary

  

- **Active block** — the populated `active:` section of `progress.md` while a feature is mid-cycle.

- **Base-commit** — the git SHA captured at stage 3 just before chain launch / direct implementation. The lower bound of the implementation diff.

- **Blueprint** — the `requirements.md` + `config.md` + `primer.md` + `diagrams/` set under `blueprints/current/`.

- **Brainstorming chain** — the isolated session running `brainstorming` → `writing-plans` → `executing-plans` (or `subagent-driven-development`) → `finishing-a-development-branch`.

- **Canonicalize** — convert a free-form finding sentence into a structured `### IR-NNN` block.

- **Cycle** — the lifespan of a single `quest/` cohort, from `/mo-run` to all features completed.

- **Direct mode** — planning-mode or review-mode that keeps work in the main session instead of spawning a Skill.

- **Drift check** — the post-chain prompt asking the overseer whether requirements changed during brainstorming.

- **Existing-vs-new framing** — visual convention in implementation diagrams that shades pre-existing system elements as `#EEEEEE` boxes / packages so the new functionality reads as a delta.

- **Findings file** — `implementation/overseer-review.md`. Contains `### IR-NNN` blocks.

- **History version (vN)** — a snapshot of `blueprints/current/` rotated into `blueprints/history/vN/` with a sibling `reason.md`.

- **IR-NNN** — finding ID in `overseer-review.md`. Zero-padded, monotonically increasing, never reused.

- **Layered load** — the primer-first context discipline; canonical files are fallbacks.

- **Millwright** — the AI agent role.

- **Overseer** — the human role.

- **Primer** — a compact derived snapshot file (`primer.md`, `review-context.md`) that bootstraps a long-running stage.

- **Quest** — the cycle-wide working state under `quest/`.

- **Re-spec / re-plan / re-implement / fix** — the four scope tiers for a finding.

- **Resume Handler / Approve Handler / Pre-flight Handler / Overseer Handler / Review-Resume Handler** — the five dispatch targets inside `/mo-continue`.

- **Stage** — one of 0–8 in the canonical workflow.

- **Sub-flow** — `none | chain-in-progress | resuming | reviewing` — secondary state dimension on top of `current-stage`.

- **Workflow stream** — the per-feature folder tree under `workflow-stream/<feature>/`.