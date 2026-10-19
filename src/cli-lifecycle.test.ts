import { dlopen, ptr } from "bun:ffi"
import { afterEach, expect, test } from "bun:test"
import { randomUUID } from "node:crypto"
import { closeSync, readSync } from "node:fs"
import { mkdir, mkdtemp, readFile, realpath, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"
import { required, TestClient, until } from "./fixtures/client.ts"
import type { HostSnapshot } from "./host/protocol.ts"
import { PrivateStorage } from "./host/storage.ts"

// All native calls have fixed signatures. In particular, do not use variadic fcntl on Darwin arm64.
const native = dlopen(process.platform === "darwin" ? "/usr/lib/libc.dylib" : "libutil.so.1", {
  openpty: { args: ["ptr", "ptr", "ptr", "ptr", "ptr"], returns: "i32" },
  pipe: { args: ["ptr"], returns: "i32" },
  poll: { args: ["ptr", "u64", "i32"], returns: "i32" },
})

function ready(fd: number, events: number): boolean {
  const descriptor = new Int32Array([fd, events])
  const result = native.symbols.poll(ptr(descriptor), 1, 0)
  if (result < 0) throw new Error("poll failed")
  return (new Int16Array(descriptor.buffer)[3] & events) !== 0
}

/** Poll before each read so the test runner never leaves a blocked read on an unread PTY. */
class TerminalOutput {
  readonly readFD: number
  readonly writeFD: number
  private text = ""
  private closed = false
  constructor(kind: "pipe" | "pty") {
    const descriptors = new Int32Array(2)
    const master = new Int32Array(1)
    const slave = new Int32Array(1)
    const result =
      kind === "pty"
        ? native.symbols.openpty(ptr(master), ptr(slave), null, null, null)
        : native.symbols.pipe(ptr(descriptors))
    if (result !== 0) throw new Error(`Cannot open ${kind}`)
    this.readFD = kind === "pty" ? master[0] : descriptors[0]
    this.writeFD = kind === "pty" ? slave[0] : descriptors[1]
  }
  drain(): void {
    const buffer = Buffer.alloc(65536)
    while (ready(this.readFD, 1)) {
      const size = readSync(this.readFD, buffer)
      if (!size) break
      this.text += buffer.subarray(0, size).toString("utf8")
      if (this.text.length > 1024 * 1024) throw new Error("Unexpected terminal output volume")
    }
  }
  async wait(pattern: RegExp): Promise<RegExpMatchArray> {
    await until(() => {
      this.drain()
      return pattern.test(this.text)
    })
    return required(this.text.match(pattern))
  }
  close(): void {
    if (this.closed) return
    this.closed = true
    closeSync(this.writeFD)
    closeSync(this.readFD)
  }
}

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ESRCH") return false
    throw error
  }
}
async function bounded<T>(operation: Promise<T>, timeout = 2000): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      operation,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error("CLI lifecycle deadline exceeded")), timeout)
      }),
    ])
  } finally {
    clearTimeout(timer)
  }
}

const fixtures: CLI[] = []
class CLI {
  readonly clients: TestClient[] = []
  readonly child: Bun.Subprocess<"pipe", number, "pipe">
  readonly stderr: Promise<string>
  pid?: number
  port = 0
  private constructor(
    readonly root: string,
    readonly output: TerminalOutput,
  ) {
    this.child = Bun.spawn(
      [
        process.execPath,
        "--preload",
        resolve("src/fixtures/cli-preload.ts"),
        resolve("src/cli.ts"),
        "serve",
        "--listen",
        "127.0.0.1",
        "--port",
        "0",
        "--pi",
        resolve("src/fixtures/fake-pi.ts"),
        "--data-dir",
        join(root, "catalog"),
      ],
      {
        cwd: join(root, "projects"),
        env: {
          ...process.env,
          RPC_FIXTURE_MODE: "normal",
          RPC_FIXTURE_PID_FILE: join(root, "rpc.pid"),
        },
        stdin: "pipe",
        stdout: output.writeFD,
        stderr: "pipe",
      },
    )
    this.stderr = new Response(this.child.stderr).text()
  }
  static async start(kind: "pipe" | "pty" = "pipe"): Promise<CLI> {
    const root = await mkdtemp(join(tmpdir(), "pi-cli-lifecycle-"))
    await mkdir(join(root, "projects", "selected"), { recursive: true })
    const cli = new CLI(root, new TerminalOutput(kind))
    fixtures.push(cli)
    const header = await cli.output.wait(/Pi Remote listening at wss:\/\/127\.0\.0\.1:(\d+)\//)
    cli.port = Number(header[1])
    await cli.output.wait(/No Pi session started\./)
    expect(await Bun.file(join(root, "rpc.pid")).exists()).toBe(false)
    return cli
  }
  async command(line: string): Promise<void> {
    this.child.stdin.write(`${line}\n`)
    await this.child.stdin.flush()
  }
  async activate(): Promise<{ client: TestClient; epoch: string; session: string }> {
    await this.command("pair")
    const pairing = await this.output.wait(
      /Private pairing code \(expires in two minutes\):\r?\n([^\r\n]+)\r?\n/,
    )
    const code = JSON.parse(Buffer.from(required(pairing[1]), "base64").toString()) as {
      grant: string
      certificate: string
    }
    const der = Buffer.from(code.certificate, "base64")
    const identity = {
      key: "",
      der,
      cert: `-----BEGIN CERTIFICATE-----\n${code.certificate}\n-----END CERTIFICATE-----\n`,
      addresses: ["127.0.0.1"],
    }
    const peer = new TestClient(this.port, identity)
    this.clients.push(peer)
    await peer.wait("challenge")
    const device = randomUUID().toUpperCase()
    peer.send({ pair: { device, name: "CLI lifecycle fixture", grant: code.grant } })
    await peer.wait("approvalRequired")
    const request = await this.output.wait(/Pairing request: ([A-F0-9-]{36})\r?\n/)
    await this.command(`approve ${request[1]}`)
    const credential = Buffer.from(required((await peer.wait("paired")).credential), "base64")
    await bounded(peer.closed)
    await this.output.wait(/Pairing approved\./)
    const client = new TestClient(this.port, identity)
    this.clients.push(client)
    await client.authenticate(device, credential)
    const epoch = required((await client.wait("authenticated")).epoch)
    const initial = await this.snapshot(client, epoch)
    expect(initial.sessions).toEqual([])
    expect(initial.selected).toBeUndefined()
    client.request(epoch, "directories")
    const listing = required((await client.wait("reply")).result) as {
      directories: { _0: { items: { id: string; name: string }[] } }
    }
    const selected = required(listing.directories._0.items.find((item) => item.name === "selected"))
    client.request(epoch, "createSession", { directory: selected.id })
    expect((await client.wait("reply")).result).toEqual({ ok: {} })
    const created = await this.snapshot(client, epoch)
    const session = required(created.selected)
    expect(created.phase).toBe("idle")
    expect(created.sessions[0]?.directory).toBe(
      await realpath(join(this.root, "projects", "selected")),
    )
    this.pid = Number(await readFile(join(this.root, "rpc.pid"), "utf8"))
    expect(Number.isSafeInteger(this.pid) && this.pid > 1).toBe(true)
    expect(this.pid).not.toBe(this.child.pid)
    expect(alive(this.pid)).toBe(true)
    client.request(
      epoch,
      "prompt",
      { text: "CLI fixture: wait for Stop", delivery: "prompt" },
      session,
    )
    expect((await client.wait("reply")).result).toEqual({ ok: {} })
    expect((await this.snapshot(client, epoch)).phase).toBe("working")
    await expect(PrivateStorage.initialize(join(this.root, "catalog"))).rejects.toMatchObject({
      code: "catalogBusy",
    })
    return { client, epoch, session }
  }
  async snapshot(client: TestClient, epoch: string): Promise<HostSnapshot> {
    client.request(epoch, "snapshot")
    const result = required((await client.wait("reply")).result) as {
      snapshot: { _0: HostSnapshot }
    }
    return result.snapshot._0
  }
  async assertStopped(code: number): Promise<void> {
    expect(await bounded(this.child.exited)).toBe(code)
    // Check at process exit, not after a grace period that could hide an orphan.
    expect(alive(required(this.pid))).toBe(false)
    const storage = await PrivateStorage.initialize(join(this.root, "catalog"))
    storage.close()
    const listener = Bun.serve({
      hostname: "127.0.0.1",
      port: this.port,
      fetch: () => new Response("rebound"),
    })
    await listener.stop(true)
    expect(await bounded(this.stderr)).toBe("")
  }
  async dispose(): Promise<void> {
    for (const client of this.clients) client.close()
    if (this.child.exitCode === null) this.child.kill("SIGKILL")
    await bounded(this.child.exited)
    this.child.stdin.end()
    const recorded = await readFile(join(this.root, "rpc.pid"), "utf8").catch(() => "")
    const pid = Number(recorded)
    if (Number.isSafeInteger(pid) && pid > 1 && alive(pid)) {
      process.kill(pid, "SIGKILL")
      await until(() => !alive(pid))
    }
    this.output.close()
    await rm(this.root, { recursive: true, force: true })
  }
}

afterEach(async () => {
  for (const fixture of fixtures.splice(0)) await fixture.dispose()
})

for (const reason of ["SIGINT", "SIGTERM", "SIGHUP", "EOF", "quit"] as const) {
  test(`real CLI ${reason} stops active Pi and releases its catalog and listener`, async () => {
    const cli = await CLI.start()
    await cli.activate()
    if (reason === "EOF") cli.child.stdin.end()
    else if (reason === "quit") await cli.command("quit")
    else cli.child.kill(reason)
    await cli.assertStopped(0)
  }, 10000)
}

// Spacing prevents the 32-command input cap from being the shutdown cause.
async function blockOutput(cli: CLI): Promise<void> {
  const deadline = performance.now() + 2000
  while (ready(cli.output.writeFD, 4)) {
    if (performance.now() >= deadline) throw new Error("Terminal did not reach backpressure")
    expect(cli.child.exitCode).toBeNull()
    await cli.command("help")
    await Bun.sleep(10)
  }
  // POLLOUT can clear with a small amount of space left. Fill that space as well.
  for (let count = 0; count < 8; count++) {
    await cli.command("help")
    await Bun.sleep(10)
  }
  expect(cli.child.exitCode).toBeNull()
  expect(alive(required(cli.pid))).toBe(true)
}

test("drained PTY remains usable with active Pi, then ordinary quit cleans up", async () => {
  const cli = await CLI.start("pty")
  const { client, epoch } = await cli.activate()
  for (let count = 0; count < 48; count++) {
    await cli.command("help")
    await Bun.sleep(10)
    cli.output.drain()
  }
  expect(cli.child.exitCode).toBeNull()
  expect((await cli.snapshot(client, epoch)).phase).toBe("working")
  expect(alive(required(cli.pid))).toBe(true)
  await cli.command("quit")
  await cli.assertStopped(0)
}, 10000)

for (const kind of ["pipe", "pty"] as const) {
  test(`unread ${kind} output deadline stops active Pi before CLI exits`, async () => {
    const cli = await CLI.start(kind)
    await cli.activate()
    // Stop reading only after startup and real pairing/session activation.
    const deadline = performance.now() + 2500
    while (cli.child.exitCode === null) {
      if (performance.now() >= deadline) throw new Error("Unread output did not stop the CLI")
      try {
        await cli.command("help")
      } catch {
        // The CLI can close stdin between the exit check and the write.
        await bounded(cli.child.exited)
        break
      }
      // Fewer than 32 writes fit within the 250 ms output deadline.
      await Bun.sleep(12)
    }
    await cli.assertStopped(1)
  }, 10000)
}

test("SIGTERM reaches a real CLI with blocked PTY stdout and stops active Pi before exit", async () => {
  const cli = await CLI.start("pty")
  await cli.activate()
  await blockOutput(cli)
  cli.child.kill("SIGTERM")
  await cli.assertStopped(1)
}, 10000)
