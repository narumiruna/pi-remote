# Explicit JSONL session import

## Result

Sessions offers **Import JSONL session** on iOS and macOS. The native file picker reads a bounded source. The review displays its format version, session title, saved Mac directory, entry count and byte count. A separate confirmation opens the imported copy. Cancel keeps the review; Discard clears it.

Versions 1, 2 and 3 are accepted. An omitted version means version 1, as in Pi 1.3.0. Pi migrates legacy files in companion-owned storage; the source remains unchanged. A header-only session is valid. Import does not attach to a running terminal session or send a prompt. Imported sessions are marked for interrupted-work review because saved history does not establish tool completion.

Opening Pi can load trusted resources in the saved directory with the Mac user's permissions. The review states this explicitly. Imported instructions, file contents and tool output can be untrusted; review them before sending anything.

## Validation and ownership

- The app and host both validate the complete input. Limits are 2 MiB per source, less than 64 KiB for its header, 128 UTF-8 bytes for the Pi ID and 4 KiB for the saved directory. Invalid UTF-8, unknown versions/types, invalid Pi ID characters, NUL/relative directory paths and malformed message roles are rejected.
- Versions 2/3 require unique entry IDs and existing earlier parents. Multiple roots and abandoned branches are preserved. Compaction references must identify an existing entry or the compaction itself. Version 1 uses its linear sequence and validates compaction indexes. Legacy `hookMessage` roles are accepted only before version 3.
  - Extension-specific details remain opaque. Structural validation is not a trust decision or a complete content-schema validator.
- Framing splits LF bytes, accepts CRLF and preserves Unicode separators inside JSON strings. It does not split Swift Characters at CRLF.
- The saved Mac directory must exist and permit read/search access. The host resolves symbolic links and records its canonical identity. It does not silently choose another directory.
- Working sessions reject import. The action checks the displayed selected session, uses the mutation journal and shares the session-operation guard. Repeating an accepted request ID cannot create another copy.
- History and directory validation precede storage creation and Pi replacement. Malformed, inaccessible, missing-directory and stale requests preserve the current session and catalog.
- Each import gets a new companion ID and private `0700` folder. The copied file retains the Pi ID and uses permissions `0600`; the caller cannot choose its destination. It is opened only through managed activation.
  - If the source has no final LF, the host adds one to the managed copy before opening it. This keeps later Pi appends on a separate line, including header-only imports. The source file is not changed.
  - Otherwise the initial copy preserves the submitted bytes. Pi owns the copy after activation and can migrate it or append normal runtime metadata. Source preservation does not mean that managed history never changes.
- Launch failure can leave the imported catalog item available for explicit recovery. No prompt or import retry occurs automatically.
- Explicit directory override and Pi's `session_before_switch` lifecycle equivalence remain open compatibility work. No feature exclusion has been approved; this does not establish complete `/import` parity or complete `PLAN.md`.

## Verified checks

- All 78 root tests pass normally and with Thread Sanitizer. Nine import cases cover source preservation, copied bytes/newline normalization, permissions, deduplication, close/resume, no prompt dispatch, legacy versions, malformed input, missing/inaccessible directories, working state and stale requests.
- Authenticated production TLS tests pass import and subsequent active-branch JSONL export on loopback, LAN and Tailscale. They check the private stored history, separate companion session and no prompt dispatch. Revoked connections cannot import or export.
- All 32 shared tests pass normally and with Thread Sanitizer. Cases cover custom IDs, multiple roots, branches, title/version review, CRLF, Unicode separators, old linear and tree compaction, unversioned input, header-only sessions, packet round-trip, broken links, invalid IDs, relative/NUL paths and size rejection.
- Isolated Pi 1.3.0 `NativeWorkflowCheck` passes real versions 1–3 import. It verifies restored user text, migrated custom messages, version-3 archives, unchanged sources, header-only import, close/resume and subsequent HTML/JSONL export. No inference or real credential operation occurs; global settings remain unchanged.
- Unsigned Mac, iOS simulator and iOS device-SDK builds pass.
- All fourteen compact-interface tests pass in three completed batches (four, six and four tests), with no skips. The import test chooses a real legacy JSONL source, verifies its directory and migration warning, cancels confirmation, confirms import and checks restored text without a working run. Earlier native-picker checks also passed version-3 input.

## Failure record

The UI fixture exposes only synthetic Documents through an explicit fixture-only Info.plist; product targets do not enable file sharing. Early UI runs failed because the fixture phase was not selected and the picker opened Recents rather than Browse. The passing check follows Browse → On My iPhone → fixture folder.

The initial CRLF test found Swift Character framing behavior; validation now splits LF bytes. A cached root SwiftPM graph omitted a new shared source; a fresh scratch directory discovered it without dependency changes. A header-only import without final LF exposed the host header reader's line-ending requirement. The managed-copy newline rule now handles that case before Pi opens it and prevents subsequent appends from joining an existing record.

Current logs: `/tmp/pi-remote-session-files-{root,core,tsan,core-tsan,installed,mac,ios,device}.log`. Passing interface summaries are `/tmp/pi-remote-session-files-ui-group{1,2,3}-summary.json`. Earlier import logs remain under `/tmp/pi-remote-import-*`. No binary test artifacts are committed. Use the [verified build commands](native-apps.md#automated-checks), [installed-Pi check](workflow-verification.md#repeat-the-real-pi-check) and [dedicated compact simulator](interface-verification.md#repeat-the-review). Current root scratch directories are `/tmp/pi-remote-import-root` and `/tmp/pi-remote-import-tsan`.
