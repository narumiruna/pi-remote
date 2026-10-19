// Private pipe protocol for bounded OS-store operations. Never log native diagnostics.
import { AsyncEntry } from "@napi-rs/keyring"

async function main(): Promise<void> {
  const chunks: Buffer[] = []
  let bytes = 0
  for await (const chunk of process.stdin) {
    const data = Buffer.from(chunk)
    bytes += data.length
    if (bytes > 2 * 1024 * 1024) throw new Error("Invalid secret operation")
    chunks.push(data)
  }
  const input = JSON.parse(Buffer.concat(chunks).toString("utf8")) as Record<string, unknown>
  if (
    typeof input.service !== "string" ||
    typeof input.account !== "string" ||
    !["get", "put", "remove"].includes(String(input.operation))
  )
    throw new Error("Invalid secret operation")
  const entry = new AsyncEntry(
    input.service,
    input.account,
    process.platform === "linux" ? { linux: { store: "secret-service" } } : undefined,
  )
  let data: string | null = null
  if (input.operation === "get") {
    const result = await entry.getSecret()
    if (result !== null) {
      if (result.length > 1024 * 1024) throw new Error("Secret limit")
      data = Buffer.from(result).toString("base64")
    }
  } else if (input.operation === "put") {
    if (typeof input.data !== "string" || input.data.length > 1_400_000)
      throw new Error("Secret limit")
    await entry.setSecret(Buffer.from(input.data, "base64"))
  } else await entry.deleteCredential()
  await Bun.write(Bun.stdout, JSON.stringify({ ok: true, data }))
}

if (import.meta.main)
  main().catch(async () => {
    await Bun.write(Bun.stdout, JSON.stringify({ ok: false }))
    process.exitCode = 1
  })
