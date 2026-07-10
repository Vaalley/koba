import { assertEquals, assertStringIncludes } from "@std/assert";
import { buildSystemPrompt, buildUserPrompt, estimateTokens } from "./llm.ts";
import { fetchLessonPage } from "./fetcher.ts";
import { KOBA_CONFIG } from "./config.ts";

Deno.test("prompt assembly keeps required ordering", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = () =>
    Promise.resolve(
      new Response(`# Lesson\n\n## Intro\n\n\`\`\`cpp\nint main() {}\n\`\`\``),
    );
  try {
    const lesson = await fetchLessonPage("https://example.com/lesson");
    const user = buildUserPrompt({
      config: KOBA_CONFIG,
      lesson,
      projectFiles: [
        {
          path: "/tmp/project/main.ts",
          relativePath: "main.ts",
          content: "console.log('hi');",
          bytes: 18,
          truncated: false,
          priority: 0,
        },
      ],
      stdlibSections: [
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
      referenceSections: [
        { title: "Pointers", content: "pointer docs", sourceUrl: "cache" },
      ],
    });

    assertStringIncludes(user, "# Lesson");
    assertStringIncludes(user, "## Project codebase");
    assertStringIncludes(user, "## Source-language code blocks");
    assertStringIncludes(user, "## Target-language stdlib API signatures");
    assertStringIncludes(user, "## Target-language reference sections");
    assertStringIncludes(user, "## Closing instruction");

    const system = buildSystemPrompt(KOBA_CONFIG);
    assertStringIncludes(system, "patient expert teacher");
    assertStringIncludes(system, "Title, Overview, Concepts & Explanations");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("estimateTokens uses the 4 chars per token heuristic", () => {
  assertEquals(estimateTokens(""), 0);
  assertEquals(estimateTokens("abcd"), 1);
  assertEquals(estimateTokens("abcde"), 2);
});
