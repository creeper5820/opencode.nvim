/**
 * Remove a registry token from values that may be surfaced to the model,
 * metadata, or error messages. Defensive: the 09A server never echoes tokens,
 * but a compromised or buggy instance must not leak one through tool output.
 */
export function redactToken<T>(value: T, token: string): T {
  return redactValue(value, token) as T
}

function redactValue(value: unknown, token: string): unknown {
  if (typeof value === "string") {
    if (token.length === 0 || !value.includes(token)) return value
    return value.split(token).join("<redacted>")
  }
  if (Array.isArray(value)) return value.map((item) => redactValue(item, token))
  if (typeof value === "object" && value !== null) {
    const copy: Record<string, unknown> = {}
    for (const [key, item] of Object.entries(value)) copy[key] = redactValue(item, token)
    return copy
  }
  return value
}
