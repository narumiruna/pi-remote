# Installed Pi release notes

## Implemented behavior

Open **Session controls → Pi release notes** on either app. This read-only view does not require an active session. Previous, Next and Reload read the selected installation's `CHANGELOG.md`; they do not start Pi, call a provider or change settings.

The host resolves the selected executable's symbolic link. It accepts only a package manifest named `@earendil-works/pi-coding-agent` whose `bin.pi` resolves to that executable inside the package. The request accepts an offset and revision, not a file path. Unknown wrappers and standalone layouts report that the feature is unavailable. Only the installed npm-style Pi 1.3.0 layout has real-runtime evidence.

The document limit is 1 MiB. Each page contains at most 32 KiB of complete UTF-8 text. The host rejects nonregular resources, final-component symbolic links, invalid UTF-8 and invalid offsets. The SHA-256 revision covers the version and document bytes. A package update between page requests expires the view; Reload starts a new read. The UI retains at most 64 previous offsets, not full pages.

The native view shows selectable source text in file order. It does not render Markdown, normalize links, open URLs or update Pi's last-viewed version. Installed Pi's terminal `/changelog` reads the same resource, parses version sections, reverses their order and normalizes links before rendering Markdown. This is evidence for access to the same release notes, not identical terminal presentation or full workflow parity.

## Verification checkpoint

- 83 root tests pass normally and with Thread Sanitizer. Release-note tests cover empty/exact-size limits, Unicode page boundaries and complete reconstruction, executable identity, revision expiry, invalid offsets, invalid UTF-8, oversized resources, symlink/directory rejection, stale host epochs and revoked authorization. The host action passes with no active session and an empty, nonexecutable fixture entry point.
- 35 shared tests pass normally and with Thread Sanitizer, including typed request/result round trips, read-only/session-independent classification and malformed page rejection.
- `NativeReleaseNotesCheck` passes normally and with Thread Sanitizer against the installed Pi: all 644,403 resource bytes match across 20 typed native-host pages, without starting a Pi child or requesting inference.
- Three focused compact-interface tests pass with no skips: release-note navigation/reload, runtime settings and session usage. The new test checks Previous/Next state, version, page content and Reload at large text size. Capture review found an awkward three-button wrap; a two-row control layout replaced it and the tests passed again. The other thirteen interface checks were not rerun at this checkpoint.
- Unsigned Mac, iOS simulator and iOS device-SDK builds pass. No signing, hardware or off-site claim is made.

Run the installed-resource check from the repository root after the package checks:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift run NativeReleaseNotesCheck "$(command -v pi)"
```

The probe uses temporary companion storage and removes it after the check. It compares the native result with the installed resource directly. The broader compatibility requirements in `PLAN.md` remain open.
