---
description: Convert non-text journal files (.pdf, .docx, .pptx, .xlsx, .png, .jpg, etc.) to sibling .md via docling, so stage 1 can pick them up. Run before /mo-run if the overseer dropped non-text resources into journal/.
argument-hint: "[<journal-subfolder>] [--dry-run] [--force]"
---

# mo-ingest

Pre-processor for the `journal/` folder. Runs [docling](https://github.com/docling-project/docling) over every non-text file and produces a sibling `.md` that the stage-1 glob in `/mo-run` will pick up (mo-run.md:87). Originals are preserved for audit.

## When to use

**You usually don't need to run this yourself.** `/mo-run` automatically detects non-text files and walks per-file decisions with you (docling vs native stub) before generating quest files. Reach for `/mo-ingest` directly only when you want to:

- Pre-convert files early (e.g., after a bulk drop, to review the produced `.md` before running `/mo-run`).
- Re-convert after editing a source file — use `--force`.
- Convert files in folders you aren't about to pass to `/mo-run`.
- Inspect what would be converted (`--dry-run`).
- Override a previous decision on a specific file via `--file` or `--stub`.

If your journal folders only ever contain `.md` and `.txt` files, you don't need `/mo-ingest` at all.

## What ingest does, by input type

The script splits handling in two based on extension, because docling is a document-layout tool and is the wrong fit for standalone UI screenshots or diagrams:

### Documents (`.pdf`, `.docx`, `.pptx`, `.xlsx`, `.html`)

- Runs `docling --to md --image-export-mode referenced --output <tmpdir> <src>`.
- Text, tables, captions, and reading order are extracted into `<stem>.md`.
- Every embedded figure is extracted as a sibling PNG; the script moves those PNGs into a `<stem>.images/` subfolder and rewrites references in the `.md` from bare `![](picture-1.png)` to `![](stem.images/picture-1.png)` so relative paths resolve.
- The frontmatter block records `kind: document`.
- PDFs with no embedded figures produce no images subfolder.

### Standalone images (`.png`, `.jpg`, `.jpeg`, `.webp`, `.tiff`, `.tif`)

- **Docling is not invoked.** Its default image pipeline base64-wraps the pixels and produces poor extraction for UI captures and diagrams; running it here was a net negative. Instead, ingest generates a stub `.md` with frontmatter plus a one-line reference to the original image.
- The frontmatter block records `kind: image`.
- The millwright reads the stub, sees the image reference, and opens the original PNG directly via its native vision capability during stage 1/2.

### Native-read stub for PDFs (opt-in via `--stub`)

- Claude Code's `Read` tool parses PDFs natively (up to 20 pages per call). For short text-heavy PDFs where docling's preprocessing overhead isn't justified, you can skip docling and use `--stub` to generate a stub `.md` that points the millwright at the original PDF.
- The frontmatter block records `kind: document-native`.
- The stub body instructs the millwright to open the PDF directly via `Read`, with a hint about chunking via `pages: "1-20"`, `"21-40"`, etc. for anything over the 20-page cap.
- `/mo-run`'s per-file decision flow uses this path when the overseer accepts the "native recommended" choice for a short PDF.

### Journal layout after a typical ingest

```
journal/specs/
  plant-spec.pdf              # original, untouched
  plant-spec.md               # docling text + references into plant-spec.images/
  plant-spec.images/          # extracted figures
    picture-1.png
    picture-2.png
  dashboard.png               # original, untouched
  dashboard.md                # stub referencing dashboard.png
  meeting-notes.md            # overseer-authored, untouched
```

`<stem>.images/` subfolders are excluded from the ingest enumeration on subsequent runs, so extracted PNGs cannot be mistaken for overseer-supplied standalone images.

## Invocation

**Folder mode** (batch — auto-dispatches each file by extension):

- `/mo-ingest` — process every subfolder under `journal/`.
- `/mo-ingest <folder>` — process just one subfolder (matches `/mo-run`'s argument style).
- `/mo-ingest <folder> --dry-run` — list what would be converted without writing.
- `/mo-ingest <folder> --force` — re-convert even if a sibling `.md` is newer than its source.

**Single-file mode** (fine-grained — used internally by `/mo-run`'s per-file decision flow, also available for manual use):

- `/mo-ingest --file <path>` — process one file via the auto-dispatch logic (documents → docling, images → stub).
- `/mo-ingest --stub <path>` — force stub generation regardless of extension. Use this to opt out of docling for a PDF you'd rather the millwright read natively via the `Read` tool (works well for short text-heavy PDFs under 20 pages). Note: stubbing a `.docx`/`.pptx`/`.xlsx` is almost always wrong — `Read` doesn't support those formats, so the stub is a dead end. The script still writes it, but the generated stub body warns about the limitation.

## Preconditions

- `docling` on PATH — if missing, Step 1 offers to install it with full cost disclosure (ML deps are ~1–2 GB). `/mo-doctor` also reports it as an optional dep.
- `journal/` exists (created by `/mo-init`).

## Execution

### Step 1 — Preflight with informed-install prompt

Check whether docling is on PATH:

```bash
if command -v docling >/dev/null 2>&1; then
  docling_present=1
else
  docling_present=0
fi
```

If `docling_present=1`, skip to Step 2.

If `docling_present=0`, **do not silently halt** — offer to install, with full disclosure of the cost. Show the overseer:

> "`docling` is not installed. It's required to convert non-text journal files (PDF/DOCX/PPTX/XLSX/images) into sibling `.md` files.
>
> **Install cost disclosure** — docling pulls ML dependencies: torch, transformers, pillow, and an OCR engine (easyocr or tesseract). Expect roughly **1–2 GB of disk** and a few minutes of download time. The first conversion may additionally download **~200–400 MB of model weights** from Hugging Face, cached under `~/.cache/huggingface/`.
>
> **What I'd run** (picking whichever is available on your machine):
>
> ```bash
> pipx install docling          # preferred — isolates deps in its own venv
> # OR, if pipx isn't available:
> python3 -m pip install --user docling
> ```
>
> The command runs in this Claude Code session via my `Bash` tool — you'll see progress output streamed inline. Nothing outside `pipx`'s managed venv (or `~/.local/lib/python*/site-packages/` for the `pip --user` fallback) is modified.
>
> **How I use it afterwards** — once `docling` is on PATH, I invoke it only via `$CLAUDE_PLUGIN_ROOT/scripts/ingest.sh`, which wraps `docling --to md --output <tmpdir> <src>` for each supported file. You never need to run `docling` by hand; `/mo-ingest` and `/mo-run`'s auto-ingest flow will handle invocation.
>
> Install now? (y/n)"

**On `y`** — run the install via the `Bash` tool. Prefer pipx if available:

```bash
if command -v pipx >/dev/null 2>&1; then
  pipx install docling
else
  python3 -m pip install --user docling
fi
```

Stream stdout so the overseer can watch progress. When the command finishes, re-run the detection:

```bash
command -v docling >/dev/null 2>&1
```

If docling is now on PATH, proceed to Step 2. If the install succeeded per its own exit code but `command -v docling` still fails, the `--user` site's `bin/` directory probably isn't on PATH. Surface this to the overseer with the fix:

> "`pip install` succeeded but `docling` isn't on PATH yet. `~/.local/bin` may not be in your PATH. Add `export PATH=\"$HOME/.local/bin:$PATH\"` to your shell profile, open a new terminal, and re-run `/mo-ingest`. Or re-run this in a fresh Claude Code session."

Halt — do not try to PATH-fix the current shell session automatically.

**On `n`** — halt with:

> "Cancelled — docling not installed, nothing converted. You can install later via `pipx install docling` or `python3 -m pip install --user docling`, then re-run `/mo-ingest`. `/mo-doctor` will also show install hints."

Exit.

### Step 2 — Run the ingest script

Pass through the overseer's arguments verbatim:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/ingest.sh $ARGUMENTS
```

The script:

1. Resolves the data root via `mo_data_root` (same precedence as every other `/mo-*` command).
2. Enumerates supported files in scope, **excluding any `*.images/` subfolder** so that PNGs docling extracted from PDFs on a previous run aren't picked up as new inputs.
3. Dispatches each file to the right handler:
   - Documents → `docling --to md --image-export-mode referenced --output <tmpdir> <src>`, then moves extracted PNGs into `<stem>.images/` and rewrites references in the produced `.md`.
   - Standalone images → stub `.md` generation only, no docling call.
4. Prepends synthetic frontmatter to every generated `.md`:

   ```yaml
   ---
   contributors:
     - docling
   date: <today>
   source: <original-filename>
   kind: document    # or: image
   ---
   ```

   This satisfies the frontmatter requirement in mo-run.md's stage-1 validation.
5. On `--force`, clears any existing `<stem>.images/` subfolder before re-extracting so stale figures from a previous run don't leak into the new reference set.
6. Leaves originals (PDF/DOCX/PNG/etc.) untouched.
7. Prints a `converted=N skipped=N failed=N` summary at the end.

**Idempotency:** if a sibling `.md` already exists and is newer than its source, the file is skipped. This makes `/mo-ingest` safe to re-run after adding new files to a folder.

### Step 3 — Report

Echo the ingest script's summary back to the overseer verbatim. If `failed > 0`, list the failed paths and suggest the overseer open the original file to check whether docling supports it, or re-run with `--force` after adjusting.

### Step 4 — Hand off

If `converted > 0`, tell the overseer:

> "Ingested N files into `journal/`. Each original now has a sibling `<stem>.md` that `/mo-run` will pick up. You can now run `/mo-run <folder1> [<folder2> ...]` as usual."

If `converted == 0 && skipped > 0`, tell them:

> "Nothing new to ingest — every supported file already has an up-to-date sibling `.md`. If you meant to re-convert, pass `--force`."

If `converted == 0 && skipped == 0 && failed == 0`, tell them:

> "No supported files found in journal/. Either the folder only has `.md`/`.txt` (ingest unnecessary) or the files use an unsupported extension. Supported: `.pdf .docx .pptx .xlsx .html .png .jpg .jpeg .webp .tiff`."

## Notes

- **No vector DB. No embeddings. No runtime retrieval layer.** Ingestion produces plain markdown artifacts, once, at the overseer's explicit request. Stage 1 consumes them exactly like hand-written `.md` notes.
- Frontmatter stamped by ingest uses `contributors: [docling]` and `date: <today>` as synthetic values. If the overseer wants to attribute real humans (e.g., the author of the ingested PDF), they can edit the generated `.md` before running `/mo-run`.
- Figma URLs, Linear ticket references, and other **live external resources** do NOT belong in `journal/` — put them in `config.md`'s `## Overseer Additions` section instead, so the brainstorming chain pulls them at runtime via MCP.
- Docling's picture-description (VLM) enrichment is **intentionally not enabled**. Image references in the generated `.md` point at extracted PNG files on disk; the millwright (a VLM) opens each file directly when processing the journal entry. Running a second VLM at ingest time to describe images for another VLM would be redundant and lossy (frozen paraphrase vs. fresh read).
- Safe to re-run any time. `--force` re-converts; default skips up-to-date siblings.
