// Project context gathering: file scanning, version detection, stdlib loading,
// reference docs, and previous lessons for lumina.

import { basename, join, relative, resolve } from "@std/path";
import { fetchWithRetry } from "./fetcher.ts";
import type { Config, StdlibModule } from "./config.ts";
import type {
  DocsSection,
  PreviousLesson,
  ProjectContext,
  ProjectFile,
  StdlibSection,
  VersionInfo,
} from "./types.ts";

const STOPWORDS: Record<string, true> = {
  a: true,
  an: true,
  and: true,
  as: true,
  at: true,
  by: true,
  for: true,
  from: true,
  how: true,
  in: true,
  into: true,
  is: true,
  of: true,
  on: true,
  or: true,
  the: true,
  to: true,
  with: true,
  what: true,
  when: true,
  where: true,
  why: true,
  which: true,
  that: true,
  this: true,
  these: true,
  those: true,
  use: true,
  using: true,
};

const ZIG_FALLBACK_VERSION = "0.16.0";

function normalizeWhitespace(input: string): string {
  return input.replace(/\r\n/g, "\n").replace(/[ \t]+\n/g, "\n");
}

function stripHtmlTags(input: string): string {
  return input
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<\/(p|div|section|article|li|h[1-6]|pre|code)>/gi, "\n")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<[^>]+>/g, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/&apos;/gi, "'")
    .replace(/&nbsp;/gi, " ")
    .replace(/\r/g, "")
    .replace(/[ \t]+/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

async function readJsonCache<T>(path: string): Promise<T | null> {
  try {
    const text = await Deno.readTextFile(path);
    return JSON.parse(text) as T;
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      return null;
    }
    throw error;
  }
}

async function writeJsonCache(path: string, value: unknown): Promise<void> {
  await Deno.mkdir(resolve(join(path, "..")), { recursive: true });
  await Deno.writeTextFile(path, `${JSON.stringify(value, null, 2)}\n`);
}

// ---------------------------------------------------------------------------
// Version detection
// ---------------------------------------------------------------------------

/**
 * Run `zig env` and parse the struct-like output for `.version` and `.std_dir`.
 * Zig prints fields as `.field = "value"`.
 */
async function runZigEnv(): Promise<{ version: string; stdDir: string }> {
  const command = new Deno.Command("zig", {
    args: ["env"],
    stdout: "piped",
    stderr: "piped",
  });
  const { code, stdout, stderr } = await command.output();
  if (code !== 0) {
    throw new Error(
      `zig env failed: ${new TextDecoder().decode(stderr)}`,
    );
  }
  const output = new TextDecoder().decode(stdout);
  const versionMatch = output.match(/\.version\s*=\s*"((?:[^"\\]|\\.)*)"/);
  const stdDirMatch = output.match(/\.std_dir\s*=\s*"((?:[^"\\]|\\.)*)"/);
  const version = versionMatch
    ? versionMatch[1].replace(/\\(.)/g, "$1")
    : ZIG_FALLBACK_VERSION;
  const stdDir = stdDirMatch ? stdDirMatch[1].replace(/\\(.)/g, "$1") : "";
  return { version, stdDir };
}

function parseVulkanSdk(buildZigText: string): string {
  const match = buildZigText.match(
    /vulkan_sdk\s*=\s*"([^"]+)"/,
  );
  if (!match) return "unknown";
  const path = match[1].replace(/\\/g, "/");
  const versionMatch = path.match(/(\d+\.\d+\.\d+\.\d+)/);
  return versionMatch ? versionMatch[1] : "unknown";
}

function parseSdlVersion(headerText: string): string {
  const major = headerText.match(/SDL_MAJOR_VERSION\s+(\d+)/)?.[1];
  const minor = headerText.match(/SDL_MINOR_VERSION\s+(\d+)/)?.[1];
  const micro = headerText.match(/SDL_MICRO_VERSION\s+(\d+)/)?.[1];
  if (!major || !minor || !micro) return "unknown";
  return `${major}.${minor}.${micro}`;
}

export async function detectVersions(config: Config): Promise<VersionInfo> {
  let zig = ZIG_FALLBACK_VERSION;
  let zigStdDir = "";
  try {
    const env = await runZigEnv();
    zig = env.version;
    zigStdDir = env.stdDir;
  } catch (error) {
    console.error(
      `[koba-lumina] warning: zig env failed: ${
        error instanceof Error ? error.message : String(error)
      }`,
    );
  }

  let vulkanSdk = "unknown";
  try {
    const buildZigText = await Deno.readTextFile(
      join(config.kobaRoot, "build.zig"),
    );
    vulkanSdk = parseVulkanSdk(buildZigText);
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) {
      console.error(
        `[koba-lumina] warning: could not read build.zig: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
  }

  let sdl3 = "unknown";
  try {
    const headerText = await Deno.readTextFile(
      join(config.kobaRoot, "third_party/SDL3/include/SDL3/SDL_version.h"),
    );
    sdl3 = parseSdlVersion(headerText);
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) {
      console.error(
        `[koba-lumina] warning: could not read SDL_version.h: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
  }

  return { zig, zigStdDir, vulkanSdk, sdl3 };
}

// ---------------------------------------------------------------------------
// Project file scanning
// ---------------------------------------------------------------------------

function isIncludedFile(name: string, config: Config): boolean {
  const lower = name.toLowerCase();
  return config.includeNames.some((entry) => entry.toLowerCase() === lower) ||
    config.includeExt.some((ext) =>
      lower.endsWith(
        ext.startsWith(".") ? ext.toLowerCase() : `.${ext.toLowerCase()}`,
      )
    );
}

function filePriority(relPath: string): number {
  const normalizedPath = relPath.replaceAll("\\", "/");
  const name = basename(normalizedPath).toLowerCase();
  if (name === "context.md") return -1;
  if (name === "build.zig" || name === "build.zig.zon") return 0;
  if (
    name === "main.zig" || normalizedPath.toLowerCase().endsWith("/main.zig") ||
    normalizedPath.toLowerCase().endsWith("/src/main.zig")
  ) {
    return 1;
  }
  if (normalizedPath.toLowerCase().startsWith("src/")) return 2;
  if (name.endsWith(".h") || name.endsWith(".hpp")) return 4;
  if (name === "readme" || name === "readme.md") return 5;
  return 3;
}

export async function scanProjectFiles(
  root: string,
  config: Config,
): Promise<ProjectFile[]> {
  const normalizedRoot = resolve(root);
  const files: Array<
    { path: string; relativePath: string; priority: number; bytes: number }
  > = [];
  const ignoreDirs = new Set(
    config.ignoreDirs.map((dir) => dir.toLowerCase()),
  );

  async function walk(current: string): Promise<void> {
    for await (const entry of Deno.readDir(current)) {
      const fullPath = join(current, entry.name);
      const relPath = relative(normalizedRoot, fullPath).replaceAll("\\", "/");
      if (entry.isDirectory) {
        if (ignoreDirs.has(entry.name.toLowerCase())) {
          continue;
        }
        if (
          relPath
            .split(/[\\/]/)
            .some((part) => ignoreDirs.has(part.toLowerCase()))
        ) {
          continue;
        }
        await walk(fullPath);
        continue;
      }
      if (!entry.isFile || !isIncludedFile(entry.name, config)) {
        continue;
      }
      const stat = await Deno.stat(fullPath);
      files.push({
        path: fullPath,
        relativePath: relPath,
        priority: filePriority(relPath),
        bytes: stat.size,
      });
    }
  }

  await walk(normalizedRoot);
  files.sort((a, b) =>
    a.priority - b.priority || a.relativePath.localeCompare(b.relativePath)
  );

  const { maxBytesPerFile, maxTotalBytes, maxFiles } = config;
  const admitted: ProjectFile[] = [];
  let totalBytes = 0;

  for (const file of files) {
    if (admitted.length >= maxFiles || totalBytes >= maxTotalBytes) {
      break;
    }
    let content = await Deno.readTextFile(file.path);
    let bytes = new TextEncoder().encode(content).length;
    let truncated = false;
    if (bytes > maxBytesPerFile) {
      const encoder = new TextEncoder();
      const encoded = encoder.encode(content);
      content = new TextDecoder().decode(encoded.slice(0, maxBytesPerFile));
      content = `${content}\n\n[truncated after ${maxBytesPerFile} bytes]\n`;
      bytes = maxBytesPerFile;
      truncated = true;
    }
    admitted.push({
      relativePath: file.relativePath,
      content,
      bytes,
      truncated,
      priority: file.priority,
    });
    totalBytes += bytes;
  }

  return admitted;
}

// ---------------------------------------------------------------------------
// Stdlib parsing
// ---------------------------------------------------------------------------

export function parseStdlibSource(
  moduleId: string,
  module: StdlibModule,
  sourceText: string,
  sourceUrl: string,
): StdlibSection[] {
  const lines = normalizeWhitespace(sourceText).split("\n");
  const sections: StdlibSection[] = [];
  const moduleDocLines: string[] = [];
  let index = 0;

  while (index < lines.length) {
    const line = lines[index].trim();
    if (line.startsWith("//!")) {
      moduleDocLines.push(line.replace(/^\/\/!\s?/, ""));
      index++;
      continue;
    }
    if (moduleDocLines.length > 0 && line === "") {
      index++;
      continue;
    }
    break;
  }

  if (moduleDocLines.length > 0) {
    sections.push({
      moduleId,
      moduleLabel: module.label,
      title: `${module.label} module`,
      signature: "",
      doc: moduleDocLines.join(" ").trim(),
      deprecated: false,
      priority: -1,
    });
  }

  type RawDecl = {
    name: string;
    signature: string;
    doc: string;
    deprecated: boolean;
    priority: number;
  };

  const decls: RawDecl[] = [];
  let pendingDoc: string[] = [];
  let pendingDeprecated = false;

  for (let i = 0; i < lines.length; i++) {
    const trimmed = lines[i].trim();
    if (trimmed.startsWith("///")) {
      pendingDoc.push(trimmed.replace(/^\/\/\/\s?/, ""));
      if (/deprecated/i.test(trimmed)) {
        pendingDeprecated = true;
      }
      continue;
    }
    if (trimmed.startsWith("//!")) {
      continue;
    }
    if (!trimmed.startsWith("pub ")) {
      pendingDoc = [];
      pendingDeprecated = false;
      continue;
    }

    let signature = trimmed;
    let end = i;
    while (
      !/[;={]/.test(signature) && end + 1 < lines.length &&
      signature.length < 420
    ) {
      end++;
      signature += ` ${lines[end].trim()}`;
    }

    const name = signature.match(
      /pub\s+(?:const|var|fn|type|usingnamespace)\s+([A-Za-z_][A-Za-z0-9_]*)/,
    )?.[1] ??
      signature.match(/pub\s+([A-Za-z_][A-Za-z0-9_]*)/)?.[1] ??
      signature;
    const deprecated = pendingDeprecated || /deprecated/i.test(signature);
    const doc = pendingDoc.join(" ").trim();
    const priorityIndex = module.priority.indexOf(name);
    decls.push({
      name,
      signature,
      doc,
      deprecated,
      priority: priorityIndex >= 0 ? priorityIndex : 1_000_000,
    });
    pendingDoc = [];
    pendingDeprecated = false;
    i = end;
  }

  decls.sort((a, b) =>
    a.priority - b.priority || Number(a.deprecated) - Number(b.deprecated) ||
    a.name.localeCompare(b.name)
  );

  const maxDecls = module.maxDecls ?? 10;
  for (const decl of decls.slice(0, maxDecls)) {
    sections.push({
      moduleId,
      moduleLabel: module.label,
      title: decl.name,
      signature: decl.signature,
      doc: decl.doc,
      deprecated: decl.deprecated,
      priority: decl.priority,
    });
  }

  // sourceUrl is retained for diagnostic use but not part of StdlibSection.
  void sourceUrl;

  return sections;
}

export async function loadStdlibSections(
  config: Config,
  options: { force?: boolean } = {},
): Promise<StdlibSection[]> {
  if (Object.keys(config.stdlibModules).length === 0) {
    return [];
  }

  const cachePath = join(config.cacheDir, "stdlib_zig_0_16_0.json");
  if (!options.force) {
    const cached = await readJsonCache<StdlibSection[]>(cachePath);
    if (cached) {
      return cached;
    }
  }

  let stdDir = "";
  try {
    const env = await runZigEnv();
    stdDir = env.stdDir;
  } catch (error) {
    console.error(
      `[koba-lumina] warning: zig env failed for stdlib load: ${
        error instanceof Error ? error.message : String(error)
      }`,
    );
  }
  if (!stdDir) {
    return [];
  }

  const parsed: StdlibSection[] = [];
  for (const [moduleId, module] of Object.entries(config.stdlibModules)) {
    const filePath = join(stdDir, module.url);
    let text: string;
    try {
      text = await Deno.readTextFile(filePath);
    } catch (error) {
      if (error instanceof Deno.errors.NotFound) {
        console.error(
          `[koba-lumina] warning: stdlib module ${moduleId} not found at ${filePath}, skipping`,
        );
        continue;
      }
      throw error;
    }
    parsed.push(...parseStdlibSource(moduleId, module, text, filePath));
  }

  await writeJsonCache(cachePath, parsed);
  return parsed;
}

// ---------------------------------------------------------------------------
// Reference docs
// ---------------------------------------------------------------------------

function parseSectionsFromHtmlOrMarkdown(
  input: string,
  sourceUrl: string,
): DocsSection[] {
  const cleaned = normalizeWhitespace(input);
  const lines = cleaned.split("\n");
  const sections: DocsSection[] = [];
  let currentTitle = "Overview";
  let buffer: string[] = [];
  let codeBuffer: string[] = [];
  let inCode = false;

  const flush = () => {
    const content = buffer.join("\n").trim();
    const code = codeBuffer.join("\n").trim();
    if (content || code) {
      sections.push({
        title: currentTitle,
        content,
        code: code || undefined,
        sourceUrl,
      });
    }
    buffer = [];
    codeBuffer = [];
  };

  for (const line of lines) {
    const fence = line.match(/^```/);
    if (fence) {
      inCode = !inCode;
      continue;
    }
    if (inCode) {
      codeBuffer.push(line);
      continue;
    }
    const heading = line.match(/^(#{1,6})\s+(.+)$/)?.[2]?.trim();
    if (heading) {
      flush();
      currentTitle = heading;
      continue;
    }
    const htmlHeading = line.match(/<h[1-6][^>]*>([\s\S]*?)<\/h[1-6]>/i)?.[1];
    if (htmlHeading) {
      flush();
      currentTitle = stripHtmlTags(htmlHeading);
      continue;
    }
    buffer.push(stripHtmlTags(line));
  }
  flush();

  if (sections.length === 0) {
    sections.push({
      title: basename(sourceUrl).replace(/\.[^.]+$/, ""),
      content: stripHtmlTags(cleaned),
      sourceUrl,
    });
  }
  return sections;
}

export async function loadReferenceSections(
  config: Config,
  options: { force?: boolean } = {},
): Promise<DocsSection[]> {
  const cachePath = join(config.cacheDir, "docs_zig_0_16_0.json");
  if (!options.force) {
    const cached = await readJsonCache<DocsSection[]>(cachePath);
    if (cached) {
      return cached;
    }
  }

  if (!config.referenceUrl) {
    return [];
  }

  const response = await fetchWithRetry(config.referenceUrl);
  if (!response.ok) {
    throw new Error(
      `Failed to fetch reference docs: ${response.status} ${response.statusText}`,
    );
  }
  const text = await response.text();
  const sections = parseSectionsFromHtmlOrMarkdown(text, config.referenceUrl);
  await writeJsonCache(cachePath, sections);
  return sections;
}

// ---------------------------------------------------------------------------
// Reference doc search
// ---------------------------------------------------------------------------

function tokenize(input: string): string[] {
  return input
    .toLowerCase()
    .replace(/[^a-z0-9_+.-]+/g, " ")
    .split(/\s+/)
    .filter((token) => token.length > 1 && !STOPWORDS[token]);
}

function scoreSection(
  section: DocsSection,
  queryTokens: string[],
  rawQuery?: string,
): number {
  const titleTokens = tokenize(section.title);
  const codeTokens = tokenize(section.code ?? "");
  const contentTokens = tokenize(section.content);
  const titleScore = queryTokens.reduce(
    (score, token) => score + (titleTokens.includes(token) ? 5 : 0),
    0,
  );
  const codeScore = queryTokens.reduce(
    (score, token) => score + (codeTokens.includes(token) ? 3 : 0),
    0,
  );
  const contentScore = queryTokens.reduce(
    (score, token) => score + (contentTokens.includes(token) ? 1 : 0),
    0,
  );
  let score = titleScore + codeScore + contentScore;
  if (rawQuery && rawQuery.trim().length > 2) {
    const lowerQuery = rawQuery.toLowerCase();
    if (section.title.toLowerCase().includes(lowerQuery)) {
      score += 10;
    } else if (section.content.toLowerCase().includes(lowerQuery)) {
      score += 4;
    }
  }
  return score;
}

export function searchLangDocs(
  sections: DocsSection[],
  query: string | string[],
  limit = 5,
): DocsSection[] {
  const queries = Array.isArray(query) ? query : [query];
  if (queries.length === 0) return [];

  if (queries.length === 1) {
    const queryTokens = tokenize(queries[0]);
    return sections
      .map((section) => ({
        ...section,
        score: scoreSection(section, queryTokens, queries[0]),
      }))
      .filter((section) => section.score && section.score > 0)
      .sort((a, b) =>
        (b.score ?? 0) - (a.score ?? 0) || a.title.localeCompare(b.title)
      )
      .slice(0, limit);
  }

  const rrfScores = new Map<DocsSection, { rrf: number; raw: number }>();

  for (const q of queries) {
    const tokens = tokenize(q);
    if (tokens.length === 0) continue;

    const scored = sections
      .map((sec) => ({ section: sec, score: scoreSection(sec, tokens, q) }))
      .filter((item) => item.score > 0)
      .sort((a, b) =>
        b.score - a.score || a.section.title.localeCompare(b.section.title)
      );

    for (let rank = 0; rank < scored.length; rank++) {
      const { section, score } = scored[rank];
      const current = rrfScores.get(section) ?? { rrf: 0, raw: 0 };
      current.rrf += 1 / (60 + rank + 1);
      current.raw += score;
      rrfScores.set(section, current);
    }
  }

  const combined = Array.from(rrfScores.entries()).map((
    [section, { rrf, raw }],
  ) => ({
    ...section,
    score: raw,
    rrfScore: rrf,
  }));

  return combined
    .sort((a, b) =>
      b.rrfScore - a.rrfScore || (b.score ?? 0) - (a.score ?? 0) ||
      a.title.localeCompare(b.title)
    )
    .slice(0, limit);
}

// ---------------------------------------------------------------------------
// Previous lessons
// ---------------------------------------------------------------------------

/**
 * Parse a Vulkan tutorial URL into a sortable position tuple.
 * URLs look like:
 *   .../tutorial/latest/04_Vertex_buffers/00_Vertex_input_description.html
 *   .../tutorial/latest/02_Drawing_a_triangle/01_Presentation/00_Swap_chain.html
 * Returns an array of section numbers extracted from path segments.
 * Falls back to [] for non-tutorial sources (local files, other URLs).
 */
export function parseTutorialPosition(source: string): number[] {
  let url: URL;
  try {
    url = new URL(source);
  } catch {
    return [];
  }
  const segments = url.pathname.split("/").filter(Boolean);
  const positions: number[] = [];
  for (const seg of segments) {
    const match = seg.match(/^(\d+)/);
    if (match) {
      positions.push(Number.parseInt(match[1], 10));
    }
  }
  return positions;
}

/**
 * Compare two tutorial position tuples lexicographically.
 * Returns negative if a comes before b, positive if after, 0 if equal.
 * Shorter prefixes that match are considered earlier (e.g. [2] < [2, 1]).
 */
function comparePositions(a: number[], b: number[]): number {
  const len = Math.min(a.length, b.length);
  for (let i = 0; i < len; i++) {
    if (a[i] !== b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

/** Extract the lumina-source metadata URL from a translated lesson file. */
function extractSourceUrl(content: string): string | null {
  const match = content.match(
    /<!--\s*lumina-source:\s*(\S+)\s*-->/,
  );
  return match?.[1] ?? null;
}

export async function loadPreviousLessons(
  docsDir: string,
  maxLessons: number,
  maxBytes: number,
  currentSource?: string,
): Promise<PreviousLesson[]> {
  const entries: Array<{
    path: string;
    name: string;
    content: string;
    sourceUrl: string | null;
    position: number[];
    mtime: number;
  }> = [];

  try {
    for await (const entry of Deno.readDir(docsDir)) {
      if (!entry.isFile || !entry.name.toLowerCase().endsWith(".md")) {
        continue;
      }
      const fullPath = join(docsDir, entry.name);
      const stat = await Deno.stat(fullPath);
      const content = await Deno.readTextFile(fullPath);
      const sourceUrl = extractSourceUrl(content);
      const position = sourceUrl ? parseTutorialPosition(sourceUrl) : [];
      entries.push({
        path: fullPath,
        name: entry.name,
        content,
        sourceUrl,
        position,
        mtime: stat.mtime?.getTime() ?? 0,
      });
    }
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      return [];
    }
    throw error;
  }

  // If we know the current lesson's position, select lessons that come
  // before it in tutorial order. Otherwise fall back to most-recently-modified.
  let selected: typeof entries;
  const currentPosition = currentSource
    ? parseTutorialPosition(currentSource)
    : [];

  if (currentPosition.length > 0) {
    // Sort by tutorial position, then pick the N lessons immediately before
    // the current one.
    const ordered = entries
      .filter((e) => e.position.length > 0)
      .sort((a, b) => comparePositions(a.position, b.position));

    const before = ordered.filter((e) =>
      comparePositions(e.position, currentPosition) < 0
    );
    selected = before.slice(-maxLessons);
  } else {
    // No tutorial position for current source — use most recent by mtime.
    selected = entries
      .sort((a, b) => b.mtime - a.mtime)
      .slice(0, maxLessons);
  }

  const lessons: PreviousLesson[] = [];
  for (const entry of selected) {
    let content = entry.content;
    const title = content.match(/^#\s+(.+)$/m)?.[1]?.trim() ??
      entry.name.replace(/\.md$/i, "");
    let bytes = new TextEncoder().encode(content).length;
    if (bytes > maxBytes) {
      const encoder = new TextEncoder();
      const encoded = encoder.encode(content);
      content = new TextDecoder().decode(encoded.slice(0, maxBytes));
      content = `${content}\n\n[truncated after ${maxBytes} bytes]\n`;
      bytes = maxBytes;
    }
    lessons.push({
      filename: entry.name,
      title,
      sourceUrl: entry.sourceUrl ?? "",
      content,
    });
  }
  return lessons;
}

// ---------------------------------------------------------------------------
// Orchestration
// ---------------------------------------------------------------------------

export async function gatherProjectContext(
  config: Config,
  options: {
    force?: boolean;
    noProject?: boolean;
    noLessons?: boolean;
    currentSource?: string;
  } = {},
): Promise<ProjectContext> {
  const versions = await detectVersions(config);

  let files: ProjectFile[] = [];
  let contextMd = "";

  // Always read contextFile for contextMd — it's the ground truth conventions.
  try {
    contextMd = await Deno.readTextFile(config.contextFile);
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) {
      console.error(
        `[koba-lumina] warning: could not read context file ${config.contextFile}: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
  }

  if (!options.noProject) {
    files = await scanProjectFiles(config.kobaRoot, config);
    // Ensure CONTEXT.md is present as a priority -1 ProjectFile when it exists.
    if (contextMd) {
      const contextBytes = new TextEncoder().encode(contextMd).length;
      const alreadyPresent = files.some(
        (f) =>
          f.relativePath.toLowerCase() === "context.md" ||
          f.relativePath.toLowerCase().endsWith("/context.md"),
      );
      if (!alreadyPresent) {
        files.unshift({
          relativePath: basename(config.contextFile),
          content: contextMd,
          bytes: contextBytes,
          truncated: false,
          priority: -1,
        });
      }
    }
  }

  const stdlibSections = await loadStdlibSections(config, {
    force: options.force,
  });
  const referenceSections = await loadReferenceSections(config, {
    force: options.force,
  });

  const previousLessons = options.noLessons ? [] : await loadPreviousLessons(
    config.docsDir,
    config.maxPreviousLessons,
    config.previousLessonMaxBytes,
    options.currentSource,
  );

  return {
    files,
    versions,
    contextMd,
    stdlibSections,
    referenceSections,
    previousLessons,
  };
}
