// Lesson fetching, HTML/markdown parsing, and code block extraction for lumina.

import { basename } from "@std/path";
import type { AnalysisResult, CodeBlock, LessonPage } from "./types.ts";
import type { Config } from "./config.ts";

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

export function stripHtmlTags(input: string): string {
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

export function normalizeWhitespace(input: string): string {
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

const DEFAULT_USER_AGENT =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) koba-lumina/0.1.0";

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
      const { promise, resolve: wake } = Promise.withResolvers<void>();
      setTimeout(wake, backoffMs * Math.pow(2, attempt));
      await promise;
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
  const fallback = basename(source).replace(/\.[^.]+$/, "");
  const title = isHtml
    ? (stripHtmlTags(
      text.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1] ?? "",
    ) ||
      stripHtmlTags(text.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i)?.[1] ?? "") ||
      fallback)
    : (text.match(/^#\s+(.+)$/m)?.[1]?.trim() ?? fallback);
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

export function analyzeFeatures(
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
