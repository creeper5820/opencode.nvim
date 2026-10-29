import { randomUUID } from "node:crypto"
import { NeovimToolError } from "./errors.ts"
import { redactToken } from "./redact.ts"
import type { RegistryEntry } from "./registry.ts"

export const ENVELOPE_VERSION = 1

export interface HealthResult {
  instance_id: string
  project_root?: string
  pid?: number
  version?: number
  [key: string]: unknown
}

export interface RpcSuccess<T = unknown> {
  version: number
  ok: true
  request_id: string
  result: T
}

export interface RpcFailure {
  version: number
  ok: false
  request_id?: string
  error: {
    code?: string
    message?: string
  }
}

export interface CallOptions {
  signal?: AbortSignal
  timeoutMs: number
}

function timeoutError(message: string): NeovimToolError {
  return new NeovimToolError("REQUEST_TIMEOUT", message)
}

function cancelledError(label: string): NeovimToolError {
  return new NeovimToolError("CANCELLED", `${label} was cancelled.`)
}

interface LinkedAbort {
  controller: AbortController
  cleanup: () => void
  timedOut: () => boolean
  externalAborted: () => boolean
}

function linkAbort(signal: AbortSignal | undefined, timeoutMs: number): LinkedAbort {
  const controller = new AbortController()
  let timedOut = false
  let externalAborted = signal?.aborted === true
  const onAbort = () => {
    externalAborted = true
    controller.abort(signal?.reason)
  }
  if (signal) {
    if (signal.aborted) controller.abort(signal.reason)
    else signal.addEventListener("abort", onAbort, { once: true })
  }
  const timer = setTimeout(() => {
    timedOut = true
    controller.abort(new Error("timeout"))
  }, timeoutMs)
  return {
    controller,
    cleanup: () => {
      clearTimeout(timer)
      signal?.removeEventListener("abort", onAbort)
    },
    timedOut: () => timedOut,
    externalAborted: () => externalAborted,
  }
}

function authHeaders(token: string): Record<string, string> {
  return {
    Authorization: `Bearer ${token}`,
    "Content-Type": "application/json",
    Accept: "application/json",
    "Cache-Control": "no-store",
  }
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

async function fetchJson(
  url: string,
  init: RequestInit,
  label: string,
  options: CallOptions,
): Promise<{ response: Response; body: unknown; invalidJson: boolean }> {
  if (options.signal?.aborted) throw cancelledError(label)
  const linked = linkAbort(options.signal, options.timeoutMs)
  try {
    const response = await fetch(url, { ...init, signal: linked.controller.signal })
    const text = await response.text()
    let body: unknown
    let invalidJson = false
    if (text.length > 0) {
      try {
        body = JSON.parse(text)
      } catch {
        invalidJson = true
      }
    }
    return { response, body, invalidJson }
  } catch (error) {
    if (error instanceof NeovimToolError) throw error
    if (linked.externalAborted()) {
      throw cancelledError(label)
    }
    if (linked.timedOut()) {
      throw timeoutError(`${label} timed out after ${options.timeoutMs}ms.`)
    }
    const cause = error instanceof Error && error.message ? `: ${error.message}` : ""
    throw new NeovimToolError("RPC_FAILED", `${label} failed to connect to Neovim${cause}.`)
  } finally {
    linked.cleanup()
  }
}

/** GET /health; succeeds only when the envelope identifies the same instance. */
export async function checkHealth(
  entry: RegistryEntry,
  options: CallOptions,
): Promise<HealthResult> {
  const { response, body, invalidJson } = await fetchJson(
    `${entry.url}/health`,
    { method: "GET", headers: authHeaders(entry.token) },
    "Neovim health check",
    options,
  )
  if (response.status === 401 || response.status === 403) {
    throw new NeovimToolError(
      "AUTH_FAILED",
      `Neovim instance ${entry.instance_id} rejected the registry token.`,
    )
  }
  if (!response.ok) {
    throw new NeovimToolError(
      "HEALTH_FAILED",
      `Neovim instance ${entry.instance_id} health check failed with HTTP ${response.status}.`,
    )
  }
  if (invalidJson || !isObject(body) || body.ok !== true || !isObject(body.result)) {
    throw new NeovimToolError(
      "INVALID_RESPONSE",
      `Neovim instance ${entry.instance_id} returned an invalid health response.`,
    )
  }
  const result = body.result as HealthResult
  if (result.instance_id !== entry.instance_id) {
    throw new NeovimToolError(
      "HEALTH_FAILED",
      `Neovim instance ${entry.instance_id} is stale: the registered id does not match its server.`,
    )
  }
  return result
}

export interface RpcResponse {
  requestId: string
  result: unknown
}

/** POST /tools/<action> using the 09A authenticated envelope. */
export async function callAction(
  entry: RegistryEntry,
  action: "open" | "notify" | "diff",
  input: Record<string, unknown>,
  options: CallOptions,
): Promise<RpcResponse> {
  const requestId = randomUUID()
  const body = JSON.stringify({
    version: ENVELOPE_VERSION,
    request_id: requestId,
    action,
    input,
  })
  const { response, body: decoded, invalidJson } = await fetchJson(
    `${entry.url}/tools/${action}`,
    { method: "POST", headers: authHeaders(entry.token), body },
    `Neovim ${action} request`,
    options,
  )
  if (isObject(decoded) && decoded.ok === false) {
    const failure = decoded as unknown as RpcFailure
    const code = typeof failure.error?.code === "string" ? failure.error.code : "RPC_FAILED"
    const rawMessage =
      typeof failure.error?.message === "string" && failure.error.message.length > 0
        ? failure.error.message
        : `Neovim ${action} request failed.`
    const message = redactToken(rawMessage, entry.token)
    throw new NeovimToolError(
      response.status === 401 || response.status === 403 ? "AUTH_FAILED" : "RPC_FAILED",
      `Neovim ${action} failed (${code}): ${message}`,
    )
  }
  if (response.status === 401 || response.status === 403) {
    throw new NeovimToolError(
      "AUTH_FAILED",
      `Neovim instance ${entry.instance_id} rejected the registry token.`,
    )
  }
  if (!response.ok) {
    throw new NeovimToolError(
      "RPC_FAILED",
      `Neovim ${action} request failed with HTTP ${response.status}.`,
    )
  }
  if (invalidJson || !isObject(decoded) || decoded.ok !== true || decoded.version !== ENVELOPE_VERSION) {
    throw new NeovimToolError(
      "INVALID_RESPONSE",
      `Neovim ${action} returned an invalid RPC envelope.`,
    )
  }
  if (decoded.request_id !== requestId) {
    throw new NeovimToolError(
      "INVALID_RESPONSE",
      `Neovim ${action} response did not match request_id.`,
    )
  }
  return { requestId, result: decoded.result }
}
