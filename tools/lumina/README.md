# koba-lumina

Vulkan lesson translator for the koba game engine project. Given a Vulkan
tutorial URL (or local file), lumina fetches the lesson, gathers rich context
about the koba project (source files, detected versions, stdlib signatures,
reference docs, previous translated lessons), builds a detailed prompt, and
calls an LLM to produce a Zig lesson in Markdown.

## Prerequisites

- [Deno](https://deno.land/)
- [Zig 0.16.0](https://ziglang.org/) on your `PATH` (used to locate the stdlib)
- `OPENROUTER_API_KEY` environment variable (or pass `-k/--api-key`)

## Running

All tasks assume your working directory is `tools/lumina`:

```bash
cd tools/lumina

# One-time: fetch Zig reference docs and stdlib signatures into .cache/
deno task fetch-docs

# Translate a Vulkan tutorial lesson
deno task translate <url-or-path>...

# Examples
deno task translate https://docs.vulkan.org/tutorial/latest/04_Vertex_buffers/00_Vertex_input_description.html
deno task translate ./my-local-lesson.md --out ./lesson.md
```

Translation output defaults to `tools/lumina/docs/<slug>.md`. Cache is stored
under `tools/lumina/.cache/`.

## Commands

### `fetch-docs`

Populate the reference-doc and stdlib caches used by translation.

```bash
deno task fetch-docs [-f|--force]
```

### `translate`

Translate one or more lessons into Zig and write the Markdown output. Shared
work (reference docs, stdlib cache, project scan, version detection, previous
lessons) is performed once and reused across all sources.

```bash
deno task translate <url-or-path>... [options]
```

Flags:

- `-o, --out <path>` — output Markdown file (single source only)
- `-m, --model <id>` — override the model (default: `openrouter/free`)
- `-k, --api-key <key>` — API key override
- `-p, --project <dir>` — project root for codebase context (default: koba root)
- `--no-project` — skip project scanning entirely
- `--no-lessons` — skip loading previous translated lessons
- `--out-dir <dir>` — write output into a directory (default: `tools/lumina/docs`)
- `--stream` — stream LLM output to stdout while generating
- `--dry-run` — print prompts and token estimates without calling the LLM
- `-f, --force` — refetch cached docs before translating
- `-h, --help` — show help

## Context file

`CONTEXT.md` (next to the lumina source) is the highest-priority project file
fed to the translator. Edit it to keep the ground-truth conventions up to date
(module names, handle types, struct field names, cleanup order, etc.).

## Development

```bash
deno task check
deno task fmt
deno task lint
deno task test
```
