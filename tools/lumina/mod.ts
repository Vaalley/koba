// CLI entry point for the lumina translator.
// Orchestrates: fetch lesson → gather context → build prompts → call LLM → save output.

import { parse } from "@std/flags";
import { basename, dirname, extname, join, resolve } from "@std/path";

import { CONFIG, type Config } from "./config.ts";
import type {
  AnalysisResult,
  DocsSection,
  LessonPage,
  ProjectContext,
  StdlibSection,
} from "./types.ts";
import { analyzeFeatures, fetchLessonPage } from "./fetcher.ts";
import {
  gatherProjectContext,
  loadPreviousLessons,
  loadReferenceSections,
  loadStdlibSections,
  searchLangDocs,
} from "./context.ts";
import { buildPrompts, estimateTokens } from "./prompt.ts";
import { translateLesson } from "./llm.ts";

// ─── Logging ───────────────────────────────────────────────────────────

function log(message: string): void {
  console.error(`[koba-lumina] ${message}`);
}

// ─── Helpers ───────────────────────────────────────────────────────────

function slugify(value: string): string {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80);
}

function deriveSlug(source: string): string {
  if (/^https?:\/\//i.test(source)) {
    try {
      const url = new URL(source);
      return slugify(
        url.pathname.split("/").filter(Boolean).at(-1) ?? url.hostname,
      );
    } catch {
      return slugify(source);
    }
  }
  return slugify(basename(source, extname(source)) || basename(source));
}

function deriveOutputPath(
  source: string,
  outDir?: string,
  outPath?: string,
): string {
  if (outPath) return resolve(outPath);
  const fileName = `${deriveSlug(source)}.md`;
  return resolve(outDir ? join(outDir, fileName) : fileName);
}

// ─── Help ──────────────────────────────────────────────────────────────

function printHelp(): void {
  console.log(`koba-lumina

Vulkan lesson translator for the koba game engine project.

Usage:
  deno task fetch-docs [--force]
  deno task translate <url-or-path>... [options]

Commands:
  fetch-docs   Populate Zig reference and stdlib caches.
  translate    Translate one or more Vulkan tutorial lessons into koba-style Zig.

Translate flags:
  -o, --out <path>     Output Markdown file (single source only)
  -m, --model <id>     Override the model (default: ${CONFIG.defaultModel})
  -k, --api-key <key>  API key override
  -p, --project <dir>  Project root for codebase context (default: koba root)
  --no-project         Skip project scanning entirely
  --no-lessons         Skip loading previous translated lessons
  --out-dir <dir>      Write output into a directory (default: tools/lumina/docs)
  --stream             Stream LLM output to stdout while generating
  --dry-run            Print prompts and token estimates without calling LLM
  -f, --force          Refetch cached docs before translating
  -h, --help           Show this help
`);
}

// ─── fetch-docs ────────────────────────────────────────────────────────

async function runFetchDocs(force: boolean): Promise<void> {
  log("fetching Zig reference documentation...");
  const refSections = await loadReferenceSections(CONFIG, { force });
  log(`  cached ${refSections.length} reference section(s)`);

  log("fetching Zig stdlib signatures...");
  const stdSections = await loadStdlibSections(CONFIG, { force });
  log(`  cached ${stdSections.length} stdlib declaration(s)`);

  log("done.");
}

// ─── translate ─────────────────────────────────────────────────────────

interface TranslateOptions {
  config: Config;
  modelOverride?: string;
  force: boolean;
  stream: boolean;
  dryRun: boolean;
  outPath?: string;
  outDir: string;
  noProject: boolean;
  noLessons: boolean;
  apiKey?: string;
}

async function translateOne(
  source: string,
  opts: TranslateOptions,
  context: ProjectContext,
): Promise<void> {
  const { config, modelOverride, stream, dryRun, outPath, outDir, apiKey } =
    opts;
  const outputPath = deriveOutputPath(source, outDir, outPath);

  // [1/4] Fetch the lesson.
  log(`[1/4] fetching lesson: ${source}`);
  const lesson: LessonPage = await fetchLessonPage(source);
  log(
    `  title: "${lesson.title}" (${lesson.codeBlocks.length} code block(s))`,
  );

  // [2/4] Analyze features → select relevant stdlib modules + reference docs.
  log("[2/4] analyzing lesson features");
  const analysis: AnalysisResult = analyzeFeatures(lesson.codeBlocks, config);
  log(
    `  features: ${analysis.features.slice(0, 6).join(", ")}${
      analysis.features.length > 6 ? "..." : ""
    }`,
  );
  log(`  stdlib modules: ${analysis.modules.join(", ") || "(none)"}`);

  // Filter stdlib sections to the matched modules.
  let filteredStdlib: StdlibSection[] = context.stdlibSections;
  if (analysis.modules.length > 0) {
    filteredStdlib = context.stdlibSections.filter((section) =>
      analysis.modules.includes(section.moduleId)
    );
  }
  filteredStdlib = filteredStdlib.slice(0, config.stdlibLimit);
  log(`  retrieved ${filteredStdlib.length} stdlib declaration(s)`);

  // Search reference docs by concepts.
  const filteredRef: DocsSection[] = searchLangDocs(
    context.referenceSections,
    analysis.concepts,
    config.referenceLimit,
  );
  log(`  retrieved ${filteredRef.length} reference section(s)`);

  // Load previous lessons for this specific source (tutorial-order aware).
  const previousLessons = opts.noLessons ? [] : await loadPreviousLessons(
    config.docsDir,
    config.maxPreviousLessons,
    config.previousLessonMaxBytes,
    source,
  );
  if (previousLessons.length > 0) {
    log(
      `  previous lessons: ${previousLessons.map((l) => l.title).join(", ")}`,
    );
  }

  // Build the filtered context.
  const filteredContext: ProjectContext = {
    ...context,
    stdlibSections: filteredStdlib,
    referenceSections: filteredRef,
    previousLessons,
  };

  // [3/4] Build prompts.
  log("[3/4] building prompts");
  const { system, user } = buildPrompts(lesson, filteredContext, config);
  const systemTokens = estimateTokens(system);
  const userTokens = estimateTokens(user);
  const totalTokens = systemTokens + userTokens;
  log(
    `  tokens: system ${systemTokens}, user ${userTokens}, total ${totalTokens}`,
  );

  if (dryRun) {
    console.log("=== System prompt ===");
    console.log(system);
    console.log("");
    console.log("=== User prompt ===");
    console.log(user);
    console.error(
      `[koba-lumina] dry run — estimated ${totalTokens} tokens`,
    );
    return;
  }

  // [4/4] Call the LLM.
  if (!apiKey) {
    throw new Error(
      `Missing API key. Provide -k/--api-key or set ${config.apiKeyEnvVar}.`,
    );
  }

  const model = modelOverride ?? config.defaultModel;
  log(`[4/4] translating via OpenRouter (model: ${model})`);

  const markdown = await translateLesson({
    system,
    user,
    apiKey,
    model,
    temperature: config.temperature,
    endpoint: config.endpoint,
    extraHeaders: config.extraHeaders,
    stream,
    onChunk: stream
      ? (chunk) => Deno.stdout.writeSync(new TextEncoder().encode(chunk))
      : undefined,
  });

  // Save output with source metadata for tutorial-order continuity.
  const output = `<!-- lumina-source: ${source} -->\n\n${markdown}`;
  await Deno.mkdir(dirname(outputPath), { recursive: true }).catch(() => {});
  await Deno.writeTextFile(outputPath, output);
  log(`saved translation to ${outputPath} (${output.length} bytes)`);
}

async function runTranslate(args: Record<string, unknown>): Promise<void> {
  const positional = (args._ ?? []) as Array<string | number>;
  const sources = positional.map(String).filter(Boolean);
  if (sources.length === 0) {
    throw new Error("translate requires a source URL or local path");
  }

  const config = { ...CONFIG };

  const modelOverride = typeof args.model === "string"
    ? String(args.model)
    : undefined;

  const force = Boolean(args.force);
  const noProject = Boolean(args["no-project"]);
  const noLessons = Boolean(args["no-lessons"]);
  const stream = Boolean(args.stream);
  const dryRun = Boolean(args["dry-run"]);
  const outPath = typeof args.out === "string" ? String(args.out) : undefined;
  const outDir = typeof args["out-dir"] === "string"
    ? String(args["out-dir"])
    : config.docsDir;
  // Resolve API key.
  const explicitKey = typeof args["api-key"] === "string" && args["api-key"]
    ? String(args["api-key"])
    : undefined;
  const envKey = Deno.env.get(config.apiKeyEnvVar);
  const apiKey = explicitKey ?? envKey;

  // Gather project context (shared across all sources).
  // Previous lessons are loaded per-source inside translateOne because
  // they depend on the current source's tutorial position.
  log("gathering project context...");
  const context = await gatherProjectContext(config, {
    force,
    noProject,
    noLessons: true,
  });
  log(
    `  versions: Zig ${context.versions.zig}, Vulkan SDK ${context.versions.vulkanSdk}, SDL3 ${context.versions.sdl3}`,
  );
  log(`  project files: ${context.files.length}`);
  log(`  stdlib sections: ${context.stdlibSections.length}`);
  log(`  reference sections: ${context.referenceSections.length}`);

  const opts: TranslateOptions = {
    config,
    modelOverride,
    force,
    stream,
    dryRun,
    outPath,
    outDir,
    noProject,
    noLessons,
    apiKey,
  };

  for (const source of sources) {
    if (sources.length > 1) {
      log(`\ntranslating ${source}`);
    }
    await translateOne(source, opts, context);
  }
}

// ─── main ──────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const [command, ...rest] = Deno.args;
  if (!command || command === "-h" || command === "--help") {
    printHelp();
    return;
  }

  if (command === "fetch-docs") {
    const args = parse(rest, {
      boolean: ["force", "help"],
      alias: { h: "help", f: "force" },
    });
    if (args.help) {
      printHelp();
      return;
    }
    await runFetchDocs(Boolean(args.force));
    return;
  }

  if (command === "translate") {
    const args = parse(rest, {
      boolean: [
        "force",
        "help",
        "no-project",
        "no-lessons",
        "stream",
        "dry-run",
      ],
      string: ["out", "model", "api-key", "project", "out-dir"],
      alias: {
        h: "help",
        o: "out",
        m: "model",
        k: "api-key",
        p: "project",
        f: "force",
      },
    });
    if (args.help) {
      printHelp();
      return;
    }
    await runTranslate(args as Record<string, unknown>);
    return;
  }

  throw new Error(`Unknown command: ${command}. Run with --help for usage.`);
}

try {
  await main();
} catch (error) {
  if (error instanceof Error) {
    console.error(`[koba-lumina] error: ${error.message}`);
  } else {
    console.error(`[koba-lumina] error: ${String(error)}`);
  }
  Deno.exit(1);
}
