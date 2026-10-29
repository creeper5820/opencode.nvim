import assert from "node:assert/strict"
import { spawn, type ChildProcess } from "node:child_process"
import { cpSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import path from "node:path"
import test from "node:test"
import { projectDir, tempDir } from "./helpers/temp.ts"

const REAL_TEST = process.env.OPENCODE_NVIM_REAL_TEST === "1"
const PLUGIN_DIR = path.resolve(import.meta.dirname, "../../opencode-plugin")
const OPENCODE_BIN = process.env.OPENCODE_NVIM_BIN ?? "opencode"

function startServer(env: NodeJS.ProcessEnv, cwd: string) {
  const child = spawn(OPENCODE_BIN, ["serve", "--hostname", "127.0.0.1", "--port", "0"], {
    cwd,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  })
  let output = ""
  let url: string | undefined
  let password: string | undefined
  const ready = new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`opencode serve did not start: ${cleanLog(output)}`)), 20_000)
    const onData = (chunk: Buffer) => {
      output += chunk.toString("utf8")
      const foundURL = output.match(/server listening on (http:\/\/127\.0\.0\.1:\d+)/)
      const foundPassword = output.match(/server password (\S+)/)
      if (foundURL) url = foundURL[1]
      if (foundPassword) password = foundPassword[1]
      if (url && password) {
        clearTimeout(timer)
        resolve()
      }
    }
    child.stdout?.on("data", onData)
    child.stderr?.on("data", onData)
    child.once("exit", (code) => {
      clearTimeout(timer)
      reject(new Error(`opencode serve exited with ${code}: ${cleanLog(output)}`))
    })
  })
  return { child, ready, get url() { return url }, get password() { return password }, log: () => cleanLog(output) }
}

function cleanLog(output: string): string {
  return output
    .split("\n")
    .filter((line) => !line.includes("server password"))
    .join("\n")
}

async function stop(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return
  child.kill("SIGTERM")
  await Promise.race([
    new Promise((resolve) => child.once("exit", resolve)),
    new Promise((resolve) => setTimeout(resolve, 3000)),
  ])
  if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL")
}

async function waitForFile(file: string, timeoutMs = 15_000): Promise<string> {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    try {
      return readFileSync(file, "utf8")
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 100))
    }
  }
  throw new Error(`timed out waiting for ${file}`)
}

test("real OpenCode V2 loads the package and lists all three tools", {
  skip: REAL_TEST ? false : "set OPENCODE_NVIM_REAL_TEST=1 to run the isolated real-OpenCode test",
  timeout: 40_000,
}, async () => {
  const tmp = tempDir("real-opencode-")
  let server: ReturnType<typeof startServer> | undefined
  try {
    const home = path.join(tmp.dir, "home")
    const config = path.join(tmp.dir, "config", "opencode")
    const data = path.join(tmp.dir, "data")
    const state = path.join(tmp.dir, "state")
    const cache = path.join(tmp.dir, "cache")
    const runtime = path.join(tmp.dir, "runtime")
    const project = projectDir(tmp.dir)
    for (const dir of [home, config, data, state, cache, runtime]) mkdirSync(dir, { recursive: true })

    const pluginDir = path.join(project, ".opencode", "plugins", "probe")
    mkdirSync(pluginDir, { recursive: true })
    const probeFile = path.join(tmp.dir, "tools.json")
    writeFileSync(
      path.join(pluginDir, "index.ts"),
      `import { Plugin } from "@opencode/plugin"
import { writeFileSync } from "node:fs"

export default Plugin.define({
  id: "test.probe",
  async setup(ctx) {
    const tools = await ctx.tool.list()
    writeFileSync(${JSON.stringify(probeFile)}, JSON.stringify(tools.map((tool) => tool.id).sort()))
  },
})
`,
    )

    cpSync(PLUGIN_DIR, path.join(project, ".opencode", "plugins", "opencode-nvim"), {
      recursive: true,
      filter: (source) => !source.includes(`${path.sep}node_modules`) && !source.includes(`${path.sep}dist`),
    })
    writeFileSync(
      path.join(project, "opencode.jsonc"),
      JSON.stringify({
        $schema: "https://opencode.ai/config.json",
        plugins: ["./.opencode/plugins/opencode-nvim"],
      }),
    )
    writeFileSync(
      path.join(config, "opencode.jsonc"),
      JSON.stringify({ $schema: "https://opencode.ai/config.json" }),
    )

    const env: NodeJS.ProcessEnv = Object.fromEntries(
      Object.entries(process.env).filter(
        ([key]) => !key.startsWith("OPENCODE_") && key !== "NVIM" && key !== "NVIM_LISTEN_ADDRESS",
      ),
    )
    Object.assign(env, {
      HOME: home,
      XDG_CONFIG_HOME: config,
      XDG_DATA_HOME: data,
      XDG_STATE_HOME: state,
      XDG_CACHE_HOME: cache,
      XDG_RUNTIME_DIR: runtime,
      OPENCODE_NVIM_REGISTRY_DIR: path.join(tmp.dir, "registry"),
    })
    server = startServer(env, project)
    await server.ready
    const auth = `Basic ${Buffer.from(`opencode:${server.password}`).toString("base64")}`
    const headers = { Authorization: auth, "Content-Type": "application/json" }

    // OpenCode materializes location plugins when the location first handles a
    // session. This prompt only triggers plugin activation; the prompt may be
    // rejected later by provider setup in the isolated environment.
    const created = await fetch(new URL("/api/session", server.url!), {
      method: "POST",
      headers,
      body: JSON.stringify({ location: { directory: project } }),
    })
    assert.equal(created.status, 200)
    const session = (await created.json()) as any
    const prompt = await fetch(new URL(`/api/session/${session.data.id}/prompt`, server.url!), {
      method: "POST",
      headers,
      body: JSON.stringify({ text: "plugin loading probe" }),
    })
    assert.equal(prompt.status, 200)

    const ids = JSON.parse(await waitForFile(probeFile)) as string[]

    const url = new URL("/api/plugin", server.url!)
    url.searchParams.set("location[directory]", project)
    const response = await fetch(url, { headers: { Authorization: auth } })
    assert.equal(response.status, 200)
    const body = (await response.json()) as any
    const loaded = body.data.find((plugin: any) => plugin.id === "opencode.nvim")
    assert.ok(loaded, `plugin not loaded: ${JSON.stringify(body.data)}\n${server.log()}`)
    assert.equal(loaded.state.status, "active", `${JSON.stringify(loaded)}\n${server.log()}`)
    assert.equal(loaded.features.server, true)
    assert.equal(loaded.source.type, "local")

    assert.ok(ids.includes("neovim_open"), `tools: ${ids.join(", ")}\n${JSON.stringify(loaded)}`)
    assert.ok(ids.includes("neovim_notify"), `tools: ${ids.join(", ")}\n${JSON.stringify(loaded)}`)
    assert.ok(ids.includes("neovim_diff"), `tools: ${ids.join(", ")}\n${JSON.stringify(loaded)}`)
  } finally {
    if (server) await stop(server.child)
    tmp.cleanup()
  }
})
