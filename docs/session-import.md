# Explicit JSONL session import

## Result

Sessions now offers **Import JSONL session** on iOS and macOS. The native file picker reads a bounded source file. Before import, the screen displays its session title, saved Mac directory, entry count and byte count. A separate confirmation opens the imported copy. Cancel keeps the review; Discard clears it.

Import copies the submitted history into private companion-owned storage. It does not attach to a running terminal session, change the source file or send a prompt. The imported session is marked for interrupted-work review because saved history does not establish tool completion.

Opening Pi can load trusted resources in the saved directory with the Mac user's permissions. The review states this explicitly. Imported instructions, file contents and tool output can be untrusted; review them before sending anything.

## Validation and ownership

- The app and host both validate the complete input before import. The current implementation accepts version-3 JSONL, valid UTF-8 and at most 2 MiB. It rejects invalid headers, repeated entry IDs, missing or forward parent links, unknown entry types and invalid message roles. Multiple roots and abandoned branches are preserved. Extension-specific entry details remain opaque; structural validation is not a trust decision or a full content-schema validator.
- Framing splits LF bytes, accepts CRLF and preserves Unicode separators inside JSON strings. It does not split Swift Characters at CRLF.
- The saved Mac directory must be absolute, must still exist and must permit read/search access. The host resolves symbolic links and records the canonical directory identity. It does not silently choose a different directory.
- Working sessions reject import. The action checks the displayed selected session, runs through the mutation journal and shares the session-operation guard. Repeating an accepted request ID cannot create another copy.
- The host validates history and directory access before creating storage or replacing Pi. Rejected malformed, inaccessible, missing-directory and stale requests preserve the current session and catalog.
- Each import has a new companion ID and private folder. The copied file retains its Pi session ID and exact submitted bytes, uses permissions `0600`, and is opened only through the managed activation path. The directory uses `0700`. The caller cannot specify a destination path.
- A launch failure can leave the imported catalog item available for explicit recovery. It does not cause an automatic prompt or import retry.
- Version-1/2 migration, directory override and Pi's `session_before_switch` lifecycle equivalence remain open compatibility work. The current import does not claim complete `/import` parity. No feature exclusion has been approved.

## Verified checks

- All 76 root tests pass normally and with Thread Sanitizer. Six focused import cases cover exact copied bytes, unchanged source, file permissions, duplicate-request handling, close/resume, no prompt dispatch, malformed input, missing/inaccessible directory, working state and stale session rejection.
- Production authenticated TLS tests pass import on loopback, LAN and Tailscale. They check the stored bytes, separate companion session and absence of prompt dispatch. Revoked connections cannot import.
- All 30 shared tests pass normally and with Thread Sanitizer. Import cases cover custom Pi IDs, multiple roots, branches, title review, CRLF, packet round-trip, malformed input, broken links, duplicate IDs, relative/NUL paths and size rejection.
- The isolated Pi 1.3.0 `NativeWorkflowCheck` passes real import through the host, exact restored user text, close/resume, unchanged source and subsequent HTML export. No inference or real credential operation occurs; global settings remain unchanged.
- Unsigned Mac, iOS simulator and iOS device-SDK builds pass.
- All thirteen compact-interface tests pass in three bounded batches (four, five and four tests), with no skips. The import test chooses a real JSONL file in the system picker, verifies the Mac directory, cancels confirmation, confirms import and checks the restored text without a working run.

The UI fixture exposes only its synthetic Documents directory through an explicit fixture-only Info.plist. Product targets do not enable file sharing. Early UI runs failed because the fixture phase was not selected and the system picker opened Recents rather than Browse. Those setup errors were corrected; the passing test follows Browse → On My iPhone → fixture folder. The initial CRLF unit test also found Swift Character framing behavior; the validator now splits LF bytes. A cached root SwiftPM graph omitted the new shared source; a fresh scratch directory discovered it without changing dependency versions.

Local logs: `/tmp/pi-remote-import-{focused,root,core,tsan,core-tsan,installed,mac,ios,device}.log` and `/tmp/pi-remote-import-ui-group{1,2,3}.log`. Passing interface summaries are `/tmp/pi-remote-import-ui-group{1,2,3}-summary.json`. No binary test artifacts are committed.

Repeat package checks with the [verified commands](native-apps.md#automated-checks); the current root scratch directory is `/tmp/pi-remote-import-root`, sanitizer scratch directory is `/tmp/pi-remote-import-tsan`. Repeat the installed check with [NativeWorkflowCheck](workflow-verification.md#repeat-the-real-pi-check). Interface tests use the [dedicated compact simulator](interface-verification.md#repeat-the-review).
