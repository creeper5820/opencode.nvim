import type { ToolDefinition } from "../../../opencode-plugin/src/tools.ts"

export interface FakeContextOptions {
  canonical: string
  directory?: string
  registryDir: string
  healthTimeoutMs?: number
  requestTimeoutMs?: number
}

export interface FakeContext {
  location: {
    directory: string
    project: { id: string; directory: string; canonical: string }
  }
  options: Record<string, unknown>
  tool: {
    transform(callback: (editor: FakeToolEditor) => void): Promise<{ dispose(): Promise<void> }>
  }
}

export interface FakeToolEditor {
  tools: Map<string, ToolDefinition>
  add(tool: ToolDefinition): void
}

export function makeContext(options: FakeContextOptions): { context: FakeContext; tools: Map<string, ToolDefinition> } {
  const tools = new Map<string, ToolDefinition>()
  const editor: FakeToolEditor = {
    tools,
    add(tool) {
      if (tools.has(tool.name)) throw new Error(`duplicate tool ${tool.name}`)
      tools.set(tool.name, tool)
    },
  }
  const context: FakeContext = {
    location: {
      directory: options.directory ?? options.canonical,
      project: { id: "project-test", directory: options.canonical, canonical: options.canonical },
    },
    options: {
      registryDir: options.registryDir,
      ...(options.healthTimeoutMs === undefined ? {} : { healthTimeoutMs: options.healthTimeoutMs }),
      ...(options.requestTimeoutMs === undefined ? {} : { requestTimeoutMs: options.requestTimeoutMs }),
    },
    tool: {
      async transform(callback) {
        callback(editor)
        return { async dispose() {} }
      },
    },
  }
  return { context, tools }
}
