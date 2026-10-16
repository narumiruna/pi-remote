# Native workflow verification

## Result

The native workflow implementation has advanced, but `PLAN.md` is not complete. Signed product-device tests, off-site Tailscale, normal installed-extension compatibility and several real-provider paths remain open.

Verified on this Mac with Pi 1.3.0, Xcode 26.6 and the iOS/macOS 26.5 SDKs:

- 47 root package tests pass; the root and shared suites also pass with Thread Sanitizer.
- 18 shared-package tests pass.
- Eight iOS app tests pass on the iPhone 17 Pro simulator, iOS 26.5, with zero failures or skips.
- Both unsigned app builds pass. The unsigned iOS device-SDK build is a compile check, not an installed personal build.
- An isolated check using the installed Pi passes model and thinking changes, input/editor dialogs, editor prefill, idle Stop, directory launch and idle session restoration. It sends no inference prompt.

## History

The new `history-pages` capability adds typed page and entry-preview requests. The older history request remains available. The UI uses paged requests only when the host reports that capability.

History reads companion-owned JSONL files, not remote paths and not an unbounded `get_entries` response. It reads backward in bounded blocks and returns at most 100 entries per page, newest first. Tests visit all 1,205 fixture entries without duplicates, including CRLF and an incomplete trailing append. Parent IDs remain visible. Newer-page navigation caches at most eight pages; reload returns to the newest entries.

Page cursors and preview IDs are opaque, bound to the session and filesystem identity, and expire after five minutes. The host retains at most eight cursors and 2,000 preview references. Repeating a valid read cursor returns the same entry IDs. File replacement, truncation that invalidates a cursor or entry, unknown IDs, malformed records and records over 8 MiB fail closed. Reads check cancellation and do not modify session files. Preview-reference limits also apply when malformed pages fail partway through a read; a regression test exercises repeated failures.

A summary is limited to 512 UTF-8 bytes; an entry preview is limited to 256 KiB and reports truncation. This is paged history inspection, not in-place branch switching. Pi's documented RPC interface cannot navigate to an arbitrary tree entry. Fork remains limited to active-branch user messages and can be rejected by Pi. Terminal-only entry renderers and full image output are not reproduced.

## Transcript and interface

Thinking and text use `contentIndex` during streaming. Completed block content replaces deltas; `message_end` replaces the full partial message. Only `agent_settled` ends automatic work. Thinking signatures and redacted blocks never enter the display DTO. Thinking and answer text share the existing 16 KiB per-message and 256 KiB aggregate budgets. Oversized content is marked as truncated. Empty assistant error messages retain their error text, and custom messages with `display: false` stay hidden.

Foundation parses Markdown. Native views render headings, paragraphs, lists, quotes, tables, code blocks and rules while retaining inline formatting. Tests cover nested lists, incomplete fences and a complete raw-source fallback for oversized tables. Remote images are not fetched, code has no syntax highlighting, and custom terminal renderers remain unsupported. Links open only for `http`, `https` and `mailto` schemes after a user action.

Thinking uses a disclosure. New conversations start at the latest output. Transcript content is clipped to its viewport so it cannot cover the header or composer. The composer limits accessibility-size input to two visible lines to preserve control space.

The app tests host real UIKit-backed SwiftUI views for idle, working, retrying, compacting and interrupted fixtures in light/dark appearance with accessibility text sizes. They also use a reduced 375 × 367-point viewport. The final four working-state captures are retained in the local result bundle for review. A reduced viewport is not a real keyboard or a tested minimum-device claim. Directory/session sheets, VoiceOver, actual keyboard and dictation, and the complete physical coding flow still need review.

## Session and lifecycle protection

All conversation and sheet actions are bound to the displayed host, epoch and session. The client checks that context before dispatch, and the host still checks its epoch and selected session. Stale UI actions, attachments and resend confirmations cannot silently target a newer session. Tests reject wrong-host, wrong-epoch and stale-session actions without dispatch. Sheets reset their local state at a context change.

Mac selection and phone lock invalidate earlier asynchronous callbacks. Old connection-task cleanup cannot change a newer connection's progress state. Phone lock clears pending previews, offers and pairing UI, cancels connection work, and leaves accepted Pi work on the Mac.

Editor prefill never overwrites a nonempty draft without an explicit Replace decision. Offers are session-bound; keeping the existing draft sends nothing. Session activation and clone clear old host prefill state. Phone drafts survive session changes and background entry. Tests use isolated preferences and do not overwrite real app drafts. No runtime authentication-bypass flag was added.

Resume compares the session header's absolute working directory with the stored canonical directory and filesystem identity. An accessible symbolic-link alias of that same directory is valid; a different or replaced directory is not. Session paths must still belong to companion storage. This does not make directory selection a tools sandbox.

## Repeat the real Pi check

Run from the repository root on this Mac:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift run NativeWorkflowCheck "$(command -v pi)" \
  /Users/narumi/.bun/install/global/node_modules/@earendil-works/pi-coding-agent/examples/extensions/rpc-demo.ts
```

The second argument is the checked demo extension bundled with the installed Pi. Resolve its path for other installations. The Swift check creates a private temporary wrapper and an isolated Pi config/session directory. It loads only that demo, disables tools, MCP, context files and other resources, and uses offline mode. A dummy, nonfunctional OpenAI key permits local model-selection checks; it is never used for a provider request. The wrapper records the subprocess working directory inside its private fixture. The check verifies that the user's global settings file is unchanged and removes its fixture after shutdown. It does not copy provider credentials or print transcripts, dialog answers or tool output.

This check does not prove normal installed-extension compatibility, active-run steering/follow-up, real compaction, attachments with a provider, or nonempty real-Pi history restoration. Those acceptance checks remain open. See [the original RPC exercise](verification.md#installed-pi-exercise) for its separate, earlier provider-run evidence.

## Failures and external gates

1. The first real-host check compared path strings and rejected a `/var` alias of the same directory. The check now compares canonical filesystem identities. The new resume regression first failed because equivalent directory URLs had different trailing-slash hints. Registered paths now compare canonical paths and filesystem identities rather than URL hints. The test passes valid header aliases and still rejects a different directory.
2. `ImageRenderer` produced blank transcript regions and unsupported-control markers for UIKit-backed controls. The harness now captures a hosted UIKit hierarchy. Fixture safe areas and appearance settings were corrected before review. These failures were not treated as passing visual evidence.
3. A fresh signed Mac build still fails in CodeSign with `errSecInternalComponent`. The session is a Background launch context. No Keychain ACL, password or certificate check was changed. The product apps still need foreground Xcode signing and physical installation; the older diagnostic signature cannot sign this source revision.
4. CoreDevice reports the iPhone 16 Pro connected. Tailscale still reports that phone offline. Off-site acceptance needs the phone connected to Tailscale from a different network; no VPN or routing configuration was changed.
5. Full workflow compatibility remains blocked by terminal-only extension APIs and missing in-place tree navigation. No scope reduction or feature deferral has been accepted.

The local iOS result bundle is `/tmp/pi-remote-workflow-phone-reviewed`. Captures and result bundles are temporary and are not committed. Build/test commands for the package and apps remain in [native app verification](native-apps.md#automated-checks).
