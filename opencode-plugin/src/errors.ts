export type NeovimToolErrorCode =
  | "NO_INSTANCE"
  | "MULTIPLE_INSTANCES"
  | "AUTH_FAILED"
  | "HEALTH_FAILED"
  | "REQUEST_TIMEOUT"
  | "CANCELLED"
  | "INVALID_RESPONSE"
  | "RPC_FAILED"
  | "INTERNAL_ERROR"

/**
 * Error surfaced to OpenCode. Messages are safe to show to the model/user:
 * they never contain registry tokens or raw registry file contents.
 */
export class NeovimToolError extends Error {
  readonly code: NeovimToolErrorCode

  constructor(code: NeovimToolErrorCode, message: string) {
    super(message)
    this.name = "NeovimToolError"
    this.code = code
  }
}
