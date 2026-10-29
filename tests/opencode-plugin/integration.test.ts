import assert from "node:assert/strict"
import { existsSync, mkdirSync, unlinkSync } from "node:fs"
import path from "node:path"
import test from "node:test"
import OpenCodeNvimTools, { NeovimToolError } from "../../opencode-plugin/src/index.ts"
import { makeContext } from "./helpers/fake-plugin-context.ts"
import { startFakeNeovim, type FakeNeovim } from "./helpers/fake-neovim-server.ts"
import {
  deadPid,
  makeAlias,
  projectDir,
  tempDir,
  writeRegistryEntry,
} from "./helpers/temp.ts"

interface Harness {
  tmp: ReturnType<typeof tempDir>
  root: string
  alias: string
  registry: string
  cleanup(): Promise<void>
  start(options?: Parameters<typeof startFakeNeovim>[0]): Promise<FakeNeovim>
  setup(options?: {
    canonical?: string
    directory?: string
    healthTimeoutMs?: number
    requestTimeoutMs?: number
  }): Promise<Map<string, any>>
}

function harness(prefix: string): Harness {
  const tmp = tempDir(prefix)
  const root = projectDir(tmp.dir, "project")
  const alias = makeAlias(tmp.dir, root)
  const registry = path.join(tmp.dir, "registry")
  const servers: FakeNeovim[] = []
  return {
    tmp,
    root,
    alias,
    registry,
    async cleanup() {
      for (const server of servers.splice(0)) await server.close()
      tmp.cleanup()
    },
    async start(options) {
      const server = await startFakeNeovim({ projectRoot: root, ...options })
      servers.push(server)
      return server
    },
    async setup(options = {}) {
      const { context, tools } = makeContext({
        canonical: options.canonical ?? alias,
        directory: options.directory ?? root,
        registryDir: registry,
        ...(options.healthTimeoutMs === undefined ? {} : { healthTimeoutMs: options.healthTimeoutMs }),
        ...(options.requestTimeoutMs === undefined ? {} : { requestTimeoutMs: options.requestTimeoutMs }),
      })
      await OpenCodeNvimTools.setup(context as any)
      return tools
    },
  }
}

async function waitFor(predicate: () => boolean, timeoutMs = 2000): Promise<void> {
  const start = Date.now()
  while (!predicate()) {
    if (Date.now() - start > timeoutMs) throw new Error("timed out waiting for condition")
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
}

async function expectError(promise: Promise<unknown>, code: string): Promise<NeovimToolError> {
  try {
    await promise
  } catch (error) {
    assert.ok(error instanceof NeovimToolError, `expected NeovimToolError, got ${String(error)}`)
    assert.equal(error.code, code)
    return error
  }
  throw new Error(`expected ${code}`)
}

const toolContext = (signal = new AbortController().signal) => ({ signal }) as any

test("open routes through canonical/symlink project to the matching instance", async () => {
  const h = harness("int-open-")
  try {
    const server = await h.start()
    writeRegistryEntry(h.registry, {
      instanceID: server.instanceID,
      projectRoot: h.root,
      url: server.url,
      token: server.token,
      pid: process.pid,
    })
    const subdir = path.join(h.root, "lua", "nested")
    mkdirSync(subdir, { recursive: true })
    const tools = await h.setup({ canonical: h.alias, directory: subdir })

    const result = await tools.get("neovim_open")!.execute(
      { path: "lua/init.lua", line: 2, column: 3 },
      toolContext(),
    )

    assert.deepEqual(server.requests.map((request) => request.url), ["/health", "/tools/open"])
    const health = server.requests[0]!
    assert.equal(health.headers.authorization, `Bearer ${server.token}`)

    const action = server.requests[1]!
    assert.equal(action.method, "POST")
    assert.equal(action.headers.authorization, `Bearer ${server.token}`)
    assert.equal(action.headers["content-type"], "application/json")
    const envelope = action.json as any
    assert.equal(envelope.version, 1)
    assert.equal(envelope.action, "open")
    assert.equal(typeof envelope.request_id, "string")
    assert.ok(envelope.request_id.length > 0)
    assert.deepEqual(envelope.input, { path: "lua/init.lua", line: 2, column: 3 })

    assert.match(String(result.content), /Opened/)
    assert.equal((result.metadata as any).instance_id, server.instanceID)
    assert.ok(!JSON.stringify(result).includes(server.token))
  } finally {
    await h.cleanup()
  }
})

test("loads and registers tools with no registry and no Neovim instance", async () => {
  const h = harness("int-offline-")
  try {
    const tools = await h.setup()
    assert.deepEqual([...tools.keys()].sort(), ["neovim_diff", "neovim_notify", "neovim_open"])
    assert.equal(existsSync(h.registry), false)

    const error = await expectError(
      tools.get("neovim_notify")!.execute({ message: "anyone there?" }, toolContext()),
      "NO_INSTANCE",
    )
    assert.match(error.message, /No Neovim instance is registered/)
    assert.equal(existsSync(h.registry), false)
  } finally {
    await h.cleanup()
  }
})

test("no instance and different project return readable NO_INSTANCE", async () => {
  const h = harness("int-none-")
  try {
    const other = projectDir(h.tmp.dir, "other-project")
    const server = await h.start({ projectRoot: other })
    writeRegistryEntry(h.registry, {
      instanceID: server.instanceID,
      projectRoot: other,
      url: server.url,
      token: server.token,
      pid: process.pid,
    })
    const tools = await h.setup()
    const error = await expectError(
      tools.get("neovim_open")!.execute({ path: "README.md" }, toolContext()),
      "NO_INSTANCE",
    )
    assert.match(error.message, /No Neovim instance is registered/)
    assert.deepEqual(server.requests, [])
  } finally {
    await h.cleanup()
  }
})

test("multiple healthy instances return MULTIPLE_INSTANCES without calling an action", async () => {
  const h = harness("int-multi-")
  try {
    const one = await h.start({ instanceID: "nvim-one" })
    const two = await h.start({ instanceID: "nvim-two" })
    for (const server of [one, two]) {
      writeRegistryEntry(h.registry, {
        instanceID: server.instanceID,
        projectRoot: h.root,
        url: server.url,
        token: server.token,
        pid: process.pid,
      })
    }
    const tools = await h.setup()
    const error = await expectError(
      tools.get("neovim_notify")!.execute({ message: "hello" }, toolContext()),
      "MULTIPLE_INSTANCES",
    )
    assert.match(error.message, /nvim-one/)
    assert.match(error.message, /nvim-two/)
    assert.ok(!error.message.includes(one.token))
    assert.ok(!one.requests.some((request) => request.url.startsWith("/tools/")))
    assert.ok(!two.requests.some((request) => request.url.startsWith("/tools/")))
  } finally {
    await h.cleanup()
  }
})

test("stale registry entries are ignored, and stale-only projects fail clearly", async () => {
  const h = harness("int-stale-")
  try {
    const live = await h.start({ instanceID: "nvim-live" })
    writeRegistryEntry(h.registry, {
      instanceID: "nvim-dead",
      projectRoot: h.root,
      url: "http://127.0.0.1:9",
      token: "dead-token",
      pid: deadPid(),
    })
    writeRegistryEntry(h.registry, {
      instanceID: live.instanceID,
      projectRoot: h.root,
      url: live.url,
      token: live.token,
      pid: process.pid,
    })
    const tools = await h.setup()
    const result = await tools.get("neovim_open")!.execute({ path: "a.txt" }, toolContext())
    assert.equal((result.metadata as any).instance_id, "nvim-live")

    const staleOnly = path.join(h.root, "stale-only")
    mkdirSync(staleOnly)
    writeRegistryEntry(h.registry, {
      instanceID: "nvim-dead-2",
      projectRoot: staleOnly,
      url: "http://127.0.0.1:9",
      token: "dead-token-2",
      pid: deadPid(),
    })
    const staleTools = await h.setup({ canonical: staleOnly, directory: staleOnly })
    const error = await expectError(
      staleTools.get("neovim_open")!.execute({ path: "a.txt" }, toolContext()),
      "NO_INSTANCE",
    )
    assert.match(error.message, /stale registry entry/)
  } finally {
    await h.cleanup()
  }
})

test("token rejection yields AUTH_FAILED and never leaks the token", async () => {
  const h = harness("int-auth-")
  try {
    const server = await h.start({ token: "server-token" })
    writeRegistryEntry(h.registry, {
      instanceID: server.instanceID,
      projectRoot: h.root,
      url: server.url,
      token: "wrong-registry-token",
      pid: process.pid,
    })
    const tools = await h.setup()
    const error = await expectError(
      tools.get("neovim_diff")!.execute({ path: "x.ts", proposed: "new" }, toolContext()),
      "AUTH_FAILED",
    )
    assert.match(error.message, /rejected the registry token/)
    assert.ok(!error.message.includes("wrong-registry-token"))
    assert.ok(!error.message.includes(server.token))
    assert.ok(!server.requests.some((request) => request.url.startsWith("/tools/")))
  } finally {
    await h.cleanup()
  }
})

test("health identity mismatch is treated as stale", async () => {
  const h = harness("int-identity-")
  try {
    const server = await h.start({ instanceID: "nvim-real", healthInstanceID: "nvim-other" })
    writeRegistryEntry(h.registry, {
      instanceID: server.instanceID,
      projectRoot: h.root,
      url: server.url,
      token: server.token,
      pid: process.pid,
    })
    const tools = await h.setup()
    const error = await expectError(
      tools.get("neovim_open")!.execute({ path: "a.txt" }, toolContext()),
      "HEALTH_FAILED",
    )
    assert.match(error.message, /stale/)
  } finally {
    await h.cleanup()
  }
})

test("health timeout is reported as an unreachable instance", async () => {
  const h = harness("int-health-timeout-")
  try {
    const server = await h.start({ healthDelayMs: 500 })
    writeRegistryEntry(h.registry, {
      instanceID: server.instanceID,
      projectRoot: h.root,
      url: server.url,
      token: server.token,
      pid: process.pid,
    })
    const tools = await h.setup({ healthTimeoutMs: 80 })
    const error = await expectError(
      tools.get("neovim_open")!.execute({ path: "a.txt" }, toolContext()),
      "NO_INSTANCE",
    )
    assert.match(error.message, /timed out after 80ms/)
    assert.ok(!server.requests.some((request) => request.url.startsWith("/tools/")))
  } finally {
    await h.cleanup()
  }
})

test("action timeout is reported with its configured budget", async () => {
  const h = harness("int-timeout-")
  try {
    const server = await h.start({ actionDelayMs: 500 })
    writeRegistryEntry(h.registry, {
      instanceID: server.instanceID,
      projectRoot: h.root,
      url: server.url,
      token: server.token,
      pid: process.pid,
    })
    const tools = await h.setup({ requestTimeoutMs: 80 })
    const error = await expectError(
      tools.get("neovim_notify")!.execute({ message: "slow" }, toolContext()),
      "REQUEST_TIMEOUT",
    )
    assert.match(error.message, /timed out after 80ms/)
  } finally {
    await h.cleanup()
  }
})

test("context.signal aborts an in-flight request", async () => {
  const h = harness("int-cancel-")
  try {
    const server = await h.start({ actionDelayMs: 1000 })
    writeRegistryEntry(h.registry, {
      instanceID: server.instanceID,
      projectRoot: h.root,
      url: server.url,
      token: server.token,
      pid: process.pid,
    })
    const tools = await h.setup({ requestTimeoutMs: 5000 })
    const controller = new AbortController()
    const pending = tools.get("neovim_open")!.execute(
      { path: "slow.txt" },
      toolContext(controller.signal),
    )
    await waitFor(() => server.requests.some((request) => request.url === "/tools/open"))
    controller.abort()
    const error = await expectError(pending, "CANCELLED")
    assert.match(error.message, /cancelled/i)
  } finally {
    await h.cleanup()
  }
})

test("context.signal aborts a pending health check before any action request", async () => {
  const h = harness("int-cancel-health-")
  try {
    const server = await h.start({ healthDelayMs: 1000 })
    writeRegistryEntry(h.registry, {
      instanceID: server.instanceID,
      projectRoot: h.root,
      url: server.url,
      token: server.token,
      pid: process.pid,
    })
    const tools = await h.setup({ healthTimeoutMs: 5000 })
    const controller = new AbortController()
    const pending = tools.get("neovim_open")!.execute(
      { path: "slow.txt" },
      toolContext(controller.signal),
    )
    await waitFor(() => server.requests.some((request) => request.url === "/health"))
    controller.abort()
    const error = await expectError(pending, "CANCELLED")
    assert.match(error.message, /cancelled/i)
    assert.ok(!server.requests.some((request) => request.url.startsWith("/tools/")))
  } finally {
    await h.cleanup()
  }
})

test("an already aborted context signal fails fast without consulting the registry", async () => {
  const h = harness("int-cancel-early-")
  try {
    const tools = await h.setup()
    const controller = new AbortController()
    controller.abort()
    const error = await expectError(
      tools.get("neovim_diff")!.execute(
        { path: "x.ts", proposed: "y" },
        toolContext(controller.signal),
      ),
      "CANCELLED",
    )
    assert.match(error.message, /cancelled/i)
    assert.equal(existsSync(h.registry), false)
  } finally {
    await h.cleanup()
  }
})

test("tool output and server error messages redact the registry token", async () => {
  const h = harness("int-redact-")
  try {
    const server = await h.start({ includeTokenInResult: true })
    const first = writeRegistryEntry(h.registry, {
      instanceID: server.instanceID,
      projectRoot: h.root,
      url: server.url,
      token: server.token,
      pid: process.pid,
    })
    const tools = await h.setup()
    const result = await tools.get("neovim_open")!.execute({ path: "a.txt" }, toolContext())
    const serialized = JSON.stringify(result)
    assert.ok(!serialized.includes(server.token), serialized)
    assert.match(String(result.content), /<redacted>/)

    unlinkSync(first.file)
    const failing = await h.start({
      instanceID: "nvim-echo-error",
      token: server.token,
      actionStatus: 422,
      actionError: { code: "ACTION_FAILED", message: `echoed ${server.token}` },
    })
    writeRegistryEntry(h.registry, {
      instanceID: failing.instanceID,
      projectRoot: h.root,
      url: failing.url,
      token: failing.token,
      pid: process.pid,
    })
    const error = await expectError(
      tools.get("neovim_notify")!.execute({ message: "x" }, toolContext()),
      "RPC_FAILED",
    )
    assert.match(error.message, /<redacted>/)
    assert.ok(!error.message.includes(server.token))
  } finally {
    await h.cleanup()
  }
})

test("notify and diff use their action routes and envelopes", async () => {
  const h = harness("int-actions-")
  try {
    const server = await h.start()
    writeRegistryEntry(h.registry, {
      instanceID: server.instanceID,
      projectRoot: h.root,
      url: server.url,
      token: server.token,
      pid: process.pid,
    })
    const tools = await h.setup()

    const notify = await tools.get("neovim_notify")!.execute(
      { message: "build finished", level: "warn" },
      toolContext(),
    )
    assert.match(String(notify.content), /warn notification/)
    const diff = await tools.get("neovim_diff")!.execute(
      { path: "src/a.ts", proposed: "export const a = 1\n" },
      toolContext(),
    )
    assert.match(String(diff.content), /not written to disk/)

    const actions = server.requests.filter((request) => request.url.startsWith("/tools/"))
    assert.deepEqual(actions.map((request) => request.url), ["/tools/notify", "/tools/diff"])
    assert.deepEqual((actions[0]!.json as any).input, { message: "build finished", level: "warn" })
    assert.deepEqual((actions[1]!.json as any).input, {
      path: "src/a.ts",
      proposed: "export const a = 1\n",
    })
    assert.ok(!JSON.stringify([notify, diff]).includes(server.token))
  } finally {
    await h.cleanup()
  }
})
