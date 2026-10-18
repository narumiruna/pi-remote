# Native display of Pi extension UI

## Result

Pi can send text widgets, footer status entries and notification severity through its standard RPC protocol. A generic Swift display can preserve these fields without an extension adapter. Pi cannot send custom terminal component factories through this protocol.

The supplied reference has two different surfaces: Progress above the ruled editor, and a segmented footer below it. These do not use the same API. Progress has a standard text-widget RPC path in the installed package. The installed Starship footer is TUI-only. Its segments are not available to the native app through RPC.

This document records read-only source research and the mapping design. The follow-up now implements generic status, widget-placement and notification-severity data; see the separate [implementation and verification record](pi-like-mac-verification.md). A custom presentation-title surface remains outside that change. The supplied references have not established final native visual acceptance.

## Sources and inspection limits

Installed package metadata reports Pi **1.3.0**, `@narumitw/pi-progress` **0.6.1**, and `@narumitw/pi-starship` **0.59.1**. These are inspected versions, not a broader compatibility claim.

Exact local roots:

| Name | Path |
| --- | --- |
| Pi | `/Users/narumi/.bun/install/global/node_modules/@earendil-works/pi-coding-agent` |
| Progress | `/Users/narumi/.pi/agent/npm/node_modules/@narumitw/pi-progress` |
| Starship | `/Users/narumi/.pi/agent/npm/node_modules/@narumitw/pi-starship` |

Paths below are relative to these roots unless they start with a repository directory.

| Source | Evidence |
| --- | --- |
| Pi `docs/extensions.md`, `docs/tui.md`, `docs/rpc-extension-ui.md` | Extension modes, component model and RPC limits; read in full |
| Pi `README.md`, `docs/rpc.md`, `docs/rpc-commands.md`, `docs/json.md`, `docs/themes.md` | Protocol, state/statistics, events and terminal theme context; read in full |
| Pi `dist/modes/rpc/rpc-mode.js:83–219` | Actual RPC `createExtensionUIContext` implementation |
| Pi `dist/modes/rpc/rpc-types.d.ts:405–483` | `RpcExtensionUIRequest` and `RpcExtensionUIResponse` unions |
| Pi `dist/core/extensions/types.d.ts:46–185` | `WidgetPlacement`, `ExtensionWidgetOptions`, `ExtensionUIContext` and component factory signatures |
| Pi `dist/modes/interactive/components/footer.js:252–263` | Built-in footer sorts extension statuses by key |
| Pi `examples/extensions/{widget-placement,custom-footer,modal-editor,rpc-demo}.ts`, `examples/rpc-extension-ui.ts` | Standard widget, footer, editor and RPC examples; read without execution |
| Progress `src/progress-widget.ts:35–137`, `src/progress-renderer.ts` | RPC text snapshots, TUI factories, placement, themed lines and completion clearing |
| Progress `dist/index.ts:800–890` | Generated runtime contains the same RPC branch |
| Starship `src/pi-starship.ts:243–266`, `:580–610` | TUI-only footer installation and footer input data |
| Starship `src/modules/extension-status.ts` | A terminal module can include other extensions' status text |
| Starship `dist/index.ts:997–1003` | Generated runtime contains the same TUI guard |
| Progress and Starship `package.json`, `README.md` | Versions and declared `./dist/index.ts` extension entry points; package READMEs read in full |
| `Packages/PiRemoteHost/Sources/PiRemoteHost/HostCoordinator.swift:1700–1753` | Existing extension request reduction and notice flattening |
| `Packages/PiRemoteCore/Sources/PiRemoteCore/AppState.swift` | Current `notices: [String]` display contract |
| `Packages/PiRemoteCore/Sources/PiRemoteCore/TranscriptReducer.swift:4–13` | `DisplayLimit.text` bounds UTF-8 text; it is not an ANSI sanitizer |

Repository context: [README](../README.md), [PLAN](../PLAN.md), and the existing [compatibility review](native-compatibility.md#standard-extension-ui-mapping). That review already records widget placement, severity and title presentation as retained differences.

No extension was loaded, imported or executed for this research. No provider, authentication, personal configuration, saved conversation or network resource was accessed. Source references to settings and credentials describe code, not inspected user data. Package presence does not prove that a package was loaded in the pictured terminal session.

## Exact RPC contract

Every UI request has `type: "extension_ui_request"`, a unique `id`, and `method`. Only dialogs need `extension_ui_response`. Do not acknowledge fire-and-forget display requests as dialogs.

| API | Wire `method` and payload | Native meaning |
| --- | --- | --- |
| `setWidget(key, stringArray, options)` | `"setWidget"`; `widgetKey`, `widgetLines: string[]`, optional `widgetPlacement` | Replace the complete text block for this widget key |
| `setWidget(key, undefined)` | `"setWidget"`; `widgetKey`, omitted `widgetLines` | Clear that widget key |
| `setStatus(key, text)` | `"setStatus"`; `statusKey`, `statusText` | Replace the footer/status-bar entry for this status key |
| `setStatus(key, undefined)` | `"setStatus"`; `statusKey`, omitted `statusText` | Clear that status key |
| `notify(message, type)` | `"notify"`; `message`, optional `notifyType` | Append a notification with severity |
| `setTitle(title)` | `"setTitle"`; `title` | Change a presentation title; not the persisted session name |
| `setEditorText(text)` | `"set_editor_text"`; `text` | Offer an editor-text update through the existing draft-consent path |

Important distinctions:

- The widget API accepts a **string array**, not a single string. It also accepts a custom component factory in TUI mode.
  - RPC emits a request only when the content is `undefined` or an array. A factory is ignored. Pi does not call it, serialize it, or send its rendered output.
- The API option is `options.placement`. The wire field is **`widgetPlacement`**.
  - Values are `"aboveEditor"` and `"belowEditor"`. An omitted placement means `"aboveEditor"`.
- `notifyType` is `"info"`, `"warning"` or `"error"`. An omitted value means `"info"`.
  - Status entries and widgets have no severity field. Do not infer severity from their key or text.
- JavaScript `undefined` fields are omitted in JSON. Omission is the documented clear signal. Do not require a JSON `undefined` literal or substitute a new custom message.
- Widget and status keys have separate namespaces. The same string can identify one of each.
- Widget lines can contain ANSI styling produced by Pi's terminal theme. The protocol sends text lines, not semantic progress steps, native colors, layout constraints or a component tree.

Example standard widget request:

```json
{"type":"extension_ui_request","id":"widget-1","method":"setWidget","widgetKey":"example","widgetLines":["Progress","Inspect source","Run focused checks"],"widgetPlacement":"aboveEditor"}
```

Example clear request:

```json
{"type":"extension_ui_request","id":"widget-2","method":"setWidget","widgetKey":"example"}
```

Dialogs remain separate: `select` carries `title`, `options`, optional `timeout`; `confirm` carries `title`, `message`, optional `timeout`; `input` carries `title`, optional `placeholder` and `timeout`; `editor` carries `title` and optional `prefill`. Responses use the same `id`, with `value`, `confirmed`, or `cancelled: true`. The installed `editor` implementation does not emit a timeout field.

## How the terminal reference maps

### Progress above the editor

The installed Progress package defines `WIDGET_KEY = "progress"` and `{ placement: "aboveEditor" }`. Its `publish` function chooses between two paths:

1. RPC: call `renderProgressWidget(...)` at **80 columns**, then send the returned `string[]` through `setWidget`.
2. TUI: give `setWidget` a factory whose `render(width)` receives the actual terminal width and terminal row count.

The renderer adds the Progress header, rule, symbols, counts and theme styling. RPC uses the default **36-row** sizing budget because it has no client dimensions. Completing all steps publishes a summary, then clears the widget after **3,000 ms**. These are package behavior, not rules for the native client.

A native client should display the received text block above its own ruled editor. It must not inspect the `progress` key, import this package, reconstruct its tool details, duplicate its completion timer or invent an editable task list. The same generic path must work for any widget key. The app cannot recover text already hidden or truncated by the producer's 80-column snapshot.

### Segmented footer

Starship's `installFooter` assigns an active target only when `ctx.mode === "tui"`. It clears its `starship` status and returns without installing the footer in RPC mode. In TUI mode it calls `setFooter(factory)` and renders from session, usage, Git, workspace and extension-status data.

Its `extension_status` module reads `footerData.getExtensionStatuses()`. Thus a pictured terminal footer can combine its own segments with ordinary `setStatus` producers, including usage or keep-awake indicators. That does **not** make the complete custom footer transportable.

The screenshots alone do not establish which package produced each segment. This inspection did not inspect the user's Starship configuration or verify usage/caffeinate producers. Generic mapping is sufficient:

| Reference area | Standard native source | Boundary |
| --- | --- | --- |
| Progress block | `setWidget` text and placement | Available if the extension emits string lines in RPC |
| Ruled editor | Native app editor | Not a transported editor component |
| Extension status text | `setStatus` key and text | Available only if that producer emits it in RPC |
| Model/thinking/session usage | Existing typed Pi state and statistics | App-owned presentation, not Starship output |
| Custom colors, separators, segment order and extra modules | No standard custom-footer record | Cannot reproduce the extension's footer from RPC |

`get_state` exposes `model` and `thinkingLevel`. `get_session_stats` exposes `tokens`, `cost`, and optional `contextUsage` with `tokens`, `contextWindow`, `percent`. These are not provider account quota or a keep-awake state. Do not invent missing values or read credentials/configuration to fill footer gaps.

## Information lost by the pre-follow-up host

At baseline commit `a66fc3a`, `HostCoordinator` has `statuses: [String: String]` and `notifications: [String]`.

- `setStatus` and `setWidget` share the same reduction branch.
  - Internally the key is `method + ":" + rawKey`, so the two namespaces remain distinct there.
  - `widgetLines` becomes one string joined with `"\n"`. The original array boundaries are lost.
  - `widgetPlacement` is never read.
  - Empty content and omitted content both remove the entry.
  - The two kinds share a 16-entry limit. Each value is truncated to 2,048 UTF-8 bytes without a typed truncation marker.
- `refreshNotices()` copies only `statuses.values` into `snapshot.notices`.
  - Clients lose the key, kind and stable ordering. They cannot distinguish a footer status from an editor widget or update a keyed view directly.
  - Recovery notices, persistent extension display and notifications become one `[String]` surface.
- The generic fallback appends `message` or `title` to notifications.
  - It discards `notifyType` and request identity.
  - `setTitle` becomes an ordinary notification instead of a presentation-title update.
  - Only the most recent eight notification strings remain.

The host still preserves text newlines in the joined string. It does not preserve widget structure or placement. Native view styling cannot recover fields already removed at this boundary.

## Generic Swift mapping and remaining design

Keep the existing Swift host, authenticated session snapshots and native views. Add no backend, Pi-side bridge or extension-specific decoder.

Use typed `Codable`/`Sendable` display state for these distinct responsibilities:

| Value | Minimum fields |
| --- | --- |
| Extension status | Opaque `key`, `text` |
| Extension widget | Opaque `key`, ordered `lines`, `placement` enum (`aboveEditor`, `belowEditor`) |
| Extension notification | Request `id`, `message`, severity enum (`info`, `warning`, `error`) |
| Extension presentation title | Optional title text, separate from the persisted session name |

Apply requests at the host boundary and publish the typed result through the existing snapshot path:

1. Replace or clear widgets/statuses by their own key and namespace. Preserve each widget's line order and placement. Sort independent entries by key for deterministic display; do not infer extension priority.
2. Render `aboveEditor` widgets immediately above the ruled editor. Render `belowEditor` widgets immediately below it and before the footer. Place status entries in the footer/status area, separate from widget blocks.
3. Render notifications as native notices with a visible severity label and accessible meaning. Color alone must not convey warning or error.
4. Use bounded native text. Remove terminal control sequences for the minimal plain-text display; do not execute cursor movement, OSC commands or terminal hyperlinks. Preserve Unicode text and line breaks.
   - ANSI SGR styling may be added only through a bounded generic parser with focused tests. It must not interpret extension keys or become a terminal emulator.
   - Plain native text is not exact terminal-theme or font reproduction.
5. Keep explicit count/byte/line bounds and report truncation or capacity loss. Preserve the existing bounded-state protections; do not replace them with unlimited widget storage.
6. Include current typed display state in session snapshots and replay. Clear it when the owning runtime/session is replaced. Reject stale-generation updates. Do not resend extension commands to rebuild display state.
   - Standard RPC has no command to read back all current widgets/statuses. Host-retained state can survive client reconnect, not an arbitrary Pi process restart.
7. Keep editor updates on the existing consent path. Keep presentation-title changes separate from `set_session_name`. Neither operation submits a prompt.
8. Keep routine logs free of widget/status/notification content. These fields can contain private work text.

The field names above describe proposed app types, not additions to Pi's protocol. The app should not expose a general raw-RPC forwarding API.

Focused acceptance checks below define the mapping. This source research did not execute them; follow-up tests are recorded in the [verification record](pi-like-mac-verification.md):

- Two arbitrary keys, including the same key in both namespaces, replace and clear independently.
- Omitted placement uses `aboveEditor`; `belowEditor` stays below the editor after snapshot/reconnect.
- Multi-line Unicode widgets retain line order. Missing lines clear a widget. Empty arrays have no visible block.
- All three severities and the omitted-severity default remain distinct after transport.
- Bounds, truncation, ANSI/control removal, stale-generation rejection and runtime replacement remain safe.
- Title changes do not rename sessions. Draft updates do not overwrite nonempty text without consent.
- A generic fixture, with no installed extension imports, verifies the mapping. A normal native-app review checks positioning separately from protocol tests.

## Unsupported custom UI and approval boundary

In installed RPC mode:

- `setHeader`, `setFooter`, `setEditorComponent`, `addAutocompleteProvider`, `setToolsExpanded`, `setWorkingMessage`, `setWorkingVisible`, `setWorkingIndicator`, and `setHiddenThinkingLabel` are no-ops.
- `custom()` resolves to `undefined`; no component, overlay, keyboard handler or layout reaches the client.
- `onTerminalInput()` returns a no-op unsubscribe function.
- `getEditorText()` returns `""`; `getEditorComponent()` returns `undefined`; `getToolsExpanded()` returns `false`.
- `pasteToEditor()` delegates to `setEditorText()`, without terminal paste handling.
- `getAllThemes()` returns `[]`; `getTheme()` returns `undefined`; `setTheme()` returns `{ success: false, error: "Theme switching not supported in RPC mode" }`.
- `ctx.mode` is `"rpc"` and `ctx.hasUI` is `true`. `hasUI` does not prove that terminal-only APIs work.

There is no missing Swift renderer that can recover an ignored factory. A custom header/footer/editor is executable JavaScript tied to Pi's TUI. It is not a declarative native view description.

Options:

1. **Stay within the accepted scope:** preserve the standard typed display data and use an app-owned native footer. Clearly retain the custom-terminal differences. No extension adapter is required.
2. **Request exact custom UI transport:** obtain explicit approval for a scope change before adding or modifying a Pi-side adapter, an individual extension, upstream Pi, or a custom protocol. This requires a separate design and verification plan; it is not implemented here.
3. **Use terminal mirroring:** this conflicts with the no-embedded-terminal requirement and needs explicit product approval. It is not a proposed implementation for the current app.

## Verification record

Verified by static inspection: installed versions, declared runtime entry points, exact RPC fields, factory/no-op behavior, Progress's string-line RPC branch, Starship's TUI-only footer guard, and baseline host flattening. The implemented typed widget stores joined text with preserved line order, not a custom component tree. Native notices use stable host-generated display IDs. `setTitle` retains the earlier info-notice mapping; it does not rename the session or recreate a custom header.

Not run: extension execution, provider calls, authentication/configuration reads, live terminal capture, native app builds/tests, or screenshot-to-app comparison. This research alone adds no runtime behavior and closes no implementation acceptance item; the linked follow-up record reports code checks separately.
