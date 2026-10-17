# Explicit JSONL session import

## Result

Sessions offers **Import JSONL session** on iOS and macOS. The native picker reads a bounded source. The review shows its format version, title, saved Mac directory, entry count and byte count. Import requires a separate confirmation. Cancel keeps the review; Discard clears it.

Versions 1, 2 and 3 are accepted. An omitted version means version 1, as in Pi 1.3.0. Pi migrates legacy files in companion-owned storage; the source remains unchanged. Header-only sessions are valid. Import does not attach to a running terminal session or send a prompt. Imported sessions are marked for interrupted-work review because saved history does not establish tool completion.

## Explicit directory choice

The user can keep a valid saved directory or choose another accessible Mac folder through the native browser. Missing, null or empty saved directories require a choice; the app never substitutes the current directory or home directory. A missing or inaccessible saved folder can also be replaced explicitly.

The review shows both the saved path and chosen path. Clearing the choice disables import if no saved directory exists. Choosing another source clears the prior choice. The browser's **Use this folder** action only changes the review; it does not open Pi. The final confirmation states which directory source will be used.

The caller sends a browser directory ID, not an arbitrary replacement path. The host resolves that ID, checks identity and read/search access, then checks again after the idle-state query. This is directory selection, not an approved-root policy or tools sandbox. Any folder accessible to the companion remains eligible.

An explicit choice changes the managed copy's header `cwd` value. Header formatting can change; message-entry bytes do not. It does not move project files or rewrite paths in saved messages. Opening Pi can load trusted resources in that directory with the Mac user's permissions. The review states these limits. Review imported instructions, file contents and tool output before sending anything.

A separate typed action and advertised capability control directory choice. An older companion cannot silently ignore a new optional directory field and import somewhere else.

## Validation and ownership

- The app and host validate the complete source. Limits are 2 MiB for source and prepared copy, less than 64 KiB for the header, 128 UTF-8 bytes for the Pi ID and 4 KiB for a saved/chosen path. Invalid UTF-8, unknown versions/types, invalid Pi IDs, NUL/relative paths and malformed message roles are rejected.
- Duplicate JSON object keys are rejected at every nesting level, including escaped names. Swift Foundation keeps the first duplicate value; Node keeps the last. Rejecting ambiguity keeps directory review and tree validation consistent with what Pi loads.
- Versions 2/3 require unique entry IDs and existing earlier parents. Canonically equivalent duplicate IDs are rejected, and parent identities must match their exact UTF-8 values. Multiple roots and abandoned branches remain valid. Compaction references must identify an existing entry or the compaction itself. Version 1 validates its linear compaction indexes and permits legacy `hookMessage` roles.
  - Extension-specific details remain opaque. Structural validation is not a trust decision or a complete content-schema validator.
- Framing splits LF bytes, accepts CRLF and preserves Unicode separators inside strings. Preparation removes leading blank lines and adds a missing final LF. This makes the first physical line a header and keeps later Pi appends on separate lines. Size checks apply after preparation; nothing is truncated.
- Working sessions reject import. Both actions check the displayed session, use the mutation journal and share the session-operation guard. Repeating an accepted request ID cannot make another copy. Reusing it with a different directory returns conflict.
- Validation precedes storage creation and Pi replacement. Missing/invalid directory IDs, file IDs, removed folders, denied access, malformed history and stale-session requests preserve the current session and catalog. There is no fallback to the saved directory when a chosen directory fails.
- Each import gets a new companion ID and private `0700` folder. The copied file retains its Pi ID and uses `0600`. The caller cannot choose a destination. Pi owns the copy after activation and can migrate it or append runtime metadata; the source remains unchanged.
- Launch failure can leave the copied catalog item for explicit recovery. No prompt or import retry occurs automatically.
- Pi's `session_before_switch` lifecycle equivalence remains open. No feature exclusion has been approved, and this does not complete `PLAN.md`.

## Verified checks

- All 79 root tests pass normally and with Thread Sanitizer. Eleven base-import cases cover source preservation, normalization, permissions, deduplication, close/resume, legacy versions, malformed/ambiguous data, missing/inaccessible directories, working state and stale requests. Ten directory-choice cases cover a different directory, absent header/path, symbolic-link selection, removed/denied folders, file/unknown IDs, working state and stale sessions.
- Process checks verify the actual child directory with `/bin/pwd -P` and filesystem identity. They verify the copied header and unchanged message bytes, source and prompt-dispatch marker. Failed choices never fall back or add a session.
- Production authenticated TLS tests pass normal import and explicit directory choice on loopback, LAN and Tailscale. They check the copy, real child directory and no prompt dispatch. Revoked connections cannot import or export.
- All 34 shared tests pass normally and with Thread Sanitizer. They cover preparation, missing directories, byte preservation, copy size, action round-trips, escaped/nested duplicate keys, quoted string values, exact parent identities, versions 1–3, compaction, CRLF, Unicode separators, header-only files, invalid IDs and size rejection.
- Isolated Pi 1.3.0 `NativeWorkflowCheck` passes actual legacy migration, source preservation, close/resume and HTML/JSONL export. A source without a directory first fails without changing selection, then opens in the explicitly chosen folder with its original path text unchanged. No inference or real credential operation occurs; global settings remain unchanged.
- Unsigned Mac, simulator and iOS device-SDK builds pass.
- All fifteen compact-interface tests pass in completed batches (one, four, six and four), with no skips. The new case verifies disabled import without a path, nested Mac folder selection, clear/reselect, confirmation, restored text, no working run and the chosen path in Session controls. Existing legacy/version-3 picker, keyboard, export and recovery checks also pass.

## Failure record

The fixture exposes only synthetic Documents through its own Info.plist; product targets do not enable file sharing. Early picker checks needed the correct fixture phase and Browse → On My iPhone → fixture folder. The CRLF check found Swift Character framing behavior; validation now splits LF bytes. Header-only input without final LF exposed the header reader's requirement; prepared copies now have complete line endings. Leading blank lines are removed from the copy before activation.

The first child-directory assertion compared path strings. On this Mac, `/var` and `/private/var` identify the same object; the check now compares filesystem identity from the actual process directory. A direct Swift/Node parser check established the duplicate-key mismatch. Ambiguous headers and cycle-producing duplicate parents are now rejected before Pi receives the copy; no deliberately cyclic Pi process was started.

Logs: `/tmp/pi-remote-import-directory-{core,core-tsan,root,tsan,installed,mac,ios,device}.log`. Passing UI summaries are `/tmp/pi-remote-import-directory-ui-group{1,2,3,4}-summary.json`. Prior checkpoints remain under `/tmp/pi-remote-session-files-*` and `/tmp/pi-remote-import-*`. No binary artifacts are committed. Use the [verified commands](native-apps.md#automated-checks), [installed check](workflow-verification.md#repeat-the-real-pi-check) and [compact simulator](interface-verification.md#repeat-the-review). Root scratch directories remain `/tmp/pi-remote-import-root` and `/tmp/pi-remote-import-tsan`.
