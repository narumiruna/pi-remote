# Local HTML session export

## Result

The native Session controls screen can export the selected idle session through Pi 1.3.0's `export_html` RPC command. The user must review History and enable explicit consent before preparing the file. Saving requires a separate system file-picker action. Cancelling the picker retains the prepared file in memory; Discard removes it and resets consent. Successful saving also removes the prepared in-memory copy and resets consent.

Pi Remote does not upload the export, open a browser, render its HTML or send an inference prompt. Saving to a cloud-backed destination can send the file to that storage provider. HTML contains active content; use a trusted browser when opening it.

The export can include the entire session tree, not only the visible transcript or active branch. It can include system instructions, prompts, thinking, tool arguments, command output, file contents and exposed secrets. No automatic redaction is claimed.

## Boundaries

- Export requires the current host epoch and selected session. Working sessions reject export. It shares the host's serialized session-operation guard.
- The host chooses an unpredictable output directory under private companion storage, with directory permissions `0700`. The phone cannot supply an output path.
- The host accepts only Pi's exact expected path and opens the output without following a final symbolic link. It checks that the output is a regular file before reading it.
- The host rejects empty, invalid UTF-8 and larger-than-2-MiB output. It reads at most the limit plus one byte and never sends a truncated export. The base64-encoded reply fits the existing 4-MiB protocol limit.
- Temporary host output is removed after success or error. A host crash can leave the private temporary directory on disk, like other companion-owned session data. No crash-proof deletion claim is made.
- Pi rejects export when no conversation has been saved yet. A session name alone does not create an exportable conversation.
- This implements HTML export only. JSONL export/import, public sharing, bug reports and terminal custom-renderer parity remain open. It does not complete `PLAN.md`.

## Verified checks

- All 75 root tests pass. The export cases cover exact bytes, packet round-trip, wrong response path, missing output, symbolic links, size rejection, stale session and working-state rejection. Production TLS tests pass export on loopback, LAN and Tailscale; revoked connections cannot export.
- All 28 shared tests pass. Export tests cover empty and invalid UTF-8 rejection, size rejection, round-trip and the maximum-size reply budget.
- Root and shared suites pass with Thread Sanitizer at the export checkpoint. No shutdown fixtures remain after the suites.
- The isolated installed-Pi `NativeWorkflowCheck` passes real HTML export without inference or global-settings changes. It seeds a synthetic session only while Pi is closed, resumes it through the host, decodes Pi's embedded session data and checks the exact marker. Temporary export output is absent afterward.
- Unsigned Mac and iOS simulator builds pass.
- All twelve compact-interface tests pass in three bounded batches (two, six and four tests), with no skips. The compact iPhone SE export test passes with large text. It verifies disabled preparation before consent, file-picker cancellation, explicit discard, consent reset and successful native saving. The saved HTML file's exact contents were read back from simulator File Provider storage. This is simulator evidence, not physical-device or cloud-provider evidence.

The first installed check tried to export a named but empty session. Pi correctly rejected it because no conversation file existed. The check now uses private synthetic history and does not write a live session file. The first picker-cancellation checks also failed: this SDK exposes a misplaced Cancel accessibility proxy over its More control. The test now uses the system sheet's standard dismissal gesture; it does not alter app authentication or file-picker behavior. A full UI run exceeded the tool's 300-second command limit and produced no complete result bundle. Subsequent batches exposed test taps on partially clipped rows behind the navigation bar. Short scroll gestures now place the target control's center below that bar before tapping. All twelve tests then passed in completed batches. No test process remained after the timeout.

Local logs: `/tmp/pi-remote-export-{root,core,tsan,core-tsan,installed,mac,ios,ui}.log`. Passing interface summaries are `/tmp/pi-remote-export-ui-{retry,group2,group3}-summary.json` (two, six and four tests). The earlier focused summary is `/tmp/pi-remote-export-ui-summary.json`. Failed UI runs remain in `/tmp/pi-remote-interface/Logs/Test/`; they are not passing evidence. See the [verified build commands](native-apps.md#automated-checks) and [installed-Pi check command](workflow-verification.md#repeat-the-real-pi-check).
