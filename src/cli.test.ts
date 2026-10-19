import { afterEach, expect, test } from "bun:test"
import { mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"
import { HELP, LineDecoder, parseOptions, terminalCommand } from "./cli.ts"
import { MemorySecrets, required, TestClient } from "./fixtures/client.ts"
import { Service } from "./host/service.ts"

const roots: string[] = [],
  services: Service[] = []
afterEach(async () => {
  for (const service of services.splice(0)) await service.stop()
  for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true })
})
async function service(): Promise<Service> {
  const root = await mkdtemp(join(tmpdir(), "pi-cli-test-"))
  roots.push(root)
  await mkdir(join(root, "src"))
  const result = await Service.start(
    {
      directory: join(root, "src"),
      dataDirectory: join(root, "catalog"),
      address: "127.0.0.1",
      port: 0,
      pi: resolve("src/fixtures/fake-pi.ts"),
    },
    { secrets: new MemorySecrets() },
  )
  services.push(result)
  return result
}

test("strict options keep the launch directory and resolve explicit paths", () => {
  expect(parseOptions([], "/example/src").command).toBe("help")
  expect(parseOptions(["serve", "--help"]).command).toBe("help")
  const parsed = parseOptions(
    ["serve", "--listen", "127.0.0.1", "--port", "0", "--pi", "bin/pi.js", "--data-dir", "private"],
    "/example/projects",
  )
  expect(parsed).toMatchObject({
    command: "serve",
    options: {
      directory: "/example/projects",
      address: "127.0.0.1",
      port: 0,
      pi: "/example/projects/bin/pi.js",
      dataDirectory: "/example/projects/private",
    },
  })
  expect(parseOptions(["serve", "--port", "65535"]).options.port).toBe(65535)
  expect(parseOptions(["addresses"]).command).toBe("addresses")
})

test("unknown, duplicate, incomplete and unsafe options fail closed", () => {
  for (const args of [
    ["unknown"],
    ["addresses", "--port", "1"],
    ["--help", "extra"],
    ["serve", "--unknown", "x"],
    ["serve", "--port"],
    ["serve", "--port", "1", "--port", "2"],
    ["serve", "--port", "-1"],
    ["serve", "--port", "65536"],
    ["serve", "--port", "1.5"],
    ["serve", "--port", "1e2"],
    ["serve", "--listen", "0.0.0.0"],
    ["serve", "--listen", "8.8.8.8"],
    ["serve", "--pi", "bad\0entry"],
    ["serve", "--data-dir", ""],
    ["serve", "--help", "extra"],
    ["serve", "--pi", "--help"],
    ["serve", "--data-dir", "--pi"],
  ])
    expect(() => parseOptions(args)).toThrow()
})

test("line decoder bounds bytes, rejects NUL/invalid UTF-8 and recovers at the next LF", () => {
  const decoder = new LineDecoder()
  const bytes = Buffer.from("status é🙂\r\nhelp\n")
  const lines: (string | null)[] = []
  for (const byte of bytes) lines.push(...decoder.feed(new Uint8Array([byte])))
  expect(lines).toEqual(["status é🙂", "help"])
  expect(decoder.feed(Buffer.from(`${"a".repeat(4096)}\n`))).toEqual(["a".repeat(4096)])
  expect(decoder.feed(Buffer.from(`${"a".repeat(4097)}\nstatus\n`))).toEqual([null, "status"])
  expect(decoder.feed(new Uint8Array([255, 10, 104, 105, 10]))).toEqual([null, "hi"])
  expect(decoder.feed(Buffer.from("bad\0line\nhelp\n"))).toEqual([null, "help"])
  expect(decoder.feed(Buffer.from("unterminated"))).toEqual([])
})

test("spawned help and argument errors require neither Pi nor an OS secret store", async () => {
  const help = Bun.spawn([process.execPath, resolve("src/cli.ts"), "--help"], {
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  })
  expect(await new Response(help.stdout).text()).toBe(`${HELP}\n`)
  expect(await new Response(help.stderr).text()).toBe("")
  expect(await help.exited).toBe(0)
  const invalid = Bun.spawn(
    [process.execPath, resolve("src/cli.ts"), "serve", "--port", "invalid"],
    { stdin: "ignore", stdout: "pipe", stderr: "pipe" },
  )
  expect(await new Response(invalid.stdout).text()).toBe("")
  expect(await new Response(invalid.stderr).text()).toContain("invalidRequest")
  expect(await invalid.exited).toBe(1)
})

test("terminal commands never forward free text and status excludes conversation content", async () => {
  const host = await service(),
    output: string[] = []
  const write = (line: string) => {
    output.push(line)
  }
  host.coordinator.snapshot.messages.push({
    id: "fixture-message",
    role: "user",
    text: "Private prompt sentinel",
    isError: false,
    streaming: false,
    truncated: false,
  })
  expect(await terminalCommand(host, "status", write)).toBe(true)
  expect(output.join("\n")).toContain("0 saved session(s)")
  expect(output.join("\n")).not.toContain("Private prompt sentinel")
  for (const command of [
    "ordinary prompt text",
    "pair extra",
    "approve",
    "status extra",
    "quit extra",
  ]) {
    output.length = 0
    expect(await terminalCommand(host, command, write)).toBe(true)
    expect(output).toEqual(["Error: invalidRequest."])
  }
  expect(host.coordinator.snapshot.sessions).toEqual([])
  output.length = 0
  await terminalCommand(host, "devices", write)
  expect(output).toEqual(["No paired devices."])
  expect(await terminalCommand(host, "quit", write)).toBe(false)
})

test("terminal pairing shows a code only on request and approves only the displayed ID", async () => {
  const host = await service(),
    output: string[] = []
  const write = (line: string) => {
    output.push(line)
  }
  expect(host.server.pendingPair).toBeUndefined()
  await terminalCommand(host, "pair", write)
  const code = JSON.parse(Buffer.from(required(output[1]), "base64").toString()) as {
    grant: string
    url: string
    certificate: string
  }
  expect(code.url).toBe(`wss://127.0.0.1:${host.server.port}/`)
  expect(Buffer.from(code.certificate, "base64").equals(host.identity.der)).toBe(true)
  const client = new TestClient(host.server.port, host.identity)
  try {
    await client.wait("challenge")
    client.send({
      pair: {
        device: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
        name: "Fixture phone",
        grant: code.grant,
      },
    })
    await client.wait("approvalRequired")
    const id = required(host.server.pendingPair).id
    output.length = 0
    await terminalCommand(host, "approve AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", write)
    expect(output).toEqual(["Error: expired."])
    expect(host.server.listDevices()).toEqual([])
    await terminalCommand(host, `approve ${id.toLowerCase()}`, write)
    expect((await client.wait("paired")).credential).toBeString()
    expect(host.server.listDevices()).toHaveLength(1)
    await terminalCommand(host, "revoke aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", write)
    expect(host.server.listDevices()).toEqual([])
    await terminalCommand(host, "cancel-pair", write)
    expect(output.at(-1)).toBe("Pairing closed.")
  } finally {
    client.close()
  }
})
