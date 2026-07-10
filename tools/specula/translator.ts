import { parse } from "@std/flags";
import {
  basename,
  dirname,
  extname,
  fromFileUrl,
  join,
  resolve,
} from "@std/path";
import {
  analyzeSourceFeatures,
  fetchLessonPage,
  getRelevantStdlib,
  loadReferenceSections,
  type ProjectFile,
  scanProjectFiles,
  searchLangDocs,
} from "./fetcher.ts";
import { type Config, KOBA_CONFIG } from "./config.ts";
import {
  buildTranslationPrompts,
  DEFAULT_MODEL,
  estimatePromptTokens,
  estimateTokens,
  translateLesson,
} from "./llm.ts";

const MODULE_DIR = dirname(fromFileUrl(import.meta.url));
const KOBA_ROOT = resolve(join(MODULE_DIR, ".."));
const DEFAULT_CACHE_ROOT = MODULE_DIR;
const DEFAULT_OUT_DIR = join(MODULE_DIR, "docs");
const CONTEXT_FILE = join(MODULE_DIR, "CONTEXT.md");

function printHelp(): void {
  console.log(`koba-specula

Embedded tutorial translator for the koba game engine project.

Usage:
  deno task fetch-docs [--force]
  deno task translate <url-or-path> [options]

Run these tasks from the tools/specula directory, or use:
  cd tools/specula && deno task ...

Commands:
  fetch-docs   Populate Zig reference and stdlib caches.
  translate    Translate a Vulkan tutorial lesson into koba-style Zig.

Translate flags:
  -o, --out <path>     Output Markdown file
  -m, --model <id>     Override the model (default: ${DEFAULT_MODEL})
  -k, --api-key <key>  API key override
  -p, --project <dir>  Project root for codebase context (default: koba root)
  --no-project         Skip project scanning entirely
  --out-dir <dir>      Write output into a directory (default: tools/specula/docs)
  --stream             Stream LLM output to stdout while generating
  --dry-run            Print prompts and token estimates without calling LLM
  -f, --force          Refetch cached docs before translating
  -h, --help           Show this help
`);
}

function slugify(value: string): string {
  return value
    .toLowerCase()
    .replace(/^https?:\/\//, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80) || "lesson";
}

function deriveSourceSlug(source: string): string {
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
  if (outPath) {
    return resolve(outPath);
  }
  const fileName = `${deriveSourceSlug(source)}.md`;
  return resolve(outDir ? join(outDir, fileName) : fileName);
}

function envApiKey(config: Config): string | undefined {
  return config.apiKeyEnvVar ? Deno.env.get(config.apiKeyEnvVar) : undefined;
}

function logProgress(message: string): void {
  console.error(`[koba-specula] ${message}`);
}

async function runFetchDocs(force: boolean): Promise<void> {
  const config = KOBA_CONFIG;
  await loadReferenceSections(config, {
    force,
    cacheRoot: DEFAULT_CACHE_ROOT,
  });
  await getRelevantStdlib(config, Object.keys(config.stdlibModules), {
    force,
    cacheRoot: DEFAULT_CACHE_ROOT,
  });
}

async function runTranslate(args: Record<string, unknown>): Promise<void> {
  const positional = (args._ ?? []) as Array<string | number>;
  const source = String(positional[0] ?? "");
  if (!source) {
    throw new Error("translate requires a source URL or local path");
  }

  const config = { ...KOBA_CONFIG };
  const modelOverride = typeof args.model === "string"
    ? String(args.model)
    : undefined;

  const projectRoot = typeof args.project === "string"
    ? String(args.project)
    : KOBA_ROOT;
  const force = Boolean(args.force);
  const noProject = Boolean(args["no-project"]);
  const stream = Boolean(args.stream);
  const dryRun = Boolean(args["dry-run"]);
  const outPath = typeof args.out === "string" ? String(args.out) : undefined;
  const outDir = typeof args["out-dir"] === "string"
    ? String(args["out-dir"])
    : DEFAULT_OUT_DIR;
  const outputPath = deriveOutputPath(source, outDir, outPath);
  const budgets = config.ragBudgets;

  if (force) {
    await loadReferenceSections(config, {
      force: true,
      cacheRoot: DEFAULT_CACHE_ROOT,
    });
    await getRelevantStdlib(config, Object.keys(config.stdlibModules), {
      force: true,
      cacheRoot: DEFAULT_CACHE_ROOT,
    });
  }

  logProgress("fetching lesson");
  const lesson = await fetchLessonPage(source);
  logProgress("analyzing features");
  const analysis = analyzeSourceFeatures(lesson.codeBlocks, config);
  logProgress("retrieving reference docs");
  const referenceSections = searchLangDocs(
    await loadReferenceSections(config, {
      force,
      cacheRoot: DEFAULT_CACHE_ROOT,
    }),
    analysis.concepts.join(" "),
    budgets.referenceLimit ?? 6,
  );
  logProgress("retrieving stdlib");
  const stdlibSections = await getRelevantStdlib(config, analysis.modules, {
    force,
    cacheRoot: DEFAULT_CACHE_ROOT,
    limit: budgets.stdlibLimit ?? 24,
  });
  logProgress("scanning project");
  const scannedFiles = noProject
    ? []
    : await scanProjectFiles(resolve(projectRoot), config, budgets);
  const projectFiles: ProjectFile[] = [];
  try {
    const contextContent = await Deno.readTextFile(CONTEXT_FILE);
    projectFiles.push({
      path: CONTEXT_FILE,
      relativePath: "CONTEXT.md",
      content: contextContent,
      bytes: new TextEncoder().encode(contextContent).length,
      truncated: false,
      priority: -1,
    });
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) {
      throw error;
    }
  }
  projectFiles.push(...scannedFiles);
  const promptInput = {
    config,
    lesson,
    projectFiles,
    stdlibSections,
    referenceSections,
  };
  const { system, user } = buildTranslationPrompts(promptInput);
  const systemTokens = estimateTokens(system);
  const userTokens = estimateTokens(user);
  const totalTokens = estimatePromptTokens(system, user);

  if (dryRun) {
    console.log("=== System prompt ===");
    console.log(system);
    console.log("");
    console.log("=== User prompt ===");
    console.log(user);
    console.error(
      `[koba-specula] Estimated tokens: system ${systemTokens}, user ${userTokens}, total ${totalTokens}`,
    );
    return;
  }

  const apiKey = String(args["api-key"] ?? envApiKey(config) ?? "");
  if (!apiKey) {
    throw new Error(
      `Missing API key. Provide -k/--api-key or set ${config.apiKeyEnvVar}.`,
    );
  }

  logProgress(
    `calling the LLM (estimated tokens: system ${systemTokens}, user ${userTokens}, total ${totalTokens})`,
  );
  const markdown = await translateLesson({
    ...promptInput,
    apiKey,
    model: modelOverride,
    stream,
    onChunk: stream
      ? (chunk) => {
        Deno.stdout.writeSync(new TextEncoder().encode(chunk));
      }
      : undefined,
  });
  await Deno.mkdir(dirname(outputPath), { recursive: true }).catch(() => {});
  await Deno.writeTextFile(outputPath, markdown);
  logProgress(`wrote ${outputPath}`);
}

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
      boolean: ["force", "help", "no-project", "stream", "dry-run"],
      string: [
        "out",
        "model",
        "api-key",
        "project",
        "out-dir",
      ],
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

  throw new Error(`Unknown command: ${command}`);
}

try {
  await main();
} catch (error) {
  if (error instanceof Error) {
    console.error(error.message);
  } else {
    console.error(String(error));
  }
  Deno.exit(1);
}
