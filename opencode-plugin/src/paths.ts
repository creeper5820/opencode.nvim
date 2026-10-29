import { realpathSync } from "node:fs"
import path from "node:path"

/**
 * Resolve a path to its canonical absolute form. Symbolic links are resolved
 * when the path exists; otherwise the path is normalized lexically.
 */
export function canonicalPath(input: string): string {
  if (typeof input !== "string" || input.length === 0) {
    throw new TypeError("path must be a non-empty string")
  }
  let resolved = path.resolve(input)
  try {
    resolved = realpathSync.native(resolved)
  } catch {
    // The path may not exist yet; keep the lexical absolute form.
  }
  // Strip trailing separators except for the filesystem root.
  if (resolved.length > 1 && (resolved.endsWith(path.sep) || resolved.endsWith("/"))) {
    resolved = resolved.replace(/[\\/]+$/, "")
    if (resolved.length === 0) resolved = path.parse(path.resolve(input)).root
  }
  return resolved
}

export interface ProjectPaths {
  /** Canonical project root. */
  root: string
  /** Directory reported by the OpenCode location; may be a subdirectory. */
  directory: string
}

/**
 * Pick the project root from the plugin location. `project.canonical` is the
 * primary source; `project.directory`, `location.directory` and the process
 * cwd are fallbacks.
 */
export function resolveProjectPaths(location: {
  readonly directory?: string
  readonly project?: {
    readonly directory?: string
    readonly canonical?: string
  }
}): ProjectPaths {
  const candidates = [
    location.project?.canonical,
    location.project?.directory,
    location.directory,
    process.cwd(),
  ]
  for (const candidate of candidates) {
    if (typeof candidate === "string" && candidate.length > 0) {
      return {
        root: canonicalPath(candidate),
        directory: typeof location.directory === "string" && location.directory.length > 0
          ? canonicalPath(location.directory)
          : canonicalPath(candidate),
      }
    }
  }
  throw new TypeError("OpenCode location has no project directory")
}
