import { createServer, type IncomingMessage, type ServerResponse } from "node:http"
import { once } from "node:events"

export interface RecordedRequest {
  method: string
  url: string
  headers: Record<string, string | string[] | undefined>
  body: string
  json?: unknown
}

export interface FakeNeovimOptions {
  instanceID?: string
  projectRoot?: string
  token?: string
  pid?: number
  healthDelayMs?: number
  actionDelayMs?: number
  healthStatus?: number
  healthInstanceID?: string
  actionStatus?: number
  actionError?: { code: string; message: string }
  includeTokenInResult?: boolean
}

export interface FakeNeovim {
  url: string
  token: string
  instanceID: string
  requests: RecordedRequest[]
  close(): Promise<void>
}

function json(res: ServerResponse, status: number, value: unknown): void {
  const body = JSON.stringify(value)
  res.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) })
  res.end(body)
}

/**
 * Minimal fake 09A Neovim tool server. Health and actions use the authenticated
 * envelope from lua/opencode/tools/protocol.lua.
 */
export async function startFakeNeovim(options: FakeNeovimOptions = {}): Promise<FakeNeovim> {
  const token = options.token ?? "test-token-secret"
  const instanceID = options.instanceID ?? "nvim-test-1"
  const projectRoot = options.projectRoot ?? process.cwd()
  const requests: RecordedRequest[] = []

  const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    const chunks: Buffer[] = []
    for await (const chunk of req) chunks.push(Buffer.from(chunk))
    const body = Buffer.concat(chunks).toString("utf8")
    let parsed: unknown
    try {
      parsed = body.length > 0 ? JSON.parse(body) : undefined
    } catch {
      parsed = undefined
    }
    requests.push({
      method: req.method ?? "GET",
      url: req.url ?? "/",
      headers: req.headers,
      body,
      json: parsed,
    })

    const authorized = req.headers.authorization === `Bearer ${token}`
    const path = req.url ?? "/"

    if (path === "/health") {
      if (options.healthDelayMs) await new Promise((resolve) => setTimeout(resolve, options.healthDelayMs))
      if (!authorized) {
        json(res, options.healthStatus ?? 401, {
          version: 1,
          ok: false,
          error: { code: "UNAUTHORIZED", message: "unauthorized" },
        })
        return
      }
      if (options.healthStatus && options.healthStatus !== 200) {
        json(res, options.healthStatus, {
          version: 1,
          ok: false,
          error: { code: "HEALTH_FAILED", message: "health failed" },
        })
        return
      }
      json(res, 200, {
        version: 1,
        ok: true,
        request_id: "health",
        result: {
          status: "ok",
          instance_id: options.healthInstanceID ?? instanceID,
          project_root: projectRoot,
          pid: options.pid ?? process.pid,
          version: 1,
        },
      })
      return
    }

    if (path.startsWith("/tools/")) {
      if (options.actionDelayMs) await new Promise((resolve) => setTimeout(resolve, options.actionDelayMs))
      if (!authorized) {
        json(res, 401, {
          version: 1,
          ok: false,
          error: { code: "UNAUTHORIZED", message: "unauthorized" },
        })
        return
      }
      if (options.actionStatus && options.actionStatus !== 200) {
        json(res, options.actionStatus, {
          version: 1,
          ok: false,
          error: options.actionError ?? { code: "ACTION_FAILED", message: "action failed" },
        })
        return
      }
      const envelope = parsed as { request_id?: string; action?: string; input?: unknown } | undefined
      const action = path.slice("/tools/".length)
      json(res, 200, {
        version: 1,
        ok: true,
        request_id: envelope?.request_id ?? "missing",
        result: {
          action,
          input: envelope?.input ?? null,
          instance_id: instanceID,
          ...(options.includeTokenInResult ? { message: `token=${token}` } : {}),
        },
      })
      return
    }

    json(res, 404, { version: 1, ok: false, error: { code: "NOT_FOUND", message: "not found" } })
  })

  server.listen(0, "127.0.0.1")
  await once(server, "listening")
  const address = server.address()
  if (!address || typeof address === "string") throw new Error("no server address")
  return {
    url: `http://127.0.0.1:${address.port}`,
    token,
    instanceID,
    requests,
    async close() {
      server.close()
      if (server.listening) await once(server, "close")
    },
  }
}
