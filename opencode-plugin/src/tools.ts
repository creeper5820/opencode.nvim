import path from "node:path"
import type { Info } from "@opencode/plugin/promise/tool"
import { NeovimToolError } from "./errors.ts"
import { resolveProjectPaths } from "./paths.ts"
import {
  assertSingleInstance,
  defaultRegistryDir,
  describeNoInstance,
  matchingEntries,
} from "./registry.ts"
import { callAction, checkHealth } from "./rpc.ts"
import { redactToken } from "./redact.ts"

export type ActionName = "open" | "notify" | "diff"

export interface PluginConfig {
  registryDir: string
  healthTimeoutMs: number
  requestTimeoutMs: number
}

export interface PluginLocation {
  readonly directory?: string
  readonly project?: {
    readonly directory?: string
    readonly canonical?: string
  }
}

export interface ToolRuntime {
  readonly location: PluginLocation
  readonly signal?: AbortSignal
  readonly options: PluginConfig
}

const DEFAULT_HEALTH_TIMEOUT_MS = 1500
const DEFAULT_REQUEST_TIMEOUT_MS = 10_000
const MAX_TIMEOUT_MS = 120_000

function positiveTimeout(value: unknown, fallback: number): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) return fallback
  return Math.min(Math.max(1, Math.floor(value)), MAX_TIMEOUT_MS)
}

function cancelled(): NeovimToolError {
  return new NeovimToolError("CANCELLED", "Neovim tool call was cancelled.")
}

function throwIfAborted(signal: AbortSignal | undefined): void {
  if (signal?.aborted) throw cancelled()
}

export function resolveConfig(options: Readonly<Record<string, unknown>> | undefined): PluginConfig {
  const raw = options ?? {}
  const registryOverride =
    typeof raw.registryDir === "string"
      ? raw.registryDir
      : typeof raw.registry_dir === "string"
        ? raw.registry_dir
        : undefined
  if (registryOverride !== undefined && registryOverride.trim().length === 0) {
    throw new TypeError("opencode.nvim plugin option registryDir must be a non-empty string")
  }
  return {
    registryDir: registryOverride ? path.resolve(registryOverride) : defaultRegistryDir(),
    healthTimeoutMs: positiveTimeout(raw.healthTimeoutMs, DEFAULT_HEALTH_TIMEOUT_MS),
    requestTimeoutMs: positiveTimeout(raw.requestTimeoutMs, DEFAULT_REQUEST_TIMEOUT_MS),
  }
}

async function selectInstance(
  location: PluginLocation,
  config: PluginConfig,
  signal: AbortSignal | undefined,
) {
  throwIfAborted(signal)
  const project = resolveProjectPaths(location)
  const { entries, stale } = matchingEntries(project, config.registryDir)
  if (entries.length === 0) {
    throw new NeovimToolError("NO_INSTANCE", describeNoInstance(project, stale.length))
  }
  throwIfAborted(signal)

  const checks = await Promise.allSettled(
    entries.map((item) =>
      checkHealth(item.entry, {
        signal,
        timeoutMs: config.healthTimeoutMs,
      }),
    ),
  )

  const healthy: typeof entries = []
  const failures: Array<{ entry: (typeof entries)[number]; error: unknown }> = []
  checks.forEach((check, index) => {
    const item = entries[index]!
    if (check.status === "fulfilled") healthy.push(item)
    else failures.push({ entry: item, error: check.reason })
  })

  if (signal?.aborted) {
    throw cancelled()
  }
  if (healthy.length > 1) {
    assertSingleInstance(healthy)
  }
  if (healthy.length === 1) {
    return healthy[0]!.entry
  }

  const authFailure = failures.find(
    (item) => item.error instanceof NeovimToolError && item.error.code === "AUTH_FAILED",
  )
  if (authFailure) throw authFailure.error

  const first = failures[0]?.error
  if (entries.length === 1 && first instanceof NeovimToolError) {
    if (first.code === "HEALTH_FAILED" || first.code === "INVALID_RESPONSE") throw first
    throw new NeovimToolError(
      "NO_INSTANCE",
      `The Neovim instance registered for project ${project.root} is not reachable (${first.message})`,
    )
  }
  throw new NeovimToolError(
    "NO_INSTANCE",
    `None of the ${entries.length} Neovim instances registered for project ${project.root} responded to a health check.`,
  )
}

function resultText(action: ActionName, input: Record<string, unknown>, result: unknown): string {
  if (typeof result === "string" && result.length > 0) return result
  if (result && typeof result === "object" && !Array.isArray(result)) {
    const message = (result as Record<string, unknown>).message
    if (typeof message === "string" && message.length > 0) return message
  }
  if (action === "open") {
    const line = typeof input.line === "number" ? `:${input.line}` : ""
    const column = typeof input.column === "number" ? `:${input.column}` : ""
    return `Opened ${String(input.path)}${line}${column} in Neovim.`
  }
  if (action === "notify") {
    const level = typeof input.level === "string" ? input.level : "info"
    return `Sent a ${level} notification to Neovim.`
  }
  return `Showed ${String(input.path)} as a diff in Neovim. The proposed content was not written to disk.`
}

async function invoke(
  action: ActionName,
  input: Record<string, unknown>,
  runtime: ToolRuntime,
): Promise<{ content: string; metadata: Record<string, unknown> }> {
  throwIfAborted(runtime.signal)
  const instance = await selectInstance(runtime.location, runtime.options, runtime.signal)
  throwIfAborted(runtime.signal)
  const response = await callAction(instance, action, input, {
    signal: runtime.signal,
    timeoutMs: runtime.options.requestTimeoutMs,
  })
  const result = redactToken(response.result, instance.token)
  return {
    content: resultText(action, input, result),
    metadata: {
      instance_id: instance.instance_id,
      action,
      result: result ?? null,
    },
  }
}

const openInput = {
  type: "object",
  properties: {
    path: {
      type: "string",
      description: "File to open. Relative paths resolve from the project root; absolute paths must stay inside it.",
    },
    line: { type: "integer", minimum: 1, description: "Optional 1-based line to place the cursor on." },
    column: { type: "integer", minimum: 1, description: "Optional 1-based column to place the cursor on." },
  },
  required: ["path"],
  additionalProperties: false,
} as const

const notifyInput = {
  type: "object",
  properties: {
    message: { type: "string", minLength: 1, maxLength: 4096, description: "Notification text." },
    level: {
      type: "string",
      enum: ["info", "warn", "error"],
      default: "info",
      description: "Notification severity. Defaults to info.",
    },
  },
  required: ["message"],
  additionalProperties: false,
} as const

const diffInput = {
  type: "object",
  properties: {
    path: {
      type: "string",
      description: "File to compare. Relative paths resolve from the project root; absolute paths must stay inside it.",
    },
    proposed: {
      type: "string",
      description: "Proposed file content shown as a side-by-side diff. It is never written to disk.",
    },
  },
  required: ["path", "proposed"],
  additionalProperties: false,
} as const

export type ToolDefinition = Info<any, undefined>

export function createTools(runtime: ToolRuntime): ToolDefinition[] {
  return [
    {
      name: "neovim_open",
      description:
        "Open a file in the Neovim instance attached to this project. Optionally place the cursor at a 1-based line and column. Use this only when the user wants to see or navigate code in Neovim.",
      input: openInput,
      execute: async (input: Record<string, unknown>, context) => {
        const current = { ...runtime, signal: context.signal }
        return invoke("open", input, current)
      },
    },
    {
      name: "neovim_notify",
      description:
        "Show a short notification inside the Neovim instance attached to this project. Use this to report status or ask the user to look at Neovim; prefer info, warn, or error.",
      input: notifyInput,
      execute: async (input: Record<string, unknown>, context) => {
        const current = { ...runtime, signal: context.signal }
        return invoke("notify", input, current)
      },
    },
    {
      name: "neovim_diff",
      description:
        "Show proposed file content as a side-by-side diff in the Neovim instance attached to this project. The proposed content is display-only and is never written to disk; the user reviews and applies changes manually.",
      input: diffInput,
      execute: async (input: Record<string, unknown>, context) => {
        const current = { ...runtime, signal: context.signal }
        return invoke("diff", input, current)
      },
    },
  ]
}
