import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs"
import path from "node:path"
import { spawnSync } from "node:child_process"

const TEST_ROOT = "/tmp/opencode"

export interface TempDir {
  dir: string
  cleanup(): void
}

export function tempDir(prefix = "09b-"): TempDir {
  mkdirSync(TEST_ROOT, { recursive: true })
  const dir = mkdtempSync(path.join(TEST_ROOT, `${prefix}${process.pid}-`))
  return {
    dir,
    cleanup() {
      rmSync(dir, { recursive: true, force: true })
    },
  }
}

export function projectDir(parent: string, name = "project"): string {
  const dir = path.join(parent, name)
  mkdirSync(dir, { recursive: true })
  return dir
}

export function deadPid(): number {
  const result = spawnSync(process.execPath, ["-e", ""], { timeout: 10_000 })
  if (typeof result.pid !== "number" || result.pid <= 0) throw new Error("failed to spawn dead pid helper")
  return result.pid
}

export interface RegistryFixture {
  file: string
  instanceID: string
  token: string
}

export function writeRegistryEntry(
  registryDir: string,
  entry: {
    instanceID: string
    projectRoot: string
    url: string
    token: string
    pid: number
  },
): RegistryFixture {
  mkdirSync(registryDir, { recursive: true, mode: 0o700 })
  const file = path.join(registryDir, `${entry.instanceID}.json`)
  writeFileSync(
    file,
    JSON.stringify({
      schema: 1,
      instance_id: entry.instanceID,
      project_root: entry.projectRoot,
      url: entry.url,
      token: entry.token,
      pid: entry.pid,
      started_at: Math.floor(Date.now() / 1000),
    }),
    { mode: 0o600 },
  )
  return { file, instanceID: entry.instanceID, token: entry.token }
}

export function makeAlias(parent: string, target: string, name = "alias"): string {
  const alias = path.join(parent, name)
  symlinkSync(target, alias, "dir")
  return alias
}
