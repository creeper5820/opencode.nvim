import assert from "node:assert/strict"
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import path from "node:path"
import test from "node:test"
import OpenCodeNvimTools, {
  assertSingleInstance,
  canonicalPath,
  defaultRegistryDir,
  matchingEntries,
  readRegistryEntries,
  resolveConfig,
  resolveProjectPaths,
} from "../../opencode-plugin/src/index.ts"
import RootOpenCodeNvimTools from "../../opencode-plugin/index.ts"
import { makeContext } from "./helpers/fake-plugin-context.ts"
import { deadPid, makeAlias, projectDir, tempDir, writeRegistryEntry } from "./helpers/temp.ts"

function schema(tool: unknown): Record<string, any> {
  return (tool as { input: Record<string, any> }).input
}

test("registers three tools with descriptions and JSON schemas", async () => {
  const tmp = tempDir("unit-register-")
  try {
    const project = projectDir(tmp.dir)
    const { context, tools } = makeContext({ canonical: project, registryDir: path.join(tmp.dir, "registry") })
    await OpenCodeNvimTools.setup(context as any)

    assert.deepEqual([...tools.keys()].sort(), ["neovim_diff", "neovim_notify", "neovim_open"])

    const open = tools.get("neovim_open")!
    assert.match(open.description, /Neovim/)
    assert.deepEqual(schema(open).required, ["path"])
    assert.equal(schema(open).properties.path.type, "string")
    assert.equal(schema(open).properties.line.minimum, 1)
    assert.equal(schema(open).additionalProperties, false)

    const notify = tools.get("neovim_notify")!
    assert.match(notify.description, /notification/i)
    assert.deepEqual(schema(notify).properties.level.enum, ["info", "warn", "error"])
    assert.deepEqual(schema(notify).required, ["message"])

    const diff = tools.get("neovim_diff")!
    assert.match(diff.description, /never written to disk/i)
    assert.match(diff.description, /display-only/i)
    assert.deepEqual(schema(diff).required, ["path", "proposed"])
    assert.equal(schema(diff).properties.proposed.type, "string")
  } finally {
    tmp.cleanup()
  }
})

test("package exports and the local-directory fallback share one plugin", () => {
  const packageDir = path.resolve(import.meta.dirname, "../../opencode-plugin")
  const manifest = JSON.parse(readFileSync(path.join(packageDir, "package.json"), "utf8")) as {
    exports: Record<string, string>
    files: string[]
  }
  assert.equal(manifest.exports["."], "./src/index.ts")
  assert.equal(manifest.exports["./server"], "./src/index.ts")
  for (const relative of [manifest.exports["."], manifest.exports["./server"], "index.ts"]) {
    assert.ok(relative, "missing entrypoint")
    assert.ok(existsSync(path.join(packageDir, relative)), `${relative} does not exist`)
  }
  assert.deepEqual([...manifest.files].sort(), ["index.ts", "src"])
  assert.equal(RootOpenCodeNvimTools, OpenCodeNvimTools)
})

test("registry directory defaults to Neovim stdpath state layout", () => {
  assert.equal(
    defaultRegistryDir({ XDG_STATE_HOME: "/tmp/state" }),
    "/tmp/state/nvim/opencode/tools",
  )
  assert.equal(
    defaultRegistryDir({ OPENCODE_NVIM_REGISTRY_DIR: "/tmp/override" }),
    "/tmp/override",
  )
})

test("plugin options resolve registry and timeout values", () => {
  const tmp = tempDir("unit-options-")
  try {
    const config = resolveConfig({
      registryDir: path.join(tmp.dir, "registry"),
      healthTimeoutMs: 50,
      requestTimeoutMs: 200,
    })
    assert.equal(config.registryDir, path.join(tmp.dir, "registry"))
    assert.equal(config.healthTimeoutMs, 50)
    assert.equal(config.requestTimeoutMs, 200)

    const defaults = resolveConfig({ registryDir: path.join(tmp.dir, "r2") })
    assert.equal(defaults.healthTimeoutMs, 1500)
    assert.equal(defaults.requestTimeoutMs, 10_000)
    assert.throws(() => resolveConfig({ registryDir: "  " }), /non-empty string/)
  } finally {
    tmp.cleanup()
  }
})

test("canonical project path handles symlinks and subdirectories", () => {
  const tmp = tempDir("unit-paths-")
  try {
    const real = projectDir(tmp.dir, "real")
    const sub = path.join(real, "lua", "nested")
    mkdirSync(sub, { recursive: true })
    const alias = makeAlias(tmp.dir, real)

    const fromAlias = resolveProjectPaths({
      directory: sub,
      project: { canonical: alias, directory: real },
    })
    assert.equal(fromAlias.root, canonicalPath(real))
    assert.equal(fromAlias.directory, canonicalPath(sub))

    const fallback = resolveProjectPaths({ directory: real })
    assert.equal(fallback.root, canonicalPath(real))
  } finally {
    tmp.cleanup()
  }
})

test("registry reader ignores invalid entries and matches canonical project root", () => {
  const tmp = tempDir("unit-registry-")
  try {
    const real = projectDir(tmp.dir, "real")
    const other = projectDir(tmp.dir, "other")
    const alias = makeAlias(tmp.dir, real)
    const registry = path.join(tmp.dir, "registry")

    const live = writeRegistryEntry(registry, {
      instanceID: "live-1",
      projectRoot: real,
      url: "http://127.0.0.1:32123",
      token: "secret-live",
      pid: process.pid,
    })
    const stale = writeRegistryEntry(registry, {
      instanceID: "stale-1",
      projectRoot: real,
      url: "http://127.0.0.1:32124",
      token: "secret-stale",
      pid: deadPid(),
    })
    writeRegistryEntry(registry, {
      instanceID: "other-1",
      projectRoot: other,
      url: "http://127.0.0.1:32125",
      token: "secret-other",
      pid: process.pid,
    })
    writeFileSync(path.join(registry, "broken.json"), "{not json", { mode: 0o600 })
    writeFileSync(path.join(registry, "wrong.json"), JSON.stringify({ schema: 2 }), { mode: 0o600 })

    const all = readRegistryEntries(registry)
    assert.equal(all.length, 3)
    assert.ok(all.every((item) => item.entry.token !== ""))

    const match = matchingEntries({ root: canonicalPath(alias), directory: canonicalPath(alias) }, registry)
    assert.deepEqual(match.entries.map((item) => item.entry.instance_id), ["live-1"])
    assert.deepEqual(match.stale.map((item) => item.entry.instance_id), ["stale-1"])
    assert.equal(match.entries[0]!.entry.token, live.token)
    assert.ok(stale.file.endsWith(".json"))
    assert.throws(() => assertSingleInstance([match.entries[0]!, match.entries[0]!]), /Multiple Neovim instances/)
  } finally {
    tmp.cleanup()
  }
})
