import type { RemoteFault } from "./protocol.ts"

const codes = new Set<RemoteFault>([
  "unsupportedVersion",
  "invalidRequest",
  "unauthorized",
  "expired",
  "conflict",
  "busy",
  "unavailable",
  "permissionDenied",
  "staleDirectory",
  "tooLarge",
  "unknownOutcome",
  "incompatiblePi",
  "unsupportedFeature",
  "storageFailure",
  "capacity",
  "cancelled",
  "providerAuthenticationRequired",
  "piLaunchFailed",
  "nodeUnavailable",
])

export function faultCode(error: unknown): RemoteFault {
  if (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    codes.has(error.code as RemoteFault)
  ) {
    return error.code as RemoteFault
  }
  if (typeof error === "object" && error !== null && "code" in error) {
    const aliases: Record<string, RemoteFault> = {
      EIO: "storageFailure",
      ENOSPC: "storageFailure",
      EROFS: "storageFailure",
      EACCES: "permissionDenied",
      EPERM: "permissionDenied",
      resourceLimit: "capacity",
      storageLimit: "tooLarge",
      catalogBusy: "conflict",
      unsafeStorage: "storageFailure",
      corruptStorage: "storageFailure",
      storageClosed: "storageFailure",
      corruptIdentity: "storageFailure",
      missingIdentity: "storageFailure",
      changedIdentity: "storageFailure",
      identityAddressMismatch: "invalidRequest",
      secretStoreUnavailable: "storageFailure",
    }
    return aliases[String(error.code)] ?? "unavailable"
  }
  return "unavailable"
}

export function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new Error("Invalid response")
  return value as Record<string, unknown>
}

export function text(value: unknown, maximum = 4096): string {
  if (typeof value !== "string" || Buffer.byteLength(value) > maximum || value.includes("\0")) {
    throw new Error("Invalid text")
  }
  return value
}

export function displayText(value: unknown, maximum = 4096): string {
  if (typeof value !== "string") return ""
  // biome-ignore lint/suspicious/noControlCharactersInRegex: Remove terminal escape sequences.
  const escapes = /\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*(?:\x07|\x1b\\)/g
  // biome-ignore lint/suspicious/noControlCharactersInRegex: Remove terminal and bidirectional controls.
  const controls = /[\x00-\x08\x0b-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]/g
  const clean = value.replace(escapes, "").replace(controls, "")
  const bytes = Buffer.from(clean)
  return new TextDecoder().decode(bytes.subarray(0, maximum)).replace(/\ufffd$/, "")
}

export function foundationNow(): number {
  return Date.now() / 1000 - 978307200
}
