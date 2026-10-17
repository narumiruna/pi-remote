# Copy and runtime control verification

## Result

Native last-response copying, queue delivery settings, automatic compaction and idle-session closing now pass local checks with Pi 1.3.0. This does not complete the accepted native-workflow scope.

The earlier copy/runtime checkpoint passed 74 root tests, 27 shared tests, three macOS tests, 29 product simulator tests and eleven interface tests. The newer upstream Pi core cycle/retry checkpoint is recorded below. Root and shared suites also pass with Thread Sanitizer. Product simulator tests pass on local LAN and Tailscale. Unsigned Mac, simulator and iOS device-SDK builds pass. These checks do not establish hardware, off-site or release support.

## Copy last response

**Session controls → Copy last assistant message** opens **Last assistant message**, a review of Pi's `get_last_assistant_text` result. Reading it does not copy automatically or start a run. Copy text is a separate explicit action. The view identifies the result as a snapshot; reopen it to refresh while Pi continues working.

The response is bounded to 256 KiB of valid UTF-8. Oversized text has an explicit warning and Copy shown text label. Empty text disables copying. Invalid response types fail closed. Pi 1.3.0 omits `text` when it is undefined, although the reference documents `null`; both forms are accepted inside an object response. Other types are rejected.

The iOS implementation requests local-only clipboard data and a two-minute expiration. A named-pasteboard test verifies exact copying, rejection without overwriting existing contents, and actual OS expiration with a short injected deadline. The Mac implementation uses AppKit's current-host-only option. Clipboard managers and other local apps can still read copied text; this is not a secret-storage mechanism.

Tests use unique named pasteboards, not the user's general clipboard. The interface fixture supplies a memory-only writer that verifies the exact synthetic payload. It checks that copying occurs only after the button action and displays success. No provider output or personal clipboard contents are logged.

## Runtime settings

The native runtime view uses Pi's **Steering mode** and **Follow-up mode** labels for queued-message delivery. It also supports automatic compaction. Typed enums permit only all queued messages or one-at-a-time delivery. These are Pi settings, not independent phone preferences. The view warns that changes can affect future terminal sessions and requires Apply or Cancel before a write.

The host requires idle state, serializes mutations through the same journal as other actions and reads Pi's state after each change. A response that does not confirm the requested value returns conflict, rather than reporting an applied setting. The view directs the user to refresh and check project overrides. Unknown outcomes are not automatically resent. Repeating the same request ID cannot dispatch another setting write.

Installed-Pi tests change and restore all three settings in a private agent directory, query their actual values and verify unchanged real global settings. Fake-process tests cover unconfirmed writes, duplicate requests and working-state rejection. Production TLS tests query and change queue delivery on loopback, LAN and Tailscale. UI tests verify Cancel leaves values unchanged and Apply displays refreshed values.

Automatic retry now has separate native controls under **Session controls → Automatic retry controls**. Pi's RPC state still does not expose its effective setting. The screen therefore offers confirmed Enable/Disable requests and labels only the last acknowledged request in this Pi process. Refresh does not claim read-back verification. A new process resets that acknowledgement to unknown. No guessed current value or arbitrary settings-file endpoint was added. Preferences outside upstream Pi core RPC are not required by the user-confirmed scope.

<a id="core-model-cycling-and-retry-checkpoint"></a>

## Upstream Pi core model cycling and retry checkpoint

The new `model-cycling` capability adds **Cycle model** and **Cycle thinking level** to Session controls. These call `cycle_model` and `cycle_thinking_level`, then refresh the actual model and supported thinking values. A null result is a valid no-change outcome. Pi controls its model cycle; the app does not invent a separate scope or sequence.

The `retry-controls` capability adds confirmed `set_auto_retry` requests and **Cancel retry wait** when the displayed phase is retrying. The host requires idle state for settings and cycling. `abort_retry` can bypass a pending mutation, just like recovery controls must; it does not approve or dismiss extension dialogs, clear queues, claim idle or replace Stop. Pi's later events determine settlement. Cancelling a retry wait cannot undo tool side effects.

Verification:

- All 86 root tests and 36 shared tests pass normally and with Thread Sanitizer. New cases cover typed round trips, old settings payloads, optional acknowledgements, request deduplication, null model-cycle responses, stale sessions, working-state rejection, failed setters, refresh/process reset and retry cancellation while another mutation waits for a dialog.
- Installed Pi 1.3.0 `NativeWorkflowCheck` passes normally and with Thread Sanitizer without inference. It checks actual cycle results, acknowledged retry requests, private fixture settings-file writes and idle retry cancellation, with unchanged real user settings. The later [upstream Pi core event checkpoint](core-event-verification.md#active-retry-cancellation) also verifies an active retry wait and cancellation with an isolated synthetic provider, without network access or inference.
- Four focused compact-interface checks pass without skips: cycling, retry consent/acknowledgement/refresh, retry cancellation, and the existing queue/compaction confirmation regression. Captures verify large-text controls. All 27 interface tests now pass in the final accepted batch set; see [acceptance evidence](core-rpc-acceptance.md).
- All three Mac-model checks and unsigned Mac, simulator and device-SDK builds pass. A separate Herdr Pi agent then ran all 31 product E2E tests on LAN and Tailscale with no failures or skips. Parent inspection confirmed both result summaries, clean fixture shutdown, unchanged Pi settings and no surviving fixture processes. Evidence is `/tmp/pi-remote-delegated-core-e2e-u6sQps/`. Source code stayed unchanged during that delegation; only documentation was updated concurrently.

Logs use `/tmp/pi-remote-core-controls-{root,tsan,core,core-tsan,installed,installed-tsan,ui-verified,mac-tests,ios,device}.log`; result summaries use the same prefix and `-summary.json`. The initial cached SwiftPM build linked an old initializer signature; a fresh scratch directory passed. UI attempts exposed short drags consumed by menu pickers and a coordinate tap on a clipped switch. The test now drags the leading gutter and targets the actual switch. Retry controls also use a separate, eager native screen rather than adding a large section to the delivery form. Failed attempts are not passing evidence.

The remaining upstream Pi core RPC audit stays open. No installed-extension integration or terminal-only settings UI is required to close it.

## Reviewed manual compaction

**Session controls → Compact context** now accepts optional summary instructions, bounded to 16 KiB of UTF-8. Empty instructions retain Pi's default behavior. The form explains provider use and possible cost. Review opens an explicit Compact/Cancel decision; Cancel sends no request. The editor is disabled while waiting. Errors, including unknown outcomes, do not trigger automatic resubmission.

One iPhone 17 Pro simulator interface test passes with no failures or skips. It verifies keyboard dismissal, retained custom text after Cancel, explicit confirmation, completion and the exact fixture-received instructions without a new prompt. Parent capture review confirms readable controls. This is not yet the final compact/large-text regression. The first attempt used an incorrect Done button; the test now returns through Session controls and closes the sheet using its actual Close action.

Evidence: `/tmp/pi-remote-parent-compaction-ui-2-summary.json`, `/tmp/pi-remote-parent-compaction-ui-2.log` and `/tmp/pi-remote-parent-compaction-captures/`. Real provider-backed custom-instruction compaction remains covered by `NativeProviderCheck`; its final current-tree rerun passes in `/tmp/pi-remote-final3-provider.log`.

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
