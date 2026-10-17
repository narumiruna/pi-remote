# Session tree inspection

## Behavior

**History → Session tree and fork options** opens a read-only view of Pi's `get_tree` result. It shows exact entry and parent IDs, entry kinds, resolved labels, actual label timestamps and the active leaf in that snapshot. It does not navigate the active branch or modify JSONL leaf state.

Fork buttons use `get_fork_messages`, not a guess based on message role. Pi 1.3.0 includes eligible text from abandoned branches. Empty-text and image-only messages are excluded; nonempty whitespace remains eligible. The installed command reference describes an active-branch restriction for `fork`, but the installed runtime accepts the abandoned-message case tested below. The app follows the runtime's authoritative options and rechecks them immediately before dispatch.

A fork creates a managed branch and puts the selected text in its draft. It does not send that text as a prompt. Pi extracts fork text by joining text blocks without separators. Full history previews keep their display block separators. These two strings can therefore differ without data loss.

Existing file-history paging and full text/image entry previews remain available. The older `history` operation returns up to 1,000 read-only summaries. Neither it nor file pages claim fork eligibility; use the tree inspector for that action.

## Consistency and limits

- Tree pages contain at most 100 nodes. The bounded mapper accepts at most 10,000 nodes and fork options.
- IDs are at most 128 UTF-8 bytes. Labels and text previews are at most 512 bytes. Partial text is marked. Unsupported or oversized structures fail explicitly.
- Traversal is iterative. Duplicate IDs, cycles, inconsistent parent links and invalid leaves are rejected. Documented orphan roots retain their missing parent ID.
- The host serializes inspection with other app actions. It checks the selected session, child generation, run revision and managed-file revision around suspended reads.
- Two tree reads surround the fork-option read. Detected changes return a conflict; the app does not combine a known inconsistent tree and option list.
  - Upstream Pi core RPC has no atomic combined inspection operation. These checks cannot establish upstream atomicity against every independent extension change.
- Cursors are opaque, session-bound and valid for five minutes. The host retains at most two snapshots and 32 tree cursors. The view retains at most eight previous pages.
- Full-preview indexing scans each unchanged session/file revision once, using at most 32 MiB, 10,000 entries and 64 KiB reads. At most two offset indexes remain cached for five minutes. File revision changes invalidate them. Existing preview references are bounded to 2,000. Pi's 8 MiB record limit and app frame limits also apply.
- Canonical visible `custom_message` entries retain their full text and original image references in entry previews. Hidden entries remain suppressed, including summary fallbacks.
- A session change, file revision or run change invalidates the relevant snapshot. Reload after an expired cursor. Preview tokens cannot cross sessions.

These limits apply to app inspection, not to Pi's complete persisted history. No arbitrary remote file path or raw RPC endpoint is exposed.

## Verified checkpoint

A separate Herdr Pi agent implemented the bounded mapper, native inspector and integration checks. Parent inspection confirmed the source and result logs.

- The later [acceptance checkpoint](core-rpc-acceptance.md) passes 135 root tests normally and with Thread Sanitizer. Inspection cases cover three-page traversal, labels/timestamps/leaf, text and image previews, authoritative fork rejection, an abandoned branch, read serialization, changed snapshots, active-work races, bounded retained snapshots, custom-message visibility/images and cached scan reuse/invalidation.
- 50 shared tests pass normally and with Thread Sanitizer, including inspection DTO round trips and the upstream Pi core event boundary cases.
- The pure mapper also passes 10,000-deep and 10,000-wide fixtures without recursive traversal. This does not test decoding a 10,000-deep JSON wire record.
- `NativeInspectionCheck` passes against installed Pi 1.3.0 normally and with Thread Sanitizer. It imports 217 entries through the supported import action, checks three-page inspection against Pi's own session-manager tree, validates exact labels/timestamps/leaf, reads full text and original image bytes, forks an abandoned message and verifies draft/catalog, close/reopen and host-restart restoration.
- The installed check denies network access at the OS level and verifies zero input/run/provider/user events, tokens or cost. Source bytes and real settings remain unchanged. Recorded children stop before private fixture removal.
- One navigation/error-recovery interface test passes. All three populated cases also pass on the iPhone 17 Pro simulator, with no failures or skips: exact leaf/label timestamp and paging; full text and original image previews; and eligible abandoned-branch fork with a retained, unsent draft. Parent review confirms all five captures. The final compact audit also passes all 27 interface tests at accessibility-extra-large, including these four inspection cases; see [acceptance evidence](core-rpc-acceptance.md#delegated-compact-interface-audit).

Evidence:

- `/tmp/pi-remote-worker-inspection-integration-{root-final,root-tsan-final,shared,shared-tsan}.log`
- `/tmp/pi-remote-worker-inspection-integration-ui-summary.json`
- `/tmp/pi-remote-worker-inspection-native-{normal,tsan}.log`
- `/tmp/pi-remote-worker-inspection-populated-build.log`
- `/tmp/pi-remote-worker-inspection-populated-final-summary.json`
- `/tmp/pi-remote-worker-inspection-populated-final-captures/`

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --filter inspection
swift run NativeInspectionCheck "$(command -v pi)"
swift run --sanitize=thread --scratch-path /tmp/pi-remote-inspection-tsan NativeInspectionCheck "$(command -v pi)"
```

These are local development results, not hardware, off-site or release-support claims. Same-process core session lifecycle and final app regressions also pass their separate checks in the [acceptance record](core-rpc-acceptance.md).
