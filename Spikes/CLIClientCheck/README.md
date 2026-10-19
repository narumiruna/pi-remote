# CLI client contract check

`CLIClientCheck` uses the production `RemoteClient`, pinned TLS channel and Swift app protocol. It does not add host authentication or approval exceptions. Device credentials stay in an in-memory test store. Failure output excludes packet contents, pairing data and paths.

## Golden fixtures

`swift run CLIClientCheck --fixtures` writes deterministic Foundation `JSONEncoder` output to stdout. `src/fixtures/wire-v1.json` contains that output, with JSON layout formatted by Biome. The credential, grant, nonce and HMAC inputs in this file are fixed test bytes, not product secrets.

The fixtures cover all Swift client actions, server envelopes, Foundation dates, enum associated values, Base64, UUIDs, tool-call ranges and the largest JavaScript safe sequence number. `bun test src/host/protocol.test.ts` validates the TypeScript contract against these fixtures.

`CLIClientCheck --decode-server <file>` decodes an array of server packets. This checks TypeScript-produced envelopes with the Swift types. It does not establish live transport behavior.

## Live fixture check

Pass one private JSON configuration file to `CLIClientCheck`. The fixture host must start with an empty private catalog and no loaded session. Its launch folder must contain a project subdirectory.

| Field | Meaning |
| --- | --- |
| `pairingCode` | Encoded short-lived `PairingCode` from the fixture host. |
| `cwd` | Host launch folder, as reported by the directory API. |
| `controlDirectory` | Private directory read by the explicit fixture harness. |
| `outputFile` | Private result file. The check writes `{"status":"pass"}` only after all checks pass. |
| `verificationFile` | Optional local copy of the host-written `acceptance.txt`, for a host on another operating system. |
| `device` | Optional fixed fixture device UUID. |

The client writes `approve.json` with the exact device UUID before requesting pairing. Only the explicit fixture harness reads this file. The harness must wait for that device's pending pairing request and use the normal local approval API. Do not add a production approval bypass.

The client also writes these control files:

1. `restart.json`: restart the host with the same private state and identity. Write `restart.done` only after the new listener is ready.
2. `revoke.json`: revoke its device through the normal registry. Write `revoke.done` only after live access is closed.

The controlled Pi fixture must handle these instructions:

1. `CLI fixture: write acceptance.txt with CLI acceptance\n`: write `CLI acceptance\n` to the selected project's `acceptance.txt`, then settle. Emit a user message and a completed assistant message.
2. `CLI fixture: wait for Stop`: stay active until Stop or host shutdown. Accept steering and follow-up while active.
3. Optional `fixture-select` command: open a standard selection dialog and accept `Second`.

The live check covers approval, pairing, authentication, parent/nested/explicit-path browsing, session creation, available model/thinking changes, coding, reconnect without prompt replay, dialogs when discovered, steering/follow-up, Stop, explicit unsupported action failure, close/resume, active host restart, explicit restoration and revocation. It distinguishes prompt acceptance from settled work. It is a controlled fixture check, not a real-provider or hardware result.

## Focused iOS checks

`Tests/PhoneTests/CLIHostCapabilitiesTests.swift` belongs to the existing `PiRemoteTests` target. It checks reduced capability controls and retains native-host actions. Its live phone-model check reads `/tmp/pi-remote-cli-simulator-fixture/config.json` with the same fixture fields, except `outputFile` and `device` are not used. It uses an injected local unlock result; host TLS, pairing, approval and device authentication remain production code.

The live phone test skips when this explicit configuration file is absent. Run only the iPhone 17 Pro simulator. A hosted capability test is not evidence of pairing or coding; record live-test results separately.
