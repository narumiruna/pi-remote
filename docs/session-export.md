# Reviewed HTML and JSONL session export

## Result

Session controls offers HTML and JSONL export for the selected idle session. The user must review History and enable consent before preparing a file. Saving requires a separate system file-picker action. Sharing requires a separate review, consent and system service-picker action. Cancelling either picker retains the prepared file in memory. Discard and successful saving clear that copy and reset consent.

HTML includes the session tree. JSONL includes only the active branch, not abandoned branches, matching Pi 1.3.0's terminal export. JSONL uses a plain-text JSON Lines file type and the `.jsonl` extension, matching Pi's session-file discovery; its contents are Pi session JSONL and can be imported through [the native import screen](session-import.md).

Pi Remote does not upload an export automatically, open a browser, render HTML or send an inference prompt. Saving to cloud storage or choosing a sharing service can send the complete file to that provider or recipient. HTML contains active content; open it only in a trusted browser. Exports can contain system instructions, prompts, thinking, tool arguments, command output, file contents and exposed secrets. No automatic redaction is claimed.

## Boundaries

- Both formats require the current host epoch and selected session. Working sessions reject export. Export shares the host's serialized session-operation guard.
- HTML uses Pi's `export_html`. The host chooses an unpredictable directory under private companion storage with permissions `0700`. The phone cannot supply an output path. The host accepts only the exact expected response path, opens without following a final symbolic link, checks for a regular file and reads at most the limit plus one byte.
  - Temporary HTML output is removed after success or error. A host crash can leave the private directory on disk. No crash-proof deletion claim is made.
  - Pi rejects HTML export when no conversation file exists. Naming an empty session alone does not make it exportable.
- JSONL uses Pi's live `get_entries` response and `leafId`, not the last physical record or a caller-supplied file path. It validates the tree, walks the active leaf's ancestors and emits a fresh version-3 header and normalized parent links.
  - This follows the installed `dist/core/session-export.js` `serializeSessionBranch` implementation. A null leaf produces a header-only export, which native import accepts.
  - The header uses the managed Pi session ID, canonical Mac directory and a fresh timestamp. It is not a byte-for-byte archive of the session file. Abandoned branches are deliberately excluded, as in Pi's terminal JSONL export.
- Both outputs are complete and bounded to 2 MiB. JSONL also limits the complete input tree to 2 MiB. Oversized output is rejected, never truncated. Replies fit the existing 4-MiB protocol limit. Empty or invalid UTF-8 HTML bytes, malformed live state, unknown leaves and invalid tree links fail closed.
- Older HTML-only replies without a format field still decode as HTML. The JSONL control appears only when the host advertises its separate capability.
- Pi's terminal-only Radius/Gist upload, bug-report flow and custom-renderer parity are outside the user-confirmed core RPC scope. The native service picker does not implement those integrations, and they are not completion requirements. Core RPC coverage still needs its separate audit; this checkpoint does not complete `PLAN.md`.

## Verified checks

- All 78 root tests pass normally and with Thread Sanitizer. HTML cases cover exact bytes, wrong response path, missing output, symbolic links, size rejection and stale/working-session rejection. JSONL cases cover the live leaf, abandoned branches, a leaf that is not the last record, an empty branch, duplicate IDs, unknown leaves, malformed state, input size rejection and stale/working-session rejection.
- Authenticated production TLS tests pass HTML and JSONL export on loopback, LAN and Tailscale. Revoked connections cannot export.
- All 32 shared tests pass normally and with Thread Sanitizer. They verify format round-trips, old HTML replies, UTF-8 and size rejection, importable JSONL and the reply byte budget.
- Isolated Pi 1.3.0 `NativeWorkflowCheck` passes HTML export, active-branch JSONL export, versions 1–3 import/migration and restoration without inference or global-settings changes. It checks the original records and unchanged source, the live exported branch and decoded HTML session data.
- Unsigned Mac, iOS simulator and iOS device-SDK builds pass.
- All fourteen compact-interface tests pass in three completed batches (four, six and four tests), with no skips. The export tests verify consent, system-picker cancellation, discard, consent reset and native saving of both formats. The latest saved `.jsonl` file was read back from simulator Documents and contained the exact three synthetic fixture records. This is simulator evidence, not hardware or cloud-provider evidence.

## System sharing checkpoint

After preparing an export, choose **Review sharing options**. The separate review warns that recipients or services can upload the file, make it public or retain it. Enable consent, then choose **Choose sharing service**. Leaving that review resets sharing consent. Cancelling the picker does not mark a save or delivery as completed. Pi Remote cannot verify service delivery, revoke recipient access or recall a shared file.

The Swift `Transferable` representation uses the exact prepared bytes, the matching HTML/JSONL content type and `pi-session.html` or `pi-session.jsonl`. It validates the 2-MiB limit and format again before transfer. It does not request a new host export, expose provider credentials or construct an upload request. Available recipients and services depend on the operating system and installed apps.

- Two new product tests pass real `CoreTransferable` export: both formats preserve every byte, content type, filename and extension. Empty, invalid UTF-8, malformed JSONL and oversized representations fail. Transfer inspection uses iOS 18.2 APIs on the current simulator; the app's sharing API does not change the provisional deployment floor.
- Both new large-text UI tests pass consent gating, real service-picker presentation, filename, cancellation and consent reset. A focused repeat also verifies that background return removes the HTML sharing review and open service picker. This cannot recall a transfer already accepted by a service. The JSONL case also saves through the system **Save to Files** service. The resulting local File Provider file matches every source fixture byte, including its final LF. No remote recipient or upload was tested.
- Both existing HTML/JSONL export UI tests pass again. The other fourteen interface tests retain their prior [regression evidence](release-notes.md#verification-checkpoint); no single 18-test run is claimed at this checkpoint. Captures show the native review and system picker.
- All 31 product tests pass with no skips on both local LAN and Tailscale. Both provider fixtures shut down cleanly and report unchanged agent settings. All 83 root and 35 shared tests pass normally and with Thread Sanitizer.
- All three Mac-model tests pass in an isolated run and in three repeated suites. Unsigned Mac, iOS simulator and device-SDK builds pass. These checks do not establish a Mac service recipient, hardware behavior or off-site delivery.

Current logs are `/tmp/pi-remote-system-share-{root,tsan,core,core-tsan,unit,ui,export-ui,mac-final,mac-repeated,device}.log` and `/tmp/pi-remote-system-share-{lan,tailscale}-{product,host}.log`. Corresponding simulator result summaries end in `-summary.json`. This checkpoint does not close the remaining compatibility gates.

## Failure record

The first installed HTML check used a named but empty session; Pi correctly rejected it. The initial JSONL implementation read the whole managed file. Inspecting Pi's terminal implementation established that JSONL exports only the current branch. The host now uses the live leaf, and dedicated tests exclude abandoned records. Comparing an export to the original import upload also incorrectly assumed that Pi never changes managed history; the check now verifies preserved source records and the current live branch.

The first system-sharing UI check expected a Close button. This SDK presents an activity popover instead; the corrected check verifies `ActivityListView` and dismisses through its outside region before confirming retained state. A concurrent Mac-model run timed out at the four-second listener-start wait. An isolated run and three repeated suites pass without changing that timeout; the concurrent failure's cause is not established.

The system picker on this SDK exposes a misplaced Cancel accessibility proxy over its More control. Tests use the standard sheet-dismissal gesture instead. A full UI run exceeded the tool's 300-second limit and left no test process running; it produced no complete result bundle and is not passing evidence. Bounded batches also found taps on partially clipped rows behind the navigation bar. Short drags now place the control's center below the bar before tapping.

Current local logs: `/tmp/pi-remote-session-files-{root,core,tsan,core-tsan,installed,mac,ios,device}.log`. Passing interface summaries are `/tmp/pi-remote-session-files-ui-group{1,2,3}-summary.json`. The final `.jsonl` file-type picker rerun also passes in `/tmp/pi-remote-session-files-ui-jsonl-summary.json`. Earlier HTML-only and import checkpoints remain under `/tmp/pi-remote-export-*` and `/tmp/pi-remote-import-*`. No binary test artifacts are committed. Use the [verified build commands](native-apps.md#automated-checks) and [installed-Pi check](workflow-verification.md#repeat-the-real-pi-check).
