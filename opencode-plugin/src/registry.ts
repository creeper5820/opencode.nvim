import { readdirSync, readFileSync, statSync } from "node:fs"
import os from "node:os"
import path from "node:path"
import { NeovimToolError } from "./errors.ts"
import { canonicalPath, type ProjectPaths } from "./paths.ts"

/** Registry schema written by lua/opencode/tools/registry.lua (09A). */
export interface RegistryEntry {
  schema: 1
  instance_id: string
  project_root: string
  url: string
  token: string
  pid: number
  started_at?: number
}

export interface RegistryEntryFile {
  file: string
  entry: RegistryEntry
}

const FILE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*\.json$/
const MAX_ENTRY_BYTES = 64 * 1024
const LOOPBACK_URL = /^http:\/\/127\.0\.0\.1:(\d{1,5})$/

/**
 * Directory used by Neovim's registry:
 *   stdpath("state")/opencode/tools
 * On Linux, stdpath("state") is $XDG_STATE_HOME/nvim (default
 * ~/.local/state/nvim). OPENCODE_NVIM_REGISTRY_DIR is a test/harness override.
 */
export function defaultRegistryDir(env: NodeJS.ProcessEnv = process.env): string {
  const override = env.OPENCODE_NVIM_REGISTRY_DIR
  if (typeof override === "string" && override.length > 0) {
    return path.resolve(override)
  }
  const stateHome =
    typeof env.XDG_STATE_HOME === "string" && env.XDG_STATE_HOME.length > 0
      ? env.XDG_STATE_HOME
      : path.join(os.homedir(), ".local", "state")
  return path.join(stateHome, "nvim", "opencode", "tools")
}

function validInstanceID(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    value.length <= 128 &&
    /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(value)
  )
}

function validEntry(value: unknown): value is RegistryEntry {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false
  const entry = value as Record<string, unknown>
  return (
    entry.schema === 1 &&
    validInstanceID(entry.instance_id) &&
    typeof entry.project_root === "string" &&
    entry.project_root.length > 0 &&
    path.isAbsolute(entry.project_root) &&
    typeof entry.url === "string" &&
    LOOPBACK_URL.test(entry.url) &&
    Number(entry.url.slice(entry.url.lastIndexOf(":") + 1)) > 0 &&
    Number(entry.url.slice(entry.url.lastIndexOf(":") + 1)) <= 65535 &&
    typeof entry.token === "string" &&
    entry.token.length > 0 &&
    typeof entry.pid === "number" &&
    Number.isInteger(entry.pid) &&
    entry.pid > 0
  )
}

/**
 * Read valid instance entries from the registry directory. Invalid or
 * unreadable files are ignored; their contents are never included in errors.
 */
export function readRegistryEntries(dir: string = defaultRegistryDir()): RegistryEntryFile[] {
  let names: string[]
  try {
    names = readdirSync(dir)
  } catch {
    return []
  }
  const entries: RegistryEntryFile[] = []
  for (const name of names.sort()) {
    if (!FILE_PATTERN.test(name)) continue
    const file = path.join(dir, name)
    try {
      const stat = statSync(file)
      if (!stat.isFile() || stat.size > MAX_ENTRY_BYTES) continue
      const decoded: unknown = JSON.parse(readFileSync(file, "utf8"))
      if (!validEntry(decoded)) continue
      entries.push({ file, entry: decoded })
    } catch {
      // Ignore malformed or partially written entries.
    }
  }
  return entries
}

export function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM"
  }
}

export interface MatchingEntries {
  entries: RegistryEntryFile[]
  stale: RegistryEntryFile[]
}

/** Select entries whose canonical project_root equals the target root. */
export function matchingEntries(
  project: ProjectPaths,
  registryDir: string = defaultRegistryDir(),
): MatchingEntries {
  const entries: RegistryEntryFile[] = []
  const stale: RegistryEntryFile[] = []
  for (const item of readRegistryEntries(registryDir)) {
    let root: string
    try {
      root = canonicalPath(item.entry.project_root)
    } catch {
      continue
    }
    if (root !== project.root) continue
    if (pidAlive(item.entry.pid)) entries.push(item)
    else stale.push(item)
  }
  return { entries, stale }
}

export function describeNoInstance(project: ProjectPaths, staleCount: number): string {
  if (staleCount > 0) {
    return `No running Neovim instance is registered for project ${project.root} (${staleCount} stale registry ${staleCount === 1 ? "entry" : "entries"} ignored).`
  }
  return `No Neovim instance is registered for project ${project.root}. Start Neovim with the opencode.nvim tool server enabled.`
}

export function assertSingleInstance(entries: RegistryEntryFile[]): RegistryEntryFile {
  if (entries.length === 0) {
    throw new NeovimToolError("NO_INSTANCE", "No reachable Neovim instance was found.")
  }
  if (entries.length > 1) {
    const ids = entries.map((item) => item.entry.instance_id).sort().join(", ")
    throw new NeovimToolError(
      "MULTIPLE_INSTANCES",
      `Multiple Neovim instances are registered for this project (${ids}); refusing to guess. Close extra instances or rerun the tool.`,
    )
  }
  return entries[0]!
}
