// LLM client for the lumina translator.
// Calls the OpenRouter chat completions API to translate a lesson.

import { fetchWithRetry } from "./fetcher.ts";

/** Input for a translation request. */
export interface TranslateLessonInput {
  system: string;
  user: string;
  apiKey: string;
  model: string;
  temperature: number;
  endpoint: string;
  extraHeaders: Record<string, string>;
  stream?: boolean;
  onChunk?: (chunk: string) => void;
}

/**
 * Call the OpenRouter chat completions API and return the translated lesson.
 * Supports both streaming (SSE) and non-streaming responses.
 */
export async function translateLesson(
  input: TranslateLessonInput,
): Promise<string> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${input.apiKey}`,
    ...input.extraHeaders,
  };

  const body = JSON.stringify({
    model: input.model,
    temperature: input.temperature,
    messages: [
      { role: "system", content: input.system },
      { role: "user", content: input.user },
    ],
    ...(input.stream ? { stream: true } : {}),
  });

  const response = await fetchWithRetry(input.endpoint, {
    method: "POST",
    headers,
    body,
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(
      `LLM request failed: ${response.status} ${response.statusText} ${errorText}`
        .trim(),
    );
  }

  if (input.stream) {
    return await readStream(response, input.onChunk);
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

/**
 * Read an SSE streaming response, invoking onChunk for each content delta and
 * returning the accumulated content. Handles the `[DONE]` sentinel.
 */
async function readStream(
  response: Response,
  onChunk?: (chunk: string) => void,
): Promise<string> {
  if (!response.body) {
    throw new Error("LLM streaming response did not include a body");
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let content = "";

  const processLine = (line: string): void => {
    const trimmed = line.trimEnd();
    if (!trimmed.startsWith("data: ")) return;
    const data = trimmed.slice("data: ".length);
    if (data === "[DONE]") return;
    try {
      const json = JSON.parse(data) as {
        choices?: Array<{ delta?: { content?: string } }>;
      };
      const delta = json.choices?.[0]?.delta?.content;
      if (delta) {
        onChunk?.(delta);
        content += delta;
      }
    } catch {
      // Ignore malformed or partial JSON line frames.
    }
  };

  while (true) {
    const { value, done } = await reader.read();
    if (value) {
      buffer += decoder.decode(value, { stream: !done });
    }

    let newlineIndex = buffer.indexOf("\n");
    while (newlineIndex !== -1) {
      const line = buffer.slice(0, newlineIndex);
      buffer = buffer.slice(newlineIndex + 1);
      processLine(line);
      newlineIndex = buffer.indexOf("\n");
    }

    if (done) break;
  }

  // Flush any trailing line that lacked a final newline.
  if (buffer.length > 0) {
    processLine(buffer);
  }

  if (!content) {
    throw new Error("LLM response did not include message content");
  }
  return content;
}
