# koba-specula

/!\ THIS IS A FULLY VIBE CODED TOOL /!\

Embedded Deno + TypeScript CLI for translating Vulkan C++ tutorial pages into
koba-style Zig lessons. It lives inside the koba repo at `tools/specula` and is
pre-configured for the project, so no `specula.config.json` is needed.

## Prerequisites

- [Deno](https://deno.land/)
- [Zig 0.16.0](https://ziglang.org/) on your `PATH` (used to locate the stdlib)
- `OPENROUTER_API_KEY` environment variable (or pass `-k/--api-key`)

## Running

All tasks assume your working directory is `tools/specula`:

```bash
cd tools/specula

# One-time: fetch Zig reference docs and stdlib signatures
# Stdlib is read from your local Zig installation via `zig env`.
deno task fetch-docs

# Translate a Vulkan tutorial lesson
deno task translate <url-or-path>...

# Examples
deno task translate https://docs.vulkan.org/tutorial/latest/03_Drawing_a_triangle/01_Presentation/00_Swap_chain.html
deno task translate ./my-local-lesson.md --out ./lesson.md

# Translate multiple lessons in one invocation
deno task translate https://docs.vulkan.org/tutorial/latest/03_Drawing_a_triangle/01_Presentation/00_Swap_chain.html https://docs.vulkan.org/tutorial/latest/03_Drawing_a_triangle/02_Rendering/01_Image_views.html
```

Translation output defaults to `tools/specula/docs/<slug>.md`. Cache is stored
under `tools/specula/.cache/`.

## Commands

### `fetch-docs`

Populate the reference-doc and stdlib caches used by translation.

```bash
deno task fetch-docs [-f|--force]
```

### `translate`

Translate one or more lessons into the target language and write the Markdown
output. Shared work (reference docs, stdlib cache, project scan) is performed
once and reused across all sources.

```bash
deno task translate <url-or-path>... [options]
```

Flags:

- `-o, --out <path>` — output Markdown file (single source only)
- `-m, --model <id>` — override the LLM model
- `-k, --api-key <key>` — API key override
- `-p, --project <dir>` — project root for codebase context (default: koba root)
- `--no-project` — skip project scanning entirely
- `--out-dir <dir>` — write output into a directory (default:
  `tools/specula/docs`)
- `--stream` — stream LLM output to stdout
- `--dry-run` — print prompts and token estimates without calling the LLM
- `-f, --force` — refetch cached docs before translating
- `-h, --help` — show help

## Configuration

All koba-specific settings (target language, stdlib modules, feature rules,
prompt sections, RAG budgets) are hardcoded in `config.ts` as `KOBA_CONFIG`.
There is no external config file to maintain.

## Context file

`CONTEXT.md` (next to the specula source) is the highest-priority project file
fed to the translator. Edit it to keep the ground-truth conventions up to date
(module names, handle types, struct field names, cleanup order, etc.).

## Development

```bash
deno task check
deno task fmt
deno task lint
deno task test
```

## System prompt for teaching

You are a very kind and helpful and patient teacher. My goal is to learn game
dev/game engine dev. Guide me step by step while teaching me stuff. Do not make
edits yourself unless I ask you to. Here is the lesson:
