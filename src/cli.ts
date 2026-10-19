#!/usr/bin/env bun
import { write } from "node:fs"
import { hostname } from "node:os"
import { resolve } from "node:path"
import { displayText, faultCode } from "./host/errors.ts"
import { allowedAddress, listenAddresses } from "./host/server.ts"
import { defaultDataDirectory, Service, type ServiceOptions } from "./host/service.ts"
import { Fault } from "./host/storage.ts"

export const HELP = `Usage: pi-remote serve [--listen IPv4] [--port PORT] [--pi PATH] [--data-dir PATH]
       pi-remote addresses
       pi-remote --help

Run serve from ~/src, ~/projects or the folder you want to browse first.
Select a project and start Pi explicitly from iOS. No GUI or terminal forwarding.
--listen    One assigned private, Tailscale or loopback IPv4 address.
            Required when more than one non-loopback address is available.
--port      Port from 0 through 65535 (default 7443; 0 selects an available port).
--pi        Pi JavaScript entry (default: resolve pi in PATH); executed with Bun.
--data-dir  Private CLI catalog, separate from the Mac app and terminal sessions.

Enter help while serving for pairing/device commands. Detach tmux to keep running.
Ctrl-C, SIGTERM, quit and stdin EOF stop managed Pi. A phone disconnect does not.
A paired device can run Pi tools with this user's file and command permissions.
Linux requires an unlocked Secret Service session; there is no plaintext fallback.`
const COMMANDS = `pair                     Show a private code valid for two minutes.
cancel-pair              Close pairing and reject its pending request.
approve REQUEST-ID       Approve only the displayed pairing request.
deny REQUEST-ID          Reject only the displayed pairing request.
devices                  List device IDs and connection state.
revoke DEVICE-ID         Revoke that device and disconnect it.
status                   Show host state, without conversation text.
help                     Show these commands.
quit                     Stop the listener and managed Pi; keep saved history.

Paste the code into Connections → Pair a host in iOS. Compare the device ID first.
Keep pairing codes private; do not save or share terminal output from pair.`

export function parseOptions(
  args: string[],
  cwd = process.cwd(),
): { command: "serve" | "addresses" | "help"; options: ServiceOptions } {
  const options: ServiceOptions = {
    directory: cwd,
    dataDirectory: defaultDataDirectory(),
    port: 7443,
  }
  const [command = "--help", ...rest] = args
  if (["--help", "-h", "addresses"].includes(command)) {
    if (rest.length) throw new Fault("invalidRequest", "This command does not accept options.")
    return { command: command === "addresses" ? "addresses" : "help", options }
  }
  if (command !== "serve")
    throw new Fault("invalidRequest", "Unknown command. Use pi-remote --help.")
  if (rest.length === 1 && ["--help", "-h"].includes(rest[0])) return { command: "help", options }
  const seen = new Set<string>()
  for (let i = 0; i < rest.length; i += 2) {
    const flag = rest[i],
      value = rest[i + 1]
    if (
      !["--listen", "--port", "--pi", "--data-dir"].includes(flag) ||
      seen.has(flag) ||
      !value ||
      value.startsWith("-") ||
      value.includes("\0")
    )
      throw new Fault(
        "invalidRequest",
        "Unknown, repeated or incomplete option. Use pi-remote --help.",
      )
    seen.add(flag)
    switch (flag) {
      case "--listen":
        if (!allowedAddress(value))
          throw new Fault("invalidRequest", "Use a private, Tailscale or loopback IPv4 address.")
        options.address = value
        break
      case "--port":
        if (!/^\d+$/.test(value) || Number(value) > 65535)
          throw new Fault("invalidRequest", "--port must be from 0 through 65535.")
        options.port = Number(value)
        break
      case "--pi":
        options.pi = resolve(cwd, value)
        break
      case "--data-dir":
        options.dataDirectory = resolve(cwd, value)
        break
    }
  }
  return { command: "serve", options }
}

export class LineDecoder {
  private bytes: number[] = []
  private oversized = false
  feed(chunk: Uint8Array): (string | null)[] {
    const lines: (string | null)[] = []
    for (const byte of chunk) {
      if (byte === 10) {
        try {
          lines.push(
            this.oversized || this.bytes.includes(0)
              ? null
              : new TextDecoder("utf-8", { fatal: true })
                  .decode(new Uint8Array(this.bytes))
                  .replace(/\r$/, ""),
          )
        } catch {
          lines.push(null)
        }
        this.bytes = []
        this.oversized = false
      } else if (this.bytes.length >= 4096) {
        this.oversized = true
      } else if (!this.oversized) this.bytes.push(byte)
    }
    return lines
  }
}

class Output {
  private chain = Promise.resolve()
  private pending = 0
  private failed = false
  get broken(): boolean {
    return this.failed
  }
  constructor(private abort: () => void) {}
  write(value: string): void {
    if (this.failed) return
    if (this.pending >= 32 || Buffer.byteLength(value) > 32768) {
      this.fail()
      return
    }
    this.pending += 1
    this.chain = this.chain
      .then(async () => {
        if (this.failed) return
        await new Promise<void>((done) => {
          const timer = setTimeout(() => {
            this.fail()
            done()
          }, 250)
          try {
            const data = Buffer.from(`${value}\n`)
            const next = (offset: number) => {
              if (this.failed) {
                clearTimeout(timer)
                done()
                return
              }
              write(1, data, offset, data.length - offset, null, (error, count) => {
                if (error || count <= 0) {
                  clearTimeout(timer)
                  this.fail()
                  done()
                  return
                }
                if (offset + count < data.length) {
                  next(offset + count)
                  return
                }
                clearTimeout(timer)
                done()
              })
            }
            next(0)
          } catch {
            clearTimeout(timer)
            this.fail()
            done()
          }
        })
      })
      .finally(() => {
        this.pending -= 1
      })
  }
  private fail(): void {
    if (this.failed) return
    this.failed = true
    this.abort()
    process.stdout.destroy()
  }
  async drain(): Promise<void> {
    await this.chain
  }
}

export async function terminalCommand(
  service: Service,
  line: string,
  output: (line: string) => void,
): Promise<boolean> {
  const [command, ...args] = line.trim().split(/\s+/)
  if (!command) return true
  try {
    if (args.length > 1) throw new Fault("invalidRequest")
    const id = args[0]?.toUpperCase()
    switch (command) {
      case "help":
        if (args.length) throw new Fault("invalidRequest")
        output(COMMANDS)
        break
      case "quit":
        if (args.length) throw new Fault("invalidRequest")
        return false
      case "status": {
        if (args.length) throw new Fault("invalidRequest")
        const state = service.coordinator.snapshot
        output(
          `Pi ${displayText(state.piVersion)}; ${displayText(state.phase)}; ${state.sessions.length} saved session(s).`,
        )
        if (state.selected) output(`Loaded session: ${state.selected}`)
        break
      }
      case "pair":
        if (args.length) throw new Fault("invalidRequest")
        output("Private pairing code (expires in two minutes):")
        output(service.server.pairingCode(service.identity, service.address, hostname()))
        break
      case "cancel-pair":
        if (args.length) throw new Fault("invalidRequest")
        service.server.closePairing()
        output("Pairing closed.")
        break
      case "approve":
        if (!id) throw new Fault("invalidRequest")
        await service.server.approve(id)
        output("Pairing approved.")
        break
      case "deny":
        if (!id) throw new Fault("invalidRequest")
        service.server.deny(id)
        output("Pairing denied.")
        break
      case "devices":
        if (args.length) throw new Fault("invalidRequest")
        for (const device of service.server.listDevices())
          output(
            `${device.id}  ${displayText(device.name).replace(/[\r\n]/g, " ")}  ${device.connected ? "connected" : "saved"}`,
          )
        if (!service.server.listDevices().length) output("No paired devices.")
        break
      case "revoke":
        if (!id) throw new Fault("invalidRequest")
        await service.server.revoke(id)
        output("Device access revoked.")
        break
      default:
        throw new Fault(
          "invalidRequest",
          "Unknown command. Enter help; terminal text is never sent to Pi.",
        )
    }
  } catch (error) {
    output(`Error: ${faultCode(error)}.`)
    if (!service.server.running) return false
  }
  return true
}

async function main(): Promise<void> {
  const { command, options } = parseOptions(process.argv.slice(2))
  if (command === "help") {
    console.log(HELP)
    return
  }
  if (command === "addresses") {
    for (const address of listenAddresses()) console.log(address)
    return
  }
  const abort = new AbortController()
  const output = new Output(() => abort.abort())
  let service: Service | undefined,
    pending = 0
  let commands = Promise.resolve()
  const decoder = new LineDecoder()
  const stop = () => abort.abort()
  const input = (data: Buffer) => {
    for (const line of decoder.feed(data)) {
      if (pending >= 32) {
        stop()
        return
      }
      pending += 1
      commands = commands
        .then(async () => {
          if (abort.signal.aborted) return
          if (line === null) {
            output.write("Error: command must be valid UTF-8, at most 4096 bytes and without NUL.")
            return
          }
          if (!service) return
          if (!(await terminalCommand(service, line, (value) => output.write(value)))) stop()
        })
        .catch(stop)
        .finally(() => {
          pending -= 1
        })
    }
  }
  const stopSignal = () => stop()
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) process.on(signal, stopSignal)
  process.stdout.on("error", stop)
  process.stdin.on("end", stop)
  process.stdin.on("error", stop)
  process.stdin.pause()
  try {
    service = await Service.start(options, { signal: abort.signal })
    service.server.observePairing((pair) => {
      if (pair)
        output.write(
          `Pairing request: ${pair.id}\nDevice: ${displayText(pair.device.name).replace(/[\r\n]/g, " ")} [${pair.device.id}]\nCompare the device ID on iOS. Enter approve ${pair.id} or deny ${pair.id}.`,
        )
    })
    output.write(`Pi Remote listening at wss://${service.address}:${service.server.port}/`)
    output.write(`Browse from: ${displayText(options.directory).replace(/[\r\n]/g, " ")}`)
    output.write(
      "No Pi session started. Select a project from iOS. Enter help for terminal controls.",
    )
    process.stdin.on("data", input)
    process.stdin.resume()
    if (!abort.signal.aborted)
      await new Promise<void>((done) =>
        abort.signal.addEventListener("abort", () => done(), { once: true }),
      )
    process.stdin.pause()
    process.stdin.off("data", input)
    await commands
  } catch (error) {
    if (!abort.signal.aborted) throw error
  } finally {
    await service?.stop()
    await output.drain()
    // A blocked asynchronous PTY write must not keep Bun alive after confirmed host cleanup.
    if (output.broken) process.exit(1)
    process.stdin.pause()
    process.stdin.off("data", input)
    process.stdin.off("end", stop)
    process.stdin.off("error", stop)
    process.stdout.off("error", stop)
    for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) process.off(signal, stopSignal)
  }
}

if (import.meta.main)
  main().catch((error) => {
    const detail =
      error instanceof Fault
        ? displayText(error.message)
        : "Check Pi, private storage, the OS secret service and listen address."
    console.error(`pi-remote: ${faultCode(error)}. ${detail}`)
    process.exitCode = 1
  })
