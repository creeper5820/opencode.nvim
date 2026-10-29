import { Plugin } from "@opencode/plugin"
import { NeovimToolError } from "./errors.ts"
import { createTools, resolveConfig } from "./tools.ts"

export { NeovimToolError } from "./errors.ts"
export { canonicalPath, resolveProjectPaths } from "./paths.ts"
export {
  assertSingleInstance,
  defaultRegistryDir,
  matchingEntries,
  readRegistryEntries,
  type RegistryEntry,
  type RegistryEntryFile,
} from "./registry.ts"
export { callAction, checkHealth } from "./rpc.ts"
export { createTools, resolveConfig, type ActionName, type PluginConfig, type ToolDefinition } from "./tools.ts"

/**
 * OpenCode V2 server plugin. Registers the neovim_open, neovim_notify and
 * neovim_diff tools against the local Neovim tool server that registered
 * itself in the 09A instance registry.
 */
export const OpenCodeNvimTools = Plugin.define({
  id: "opencode.nvim",
  async setup(ctx) {
    const config = resolveConfig(ctx.options)
    const registration = await ctx.tool.transform((editor) => {
      for (const tool of createTools({
        location: ctx.location,
        options: config,
      })) {
        editor.add(tool)
      }
    })
    return () => registration.dispose()
  },
})

export default OpenCodeNvimTools
