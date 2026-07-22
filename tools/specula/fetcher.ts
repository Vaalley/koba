import { basename, join, relative, resolve } from "@std/path";
import type { Config, StdlibModule } from "./config.ts";

export interface CodeBlock {
  heading: string;
  language: string;
  code: string;
}

export interface LessonPage {
  title: string;
  rawText: string;
  codeBlocks: CodeBlock[];
  source: string;
}

export interface AnalysisResult {
  features: string[];
  concepts: string[];
  modules: string[];
}

export interface DocsSection {
  title: string;
  content: string;
  code?: string;
  sourceUrl: string;
  score?: number;
}

export interface StdlibSection {
  moduleId: string;
  moduleLabel: string;
  title: string;
  signature: string;
  doc: string;
  deprecated: boolean;
  priority: number;
  sourceUrl: string;
}

export interface ProjectFile {
  path: string;
  relativePath: string;
  content: string;
  bytes: number;
  truncated: boolean;
  priority: number;
}

export interface RetrievalBudgets {
  maxBytesPerFile?: number;
  maxTotalBytes?: number;
  maxFiles?: number;
  referenceLimit?: number;
  stdlibLimit?: number;
}

const STOPWORDS = new Set([
  "a",
  "an",
  "and",
  "as",
  "at",
  "by",
  "for",
  "from",
  "how",
  "in",
  "into",
  "is",
  "of",
  "on",
  "or",
  "the",
  "to",
  "with",
  "what",
  "when",
  "where",
  "why",
  "which",
  "that",
  "this",
  "these",
  "those",
  "use",
  "using",
]);

const BASELINE_CONCEPTS = [
  "error handling",
  "resource cleanup",
  "containers",
  "strings",
  "imports",
  "iteration",
];

export function decodeHtmlEntities(input: string): string {
  const named: Record<string, string> = {
    amp: "&",
    lt: "<",
    gt: ">",
    quot: '"',
    apos: "'",
    nbsp: " ",
  };

  return input
    .replace(
      /&#x([0-9a-f]+);/gi,
      (_, hex: string) => String.fromCodePoint(Number.parseInt(hex, 16)),
    )
    .replace(
      /&#([0-9]+);/g,
      (_, dec: string) => String.fromCodePoint(Number.parseInt(dec, 10)),
    )
    .replace(/&([a-z]+);/gi, (_, name: string) => named[name] ?? `&${name};`);
}

function stripHtmlTags(input: string): string {
  return decodeHtmlEntities(
    input
      .replace(/<script[\s\S]*?<\/script>/gi, " ")
      .replace(/<style[\s\S]*?<\/style>/gi, " ")
      .replace(/<\/(p|div|section|article|li|h[1-6]|pre|code)>/gi, "\n")
      .replace(/<br\s*\/?>/gi, "\n")
      .replace(/<[^>]+>/g, " "),
  )
    .replace(/\r/g, "")
    .replace(/[ \t]+/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function normalizeWhitespace(input: string): string {
  return input.replace(/\r\n/g, "\n").replace(/[ \t]+\n/g, "\n");
}

function headingForLine(lines: string[], index: number): string {
  for (let i = index - 1; i >= 0; i--) {
    const line = lines[i].trim();
    if (/^#{1,6}\s+/.test(line)) {
      return line.replace(/^#{1,6}\s+/, "").trim();
    }
  }
  return "";
}

function parseMarkdownCodeBlocks(input: string): CodeBlock[] {
  const lines = normalizeWhitespace(input).split("\n");
  const blocks: CodeBlock[] = [];
  let inBlock = false;
  let language = "";
  let startLine = 0;
  let buffer: string[] = [];

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const fence = line.match(/^```([^\s`]*)\s*$/);
    if (fence) {
      if (!inBlock) {
        inBlock = true;
        language = fence[1] || "";
        startLine = i;
        buffer = [];
      } else {
        blocks.push({
          heading: headingForLine(lines, startLine),
          language,
          code: buffer.join("\n").trim(),
        });
        inBlock = false;
        language = "";
      }
      continue;
    }
    if (inBlock) {
      buffer.push(line);
    }
  }
  return blocks;
}

function parseHtmlCodeBlocks(input: string): CodeBlock[] {
  const blocks: CodeBlock[] = [];
  const pattern = /<pre[^>]*>\s*<code([^>]*)>([\s\S]*?)<\/code>\s*<\/pre>/gi;
  const lines = input.split(/\r?\n/);
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(input)) !== null) {
    const attrs = match[1] ?? "";
    const classMatch = attrs.match(
      /class=["'][^"']*language-([a-z0-9_+-]+)[^"']*["']/i,
    );
    const before = input.slice(0, match.index);
    const headingMatches = [
      ...before.matchAll(/<h[1-6][^>]*>([\s\S]*?)<\/h[1-6]>/gi),
    ];
    const heading = headingMatches.length
      ? stripHtmlTags(headingMatches[headingMatches.length - 1][1])
      : "";
    blocks.push({
      heading,
      language: classMatch?.[1] ?? "",
      code: decodeHtmlEntities(match[2]).replace(/^\n+|\n+$/g, "").trim(),
    });
  }
  if (blocks.length === 0 && lines.length > 1) {
    return parseMarkdownCodeBlocks(stripHtmlTags(input));
  }
  return blocks;
}

export function extractCodeBlocks(input: string): CodeBlock[] {
  const trimmed = input.trim();
  if (/<pre[\s>]/i.test(trimmed) || /<code[\s>]/i.test(trimmed)) {
    return parseHtmlCodeBlocks(trimmed);
  }
  return parseMarkdownCodeBlocks(trimmed);
}

function parseTitleFromMarkdown(input: string, fallback: string): string {
  const title = input.match(/^#\s+(.+)$/m)?.[1]?.trim();
  return title ?? fallback;
}

function parseTitleFromHtml(input: string, fallback: string): string {
  return (
    stripHtmlTags(input.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1] ?? "") ||
    stripHtmlTags(input.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i)?.[1] ?? "") ||
    fallback
  );
}

const DEFAULT_USER_AGENT =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) koba-specula/0.1.0";

export async function fetchWithRetry(
  url: string | URL,
  init?: RequestInit,
  retries = 3,
  backoffMs = 500,
): Promise<Response> {
  const headers = new Headers(init?.headers);
  if (!headers.has("User-Agent")) {
    headers.set("User-Agent", DEFAULT_USER_AGENT);
  }
  const requestInit = { ...init, headers };

  let lastError: Error | null = null;
  for (let attempt = 0; attempt < retries; attempt++) {
    try {
      const response = await fetch(url, requestInit);
      if (
        response.ok ||
        (response.status >= 400 &&
          response.status < 500 &&
          response.status !== 429)
      ) {
        return response;
      }
      lastError = new Error(`HTTP ${response.status} ${response.statusText}`);
    } catch (err) {
      lastError = err instanceof Error ? err : new Error(String(err));
    }
    if (attempt < retries - 1) {
      await new Promise((res) =>
        setTimeout(res, backoffMs * Math.pow(2, attempt))
      );
    }
  }
  throw lastError ?? new Error(`Failed to fetch ${url}`);
}
async function readSourceText(source: string): Promise<string> {
  if (/^https?:\/\//i.test(source)) {
    const response = await fetchWithRetry(source);
    if (!response.ok) {
      throw new Error(
        `Failed to fetch ${source}: ${response.status} ${response.statusText}`,
      );
    }
    return await response.text();
  }
  return await Deno.readTextFile(source);
}

export async function fetchLessonPage(source: string): Promise<LessonPage> {
  const text = await readSourceText(source);
  const isHtml = /\.(html?|xhtml)$/i.test(source) || /<html[\s>]/i.test(text);
  const isMarkdown = /\.md$/i.test(source) || /\.markdown$/i.test(source);
  const codeBlocks = extractCodeBlocks(text);
  const title = isHtml
    ? parseTitleFromHtml(text, basename(source).replace(/\.[^.]+$/, ""))
    : parseTitleFromMarkdown(text, basename(source).replace(/\.[^.]+$/, ""));
  const rawText = isHtml
    ? stripHtmlTags(text)
    : normalizeWhitespace(text).trim();
  return {
    source,
    title: title || basename(source),
    rawText: isMarkdown ? normalizeWhitespace(text).trim() : rawText,
    codeBlocks,
  };
}

function uniq(values: string[]): string[] {
  return [...new Set(values.filter(Boolean))];
}

export function analyzeSourceFeatures(
  codeBlocks: CodeBlock[],
  config: Config,
): AnalysisResult {
  const joined = codeBlocks.map((block) => `${block.heading}\n${block.code}`)
    .join("\n");
  const features: string[] = [];
  const concepts: string[] = [...BASELINE_CONCEPTS];
  const modules: string[] = [];

  for (const rule of config.featureRules) {
    const regex = new RegExp(rule.pattern, "mi");
    if (regex.test(joined)) {
      features.push(rule.feature);
      concepts.push(...rule.concepts);
      modules.push(...rule.modules);
    }
  }

  return {
    features: uniq(features),
    concepts: uniq(concepts),
    modules: uniq(modules),
  };
}

function tokenize(input: string): string[] {
  return input
    .toLowerCase()
    .replace(/[^a-z0-9_+.-]+/g, " ")
    .split(/\s+/)
    .filter((token) => token.length > 1 && !STOPWORDS.has(token));
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

function cacheRootPath(cacheRoot?: string): string {
  return resolve(cacheRoot ?? Deno.cwd(), ".cache");
}

function cacheFileName(
  kind: string,
  language: string,
  version: string,
): string {
  const safeLanguage = language.toLowerCase().replace(/[^a-z0-9._-]+/g, "_");
  const safeVersion = version.toLowerCase().replace(/[^a-z0-9._-]+/g, "_");
  return `${safeLanguage}_${kind}_${safeVersion}.json`;
}

async function ensureCacheDir(cacheRoot?: string): Promise<string> {
  const dir = cacheRootPath(cacheRoot);
  await Deno.mkdir(dir, { recursive: true });
  return dir;
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
  await Deno.writeTextFile(path, `${JSON.stringify(value, null, 2)}\n`);
}

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
  options: { force?: boolean; cacheRoot?: string } = {},
): Promise<DocsSection[]> {
  const dir = await ensureCacheDir(options.cacheRoot);
  const path = join(
    dir,
    cacheFileName("docs", config.targetLanguage, config.targetVersion),
  );
  if (!options.force) {
    const cached = await readJsonCache<DocsSection[]>(path);
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
  await writeJsonCache(path, sections);
  return sections;
}

/**
 * Run `zig env` and parse the `.std_dir` field from the Zig struct output.
 */
async function getZigStdDir(): Promise<string> {
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
  const match = output.match(/\.std_dir\s*=\s*"((?:[^"\\]|\\.)*)"/);
  if (!match) {
    throw new Error(
      `Could not parse std_dir from zig env output: ${output.slice(0, 200)}`,
    );
  }
  return match[1].replace(/\\(.)/g, "$1");
}

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
      sourceUrl,
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
      sourceUrl,
    });
  }

  return sections;
}

export async function getRelevantStdlib(
  config: Config,
  moduleIds: string[],
  options: { force?: boolean; cacheRoot?: string; limit?: number } = {},
): Promise<StdlibSection[]> {
  if (Object.keys(config.stdlibModules).length === 0) {
    return [];
  }

  const dir = await ensureCacheDir(options.cacheRoot);
  const path = join(
    dir,
    cacheFileName("stdlib", config.targetLanguage, config.targetVersion),
  );
  let cached = options.force
    ? null
    : await readJsonCache<StdlibSection[]>(path);

  if (!cached) {
    const stdDir = await getZigStdDir();
    const parsed: StdlibSection[] = [];
    for (const [moduleId, module] of Object.entries(config.stdlibModules)) {
      const filePath = join(stdDir, module.url);
      let text: string;
      try {
        text = await Deno.readTextFile(filePath);
      } catch (error) {
        if (error instanceof Deno.errors.NotFound) {
          console.error(
            `[koba-specula] warning: stdlib module ${moduleId} not found at ${filePath}, skipping`,
          );
          continue;
        }
        throw error;
      }
      parsed.push(...parseStdlibSource(moduleId, module, text, filePath));
    }
    cached = parsed;
    await writeJsonCache(path, cached);
  }

  const selected = moduleIds.length
    ? cached.filter((section) => moduleIds.includes(section.moduleId))
    : cached;
  const limit = options.limit ?? 24;
  return selected.slice(0, limit);
}

function isIncludedFile(name: string, config: Config): boolean {
  const lower = name.toLowerCase();
  return config.projectIncludeNames.some((entry) =>
    entry.toLowerCase() === lower
  ) ||
    config.projectIncludeExt.some((ext) =>
      lower.endsWith(
        ext.startsWith(".") ? ext.toLowerCase() : `.${ext.toLowerCase()}`,
      )
    );
}

function filePriority(relPath: string, config: Config): number {
  const normalizedPath = relPath.replaceAll("\\", "/");
  const name = basename(normalizedPath).toLowerCase();
  if (
    config.projectFilePriority.contextNames?.some((entry) =>
      entry.toLowerCase() === name
    )
  ) {
    return -1;
  }
  if (
    config.projectFilePriority.buildNames.some((entry) =>
      entry.toLowerCase() === name
    )
  ) {
    return 0;
  }
  if (
    config.projectFilePriority.entrypointNames.some((entry) =>
      entry.toLowerCase() === name ||
      normalizedPath.toLowerCase().endsWith(`/${entry.toLowerCase()}`)
    )
  ) {
    return 1;
  }
  if (
    config.projectFilePriority.sourceDirPrefixes.some((entry) =>
      normalizedPath.toLowerCase().startsWith(entry.toLowerCase())
    )
  ) {
    return 2;
  }
  if (
    config.projectFilePriority.headerExts.some((ext) =>
      name.endsWith(ext.toLowerCase())
    )
  ) {
    return 4;
  }
  if (
    config.projectFilePriority.readmeNames.some((entry) =>
      entry.toLowerCase() === name
    )
  ) {
    return 5;
  }
  return 3;
}

async function readTextIfSmallEnough(path: string): Promise<string> {
  return await Deno.readTextFile(path);
}

export async function scanProjectFiles(
  root: string,
  config: Config,
  budgets: RetrievalBudgets = {},
): Promise<ProjectFile[]> {
  const normalizedRoot = resolve(root);
  const files: Array<
    { path: string; relativePath: string; priority: number; bytes: number }
  > = [];
  const ignoreDirs = new Set(
    config.projectIgnoreDirs.map((dir) => dir.toLowerCase()),
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
        priority: filePriority(relPath, config),
        bytes: stat.size,
      });
    }
  }

  await walk(normalizedRoot);
  files.sort((a, b) =>
    a.priority - b.priority || a.relativePath.localeCompare(b.relativePath)
  );

  const maxBytesPerFile = budgets.maxBytesPerFile ?? 12_000;
  const maxTotalBytes = budgets.maxTotalBytes ?? 40_000;
  const maxFiles = budgets.maxFiles ?? 12;
  const admitted: ProjectFile[] = [];
  let totalBytes = 0;

  for (const file of files) {
    if (admitted.length >= maxFiles || totalBytes >= maxTotalBytes) {
      break;
    }
    let content = await readTextIfSmallEnough(file.path);
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
      path: file.path,
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
