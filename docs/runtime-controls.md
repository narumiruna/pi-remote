# Copy and runtime control verification

## Result

Native last-response copying, queue delivery settings, automatic compaction and idle-session closing now pass local checks with Pi 1.3.0. This does not complete the accepted native-workflow scope.

The current checks pass 74 root tests, 27 shared tests, three macOS tests, 29 product simulator tests and eleven interface tests. Root and shared suites also pass with Thread Sanitizer. Product simulator tests pass on local LAN and Tailscale. Unsigned Mac, simulator and iOS device-SDK builds pass. These checks do not establish hardware, off-site or release support.

## Copy last response

Session controls open a review of Pi's `get_last_assistant_text` result. Reading it does not copy automatically or start a run. Copy text is a separate explicit action. The view identifies the result as a snapshot; reopen it to refresh while Pi continues working.

The response is bounded to 256 KiB of valid UTF-8. Oversized text has an explicit warning and Copy shown text label. Empty text disables copying. Invalid response types fail closed. Pi 1.3.0 omits `text` when it is undefined, although the reference documents `null`; both forms are accepted inside an object response. Other types are rejected.

The iOS implementation requests local-only clipboard data and a two-minute expiration. A named-pasteboard test verifies exact copying, rejection without overwriting existing contents, and actual OS expiration with a short injected deadline. The Mac implementation uses AppKit's current-host-only option. Clipboard managers and other local apps can still read copied text; this is not a secret-storage mechanism.

Tests use unique named pasteboards, not the user's general clipboard. The interface fixture supplies a memory-only writer that verifies the exact synthetic payload. It checks that copying occurs only after the button action and displays success. No provider output or personal clipboard contents are logged.

## Runtime settings

The native runtime view supports steering delivery, follow-up delivery and automatic compaction. Typed enums permit only all queued messages or one-at-a-time delivery. These are Pi settings, not independent phone preferences. The view warns that changes can affect future terminal sessions and requires Apply or Cancel before a write.

The host requires idle state, serializes mutations through the same journal as other actions and reads Pi's state after each change. A response that does not confirm the requested value returns conflict, rather than reporting an applied setting. The view directs the user to refresh and check project overrides. Unknown outcomes are not automatically resent. Repeating the same request ID cannot dispatch another setting write.

Installed-Pi tests change and restore all three settings in a private agent directory, query their actual values and verify unchanged real global settings. Fake-process tests cover unconfirmed writes, duplicate requests and working-state rejection. Production TLS tests query and change queue delivery on loopback, LAN and Tailscale. UI tests verify Cancel leaves values unchanged and Apply displays refreshed values.

Automatic retry and the broader settings UI remain incomplete. Pi's inspected RPC state does not expose a current automatic-retry setting. No guessed value or arbitrary settings-file endpoint was added.

## Close Pi session

Close Pi session requires explicit confirmation and idle state. It stops the child, clears its display state and image references, and deselects the session. It does not stop the listener or delete history. Saved interruption flags remain unchanged. The session can be reopened explicitly without resending any prompt.

A working session rejects close until Stop reaches idle. Failed child shutdown retains the child reference and reports unavailable instead of claiming closure. Host generation checks reject late events from the closed child. The action is session-bound and journaled; a stale request cannot close a different session.

Fake-process tests verify idle-only closing, retained catalog and explicit resume. Installed-Pi checks close and reopen both empty and nonempty sessions. The simulator closes a previously interrupted session, verifies the retained catalog and interruption flag, then reopens it with unchanged message text and roles. The UI test closes the fixture session and reopens the retained session from Sessions.

## Failure record

- A cached SwiftPM graph did not discover the new shared source file. A fresh sanitizer scratch directory built it and passed. No dependency versions or package source were changed to work around this.
- The first installed-Pi check rejected an omitted empty text field. Inspecting the installed implementation established its `undefined` result; the host now accepts the omitted field as well as documented null. Invalid-type tests still fail closed.
- Initial confirmation dialogs did not expose the required title or Cancel control consistently on the compact simulator. Native alerts now provide explicit titles, Apply/Cancel and destructive-close confirmation. The focused checks and the full eleven-test suite pass.
- One concurrent sanitizer run crashed inside Swift's string allocation while constructing the existing oversized-frame fixture. Its cause is unproven; it was not a reported product data race. Two subsequent standalone runs pass all 72 tests. The failure remains recorded in `/tmp/pi-remote-runtime-tsan-final.log`; it is not counted as passing evidence.
- A simulator host restart encountered the exclusive catalog lease while cancelled socket/observer tasks still retained the old host. The test fixture now waits for host release and probes the actual lock before constructing the next host. It does not weaken or release the production lease early. Two complete LAN runs and the subsequent Tailscale run pass both restarts and shutdown after this barrier change.

## Shutdown fixture safety

The sanitizer crash left two shutdown-test shells running under PID 1. Both deliberately ignored TERM and used unbounded busy loops, consuming about one CPU core each. The crashed runner could not finish forced shutdown or execute destructors. Subsequent passing tests did not remove these earlier processes. Both were explicitly killed after their command lines were checked.

The two fixtures now ignore stdin and TERM while sleeping between owner checks. They exit when their original owner disappears or when their 15-second lifetime expires. This preserves the forced-shutdown tests without continuous CPU use. The finite lifetime also bounds the PID-reuse case. A sleep subprocess can survive shell termination for at most its 50-millisecond interval. Production process behavior is unchanged.

Two regression tests verify cleanup after SIGKILL of a disposable owner and expiration while the owner remains alive. All 18 RPC tests and all 74 root tests pass; all 74 also pass with Thread Sanitizer. A focused live sample measured the replacement shell at 0.6–1.1% CPU with 0.01 seconds of accumulated CPU time. Process scans after the suites and focused run found no remaining shutdown fixtures. These results do not establish the cause of the earlier Swift sanitizer crash.

After any runner crash, inspect processes for surviving test fixtures before retrying. Check PID, parent PID and the full command before terminating a process; do not kill unrelated shells or Pi processes.

## Local evidence

- `/tmp/pi-remote-fixture-tests.log` (18 RPC tests)
- `/tmp/pi-remote-fixture-root.log` and `/tmp/pi-remote-fixture-tsan.log` (74 tests each)
- `/tmp/pi-remote-fixture-cpu-test.log` (focused forced-shutdown rerun)
- `/tmp/pi-remote-runtime-root-final.log` (historical 72-test checkpoint)
- `/tmp/pi-remote-runtime-tsan-repeat-1.log` and `/tmp/pi-remote-runtime-tsan-repeat-2.log` (72 tests each)
- `/tmp/pi-remote-runtime-core.log` and `/tmp/pi-remote-runtime-core-tsan.log` (27 tests)
- `/tmp/pi-remote-runtime-installed-final.log` and `/tmp/pi-remote-runtime-provider.log`
- `/tmp/pi-remote-runtime-ui-full-summary.json` (eleven tests) and `/tmp/pi-remote-runtime-ui-verified.log` (final focused rerun)
- `/tmp/pi-remote-runtime-ui-full-attachments/` (reviewed copy/settings captures)
- `/tmp/pi-remote-runtime-lan-verified-1-summary.json` and `/tmp/pi-remote-runtime-lan-verified-2-summary.json` (29 tests each)
- `/tmp/pi-remote-runtime-tailscale-final-summary.json` (29 tests)
- `/tmp/pi-remote-runtime-mac-summary.json` (three tests)
- `/tmp/pi-remote-runtime-device-final.log`

Use the commands in [native app verification](native-apps.md#automated-checks) and [workflow verification](workflow-verification.md). No screenshots, recordings or binary test artifacts are committed.
