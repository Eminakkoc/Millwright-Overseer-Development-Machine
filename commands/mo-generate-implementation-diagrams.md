---
description: Render diagrams of the implementation (commit range base-commit..HEAD) into implementation/diagrams/, with pre-existing system context framed alongside the new functionality. Called by /mo-continue at stage 4.
---

# mo-generate-implementation-diagrams

Generates the single set of diagrams the overseer reviews at stage 5. Each diagram shows the **implemented** behaviour of `base-commit..HEAD` with **pre-existing** participants, classes, and flows kept in view as framed/shaded context so the overseer can spot what changed at a glance.

## Execution

### Step 1 — Resolve inputs

```bash
active_feature="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get-active)"
base_commit="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit)"
dest_dir="millwright-overseer/workflow-stream/$active_feature/implementation/diagrams"
mkdir -p "$dest_dir"
```

### Step 2 — Ensure `implementation/change-summary.md` is current (AI work)

Diagram generation reads from a cached analysis artifact instead of re-running the codebase scan from scratch. `/mo-update-blueprint` writes the same artifact when it runs in the same stage-4 turn (post-chain drift refresh), so the analysis happens once per `base-commit..HEAD` range.

```bash
summary_file="$dest_dir/../change-summary.md"
if $CLAUDE_PLUGIN_ROOT/scripts/commits.sh change-summary-fresh "$active_feature"; then
  echo "change-summary.md is current (cache hit) — reusing"
else
  echo "change-summary.md is missing or stale — regenerating"
  # Fall through to Step 2a.
fi
```

#### Step 2a — Generate or refresh `change-summary.md`

When the freshness check fails (exit 1 = stale, exit 2 = missing), regenerate the artifact:

```bash
requirements_file="millwright-overseer/workflow-stream/$active_feature/blueprints/current/requirements.md"
requirements_id="$($CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh get "$requirements_file" id)"
base_commit_sha="$($CLAUDE_PLUGIN_ROOT/scripts/progress.sh get base-commit)"
head_sha="$(git rev-parse HEAD)"
$CLAUDE_PLUGIN_ROOT/scripts/frontmatter.sh init change-summary \
  "millwright-overseer/workflow-stream/$active_feature/implementation/change-summary.md" \
  "REQUIREMENTS_ID=$requirements_id" \
  "FEATURE=$active_feature" \
  "BASE_COMMIT=$base_commit_sha" \
  "HEAD=$head_sha"
```

Then fill the body via `Edit`. Source the changed-file list from the script — do **not** re-scan the working tree:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/commits.sh changed-files "$active_feature"
# Emits TSV rows: <status>\t<adds>\t<dels>\t<path>
```

For each file in the changed-files output, decide what depth to inspect using the **bounded context policy** below. Then write each section per the template's guide:

- **`## Range`** — fill `commit count` from `git rev-list --count "$base_commit_sha..HEAD"`.
- **`## Changed files`** — group the TSV rows by area (top-level dir, layer, or feature concern). Format: `<status> <path> (+adds/-dels): <one-line purpose>`. Skip the per-file purpose for trivial files (e.g., simple imports). Do **not** paste full diffs.
- **`## Detected entrypoints`** — public surface introduced or modified: HTTP routes, RPC handlers, CLI commands, scheduled jobs, queue consumers, new exports. One bullet per entrypoint with `<path>:<symbol>`. Skip the section if no public surface changed.
- **`## Suspected flows`** — end-to-end flows the change enables (validated against the actual diagram pass in Step 3). Each entry: `<flow name>: <one-line trace>`.
- **`## Omitted from analysis`** — every changed file you intentionally skipped per the bounded-context policy, listed by path so reviewers can spot blind spots.

#### Bounded context policy

The naive expansion — read every changed file plus all callers/callees — pulls hundreds of lines of unchanged code into the analysis context for moderate-sized diffs. Apply these defaults:

1. **Diff hunks first.** Always read `git diff "$base_commit_sha..HEAD" -- <path>` for every changed file before opening unchanged-side context.
2. **Cap caller/callee expansion at 3 per changed file.** Only open more when a flow would be unreadable without them — and note the expansion in the file's `## Changed files` bullet.
3. **Prefer symbol search over whole-file reads.** If you only need the signature or one function from a caller/callee, grep for it rather than `Read`-ing the whole file.
4. **Skip generated/vendor/lock files.** Default omissions: `dist/`, `build/`, `node_modules/`, `vendor/`, `*.lock`, `package-lock.json`, `yarn.lock`, `Cargo.lock`, `Gemfile.lock`, `*.min.js`, `*.svg`. List anything skipped under `## Omitted from analysis`.
5. **Skip large binary diffs.** Files where `commits.sh changed-files` reports `-/-` for adds/dels are binary; record the path under `## Omitted from analysis` and move on.

When the cache is fresh (Step 2 freshness check exited 0), skip Step 2a entirely — the summary is already correct for the current range.

### Step 2b — Frame diagrams from the cached summary (AI work)

Now build each diagram subject from `change-summary.md` + targeted re-reads:

1. **New** — actors, participants, messages, classes, and flows introduced by `base-commit..HEAD`. Derive from `## Detected entrypoints` and `## Suspected flows`, with diff hunks for the underlying code where needed.
2. **Existing** — the pre-existing participants, classes, and flows the new code touches or sits next to. Derive from the unchanged side of touched files (read only what the bounded context policy allows). Only include enough context to make the new bits legible — do not redraw the whole system.

### Step 3 — Generate diagrams (AI + PlantUML MCP)

Follow `docs/workflow-spec.md` § "Diagram conventions":

- **`use-case-<feature>.puml`** — mandatory, exactly one. Implemented capabilities with framed actors that pre-existed.
- **`sequence-<flow>.puml`** — one per significant implemented flow. Aim for 1–5 total.
- **`class-<domain>.puml`** — only if the implementation introduced 3+ new classes/modules with non-trivial relationships.

#### Existing-vs-new convention (consistent across all diagrams)

Use this fixed visual convention so the overseer can read every diagram the same way:

- Pre-existing participants/classes are grouped in a `box "Existing system" #EEEEEE … end box` (sequence) or a tinted `package "Existing" #EEEEEE { … }` block (class / use-case).
- New participants/classes sit outside the existing box with the default skin.
- Pre-existing message arrows and activations are shaded grey: `A -[#888888]-> B` and `#EEEEEE` activation colour. New arrows use the default colour.
- Each diagram includes a small legend so the convention is self-documenting:

  ```plantuml
  legend right
    |= |= Meaning |
    |<back:#EEEEEE>   </back>| existing (pre-`base-commit`) |
    |<back:#FFFFFF>   </back>| new in this implementation |
  endlegend
  ```

Use the PlantUML MCP (`plantuml` server) to render each diagram. Save the `.puml` source. Skip the `.svg` render — the millwright never reads `.svg` files (they're banned by the review commands' hard exclusion), and PlantUML sources are what the overseer diffs.

### Step 4 — Write diagrams/README.md

```yaml
---
id: <uuid>
stage: implementation
---
```

Body: bullet list of diagrams with a one-line purpose each. If the implementation added a flow that wasn't in `requirements.md`, or omitted one that was, call it out under a `## Notable deviations from requirements` subsection — that's a heads-up for the overseer review at stage 5.

Use `$CLAUDE_PLUGIN_ROOT/scripts/uuid.sh` for the id.

### Step 5 — Report

> "Implementation diagrams generated at `$dest_dir` (N diagrams). Existing-system context is shaded; new functionality is highlighted."

## Delegation (optional)

When Step 2a fires (cache miss/stale) and the diff touches many areas, writing the `change-summary.md` body is a good delegation candidate (see `docs/workflow-spec.md` § "Delegation guidance"). One sub-agent at "strong code-analysis, high effort" tier; output artifact is `implementation/change-summary.md`; chat reply stays ≤ 20 lines. The millwright reads the artifact for Step 2b's diagram framing. When the cache is fresh (Step 2 exited 0), no delegation is needed.
