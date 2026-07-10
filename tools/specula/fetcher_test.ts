import { assert, assertArrayIncludes, assertEquals } from "@std/assert";
import { join } from "@std/path";
import {
  analyzeSourceFeatures,
  decodeHtmlEntities,
  extractCodeBlocks,
  getRelevantStdlib,
  loadReferenceSections,
  parseStdlibSource,
  scanProjectFiles,
  searchLangDocs,
} from "./fetcher.ts";
import { KOBA_CONFIG } from "./config.ts";

Deno.test("decodeHtmlEntities decodes named and numeric entities", () => {
  assertEquals(decodeHtmlEntities("A &amp; B &#x43; &#67;"), "A & B C C");
});

Deno.test("extractCodeBlocks extracts markdown blocks with headings", () => {
  const blocks = extractCodeBlocks(
    `# Chapter\n\n## Example\n\n\`\`\`ts\nconsole.log(1);\n\`\`\``,
  );
  assertEquals(blocks.length, 1);
  assertEquals(blocks[0].heading, "Example");
  assertEquals(blocks[0].language, "ts");
  assertEquals(blocks[0].code, "console.log(1);");
});

Deno.test("feature analysis returns config-driven concepts and modules", () => {
  const result = analyzeSourceFeatures(
    [{
      heading: "Example",
      language: "cpp",
      code: "std::vector<int> items; throw std::runtime_error{};",
    }],
    KOBA_CONFIG,
  );
  assertArrayIncludes(result.features, [
    "dynamic arrays",
    "exception-style error handling",
  ]);
  assertArrayIncludes(result.modules, [
    "array_list",
    "allocator",
    "mem",
    "log",
    "debug",
  ]);
  assert(result.concepts.includes("error handling"));
});

Deno.test("stdlib parser orders prioritized declarations first", () => {
  const source = `//! module docs

/// lower priority
pub fn zed() void {}

/// important
pub fn alpha() void {}

/// deprecated
pub fn oldThing() void {}
`;
  const sections = parseStdlibSource(
    "demo",
    { url: "demo.zig", label: "Demo", priority: ["alpha", "zed"], maxDecls: 3 },
    source,
    "https://example.com/demo.zig",
  );
  assertEquals(sections[0].title, "Demo module");
  assertEquals(sections[1].title, "alpha");
  assertEquals(sections[2].title, "zed");
  assertEquals(sections[3].title, "oldThing");
});

Deno.test("reference search scores title matches above content matches", () => {
  const results = searchLangDocs(
    [
      {
        title: "Array Lists",
        content: "general containers",
        sourceUrl: "cache",
      },
      {
        title: "Memory",
        content: "array list and allocator",
        sourceUrl: "cache",
      },
      { title: "Other", content: "unrelated", sourceUrl: "cache" },
    ],
    "array list allocator",
    2,
  );
  assertEquals(results.length, 2);
  assertEquals(results[0].title, "Array Lists");
  assertEquals(results[1].title, "Memory");
});

Deno.test("project scanning prunes ignored dirs and respects budgets", async () => {
  const root = await Deno.makeTempDir();
  await Deno.mkdir(join(root, "src"), { recursive: true });
  await Deno.mkdir(join(root, "node_modules", "pkg"), { recursive: true });
  await Deno.writeTextFile(join(root, "build.zig"), "build file");
  await Deno.writeTextFile(
    join(root, "src", "main.zig"),
    "pub fn main() void {}\n",
  );
  await Deno.writeTextFile(join(root, "src", "notes.md"), "# notes\n");
  await Deno.writeTextFile(
    join(root, "node_modules", "pkg", "skip.ts"),
    "skip",
  );
  const files = await scanProjectFiles(root, KOBA_CONFIG, {
    maxBytesPerFile: 200,
    maxTotalBytes: 1_000,
    maxFiles: 3,
  });
  assertEquals(files[0].relativePath, "build.zig");
  assertEquals(files[1].relativePath, "src/main.zig");
  assertEquals(
    files.every((file) => !file.relativePath.includes("node_modules")),
    true,
  );
});

Deno.test("reference cache can be loaded from disk", async () => {
  const cacheDir = await Deno.makeTempDir();
  await Deno.mkdir(join(cacheDir, ".cache"), { recursive: true });
  const cachePath = join(cacheDir, ".cache", "zig_docs_0.16.0.json");
  await Deno.writeTextFile(
    cachePath,
    JSON.stringify(
      [{ title: "Alpha", content: "beta array list", sourceUrl: "cache" }],
      null,
      2,
    ),
  );
  const sections = await loadReferenceSections(KOBA_CONFIG, {
    cacheRoot: cacheDir,
  });
  assertEquals(sections.length, 1);
  assertEquals(sections[0].title, "Alpha");
});

Deno.test("stdlib cache can be loaded from disk", async () => {
  const cacheDir = await Deno.makeTempDir();
  await Deno.mkdir(join(cacheDir, ".cache"), { recursive: true });
  const cachePath = join(cacheDir, ".cache", "zig_stdlib_0.16.0.json");
  await Deno.writeTextFile(
    cachePath,
    JSON.stringify(
      [
        {
          moduleId: "mem",
          moduleLabel: "mem",
          title: "copy",
          signature: "pub fn copy(...) void;",
          doc: "copy docs",
          deprecated: false,
          priority: 0,
          sourceUrl: "cache",
        },
      ],
      null,
      2,
    ),
  );
  const sections = await getRelevantStdlib(KOBA_CONFIG, ["mem"], {
    cacheRoot: cacheDir,
  });
  assertEquals(sections.length, 1);
  assertEquals(sections[0].title, "copy");
});
