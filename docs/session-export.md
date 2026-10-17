# Reviewed HTML and JSONL session export

## Result

Session controls offers HTML and JSONL export for the selected idle session. The user must review History and enable consent before preparing a file. Saving requires a separate system file-picker action. Cancelling the picker retains the prepared file in memory. Discard and successful saving clear that copy and reset consent.

HTML includes the session tree. JSONL includes only the active branch, not abandoned branches, matching Pi 1.3.0's terminal export. JSONL uses a plain-text JSON Lines file type and the `.jsonl` extension, matching Pi's session-file discovery; its contents are Pi session JSONL and can be imported through [the native import screen](session-import.md).

Pi Remote does not upload an export, open a browser, render HTML or send an inference prompt. Saving to a cloud-backed destination can send it to that storage provider. HTML contains active content; open it only in a trusted browser. Exports can contain system instructions, prompts, thinking, tool arguments, command output, file contents and exposed secrets. No automatic redaction is claimed.

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
- Public sharing, bug reports, terminal custom-renderer parity and complete workflow compatibility remain open. This does not complete `PLAN.md`.

## Verified checks

- All 78 root tests pass normally and with Thread Sanitizer. HTML cases cover exact bytes, wrong response path, missing output, symbolic links, size rejection and stale/working-session rejection. JSONL cases cover the live leaf, abandoned branches, a leaf that is not the last record, an empty branch, duplicate IDs, unknown leaves, malformed state, input size rejection and stale/working-session rejection.
- Authenticated production TLS tests pass HTML and JSONL export on loopback, LAN and Tailscale. Revoked connections cannot export.
- All 32 shared tests pass normally and with Thread Sanitizer. They verify format round-trips, old HTML replies, UTF-8 and size rejection, importable JSONL and the reply byte budget.
- Isolated Pi 1.3.0 `NativeWorkflowCheck` passes HTML export, active-branch JSONL export, versions 1–3 import/migration and restoration without inference or global-settings changes. It checks the original records and unchanged source, the live exported branch and decoded HTML session data.
- Unsigned Mac, iOS simulator and iOS device-SDK builds pass.
- All fourteen compact-interface tests pass in three completed batches (four, six and four tests), with no skips. The export tests verify consent, system-picker cancellation, discard, consent reset and native saving of both formats. The latest saved `.jsonl` file was read back from simulator Documents and contained the exact three synthetic fixture records. This is simulator evidence, not hardware or cloud-provider evidence.

## Failure record

The first installed HTML check used a named but empty session; Pi correctly rejected it. The initial JSONL implementation read the whole managed file. Inspecting Pi's terminal implementation established that JSONL exports only the current branch. The host now uses the live leaf, and dedicated tests exclude abandoned records. Comparing an export to the original import upload also incorrectly assumed that Pi never changes managed history; the check now verifies preserved source records and the current live branch.

The system picker on this SDK exposes a misplaced Cancel accessibility proxy over its More control. Tests use the standard sheet-dismissal gesture instead. A full UI run exceeded the tool's 300-second limit and left no test process running; it produced no complete result bundle and is not passing evidence. Bounded batches also found taps on partially clipped rows behind the navigation bar. Short drags now place the control's center below the bar before tapping.

Current local logs: `/tmp/pi-remote-session-files-{root,core,tsan,core-tsan,installed,mac,ios,device}.log`. Passing interface summaries are `/tmp/pi-remote-session-files-ui-group{1,2,3}-summary.json`. The final `.jsonl` file-type picker rerun also passes in `/tmp/pi-remote-session-files-ui-jsonl-summary.json`. Earlier HTML-only and import checkpoints remain under `/tmp/pi-remote-export-*` and `/tmp/pi-remote-import-*`. No binary test artifacts are committed. Use the [verified build commands](native-apps.md#automated-checks) and [installed-Pi check](workflow-verification.md#repeat-the-real-pi-check).
