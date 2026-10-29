/**
 * Root entrypoint for local-directory plugin loading.
 *
 * OpenCode's package loader prefers the `exports` map in package.json. Older
 * OpenCode V2 builds that load a local plugin directory by conventional file
 * names use this root `index.ts` instead. Both paths resolve to the same
 * plugin, and neither needs Neovim to be running: the plugin only talks to a
 * Neovim tool server when a tool is actually invoked.
 */
export { default } from "./src/index.ts"
export * from "./src/index.ts"
