import type {
  DocsSection,
  LessonPage,
  ProjectFile,
  StdlibSection,
} from "./fetcher.ts";
import { fetchWithRetry } from "./fetcher.ts";
import type { Config } from "./config.ts";
import { extname } from "@std/path";

// export const DEFAULT_MODEL = "anthropic/claude-sonnet-5";
export const DEFAULT_MODEL = "openai/gpt-5.6-luna-pro";

const DEFAULT_PROVIDER = {
  endpoint: "https://openrouter.ai/api/v1/chat/completions",
  headers: {
    "HTTP-Referer": "https://github.com/Vaalley/specula",
    "X-Title": "koba",
  },
};

interface PromptInput {
  config: Config;
  lesson: LessonPage;
  projectFiles?: ProjectFile[];
  stdlibSections?: StdlibSection[];
  referenceSections?: DocsSection[];
}

export function estimateTokens(text: string): number {
  return Math.ceil(text.length / 4);
}

export function estimatePromptTokens(system: string, user: string): number {
  return estimateTokens(system) + estimateTokens(user);
}

function formatProjectFiles(files: ProjectFile[], config: Config): string {
  return files
    .map((file) => {
      const fence = config
        .fenceLanguage[extname(file.relativePath).toLowerCase()] ??
        "text";
      return [
        `### ${file.relativePath}`,
        `\`\`\`${fence}`,
        file.content.trimEnd(),
        "```",
      ].join("\n");
    })
    .join("\n\n");
}

function formatCodeBlocks(lesson: LessonPage): string {
  return lesson.codeBlocks
    .map((block, index) => {
      const heading = block.heading || `Code block ${index + 1}`;
      const fence = block.language || "text";
      return [
        `### ${heading}`,
        `\`\`\`${fence}`,
        block.code.trimEnd(),
        "```",
      ].join("\n");
    })
    .join("\n\n");
}

function formatStdlibSections(sections: StdlibSection[]): string {
  return sections
    .map((section) => {
      const pieces = [
        `### ${section.moduleLabel}: ${section.title}`,
      ];
      if (section.signature) {
        pieces.push("```");
        pieces.push(section.signature.trimEnd());
        pieces.push("```");
      }
      if (section.doc) {
        pieces.push(section.doc.trimEnd());
      }
      return pieces.join("\n");
    })
    .join("\n\n");
}

function formatReferenceSections(sections: DocsSection[]): string {
  return sections
    .map((section) =>
      [`### ${section.title}`, section.content.trimEnd()].join("\n")
    )
    .join("\n\n");
}

export function buildSystemPrompt(config: Config): string {
  const fixedSections = [
    `You are a patient expert teacher translating a programming lesson from ${config.sourceLanguage} to ${config.targetLanguage} ${config.targetVersion}.`,
    "Teach the reader in plain language.",
    "Explain why before how.",
    "Call out trade-offs, edge cases, and likely confusion points.",
    "Connect new ideas back to the lesson's prior steps.",
    "Treat the provided project files as ground truth for imports, naming, module layout, and build setup.",
    "Extend the existing entrypoint instead of inventing a separate architecture.",
    "Use the supplied stdlib signatures as authoritative and match them exactly.",
    "Produce a single Markdown document with the required sections in order: Title, Overview, Concepts & Explanations, Code Translation Sections, Recap & What's Next.",
  ];

  return [
    ...fixedSections,
    ...(config.promptSections.length ? ["", ...config.promptSections] : []),
  ].join("\n");
}

export function buildUserPrompt(input: PromptInput): string {
  const sections: string[] = [
    `# ${input.lesson.title}`,
  ];

  if (input.projectFiles?.length) {
    sections.push(
      "## Project codebase",
      formatProjectFiles(input.projectFiles, input.config),
    );
  }

  sections.push(
    "## Source-language code blocks",
    formatCodeBlocks(input.lesson),
  );

  if (input.stdlibSections?.length) {
    sections.push(
      "## Target-language stdlib API signatures",
      formatStdlibSections(input.stdlibSections),
    );
  }

  if (input.referenceSections?.length) {
    sections.push(
      "## Target-language reference sections",
      formatReferenceSections(input.referenceSections),
    );
  }

  sections.push(
    "## Closing instruction",
    "Write the Markdown so it teaches the reader and produces one compilable target-language file that fits the supplied project.",
  );

  return sections.join("\n\n");
}

export function buildTranslationPrompts(input: PromptInput): {
  system: string;
  user: string;
} {
  return {
    system: buildSystemPrompt(input.config),
    user: buildUserPrompt(input),
  };
}

export async function translateLesson(
  input: PromptInput & {
    apiKey: string;
    model?: string;
    stream?: boolean;
    onChunk?: (chunk: string) => void;
  },
): Promise<string> {
  const provider = input.config.provider ?? DEFAULT_PROVIDER;
  const model = input.model ?? DEFAULT_MODEL;
  if (!input.apiKey) {
    throw new Error("Missing API key");
  }

  const { system, user } = buildTranslationPrompts(input);
  const response = await fetchWithRetry(provider.endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${input.apiKey}`,
      ...provider.headers,
    },
    body: JSON.stringify({
      model,
      temperature: input.config.temperature,
      ...(input.stream ? { stream: true } : {}),
      messages: [
        { role: "system", content: system },
        { role: "user", content: user },
      ],
    }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(
      `LLM request failed: ${response.status} ${response.statusText} ${errorText}`
        .trim(),
    );
  }

  if (input.stream) {
    if (!response.body) {
      throw new Error("LLM streaming response did not include a body");
    }

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    let content = "";

    while (true) {
      const { value, done } = await reader.read();
      if (value) {
        buffer += decoder.decode(value, { stream: !done });
      }

      let newlineIndex = buffer.indexOf("\n");
      while (newlineIndex !== -1) {
        const line = buffer.slice(0, newlineIndex).trimEnd();
        buffer = buffer.slice(newlineIndex + 1);
        if (line.startsWith("data: ")) {
          const data = line.slice("data: ".length);
          if (data !== "[DONE]") {
            try {
              const json = JSON.parse(data) as {
                choices?: Array<{ delta?: { content?: string } }>;
              };
              const delta = json.choices?.[0]?.delta?.content;
              if (delta) {
                input.onChunk?.(delta);
                content += delta;
              }
            } catch {
              // Ignore malformed or partial JSON line frame
            }
          }
        }
        newlineIndex = buffer.indexOf("\n");
      }

      if (done) {
        break;
      }
    }

    const trailing = buffer.trim();
    if (trailing.startsWith("data: ")) {
      const data = trailing.slice("data: ".length);
      if (data !== "[DONE]") {
        try {
          const json = JSON.parse(data) as {
            choices?: Array<{ delta?: { content?: string } }>;
          };
          const delta = json.choices?.[0]?.delta?.content;
          if (delta) {
            input.onChunk?.(delta);
            content += delta;
          }
        } catch {
          // Ignore malformed or partial JSON line frame
        }
      }
    }

    if (!content) {
      throw new Error("LLM response did not include message content");
    }
    return content;
  }

  const json = await response.json() as {
    choices?: Array<{ message?: { content?: string } }>;
  };
  const content = json.choices?.[0]?.message?.content;
  if (!content) {
    throw new Error("LLM response did not include message content");
  }
  return content;
}
