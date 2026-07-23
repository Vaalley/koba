// Shared types for the lumina translator.

export interface CodeBlock {
  heading: string;
  language: string;
  code: string;
}

export interface LessonPage {
  source: string;
  title: string;
  rawText: string;
  codeBlocks: CodeBlock[];
}

export interface ProjectFile {
  relativePath: string;
  content: string;
  bytes: number;
  truncated: boolean;
  priority: number;
}

export interface VersionInfo {
  zig: string;
  zigStdDir: string;
  vulkanSdk: string;
  sdl3: string;
}

export interface StdlibSection {
  moduleId: string;
  moduleLabel: string;
  title: string;
  signature: string;
  doc: string;
  deprecated: boolean;
  priority: number;
}

export interface DocsSection {
  title: string;
  content: string;
  code?: string;
  sourceUrl: string;
  score?: number;
}

export interface PreviousLesson {
  filename: string;
  title: string;
  sourceUrl: string;
  content: string;
}

export interface ProjectContext {
  files: ProjectFile[];
  versions: VersionInfo;
  contextMd: string;
  stdlibSections: StdlibSection[];
  referenceSections: DocsSection[];
  previousLessons: PreviousLesson[];
}

export interface AnalysisResult {
  features: string[];
  concepts: string[];
  modules: string[];
}
